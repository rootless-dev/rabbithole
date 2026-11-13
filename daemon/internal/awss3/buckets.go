package awss3

import (
	"context"
	"errors"
	"sort"

	"github.com/aws/aws-sdk-go-v2/aws"
	awshttp "github.com/aws/aws-sdk-go-v2/aws/transport/http"
	"github.com/aws/aws-sdk-go-v2/credentials"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/aws/aws-sdk-go-v2/service/s3/types"

	"rabbithole/daemon/internal/buckets"
	"rabbithole/daemon/internal/uploader"
)

// usEast1 is the one region CreateBucket takes no location constraint for.
const usEast1 = "us-east-1"

// bucketRegionHeader is the header S3 answers every bucket request with.
const bucketRegionHeader = "X-Amz-Bucket-Region"

// Buckets lists and creates buckets with the credentials of each call. It
// keeps nothing between calls and never reads the daemon's own settings.
type Buckets struct {
	httpClient s3.HTTPClient // nil selects the SDK default
}

// NewBuckets returns the production buckets.Service.
func NewBuckets() *Buckets { return &Buckets{} }

var _ buckets.Service = (*Buckets)(nil)

func (b *Buckets) client(c buckets.Credentials) (*s3.Client, error) {
	if c.AccessKeyID == "" || c.SecretAccessKey == "" || c.Region == "" {
		return nil, errors.New("awss3: access key id, secret access key and region are required")
	}
	return s3.New(s3.Options{
		Region:                     c.Region,
		Credentials:                credentials.NewStaticCredentialsProvider(c.AccessKeyID, c.SecretAccessKey, ""),
		HTTPClient:                 b.httpClient,
		RequestChecksumCalculation: aws.RequestChecksumCalculationWhenRequired,
	}), nil
}

// List returns every bucket the key can see, sorted by name, each with its
// region. The region comes with the listing; when it does not, S3 is asked for
// it, and a bucket whose region cannot be read has an empty one. A denied
// listing is uploader.ErrListBucketsDenied.
func (b *Buckets) List(ctx context.Context, c buckets.Credentials) ([]buckets.Bucket, error) {
	client, err := b.client(c)
	if err != nil {
		return nil, err
	}
	pages := s3.NewListBucketsPaginator(client, &s3.ListBucketsInput{})
	var out []buckets.Bucket
	for pages.HasMorePages() {
		page, err := pages.NextPage(ctx)
		if err != nil {
			return nil, mapErrorWithDenial(err, uploader.ErrListBucketsDenied)
		}
		for _, bk := range page.Buckets {
			out = append(out, buckets.Bucket{Name: aws.ToString(bk.Name), Region: aws.ToString(bk.BucketRegion)})
		}
	}
	for i := range out {
		if out[i].Region == "" {
			out[i].Region = regionOf(ctx, client, out[i].Name)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out, nil
}

// regionOf asks S3 where a bucket lives. S3 names the region in a header even
// when it refuses the request, so a bucket the key may not open still answers.
func regionOf(ctx context.Context, client *s3.Client, name string) string {
	out, err := client.HeadBucket(ctx, &s3.HeadBucketInput{Bucket: aws.String(name)})
	if err == nil {
		return aws.ToString(out.BucketRegion)
	}
	var respErr *awshttp.ResponseError
	if errors.As(err, &respErr) && respErr.Response != nil {
		return respErr.Response.Header.Get(bucketRegionHeader)
	}
	return ""
}

// Create makes a private bucket in c.Region. New buckets already block public
// access and disable ACLs, so no public access block is set: that would need
// the extra s3:PutBucketPublicAccessBlock permission.
func (b *Buckets) Create(ctx context.Context, c buckets.Credentials, name string) error {
	client, err := b.client(c)
	if err != nil {
		return err
	}
	in := &s3.CreateBucketInput{Bucket: aws.String(name)}
	if c.Region != usEast1 {
		in.CreateBucketConfiguration = &types.CreateBucketConfiguration{LocationConstraint: types.BucketLocationConstraint(c.Region)}
	}
	_, err = client.CreateBucket(ctx, in)
	return mapErrorWithDenial(err, buckets.ErrCreateDenied)
}
