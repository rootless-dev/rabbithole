package uploader

import "errors"

// fatalErrors are the errors that will hit every other file of the same
// upload too.
var fatalErrors = []error{
	ErrBadCredentials, ErrBucketNotFound, ErrBucketInaccessible, ErrWrongRegion,
	ErrNoNetwork, ErrForbidden, ErrWriteDenied,
}

// IsFatal reports whether err will hit every other file of the same upload
// too, so the upload should stop instead of failing one file at a time.
func IsFatal(err error) bool {
	for _, fatal := range fatalErrors {
		if errors.Is(err, fatal) {
			return true
		}
	}
	return false
}

// fallbackMessage describes an error that matches no sentinel.
const fallbackMessage = "Upload failed"

// messages pairs each sentinel with its sentence, in the order they are
// tested: an error wrapping several sentinels is described by the first match.
var messages = []struct {
	err  error
	text string
}{
	{ErrBadCredentials, "AWS rejected the access key"},
	{ErrBucketNotFound, "Bucket not found"},
	{ErrBucketInaccessible, "AWS blocked access to this bucket: check that the bucket name is yours"},
	{ErrWrongRegion, "The bucket is in a different region"},
	{ErrNoNetwork, "No internet connection"},
	{ErrForbidden, "AWS denied the existence check: the access key needs the s3:ListBucket permission"},
	{ErrWriteDenied, "AWS denied permission to write to the bucket"},
	{ErrDeleteDenied, "AWS denied permission to delete from the bucket: the access key needs the s3:DeleteObject permission"},
	{ErrListPartsDenied, "AWS denied listing the uploaded parts: the access key needs the s3:ListMultipartUploadParts permission"},
	{ErrPreconditionFailed, "An object with this name appeared during the upload"},
	{ErrNoFreeName, "Could not find a free name for this file"},
	{ErrFileUnreadable, "File could not be read"},
}

// Message turns an upload error into a short, readable sentence for the user.
func Message(err error) string {
	for _, m := range messages {
		if errors.Is(err, m.err) {
			return m.text
		}
	}
	return fallbackMessage
}
