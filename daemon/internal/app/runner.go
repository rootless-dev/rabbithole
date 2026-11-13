package app

import (
	"context"
	"path/filepath"
	"sync"

	"rabbithole/daemon/internal/awss3"
	"rabbithole/daemon/internal/logging"
	"rabbithole/daemon/internal/uploader"
)

// s3Factory builds an S3 client from the settings of an upload.
type s3Factory func(ctx context.Context, s uploader.Settings) (uploader.S3, error)

// runner is the queue.Runner used in production: it hands the uploader an S3
// client built from the job's settings.
type runner struct {
	uploader *uploader.Uploader
	newS3    s3Factory
	log      *logging.Logger

	// The last client built, kept while the settings stay the same so the files
	// of one upload share its connections instead of opening new ones each.
	mu       sync.Mutex
	cached   uploader.S3
	cachedOf uploader.Settings
}

// Run uploads one file and logs one line if it fails. The line carries the
// readable reason, the AWS error code and HTTP status when the error has them,
// and the file name; never the error's own text, which may echo request content.
func (r *runner) Run(ctx context.Context, s uploader.Settings, req uploader.Request, cb uploader.Callbacks) error {
	name := filepath.Base(req.LocalPath)
	cb.AbortFailed = func(err error) {
		r.logFailure(ctx, "multipart abort failed", name, err)
	}
	client, err := r.client(ctx, s)
	if err == nil {
		err = r.uploader.Upload(ctx, client, req, cb)
	}
	if err != nil {
		r.logFailure(ctx, "upload failed", name, err)
	}
	return err
}

// ResolveFolder picks the name a folder lands under at the destination, and
// logs one line if that fails, like Run.
func (r *runner) ResolveFolder(ctx context.Context, s uploader.Settings, name string) (string, error) {
	client, err := r.client(ctx, s)
	if err == nil {
		var resolved string
		if resolved, err = r.uploader.ResolveFolder(ctx, client, s.Prefix, name); err == nil {
			return resolved, nil
		}
	}
	r.logFailure(ctx, "folder name resolution failed", name, err)
	return "", err
}

// client returns the S3 client for s, building one only when s differs from
// the settings of the client it already has.
func (r *runner) client(ctx context.Context, s uploader.Settings) (uploader.S3, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.cached != nil && r.cachedOf == s {
		return r.cached, nil
	}
	client, err := r.newS3(ctx, s)
	if err != nil {
		return nil, err
	}
	r.cached, r.cachedOf = client, s
	return client, nil
}

func (r *runner) logFailure(ctx context.Context, msg, file string, err error) {
	kv := []any{"file", file, "reason", uploader.Message(err)}
	code, status := awss3.ErrorDetails(err)
	if code != "" {
		kv = append(kv, "aws_code", code)
	}
	if status != 0 {
		kv = append(kv, "http_status", status)
	}
	if ctx.Err() != nil {
		r.log.Warn(msg, kv...) // shutdown cancelled the work; not a defect
		return
	}
	r.log.Error(msg, kv...)
}
