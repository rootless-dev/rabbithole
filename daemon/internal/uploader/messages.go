package uploader

import "errors"

// Message turns an upload error into a short, readable sentence for the user.
func Message(err error) string {
	switch {
	case errors.Is(err, ErrBadCredentials):
		return "AWS rejected the access key"
	case errors.Is(err, ErrBucketNotFound):
		return "Bucket not found"
	case errors.Is(err, ErrBucketInaccessible):
		return "AWS blocked access to this bucket: check that the bucket name is yours"
	case errors.Is(err, ErrWrongRegion):
		return "The bucket is in a different region"
	case errors.Is(err, ErrNoNetwork):
		return "No internet connection"
	case errors.Is(err, ErrForbidden):
		return "AWS denied the existence check: the access key needs the s3:ListBucket permission"
	case errors.Is(err, ErrWriteDenied):
		return "AWS denied permission to write to the bucket"
	case errors.Is(err, ErrPreconditionFailed):
		return "An object with this name appeared during the upload"
	case errors.Is(err, ErrNoFreeName):
		return "Could not find a free name for this file"
	case errors.Is(err, ErrFileUnreadable):
		return "File could not be read"
	default:
		return "Upload failed"
	}
}
