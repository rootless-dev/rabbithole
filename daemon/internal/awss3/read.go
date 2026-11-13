package awss3

import (
	"context"
	"errors"
	"io"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/s3"

	"rabbithole/daemon/internal/uploader"
)

// GetObject opens the object under key. It needs s3:GetObject: a denied call
// maps to ErrReadDenied and a missing key to ErrObjectNotFound. A failure while
// the body is read is mapped the same way, so a network error mid-file is
// ErrNoNetwork. The caller closes the body.
func (c *client) GetObject(ctx context.Context, key string) (io.ReadCloser, int64, error) {
	out, err := c.s3.GetObject(ctx, &s3.GetObjectInput{Bucket: aws.String(c.bucket), Key: aws.String(key)})
	if err != nil {
		return nil, 0, mapErrorWithDenial(err, uploader.ErrReadDenied)
	}
	return &mappedBody{ReadCloser: out.Body}, aws.ToInt64(out.ContentLength), nil
}

type mappedBody struct{ io.ReadCloser }

func (b *mappedBody) Read(p []byte) (int, error) {
	n, err := b.ReadCloser.Read(p)
	if err != nil && !errors.Is(err, io.EOF) {
		err = mapErrorWithDenial(err, uploader.ErrReadDenied)
	}
	return n, err
}
