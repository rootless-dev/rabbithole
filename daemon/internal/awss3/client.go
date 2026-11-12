// Package awss3 adapts the AWS SDK for Go v2 S3 client to the uploader.S3
// interface. Every write is conditional (If-None-Match: *) and every SDK error
// is translated into one of the uploader sentinel errors.
package awss3

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"

	"github.com/aws/aws-sdk-go-v2/aws"
	awshttp "github.com/aws/aws-sdk-go-v2/aws/transport/http"
	"github.com/aws/aws-sdk-go-v2/credentials"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/aws/aws-sdk-go-v2/service/s3/types"
	"github.com/aws/smithy-go"

	"rabbithole/daemon/internal/uploader"
)

// ifNoneMatchAny makes S3 reject the write when the key already exists.
const ifNoneMatchAny = "*"

type client struct {
	s3     *s3.Client
	bucket string
}

// New builds an S3 adapter that uses only the static credentials in s. It does
// not consult environment variables, shared config files or instance metadata.
func New(_ context.Context, s uploader.Settings) (uploader.S3, error) {
	return newClient(s, nil)
}

// newClient is New with an injectable HTTP client; nil selects the SDK default.
func newClient(s uploader.Settings, httpClient s3.HTTPClient) (uploader.S3, error) {
	switch {
	case s.AccessKeyID == "" || s.SecretAccessKey == "":
		return nil, errors.New("awss3: access key id and secret access key are required")
	case s.Region == "":
		return nil, errors.New("awss3: region is required")
	case s.Bucket == "":
		return nil, errors.New("awss3: bucket is required")
	}
	// s3.New with explicit Options skips the default config chain entirely.
	c := s3.New(s3.Options{
		Region:      s.Region,
		Credentials: credentials.NewStaticCredentialsProvider(s.AccessKeyID, s.SecretAccessKey, ""),
		HTTPClient:  httpClient,
		// Bodies are plain, non-seekable readers. Pin checksums to "when
		// required" so the SDK never wraps them in an aws-chunked trailer; over
		// TLS the payload is then signed as UNSIGNED-PAYLOAD without seeking.
		RequestChecksumCalculation: aws.RequestChecksumCalculationWhenRequired,
	})
	return &client{s3: c, bucket: s.Bucket}, nil
}

// ObjectExists lists the bucket with the key as prefix and reports whether the
// first key returned is exactly key. HeadObject would need s3:GetObject, which
// the access key does not have; listing needs only s3:ListBucket. Keys sort
// lexicographically, so an exact match is always the first result for its own
// prefix.
func (c *client) ObjectExists(ctx context.Context, key string) (bool, error) {
	out, err := c.s3.ListObjectsV2(ctx, &s3.ListObjectsV2Input{
		Bucket:  aws.String(c.bucket),
		Prefix:  aws.String(key),
		MaxKeys: aws.Int32(1),
	})
	if err != nil {
		return false, mapErrorWithDenial(err, uploader.ErrForbidden)
	}
	return len(out.Contents) > 0 && aws.ToString(out.Contents[0].Key) == key, nil
}

func (c *client) PutObject(ctx context.Context, key string, body io.Reader, size int64) error {
	_, err := c.s3.PutObject(ctx, &s3.PutObjectInput{
		Bucket:        aws.String(c.bucket),
		Key:           aws.String(key),
		Body:          body,
		ContentLength: aws.Int64(size),
		IfNoneMatch:   aws.String(ifNoneMatchAny),
	})
	return mapError(err)
}

func (c *client) CreateMultipart(ctx context.Context, key string) (string, error) {
	out, err := c.s3.CreateMultipartUpload(ctx, &s3.CreateMultipartUploadInput{
		Bucket: aws.String(c.bucket),
		Key:    aws.String(key),
	})
	if err != nil {
		return "", mapError(err)
	}
	return aws.ToString(out.UploadId), nil
}

func (c *client) UploadPart(ctx context.Context, key, uploadID string, number int32, body io.Reader, size int64) (string, error) {
	out, err := c.s3.UploadPart(ctx, &s3.UploadPartInput{
		Bucket:        aws.String(c.bucket),
		Key:           aws.String(key),
		UploadId:      aws.String(uploadID),
		PartNumber:    aws.Int32(number),
		Body:          body,
		ContentLength: aws.Int64(size),
	})
	if err != nil {
		return "", mapError(err)
	}
	return aws.ToString(out.ETag), nil
}

func (c *client) CompleteMultipart(ctx context.Context, key, uploadID string, parts []uploader.CompletedPart) error {
	completed := make([]types.CompletedPart, len(parts))
	for i, p := range parts {
		completed[i] = types.CompletedPart{PartNumber: aws.Int32(p.Number), ETag: aws.String(p.ETag)}
	}
	_, err := c.s3.CompleteMultipartUpload(ctx, &s3.CompleteMultipartUploadInput{
		Bucket:          aws.String(c.bucket),
		Key:             aws.String(key),
		UploadId:        aws.String(uploadID),
		MultipartUpload: &types.CompletedMultipartUpload{Parts: completed},
		IfNoneMatch:     aws.String(ifNoneMatchAny),
	})
	return mapError(err)
}

func (c *client) AbortMultipart(ctx context.Context, key, uploadID string) error {
	_, err := c.s3.AbortMultipartUpload(ctx, &s3.AbortMultipartUploadInput{
		Bucket:   aws.String(c.bucket),
		Key:      aws.String(key),
		UploadId: aws.String(uploadID),
	})
	return mapError(err)
}

// ErrorDetails returns the AWS error code and the HTTP status an error carries,
// for diagnostics. Either is zero-valued when the error does not carry it. It
// never returns the error's text, which may echo request content.
func ErrorDetails(err error) (code string, httpStatus int) {
	var apiErr smithy.APIError
	if errors.As(err, &apiErr) {
		code = apiErr.ErrorCode()
	}
	var respErr *awshttp.ResponseError
	if errors.As(err, &respErr) {
		httpStatus = respErr.HTTPStatusCode()
	}
	return code, httpStatus
}

// mapError translates the error of a write call into an uploader sentinel,
// keeping the original error in the chain. AccessDenied maps to ErrWriteDenied.
// Errors it does not recognise are returned unchanged.
func mapError(err error) error {
	return mapErrorWithDenial(err, uploader.ErrWriteDenied)
}

// mapErrorWithDenial is mapError with the sentinel that AccessDenied maps to,
// which depends on whether the call was a write or the existence check.
func mapErrorWithDenial(err error, denied error) error {
	if err == nil {
		return nil
	}
	// A cancelled or expired context is not a connectivity problem.
	if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
		return err
	}
	var apiErr smithy.APIError
	if errors.As(err, &apiErr) {
		switch apiErr.ErrorCode() {
		case "NoSuchBucket":
			return fmt.Errorf("%w: %w", uploader.ErrBucketNotFound, err)
		case "InvalidAccessKeyId", "SignatureDoesNotMatch":
			return fmt.Errorf("%w: %w", uploader.ErrBadCredentials, err)
		case "PreconditionFailed", "ConditionalRequestConflict":
			return fmt.Errorf("%w: %w", uploader.ErrPreconditionFailed, err)
		case "PermanentRedirect", "AuthorizationHeaderMalformed":
			return fmt.Errorf("%w: %w", uploader.ErrWrongRegion, err)
		case "AllAccessDisabled":
			return fmt.Errorf("%w: %w", uploader.ErrBucketInaccessible, err)
		case "AccessDenied":
			return fmt.Errorf("%w: %w", denied, err)
		}
	}
	var netErr net.Error
	if errors.As(err, &netErr) {
		return fmt.Errorf("%w: %w", uploader.ErrNoNetwork, err)
	}
	return err
}
