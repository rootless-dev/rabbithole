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

	"rabbithole/daemon/internal/buckets"
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
	first, found, err := c.firstKeyUnder(ctx, key)
	return found && first == key, err
}

// PrefixExists reports whether any object lives under prefix. Like
// ObjectExists it needs only s3:ListBucket.
func (c *client) PrefixExists(ctx context.Context, prefix string) (bool, error) {
	_, found, err := c.firstKeyUnder(ctx, prefix)
	return found, err
}

// firstKeyUnder lists at most one key under prefix and returns it; found is
// false when there is none. A denied listing maps to ErrForbidden.
func (c *client) firstKeyUnder(ctx context.Context, prefix string) (key string, found bool, err error) {
	out, err := c.s3.ListObjectsV2(ctx, &s3.ListObjectsV2Input{
		Bucket:  aws.String(c.bucket),
		Prefix:  aws.String(prefix),
		MaxKeys: aws.Int32(1),
	})
	if err != nil {
		return "", false, mapErrorWithDenial(err, uploader.ErrForbidden)
	}
	if len(out.Contents) == 0 {
		return "", false, nil
	}
	return aws.ToString(out.Contents[0].Key), true, nil
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

// ListParts lists every part S3 holds for the multipart upload, one page at a
// time. It needs s3:ListMultipartUploadParts: a denied call maps to
// ErrListPartsDenied, and an upload id S3 does not know to ErrNoSuchUpload.
func (c *client) ListParts(ctx context.Context, key, uploadID string) ([]uploader.HeldPart, error) {
	held, _, err := c.ListPartsChecked(ctx, key, uploadID)
	return held, err
}

// DeleteObjects deletes the keys in one request. S3 reports a missing key as
// deleted, and so does this: only a key S3 refused to delete is left out of
// the result. The error never carries the text S3 sent back for a key.
func (c *client) DeleteObjects(ctx context.Context, keys []string) ([]string, error) {
	if len(keys) == 0 {
		return nil, nil
	}
	if len(keys) > uploader.MaxDeleteBatch {
		return nil, fmt.Errorf("awss3: %d keys exceed the limit of %d per request", len(keys), uploader.MaxDeleteBatch)
	}
	objects := make([]types.ObjectIdentifier, len(keys))
	for i, k := range keys {
		objects[i] = types.ObjectIdentifier{Key: aws.String(k)}
	}
	out, err := c.s3.DeleteObjects(ctx, &s3.DeleteObjectsInput{
		Bucket: aws.String(c.bucket),
		Delete: &types.Delete{Objects: objects, Quiet: aws.Bool(true)},
	})
	if err != nil {
		return nil, mapErrorWithDenial(err, uploader.ErrDeleteDenied)
	}
	return deletedKeys(keys, out.Errors)
}

// deletedKeys returns the keys that are not among the failures. It reports the
// first failure as an error built from its code alone.
func deletedKeys(keys []string, failures []types.Error) ([]string, error) {
	failed := map[string]string{}
	var first string
	for _, f := range failures {
		code := aws.ToString(f.Code)
		if code == "NoSuchKey" {
			continue // already gone
		}
		failed[aws.ToString(f.Key)] = code
		if first == "" {
			first = code
		}
	}
	deleted := make([]string, 0, len(keys))
	for _, k := range keys {
		if _, bad := failed[k]; !bad {
			deleted = append(deleted, k)
		}
	}
	if len(failed) == 0 {
		return deleted, nil
	}
	return deleted, mapErrorWithDenial(&smithy.GenericAPIError{Code: first}, uploader.ErrDeleteDenied)
}

// ListKeys lists every key under prefix, one page at a time. It needs only
// s3:ListBucket. A denied listing maps to ErrForbidden.
func (c *client) ListKeys(ctx context.Context, prefix string, visit func(key string)) error {
	pages := s3.NewListObjectsV2Paginator(c.s3, &s3.ListObjectsV2Input{
		Bucket: aws.String(c.bucket),
		Prefix: aws.String(prefix),
	})
	for pages.HasMorePages() {
		page, err := pages.NextPage(ctx)
		if err != nil {
			return mapErrorWithDenial(err, uploader.ErrForbidden)
		}
		for _, obj := range page.Contents {
			visit(aws.ToString(obj.Key))
		}
	}
	return nil
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
		code := apiErr.ErrorCode()
		if code == accessDeniedCode {
			return fmt.Errorf("%w: %w", denied, err)
		}
		if sentinel, known := sentinelByCode[code]; known {
			return fmt.Errorf("%w: %w", sentinel, err)
		}
	}
	var netErr net.Error
	if errors.As(err, &netErr) {
		return fmt.Errorf("%w: %w", uploader.ErrNoNetwork, err)
	}
	return err
}

// accessDeniedCode is the AWS error code whose meaning depends on the call.
const accessDeniedCode = "AccessDenied"

// sentinelByCode maps the AWS error codes that mean the same for every call
// to the uploader sentinel that describes them.
var sentinelByCode = map[string]error{
	"NoSuchBucket":                 uploader.ErrBucketNotFound,
	"NoSuchUpload":                 uploader.ErrNoSuchUpload,
	"InvalidAccessKeyId":           uploader.ErrBadCredentials,
	"SignatureDoesNotMatch":        uploader.ErrBadCredentials,
	"PreconditionFailed":           uploader.ErrPreconditionFailed,
	"ConditionalRequestConflict":   uploader.ErrPreconditionFailed,
	"PermanentRedirect":            uploader.ErrWrongRegion,
	"AuthorizationHeaderMalformed": uploader.ErrWrongRegion,
	"AllAccessDisabled":            uploader.ErrBucketInaccessible,
	"NoSuchKey":                    uploader.ErrObjectNotFound,
	// S3 answers these when the checksum sent with a body is not the one it
	// computed from the body it received.
	"BadDigest":                 uploader.ErrChecksumMismatch,
	"XAmzContentSHA256Mismatch": uploader.ErrChecksumMismatch,
	"BucketAlreadyExists":       buckets.ErrNameTaken,
	"BucketAlreadyOwnedByYou":   buckets.ErrOwnedByYou,
	"InvalidBucketName":         buckets.ErrInvalidName,
	"TooManyBuckets":            buckets.ErrTooManyBucket,
}
