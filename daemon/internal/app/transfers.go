package app

import (
	"context"
	"errors"
	"sync/atomic"
	"time"

	"rabbithole/daemon/internal/download"
	"rabbithole/daemon/internal/ratelimit"
	"rabbithole/daemon/internal/uploader"
)

// transfers holds the options that shape every upload while it is sent: the
// speed limit shared by all of them, and whether S3 verifies them. A fresh
// daemon starts unlimited and unverified; nothing here is stored.
type transfers struct {
	limiter *ratelimit.Limiter
	verify  atomic.Bool
}

func newTransfers() *transfers { return &transfers{limiter: ratelimit.New(nil, nil)} }

// SetSpeedLimit limits all uploads together, those already running included.
func (t *transfers) SetSpeedLimit(bytesPerSecond int64) { t.limiter.SetRate(bytesPerSecond) }

// SetVerifyUploads applies from the next file an upload starts.
func (t *transfers) SetVerifyUploads(on bool) { t.verify.Store(on) }

// uploaderFor builds the uploader the runner uses: it sends through the shared
// limiter and reads the verification setting at the start of each file.
func (t *transfers) uploaderFor(now func() time.Time) *uploader.Uploader {
	return uploader.New(now, uploader.WithLimiter(t.limiter), uploader.WithVerify(t.verify.Load))
}

// errNoReads means the S3 client cannot read objects.
var errNoReads = errors.New("the S3 client cannot read objects")

// sourceOpener builds the download.Opener over an S3 factory: each download
// gets a client built from the settings in force when it started. Downloads are
// not limited: they do not go through the limiter.
func sourceOpener(newS3 s3Factory) download.Opener {
	return func(ctx context.Context, s uploader.Settings) (download.Source, error) {
		client, err := newS3(ctx, s)
		if err != nil {
			return nil, err
		}
		src, ok := client.(download.Source)
		if !ok {
			return nil, errNoReads
		}
		return src, nil
	}
}
