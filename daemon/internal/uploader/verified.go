package uploader

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"os"
	"strconv"
)

// CheckedS3 is an S3 that can have the service verify what it receives. Every
// checksum is the base64 SHA-256 of the bytes, computed from the local file
// before the body is sent; S3 rejects a body that does not match it and the
// implementation reports that as ErrChecksumMismatch. The body stays a plain
// reader: nothing is seeked and nothing is hashed on the way out.
type CheckedS3 interface {
	S3
	// PutObjectChecked is PutObject with the body's SHA-256 declared.
	PutObjectChecked(ctx context.Context, key string, body io.Reader, size int64, sha256 string) error
	// CreateMultipartChecked starts a multipart upload whose parts carry
	// SHA-256 checksums.
	CreateMultipartChecked(ctx context.Context, key string) (uploadID string, err error)
	// UploadPartChecked is UploadPart with the part's SHA-256 declared.
	UploadPartChecked(ctx context.Context, key, uploadID string, number int32, body io.Reader, size int64, sha256 string) (etag string, err error)
	// CompleteMultipartChecked completes the upload with the checksum of each
	// part, and compares the checksum of the whole object S3 reports with the
	// one defined for the parts (CompositeSHA256).
	CompleteMultipartChecked(ctx context.Context, key, uploadID string, parts []CheckedPart) error
	// ListPartsChecked is ListParts that also fills HeldPart.SHA256 and tells
	// whether the upload was started with checksums.
	ListPartsChecked(ctx context.Context, key, uploadID string) (parts []HeldPart, checksummed bool, err error)
}

// CheckedPart is an uploaded part with the SHA-256 it was sent with.
type CheckedPart struct {
	CompletedPart
	SHA256 string
}

// CompositeSHA256 is the checksum S3 defines for a multipart object: the
// base64 SHA-256 of the raw SHA-256 digests of the parts in order, followed by
// "-" and the number of parts. parts are base64 digests.
func CompositeSHA256(parts []string) (string, error) {
	h := sha256.New()
	for _, p := range parts {
		raw, err := base64.StdEncoding.DecodeString(p)
		if err != nil {
			return "", fmt.Errorf("part checksum is not base64: %w", err)
		}
		h.Write(raw)
	}
	return base64.StdEncoding.EncodeToString(h.Sum(nil)) + "-" + strconv.Itoa(len(parts)), nil
}

// ctxReader fails reads once ctx has ended.
type ctxReader struct {
	ctx context.Context
	r   io.Reader
}

func (c ctxReader) Read(p []byte) (int, error) {
	if err := c.ctx.Err(); err != nil {
		return 0, err
	}
	return c.r.Read(p)
}

// sectionSHA256 is the base64 SHA-256 of length bytes of f from offset. A file
// that ends early fails with ErrFileUnreadable.
func sectionSHA256(ctx context.Context, f *os.File, offset, length int64) (string, error) {
	h := sha256.New()
	n, err := io.Copy(h, ctxReader{ctx, io.NewSectionReader(f, offset, length)})
	if err != nil {
		return "", err
	}
	if n < length {
		return "", fmt.Errorf("%w: file ended %d bytes early", ErrFileUnreadable, length-n)
	}
	return base64.StdEncoding.EncodeToString(h.Sum(nil)), nil
}

// putSingle sends a file below the multipart threshold.
func putSingle(ctx context.Context, s3 S3, key, path string, size int64, progress *progressTracker) error {
	if progress.verify {
		return putSingleChecked(ctx, s3.(CheckedS3), key, path, size, progress)
	}
	return uploadSingle(ctx, s3, key, path, size, progress)
}

// startMultipart starts a multipart upload of a file and sends it.
func startMultipart(ctx context.Context, s3 S3, key, path string, size, modNanos int64, progress *progressTracker, cb Callbacks) error {
	if progress.verify {
		return uploadMultipartChecked(ctx, s3.(CheckedS3), key, path, size, modNanos, progress, cb)
	}
	return uploadMultipart(ctx, s3, key, path, size, modNanos, progress, cb)
}

func putSingleChecked(ctx context.Context, s3 CheckedS3, key, path string, size int64, progress *progressTracker) error {
	f, err := os.Open(path)
	if err != nil {
		return fmt.Errorf("%w: %v", ErrFileUnreadable, err)
	}
	defer f.Close()
	sum, err := sectionSHA256(ctx, f, 0, size)
	if err != nil {
		return err
	}
	body := &sectionBody{r: io.NewSectionReader(f, 0, size), size: size, onRead: func(n int64) { progress.advance(n) }}
	return s3.PutObjectChecked(ctx, key, progress.limit(ctx, body), size, sum)
}

func uploadMultipartChecked(ctx context.Context, s3 CheckedS3, key, path string, size, modNanos int64, progress *progressTracker, cb Callbacks) error {
	f, err := os.Open(path)
	if err != nil {
		return fmt.Errorf("%w: %v", ErrFileUnreadable, err)
	}
	defer f.Close()
	uploadID, err := s3.CreateMultipartChecked(ctx, key)
	if err != nil {
		return err
	}
	m := Multipart{Key: key, UploadID: uploadID, PartSize: PartSize(size), FileSize: size, ModTimeNanos: modNanos}
	recorded(cb, m)
	return sendPartsChecked(ctx, s3, f, m, nil, progress, cb)
}

// resumeChecked continues a multipart upload S3 holds with checksums. A held
// part is kept only when its stored checksum equals the one computed from the
// local file now; any other is sent again.
func resumeChecked(ctx context.Context, s3 CheckedS3, f *os.File, m Multipart, held []HeldPart, progress *progressTracker, cb Callbacks) error {
	sums := make(map[int32]string, len(held))
	for _, p := range held {
		sums[p.Number] = p.SHA256
	}
	have := map[int32]CheckedPart{}
	m.Parts = m.Parts[:0:0]
	valid := validParts(held, m.FileSize, m.PartSize)
	for number := int32(1); int64(number-1)*m.PartSize < m.FileSize; number++ {
		etag, ok := valid[number]
		if !ok || sums[number] == "" {
			continue
		}
		offset := int64(number-1) * m.PartSize
		local, err := sectionSHA256(ctx, f, offset, min(m.PartSize, m.FileSize-offset))
		if err != nil {
			return err
		}
		if local == sums[number] {
			have[number] = CheckedPart{CompletedPart{Number: number, ETag: etag}, local}
			m.Parts = append(m.Parts, have[number].CompletedPart)
		}
	}
	recorded(cb, m)
	return sendPartsChecked(ctx, s3, f, m, have, progress, cb)
}

// sendPartsChecked sends the parts that are not in have, each with its
// SHA-256, and completes the upload. Failures leave the upload in S3 to be
// continued, except a rejected completion, which aborts it.
func sendPartsChecked(ctx context.Context, s3 CheckedS3, f *os.File, m Multipart, have map[int32]CheckedPart, progress *progressTracker, cb Callbacks) error {
	var done int64
	for n := range have {
		done += min(m.PartSize, m.FileSize-int64(n-1)*m.PartSize)
	}
	progress.advance(done)

	var parts []CheckedPart
	for offset, number := int64(0), int32(1); offset < m.FileSize; offset, number = offset+m.PartSize, number+1 {
		if p, ok := have[number]; ok {
			parts = append(parts, p)
			continue
		}
		if err := ctx.Err(); err != nil {
			return err
		}
		length := min(m.PartSize, m.FileSize-offset)
		part, err := sendPartChecked(ctx, s3, f, m, number, offset, length, done, progress)
		if err != nil {
			return err
		}
		done += length
		parts = append(parts, part)
		if cb.PartDone != nil {
			cb.PartDone(part.CompletedPart)
		}
		progress.advance(done)
	}
	return completeChecked(ctx, s3, m, parts, cb)
}

func sendPartChecked(ctx context.Context, s3 CheckedS3, f *os.File, m Multipart, number int32, offset, length, base int64, progress *progressTracker) (CheckedPart, error) {
	sum, err := sectionSHA256(ctx, f, offset, length)
	if err != nil {
		return CheckedPart{}, err
	}
	body := &sectionBody{
		r:      io.NewSectionReader(f, offset, length),
		size:   length,
		onRead: func(n int64) { progress.advance(base + n) },
	}
	etag, err := s3.UploadPartChecked(ctx, m.Key, m.UploadID, number, progress.limit(ctx, body), length, sum)
	if err != nil {
		return CheckedPart{}, err
	}
	return CheckedPart{CompletedPart{Number: number, ETag: etag}, sum}, nil
}

func completeChecked(ctx context.Context, s3 CheckedS3, m Multipart, parts []CheckedPart, cb Callbacks) error {
	err := s3.CompleteMultipartChecked(ctx, m.Key, m.UploadID, parts)
	switch {
	case err == nil:
		recordEnded(cb)
	case errors.Is(err, ErrPreconditionFailed), errors.Is(err, ErrChecksumMismatch):
		discard(ctx, s3, m, cb)
	}
	return err
}
