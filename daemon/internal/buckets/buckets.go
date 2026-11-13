// Package buckets holds what the daemon does with the buckets of an account
// before it is configured: listing them and creating one. It does not touch the
// settings the daemon uploads with.
package buckets

import (
	"context"
	"errors"
	"regexp"

	"rabbithole/daemon/internal/uploader"
)

// Credentials are what a request supplies to reach S3. They are used for the
// one call and never stored or logged.
type Credentials struct {
	AccessKeyID     string
	SecretAccessKey string
	Region          string
}

// String redacts the credentials so a value is safe to log or print.
func (c Credentials) String() string {
	return "Credentials{AccessKeyID:[redacted] SecretAccessKey:[redacted] Region:" + c.Region + "}"
}

// GoString keeps the credentials redacted under the %#v verb as well.
func (c Credentials) GoString() string { return c.String() }

// Bucket is a bucket the key can see. Region is empty when it could not be read.
type Bucket struct {
	Name   string
	Region string
}

// Service lists and creates buckets. Implementations report the failures
// below, or uploader.ErrBadCredentials, uploader.ErrNoNetwork and
// uploader.ErrListBucketsDenied, possibly wrapped.
type Service interface {
	List(ctx context.Context, c Credentials) ([]Bucket, error)
	// Create makes a bucket with public access blocked, in c.Region.
	Create(ctx context.Context, c Credentials, name string) error
}

// Why a bucket could not be created.
var (
	ErrNameTaken     = errors.New("This name is already taken by another AWS account. Bucket names are unique in all of AWS: try another one.")
	ErrOwnedByYou    = errors.New("You already have a bucket with this name. Choose it in the list instead.")
	ErrInvalidName   = errors.New("This name is not valid. Use 3 to 63 lowercase letters, numbers and hyphens, starting and ending with a letter or a number.")
	ErrCreateDenied  = errors.New("AWS denied permission to create buckets: the access key needs the s3:CreateBucket permission")
	ErrTooManyBucket = errors.New("This account has reached its limit of buckets")
)

// CreateFailed is the sentence for a creation that failed for any other reason.
const CreateFailed = "The bucket could not be created"

var namePattern = regexp.MustCompile(`^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$`)

// ValidateName checks a bucket name locally: 3 to 63 lowercase letters, digits
// and hyphens, starting and ending with a letter or a digit. It returns
// ErrInvalidName when the name does not qualify.
func ValidateName(name string) error {
	if !namePattern.MatchString(name) {
		return ErrInvalidName
	}
	return nil
}

// CreateMessage is the sentence for an error of Create, ready to show.
func CreateMessage(err error) string {
	switch {
	case errors.Is(err, ErrNameTaken):
		return ErrNameTaken.Error()
	case errors.Is(err, ErrOwnedByYou):
		return ErrOwnedByYou.Error()
	case errors.Is(err, ErrInvalidName):
		return ErrInvalidName.Error()
	case errors.Is(err, ErrCreateDenied):
		return ErrCreateDenied.Error()
	case errors.Is(err, ErrTooManyBucket):
		return ErrTooManyBucket.Error()
	case errors.Is(err, uploader.ErrBadCredentials), errors.Is(err, uploader.ErrNoNetwork):
		return uploader.Message(err)
	}
	return CreateFailed
}
