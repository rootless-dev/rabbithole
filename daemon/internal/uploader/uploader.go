package uploader

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"time"
)

const abortTimeout = 1 * time.Second

// Request describes one file to upload.
type Request struct {
	Prefix    string
	LocalPath string
}

// Callbacks receive upload events. Either field may be nil.
type Callbacks struct {
	// KeyResolved is called with each object key the upload is about to write.
	// The last call is the key the object ends up under.
	KeyResolved func(key string)
	// Progress is called with the bytes handed to S3 so far: non-decreasing,
	// never above the file size, and equal to it on success.
	Progress func(sent int64)
}

// Uploader uploads local files to S3 with conditional writes.
type Uploader struct {
	now func() time.Time
}

// New returns an Uploader that reads the current time from now.
func New(now func() time.Time) *Uploader {
	return &Uploader{now: now}
}

// Upload sends the file at req.LocalPath to s3 under a key that does not exist yet.
func (u *Uploader) Upload(ctx context.Context, s3 S3, req Request, cb Callbacks) error {
	info, err := os.Stat(req.LocalPath)
	if err != nil {
		return fmt.Errorf("%w: %v", ErrFileUnreadable, err)
	}
	size := info.Size()
	name := filepath.Base(req.LocalPath)
	progress := &progressTracker{total: size, report: cb.Progress}

	for attempt := 0; ; attempt++ {
		if err := ctx.Err(); err != nil {
			return err
		}
		key := CandidateKey(req.Prefix, name, u.now(), attempt)
		exists, err := s3.ObjectExists(ctx, key)
		if err != nil {
			return cancelOr(ctx, err)
		}
		if exists {
			continue
		}
		if cb.KeyResolved != nil {
			cb.KeyResolved(key)
		}

		if UseMultipart(size) {
			err = uploadMultipart(ctx, s3, key, req.LocalPath, size, progress)
		} else {
			err = uploadSingle(ctx, s3, key, req.LocalPath, size, progress)
			if errors.Is(err, ErrPreconditionFailed) {
				continue // the name was taken after the check; try the next candidate
			}
		}
		if err != nil {
			return cancelOr(ctx, err)
		}
		progress.advance(size)
		return nil
	}
}

func uploadSingle(ctx context.Context, s3 S3, key, path string, size int64, progress *progressTracker) error {
	f, err := os.Open(path)
	if err != nil {
		return fmt.Errorf("%w: %v", ErrFileUnreadable, err)
	}
	defer f.Close()

	body := &sectionBody{r: io.NewSectionReader(f, 0, size), size: size, onRead: func(n int64) { progress.advance(n) }}
	return s3.PutObject(ctx, key, body, size)
}

func uploadMultipart(ctx context.Context, s3 S3, key, path string, size int64, progress *progressTracker) (err error) {
	f, err := os.Open(path)
	if err != nil {
		return fmt.Errorf("%w: %v", ErrFileUnreadable, err)
	}
	defer f.Close()

	uploadID, err := s3.CreateMultipart(ctx, key)
	if err != nil {
		return err
	}
	defer func() {
		if err != nil {
			abortCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), abortTimeout)
			defer cancel()
			_ = s3.AbortMultipart(abortCtx, key, uploadID) // best effort; the original error wins
		}
	}()

	partSize := PartSize(size)
	var parts []CompletedPart
	for offset, number := int64(0), int32(1); offset < size; offset, number = offset+partSize, number+1 {
		if err := ctx.Err(); err != nil {
			return err
		}
		length := min(partSize, size-offset)
		base := offset
		body := &sectionBody{
			r:      io.NewSectionReader(f, offset, length),
			size:   length,
			onRead: func(n int64) { progress.advance(base + n) },
		}
		etag, err := s3.UploadPart(ctx, key, uploadID, number, body, length)
		if err != nil {
			return err
		}
		parts = append(parts, CompletedPart{Number: number, ETag: etag})
		progress.advance(offset + length)
	}
	return s3.CompleteMultipart(ctx, key, uploadID, parts)
}

// cancelOr reports the context error when the context ended, because S3
// implementations wrap cancellation in their own errors.
func cancelOr(ctx context.Context, err error) error {
	if ctxErr := ctx.Err(); ctxErr != nil {
		return ctxErr
	}
	return err
}

// sectionBody reads a fixed-size section of the file. If the file ends before
// the recorded size, it fails with ErrFileUnreadable instead of a short read.
type sectionBody struct {
	r      *io.SectionReader
	size   int64
	read   int64
	onRead func(readInSection int64)
}

func (b *sectionBody) Read(p []byte) (int, error) {
	n, err := b.r.Read(p)
	b.read += int64(n)
	if n > 0 {
		b.onRead(b.read)
	}
	if err == io.EOF && b.read < b.size {
		return n, fmt.Errorf("%w: file ended %d bytes early", ErrFileUnreadable, b.size-b.read)
	}
	return n, err
}

// progressTracker reports monotonic progress clamped to the total.
type progressTracker struct {
	total  int64
	sent   int64
	report func(sent int64)
}

func (p *progressTracker) advance(sent int64) {
	sent = min(sent, p.total)
	if sent <= p.sent {
		return
	}
	p.sent = sent
	if p.report != nil {
		p.report(sent)
	}
}
