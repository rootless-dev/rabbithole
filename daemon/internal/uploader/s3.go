package uploader

import (
	"context"
	"errors"
	"fmt"
	"io"
)

// Sentinel errors an S3 implementation returns (possibly wrapped) so the
// uploader can react to them and Message can describe them to the user.
var (
	// ErrPreconditionFailed means a conditional write (If-None-Match) was rejected
	// because an object with that key already exists.
	ErrPreconditionFailed = errors.New("conditional write rejected: object already exists")
	// ErrForbidden means the existence check was denied (missing s3:ListBucket).
	ErrForbidden = errors.New("existence check denied")
	// ErrWriteDenied means a write call was denied.
	ErrWriteDenied = errors.New("write denied")
	// ErrDeleteDenied means a delete call was denied (missing s3:DeleteObject).
	ErrDeleteDenied = errors.New("delete denied")
	// ErrBucketInaccessible means AWS has disabled all access to the bucket,
	// which is what a bucket name owned by another account usually answers.
	ErrBucketInaccessible = errors.New("bucket inaccessible")
	// ErrBucketNotFound means the bucket does not exist.
	ErrBucketNotFound = errors.New("bucket not found")
	// ErrWrongRegion means the bucket lives in a different region than the one
	// configured.
	ErrWrongRegion = errors.New("The bucket is in a different region")
	// ErrNoFreeName means every candidate object key for the file was taken.
	ErrNoFreeName = errors.New("Could not find a free name for this file")
	// ErrBadCredentials means AWS rejected the access key.
	ErrBadCredentials = errors.New("bad credentials")
	// ErrNoNetwork means the request could not reach AWS.
	ErrNoNetwork = errors.New("no network")
	// ErrNoSuchUpload means S3 does not know a multipart upload id: it was
	// aborted, completed or expired.
	ErrNoSuchUpload = errors.New("multipart upload not found")
	// ErrListPartsDenied means listing the parts of a multipart upload was
	// denied (missing s3:ListMultipartUploadParts). It is not fatal: the file
	// starts over.
	ErrListPartsDenied = errors.New("listing parts denied")
	// ErrChecksumMismatch means S3 found that what it received differs from the
	// checksum computed from the local file. It fails that file only.
	ErrChecksumMismatch = errors.New("The file in the bucket does not match the local file")
	// ErrVerifyUnsupported means verification was asked for but the S3 client
	// cannot send checksums.
	ErrVerifyUnsupported = errors.New("verification is not supported by this S3 client")
	// ErrReadDenied means reading an object was denied (missing s3:GetObject).
	ErrReadDenied = errors.New("read denied")
	// ErrObjectNotFound means the object is not in the bucket.
	ErrObjectNotFound = errors.New("object not found")
	// ErrListBucketsDenied means listing the buckets of the account was denied.
	ErrListBucketsDenied = errors.New("listing buckets denied")
	// ErrFileUnreadable means the local file vanished, could not be opened, or
	// ended before the size recorded at the start of the upload.
	ErrFileUnreadable = errors.New("file unreadable")
)

// Settings holds the S3 destination and the credentials used to reach it.
type Settings struct {
	AccessKeyID     string
	SecretAccessKey string
	Region          string
	Bucket          string
	Prefix          string
}

// String redacts the credentials so a Settings value is safe to log or print.
func (s Settings) String() string {
	return fmt.Sprintf("Settings{AccessKeyID:[redacted] SecretAccessKey:[redacted] Region:%s Bucket:%s Prefix:%s}",
		s.Region, s.Bucket, s.Prefix)
}

// GoString keeps the credentials redacted under the %#v verb as well.
func (s Settings) GoString() string { return s.String() }

// CompletedPart identifies one uploaded part of a multipart upload.
type CompletedPart struct {
	Number int32
	ETag   string
}

// S3 is the subset of S3 the uploader needs. Writes are conditional: an
// implementation sends If-None-Match and reports a rejection as
// ErrPreconditionFailed.
type S3 interface {
	ObjectExists(ctx context.Context, key string) (bool, error)
	// PrefixExists reports whether any object lives under prefix.
	PrefixExists(ctx context.Context, prefix string) (bool, error)
	PutObject(ctx context.Context, key string, body io.Reader, size int64) error
	CreateMultipart(ctx context.Context, key string) (uploadID string, err error)
	UploadPart(ctx context.Context, key, uploadID string, number int32, body io.Reader, size int64) (etag string, err error)
	CompleteMultipart(ctx context.Context, key, uploadID string, parts []CompletedPart) error
	AbortMultipart(ctx context.Context, key, uploadID string) error
	// ListParts returns every part S3 holds for a multipart upload, page after
	// page. An id S3 does not know is reported as ErrNoSuchUpload and a denied
	// call as ErrListPartsDenied.
	ListParts(ctx context.Context, key, uploadID string) ([]HeldPart, error)
	// DeleteObjects deletes up to MaxDeleteBatch objects by exact key in one
	// request and returns the keys that are gone; a key that did not exist
	// counts as gone. When it fails part-way, deleted still lists the keys
	// that were deleted. A denied delete is reported as ErrDeleteDenied.
	DeleteObjects(ctx context.Context, keys []string) (deleted []string, err error)
	// ListKeys calls visit with every key under prefix, page after page. When
	// it returns an error the listing is incomplete.
	ListKeys(ctx context.Context, prefix string, visit func(key string)) error
}

// MaxDeleteBatch is the most keys one S3 DeleteObjects request may carry.
const MaxDeleteBatch = 1000

// DeleteKeys deletes keys from the bucket of s3 in batches of at most
// MaxDeleteBatch, stopping at the first batch that fails. It returns the keys
// deleted so far, including those of a batch that failed part-way.
func DeleteKeys(ctx context.Context, s3 S3, keys []string) ([]string, error) {
	var deleted []string
	for start := 0; start < len(keys); start += MaxDeleteBatch {
		batch := keys[start:min(start+MaxDeleteBatch, len(keys))]
		done, err := s3.DeleteObjects(ctx, batch)
		deleted = append(deleted, done...)
		if err != nil {
			return deleted, err
		}
	}
	return deleted, nil
}
