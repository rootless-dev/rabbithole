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

// maxKeyAttempts caps how many candidate keys one upload tries.
const maxKeyAttempts = 1000

// Request describes one file to upload.
type Request struct {
	Prefix    string
	LocalPath string
	// Name is the destination file name. Empty means the base name of LocalPath.
	Name string
	// SkipExistenceCheck sends files below the multipart threshold straight to
	// the conditional PUT, without asking S3 whether the key exists first. It is
	// for files inside a folder whose destination was just found empty. A
	// rejected write still falls back to the next candidate key.
	SkipExistenceCheck bool
	// Resume is the record of an earlier multipart upload of this file. When
	// the file is unchanged the upload continues with the parts S3 does not
	// hold yet, under the recorded key; otherwise the old multipart upload is
	// aborted and the file starts over.
	Resume *Multipart
}

// Callbacks receive upload events. Either field may be nil.
type Callbacks struct {
	// KeyResolved is called with each object key the upload is about to write.
	// The last call is the key the object ends up under.
	KeyResolved func(key string)
	// Progress is called with the bytes handed to S3 so far: non-decreasing,
	// never above the file size, and equal to it on success.
	Progress func(sent int64)
	// AbortFailed is called when aborting a multipart upload the uploader
	// itself decided to drop (a changed file, a rejected completion) fails.
	AbortFailed func(err error)
	// MultipartRecorded is called with the full record of a multipart upload
	// when it starts, and again when a resumed one adopts the list of parts S3
	// reported. The record is what Request.Resume needs.
	MultipartRecorded func(m Multipart)
	// PartDone is called with each part that completes.
	PartDone func(p CompletedPart)
	// MultipartEnded is called when the recorded multipart upload is finished
	// or aborted, so there is nothing left to continue.
	MultipartEnded func()
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
	name := req.Name
	if name == "" {
		name = filepath.Base(req.LocalPath)
	}
	modNanos := modTimeNanos(info)
	progress := &progressTracker{total: size, report: cb.Progress}

	if req.Resume != nil {
		handled, err := resumeMultipart(ctx, s3, req, info, progress, cb)
		if handled {
			return cancelOr(ctx, err)
		}
	}

	// One timestamp for every candidate, so "-2", "-3" extend the same stamp.
	stamp := u.now()
	for attempt := range maxKeyAttempts {
		if err := ctx.Err(); err != nil {
			return err
		}
		key := CandidateKey(req.Prefix, name, stamp, attempt)
		taken, err := sendUnder(ctx, s3, key, req, size, modNanos, progress, cb)
		if err != nil {
			return cancelOr(ctx, err)
		}
		if taken {
			continue
		}
		progress.advance(size)
		return nil
	}
	return ErrNoFreeName
}

// sendUnder tries to write the file under key. It reports taken when the key
// is already in use, so the caller moves on to the next candidate.
func sendUnder(ctx context.Context, s3 S3, key string, req Request, size, modNanos int64, progress *progressTracker, cb Callbacks) (taken bool, err error) {
	multipart := UseMultipart(size)
	// A rejected conditional write moves on to the next candidate, so the
	// check is only needed where a rejection would be a failure: multipart.
	if multipart || !req.SkipExistenceCheck {
		exists, err := s3.ObjectExists(ctx, key)
		if err != nil || exists {
			return exists, err
		}
	}
	if cb.KeyResolved != nil {
		cb.KeyResolved(key)
	}
	if multipart {
		return false, uploadMultipart(ctx, s3, key, req.LocalPath, size, modNanos, progress, cb)
	}
	err = uploadSingle(ctx, s3, key, req.LocalPath, size, progress)
	if errors.Is(err, ErrPreconditionFailed) {
		return true, nil // the name was taken after the check
	}
	return false, err
}

// ResolveFolder finds the destination folder name for a folder called name:
// the first candidate with nothing under prefix + candidate + "/". The
// caller puts the folder's files under it.
func (u *Uploader) ResolveFolder(ctx context.Context, s3 S3, prefix, name string) (string, error) {
	stamp := u.now()
	for attempt := 0; attempt < maxKeyAttempts; attempt++ {
		if err := ctx.Err(); err != nil {
			return "", err
		}
		candidate := CandidateFolderName(name, stamp, attempt)
		exists, err := s3.PrefixExists(ctx, prefix+candidate+"/")
		if err != nil {
			return "", cancelOr(ctx, err)
		}
		if !exists {
			return candidate, nil
		}
	}
	return "", ErrNoFreeName
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
