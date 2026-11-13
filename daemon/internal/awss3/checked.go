package awss3

import (
	"context"
	"fmt"
	"io"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/aws/aws-sdk-go-v2/service/s3/types"

	"rabbithole/daemon/internal/uploader"
)

// The checked calls make S3 verify what it stores. Each one declares the
// base64 SHA-256 of the body in the x-amz-checksum-sha256 header, a value the
// uploader computed from the local file before sending. The SDK sees a
// checksum header already set and neither computes nor streams one, so the body
// stays a plain reader that is never seeked, and over TLS the payload is still
// sent as UNSIGNED-PAYLOAD. S3 compares the declared value with the bytes it
// received and rejects a difference with BadDigest, which maps to
// uploader.ErrChecksumMismatch. When the response carries the checksum S3
// stored, it is compared again here.

var _ uploader.CheckedS3 = (*client)(nil)

func (c *client) PutObjectChecked(ctx context.Context, key string, body io.Reader, size int64, sum string) error {
	out, err := c.s3.PutObject(ctx, &s3.PutObjectInput{
		Bucket:         aws.String(c.bucket),
		Key:            aws.String(key),
		Body:           body,
		ContentLength:  aws.Int64(size),
		IfNoneMatch:    aws.String(ifNoneMatchAny),
		ChecksumSHA256: aws.String(sum),
	})
	if err != nil {
		return mapError(err)
	}
	return sameChecksum(out.ChecksumSHA256, sum)
}

func (c *client) CreateMultipartChecked(ctx context.Context, key string) (string, error) {
	out, err := c.s3.CreateMultipartUpload(ctx, &s3.CreateMultipartUploadInput{
		Bucket:            aws.String(c.bucket),
		Key:               aws.String(key),
		ChecksumAlgorithm: types.ChecksumAlgorithmSha256,
	})
	if err != nil {
		return "", mapError(err)
	}
	return aws.ToString(out.UploadId), nil
}

func (c *client) UploadPartChecked(ctx context.Context, key, uploadID string, number int32, body io.Reader, size int64, sum string) (string, error) {
	out, err := c.s3.UploadPart(ctx, &s3.UploadPartInput{
		Bucket:         aws.String(c.bucket),
		Key:            aws.String(key),
		UploadId:       aws.String(uploadID),
		PartNumber:     aws.Int32(number),
		Body:           body,
		ContentLength:  aws.Int64(size),
		ChecksumSHA256: aws.String(sum),
	})
	if err != nil {
		return "", mapError(err)
	}
	if err := sameChecksum(out.ChecksumSHA256, sum); err != nil {
		return "", err
	}
	return aws.ToString(out.ETag), nil
}

func (c *client) CompleteMultipartChecked(ctx context.Context, key, uploadID string, parts []uploader.CheckedPart) error {
	completed := make([]types.CompletedPart, len(parts))
	sums := make([]string, len(parts))
	for i, p := range parts {
		completed[i] = types.CompletedPart{
			PartNumber: aws.Int32(p.Number), ETag: aws.String(p.ETag), ChecksumSHA256: aws.String(p.SHA256),
		}
		sums[i] = p.SHA256
	}
	out, err := c.s3.CompleteMultipartUpload(ctx, &s3.CompleteMultipartUploadInput{
		Bucket:          aws.String(c.bucket),
		Key:             aws.String(key),
		UploadId:        aws.String(uploadID),
		MultipartUpload: &types.CompletedMultipartUpload{Parts: completed},
		IfNoneMatch:     aws.String(ifNoneMatchAny),
	})
	if err != nil {
		return mapError(err)
	}
	want, err := uploader.CompositeSHA256(sums)
	if err != nil {
		return err
	}
	return sameChecksum(out.ChecksumSHA256, want)
}

// ListPartsChecked lists every part S3 holds for the multipart upload, one page
// at a time, with the SHA-256 stored for each, and reports whether the upload
// was started with SHA-256 checksums. It needs s3:ListMultipartUploadParts: a
// denied call maps to ErrListPartsDenied, and an upload id S3 does not know to
// ErrNoSuchUpload.
func (c *client) ListPartsChecked(ctx context.Context, key, uploadID string) ([]uploader.HeldPart, bool, error) {
	pages := s3.NewListPartsPaginator(c.s3, &s3.ListPartsInput{
		Bucket:   aws.String(c.bucket),
		Key:      aws.String(key),
		UploadId: aws.String(uploadID),
	})
	var held []uploader.HeldPart
	checksummed := false
	for pages.HasMorePages() {
		page, err := pages.NextPage(ctx)
		if err != nil {
			return nil, false, mapErrorWithDenial(err, uploader.ErrListPartsDenied)
		}
		checksummed = checksummed || page.ChecksumAlgorithm == types.ChecksumAlgorithmSha256
		for _, p := range page.Parts {
			held = append(held, uploader.HeldPart{
				Number: aws.ToInt32(p.PartNumber), ETag: aws.ToString(p.ETag), Size: aws.ToInt64(p.Size),
				SHA256: aws.ToString(p.ChecksumSHA256),
			})
		}
	}
	return held, checksummed, nil
}

// sameChecksum compares the checksum S3 reports with the one expected. A
// response without one is accepted: S3 already compared the declared value
// when it accepted the request.
func sameChecksum(got *string, want string) error {
	if got == nil || *got == want {
		return nil
	}
	return fmt.Errorf("%w: S3 stored a different checksum", uploader.ErrChecksumMismatch)
}
