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

// DeleteObjects deletes the objects with exactly these keys from the bucket of
// s, in batches of at most uploader.MaxDeleteBatch, and logs one line if it
// fails, like Run. It returns the keys deleted, also when it fails.
func (r *runner) DeleteObjects(ctx context.Context, s uploader.Settings, keys []string) ([]string, error) {
	client, err := r.client(ctx, s)
	var deleted []string
	if err == nil {
		deleted, err = uploader.DeleteKeys(ctx, client, keys)
	}
	if err != nil {
		r.logFailureOf(ctx, "delete from bucket failed", []any{"keys", len(keys), "deleted", len(deleted)}, err)
	}
	return deleted, err
}

// ListKeys lists every key under prefix in the bucket of s, and logs one line
// if that fails, like Run.
func (r *runner) ListKeys(ctx context.Context, s uploader.Settings, prefix string, visit func(key string)) error {
	client, err := r.client(ctx, s)
	if err == nil {
		err = client.ListKeys(ctx, prefix, visit)
	}
	if err != nil {
		r.logFailureOf(ctx, "bucket listing failed", []any{"prefix", prefix}, err)
	}
	return err
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
	r.logFailureOf(ctx, msg, []any{"file", file}, err)
}

// logFailureOf logs one line with the fields in what, the readable reason, and
// the AWS error code and HTTP status when err has them.
func (r *runner) logFailureOf(ctx context.Context, msg string, what []any, err error) {
	kv := append(what, "reason", uploader.Message(err))
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
