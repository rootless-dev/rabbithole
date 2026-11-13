package uploader

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
)

// Multipart is what is needed to continue a multipart upload later, after the
// process that started it stopped: where it lives in S3, how the file was cut
// into parts, which file it was made from and which parts are done.
type Multipart struct {
	Key      string
	UploadID string // the S3 upload id
	PartSize int64
	// FileSize and ModTimeNanos identify the local file at the moment the
	// multipart upload started; a file that differs now cannot be continued.
	FileSize     int64
	ModTimeNanos int64
	Parts        []CompletedPart // the parts completed so far, in number order
}

// HeldPart is a part S3 reports for a multipart upload.
type HeldPart struct {
	Number int32
	ETag   string
	Size   int64
}

// recorded hands the full record of the multipart upload to cb.
func recorded(cb Callbacks, m Multipart) {
	if cb.MultipartRecorded != nil {
		m.Parts = append([]CompletedPart(nil), m.Parts...)
		cb.MultipartRecorded(m)
	}
}

// recordEnded tells cb that there is no multipart upload to continue any more.
func recordEnded(cb Callbacks) {
	if cb.MultipartEnded != nil {
		cb.MultipartEnded()
	}
}

// discard aborts a multipart upload on a best-effort basis and ends its record.
func discard(ctx context.Context, s3 S3, m Multipart, cb Callbacks) {
	abortCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), abortTimeout)
	defer cancel()
	if err := s3.AbortMultipart(abortCtx, m.Key, m.UploadID); err != nil && !errors.Is(err, ErrNoSuchUpload) && cb.AbortFailed != nil {
		cb.AbortFailed(err)
	}
	recordEnded(cb)
}

// resumeMultipart continues the multipart upload of req.Resume. handled is
// false when the file has to be sent from the start: it changed, S3 does not
// know the upload any more, or S3 would not say which parts it holds. In that
// case the old multipart upload is gone (or was never there) and its record
// ended. When handled is true, err is how the continued upload ended.
func resumeMultipart(ctx context.Context, s3 S3, req Request, info os.FileInfo, progress *progressTracker, cb Callbacks) (handled bool, err error) {
	m := *req.Resume
	if !UseMultipart(info.Size()) || m.FileSize != info.Size() || m.ModTimeNanos != modTimeNanos(info) {
		discard(ctx, s3, m, cb)
		return false, nil
	}
	held, start, err := heldParts(ctx, s3, m, cb)
	if start {
		return false, nil
	}
	if err != nil {
		return true, err
	}

	f, err := os.Open(req.LocalPath)
	if err != nil {
		return true, fmt.Errorf("%w: %v", ErrFileUnreadable, err)
	}
	defer f.Close()
	if cb.KeyResolved != nil {
		cb.KeyResolved(m.Key)
	}
	have := validParts(held, m.FileSize, m.PartSize)
	m.Parts = m.Parts[:0:0]
	for number := int32(1); int64(number-1)*m.PartSize < m.FileSize; number++ {
		if etag, ok := have[number]; ok {
			m.Parts = append(m.Parts, CompletedPart{Number: number, ETag: etag})
		}
	}
	recorded(cb, m)
	return true, sendParts(ctx, s3, f, m, progress, cb)
}

// heldParts asks S3 which parts it holds for m. startOver is set when the upload
// cannot be continued: S3 does not know it (nothing to abort), or would not say
// what it holds (the upload is aborted). Either way its record has ended.
func heldParts(ctx context.Context, s3 S3, m Multipart, cb Callbacks) (held []HeldPart, startOver bool, err error) {
	held, err = s3.ListParts(ctx, m.Key, m.UploadID)
	switch {
	case errors.Is(err, ErrNoSuchUpload):
		recordEnded(cb)
		return nil, true, nil
	case errors.Is(err, ErrListPartsDenied):
		discard(ctx, s3, m, cb)
		return nil, true, nil
	}
	return held, false, err
}

// validParts returns the ETag of each held part that has the size it must have
// in a file of fileSize cut in parts of partSize. A part of another size, from
// a different cut, is sent again.
func validParts(held []HeldPart, fileSize, partSize int64) map[int32]string {
	have := make(map[int32]string, len(held))
	for _, p := range held {
		offset := int64(p.Number-1) * partSize
		if p.Number >= 1 && offset < fileSize && p.Size == min(partSize, fileSize-offset) {
			have[p.Number] = p.ETag
		}
	}
	return have
}

// uploadMultipart starts a multipart upload of the file and sends it.
func uploadMultipart(ctx context.Context, s3 S3, key, path string, size int64, modNanos int64, progress *progressTracker, cb Callbacks) error {
	f, err := os.Open(path)
	if err != nil {
		return fmt.Errorf("%w: %v", ErrFileUnreadable, err)
	}
	defer f.Close()

	uploadID, err := s3.CreateMultipart(ctx, key)
	if err != nil {
		return err
	}
	m := Multipart{Key: key, UploadID: uploadID, PartSize: PartSize(size), FileSize: size, ModTimeNanos: modNanos}
	recorded(cb, m)
	return sendParts(ctx, s3, f, m, progress, cb)
}

// sendParts sends the parts of m that are not in m.Parts and completes the
// upload. A failure leaves the multipart upload in S3, for a later attempt to
// continue: only a rejected completion aborts it, because retrying would be
// rejected the same way.
func sendParts(ctx context.Context, s3 S3, f *os.File, m Multipart, progress *progressTracker, cb Callbacks) error {
	have := make(map[int32]string, len(m.Parts))
	var done int64
	for _, p := range m.Parts {
		have[p.Number] = p.ETag
		done += min(m.PartSize, m.FileSize-int64(p.Number-1)*m.PartSize)
	}
	progress.advance(done)

	var parts []CompletedPart
	for offset, number := int64(0), int32(1); offset < m.FileSize; offset, number = offset+m.PartSize, number+1 {
		if etag, ok := have[number]; ok {
			parts = append(parts, CompletedPart{Number: number, ETag: etag})
			continue
		}
		if err := ctx.Err(); err != nil {
			return err
		}
		length := min(m.PartSize, m.FileSize-offset)
		base := done
		body := &sectionBody{
			r:      io.NewSectionReader(f, offset, length),
			size:   length,
			onRead: func(n int64) { progress.advance(base + n) },
		}
		etag, err := s3.UploadPart(ctx, m.Key, m.UploadID, number, body, length)
		if err != nil {
			return err
		}
		done += length
		part := CompletedPart{Number: number, ETag: etag}
		parts = append(parts, part)
		if cb.PartDone != nil {
			cb.PartDone(part)
		}
		progress.advance(done)
	}
	return completeMultipart(ctx, s3, m, parts, cb)
}

func completeMultipart(ctx context.Context, s3 S3, m Multipart, parts []CompletedPart, cb Callbacks) error {
	err := s3.CompleteMultipart(ctx, m.Key, m.UploadID, parts)
	switch {
	case err == nil:
		recordEnded(cb)
	case errors.Is(err, ErrPreconditionFailed):
		discard(ctx, s3, m, cb)
	}
	return err
}

// modTimeNanos is the modification time of the file as it is recorded.
func modTimeNanos(info os.FileInfo) int64 { return info.ModTime().UnixNano() }
