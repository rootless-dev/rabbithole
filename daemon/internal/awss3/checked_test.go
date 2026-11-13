package awss3

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"io"
	"net"
	"net/http"
	"strings"
	"testing"

	"rabbithole/daemon/internal/buckets"
	"rabbithole/daemon/internal/uploader"
)

func sha(s string) string {
	h := sha256.Sum256([]byte(s))
	return base64.StdEncoding.EncodeToString(h[:])
}

func checkedClient(t *testing.T, respond func(r *http.Request) *http.Response) (uploader.CheckedS3, *stubTransport) {
	t.Helper()
	c, stub := newTestClient(t, respond)
	return c.(uploader.CheckedS3), stub
}

func TestPutObjectCheckedDeclaresTheChecksumAndSendsThePlainBody(t *testing.T) {
	c, stub := checkedClient(t, func(*http.Request) *http.Response { return reply(200, "", nil) })

	if err := c.PutObjectChecked(context.Background(), "a/b.txt", strings.NewReader("hello"), 5, sha("hello")); err != nil {
		t.Fatal(err)
	}
	r := stub.requests()[0]
	if got := r.Header.Get("x-amz-checksum-sha256"); got != sha("hello") {
		t.Fatalf("x-amz-checksum-sha256 = %q, want %q", got, sha("hello"))
	}
	if got := r.Header.Get("x-amz-content-sha256"); got != "UNSIGNED-PAYLOAD" {
		t.Fatalf("x-amz-content-sha256 = %q, want UNSIGNED-PAYLOAD over TLS without chunked trailers", got)
	}
	if enc := r.Header.Get("Content-Encoding"); strings.Contains(enc, "aws-chunked") || stub.lastBody() != "hello" {
		t.Fatalf("encoding %q, body %q; want the plain body", enc, stub.lastBody())
	}
	if r.Header.Get("If-None-Match") != "*" {
		t.Fatal("the checked write must stay conditional")
	}
}

func TestPutObjectCheckedMapsBadDigestToAMismatch(t *testing.T) {
	c, _ := checkedClient(t, func(*http.Request) *http.Response { return reply(400, errorXML("BadDigest"), nil) })
	err := c.PutObjectChecked(context.Background(), "k", strings.NewReader("hello"), 5, sha("hello"))
	if !errors.Is(err, uploader.ErrChecksumMismatch) || uploader.IsFatal(err) {
		t.Fatalf("err = %v, want a non-fatal ErrChecksumMismatch", err)
	}
}

func TestPutObjectCheckedFailsWhenS3StoredAnotherChecksum(t *testing.T) {
	c, _ := checkedClient(t, func(*http.Request) *http.Response {
		return reply(200, "", map[string]string{"x-amz-checksum-sha256": sha("other")})
	})
	err := c.PutObjectChecked(context.Background(), "k", strings.NewReader("hello"), 5, sha("hello"))
	if !errors.Is(err, uploader.ErrChecksumMismatch) {
		t.Fatalf("err = %v, want ErrChecksumMismatch", err)
	}
}

func TestMultipartCheckedFlowCarriesChecksumsAndComparesTheComposite(t *testing.T) {
	parts := []uploader.CheckedPart{
		{CompletedPart: uploader.CompletedPart{Number: 1, ETag: `"e1"`}, SHA256: sha("one")},
		{CompletedPart: uploader.CompletedPart{Number: 2, ETag: `"e2"`}, SHA256: sha("two")},
	}
	composite, err := uploader.CompositeSHA256([]string{parts[0].SHA256, parts[1].SHA256})
	if err != nil {
		t.Fatal(err)
	}
	answer := composite
	c, stub := checkedClient(t, func(r *http.Request) *http.Response {
		q := r.URL.Query()
		switch {
		case r.Method == http.MethodPost && q.Has("uploads"):
			return reply(200, `<?xml version="1.0"?><InitiateMultipartUploadResult><UploadId>up-1</UploadId></InitiateMultipartUploadResult>`, nil)
		case r.Method == http.MethodPut && q.Has("partNumber"):
			return reply(200, "", map[string]string{"ETag": `"e"`})
		}
		return reply(200, `<?xml version="1.0"?><CompleteMultipartUploadResult><ETag>"f"</ETag><ChecksumSHA256>`+answer+`</ChecksumSHA256></CompleteMultipartUploadResult>`, nil)
	})
	ctx := context.Background()

	id, err := c.CreateMultipartChecked(ctx, "k")
	if err != nil || id != "up-1" {
		t.Fatalf("CreateMultipartChecked = %q, %v", id, err)
	}
	if _, err := c.UploadPartChecked(ctx, "k", id, 1, strings.NewReader("one"), 3, sha("one")); err != nil {
		t.Fatal(err)
	}
	if err := c.CompleteMultipartChecked(ctx, "k", id, parts); err != nil {
		t.Fatalf("CompleteMultipartChecked: %v", err)
	}

	reqs := stub.requests()
	if got := reqs[0].Header.Get("x-amz-checksum-algorithm"); got != "SHA256" {
		t.Fatalf("create declared algorithm %q, want SHA256", got)
	}
	if got := reqs[1].Header.Get("x-amz-checksum-sha256"); got != sha("one") {
		t.Fatalf("part declared %q, want the checksum of its bytes", got)
	}
	body := stub.bodies[2]
	for _, p := range parts {
		if !strings.Contains(body, "<ChecksumSHA256>"+p.SHA256+"</ChecksumSHA256>") {
			t.Fatalf("complete body lacks the checksum of part %d: %s", p.Number, body)
		}
	}

	answer = composite + "x"
	err = c.CompleteMultipartChecked(ctx, "k", id, parts)
	if !errors.Is(err, uploader.ErrChecksumMismatch) {
		t.Fatalf("err = %v, want ErrChecksumMismatch for a composite that differs", err)
	}
}

func TestListPartsCheckedReportsChecksumsAndTheAlgorithm(t *testing.T) {
	c, _ := checkedClient(t, func(*http.Request) *http.Response {
		return reply(200, `<?xml version="1.0"?><ListPartsResult><IsTruncated>false</IsTruncated><ChecksumAlgorithm>SHA256</ChecksumAlgorithm>`+
			`<Part><PartNumber>1</PartNumber><ETag>"e1"</ETag><Size>8</Size><ChecksumSHA256>`+sha("one")+`</ChecksumSHA256></Part></ListPartsResult>`, nil)
	})
	parts, checksummed, err := c.ListPartsChecked(context.Background(), "k", "up-1")
	if err != nil || !checksummed || len(parts) != 1 || parts[0].SHA256 != sha("one") {
		t.Fatalf("parts %+v, checksummed %v, err %v", parts, checksummed, err)
	}

	plain, _ := checkedClient(t, func(*http.Request) *http.Response {
		return reply(200, partsXML(false, 0, [3]any{1, `"e1"`, 8}), nil)
	})
	if _, checksummed, err := plain.ListPartsChecked(context.Background(), "k", "up-1"); err != nil || checksummed {
		t.Fatalf("checksummed = %v, err %v; want false for an upload started without checksums", checksummed, err)
	}
}

func TestGetObjectReturnsTheBodyAndItsSize(t *testing.T) {
	c, stub := newTestClient(t, func(*http.Request) *http.Response {
		return reply(200, "file bytes", map[string]string{"Content-Length": "10"})
	})
	body, size, err := c.(interface {
		GetObject(context.Context, string) (io.ReadCloser, int64, error)
	}).GetObject(context.Background(), "quick/a.txt")
	if err != nil {
		t.Fatal(err)
	}
	defer body.Close()
	got, _ := io.ReadAll(body)
	if string(got) != "file bytes" || size != 10 {
		t.Fatalf("body %q size %d", got, size)
	}
	if r := stub.requests()[0]; r.Method != http.MethodGet || !strings.HasSuffix(r.URL.Path, "/quick/a.txt") {
		t.Fatalf("request = %s %s", r.Method, r.URL.Path)
	}
}

func TestGetObjectMapsErrors(t *testing.T) {
	cases := []struct {
		name   string
		status int
		code   string
		want   error
	}{
		{"denied", 403, "AccessDenied", uploader.ErrReadDenied},
		{"gone", 404, "NoSuchKey", uploader.ErrObjectNotFound},
		{"no bucket", 404, "NoSuchBucket", uploader.ErrBucketNotFound},
		{"bad key", 403, "InvalidAccessKeyId", uploader.ErrBadCredentials},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			c, _ := newTestClient(t, func(*http.Request) *http.Response { return reply(tc.status, errorXML(tc.code), nil) })
			_, _, err := c.(interface {
				GetObject(context.Context, string) (io.ReadCloser, int64, error)
			}).GetObject(context.Background(), "k")
			if !errors.Is(err, tc.want) {
				t.Fatalf("err = %v, want %v", err, tc.want)
			}
		})
	}
}

func newTestBuckets(respond func(r *http.Request) *http.Response) (*Buckets, *stubTransport) {
	stub := &stubTransport{respond: respond}
	return &Buckets{httpClient: stub}, stub
}

var testCreds = buckets.Credentials{AccessKeyID: "AKIDEXAMPLE", SecretAccessKey: "secret-example", Region: "eu-west-1"}

func bucketsXML(entries ...[2]string) string {
	var b strings.Builder
	b.WriteString(`<?xml version="1.0"?><ListAllMyBucketsResult><Buckets>`)
	for _, e := range entries {
		b.WriteString("<Bucket><Name>" + e[0] + "</Name>")
		if e[1] != "" {
			b.WriteString("<BucketRegion>" + e[1] + "</BucketRegion>")
		}
		b.WriteString("</Bucket>")
	}
	b.WriteString(`</Buckets></ListAllMyBucketsResult>`)
	return b.String()
}

func TestListBucketsSortsByNameAndFillsRegions(t *testing.T) {
	svc, _ := newTestBuckets(func(r *http.Request) *http.Response {
		if r.Method == http.MethodHead {
			if strings.Contains(r.URL.Host+r.URL.Path, "no-region") {
				return reply(403, "", map[string]string{"X-Amz-Bucket-Region": "sa-east-1"})
			}
			return reply(403, "", nil)
		}
		return reply(200, bucketsXML([2]string{"zeta", "us-east-1"}, [2]string{"no-region", ""}, [2]string{"alpha", "eu-west-1"}, [2]string{"unknown", ""}), nil)
	})

	got, err := svc.List(context.Background(), testCreds)
	if err != nil {
		t.Fatal(err)
	}
	want := []buckets.Bucket{{Name: "alpha", Region: "eu-west-1"}, {Name: "no-region", Region: "sa-east-1"}, {Name: "unknown"}, {Name: "zeta", Region: "us-east-1"}}
	if len(got) != len(want) {
		t.Fatalf("got %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("got %v, want %v", got, want)
		}
	}
}

func TestListBucketsMapsErrors(t *testing.T) {
	cases := []struct {
		name string
		resp func(*http.Request) (*http.Response, error)
		want error
	}{
		{"denied", func(*http.Request) (*http.Response, error) { return reply(403, errorXML("AccessDenied"), nil), nil }, uploader.ErrListBucketsDenied},
		{"bad key", func(*http.Request) (*http.Response, error) {
			return reply(403, errorXML("InvalidAccessKeyId"), nil), nil
		}, uploader.ErrBadCredentials},
		{"no network", func(*http.Request) (*http.Response, error) {
			return nil, &net.OpError{Op: "dial", Err: errors.New("refused")}
		}, uploader.ErrNoNetwork},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			svc := &Buckets{httpClient: doFunc(tc.resp)}
			_, err := svc.List(context.Background(), testCreds)
			if !errors.Is(err, tc.want) {
				t.Fatalf("err = %v, want %v", err, tc.want)
			}
		})
	}
}

type doFunc func(*http.Request) (*http.Response, error)

func (f doFunc) Do(r *http.Request) (*http.Response, error) { return f(r) }

func TestCreateBucketSendsTheRegionAndNothingToWeakenPrivacy(t *testing.T) {
	svc, stub := newTestBuckets(func(*http.Request) *http.Response { return reply(200, "", nil) })
	if err := svc.Create(context.Background(), testCreds, "my-new-bucket"); err != nil {
		t.Fatal(err)
	}
	reqs := stub.requests()
	if len(reqs) != 1 || reqs[0].Method != http.MethodPut {
		t.Fatalf("requests = %d, want exactly one PUT (no public access block call)", len(reqs))
	}
	if !strings.Contains(stub.lastBody(), "<LocationConstraint>eu-west-1</LocationConstraint>") {
		t.Fatalf("body = %q, want the location constraint", stub.lastBody())
	}
	if a := reqs[0].Header.Get("x-amz-acl"); a != "" {
		t.Fatalf("x-amz-acl = %q, want none", a)
	}

	east := testCreds
	east.Region = "us-east-1"
	if err := svc.Create(context.Background(), east, "my-new-bucket"); err != nil {
		t.Fatal(err)
	}
	if strings.Contains(stub.lastBody(), "LocationConstraint") {
		t.Fatalf("us-east-1 takes no location constraint, body = %q", stub.lastBody())
	}
}

func TestCreateBucketMapsErrors(t *testing.T) {
	cases := []struct {
		code   string
		status int
		want   error
	}{
		{"BucketAlreadyExists", 409, buckets.ErrNameTaken},
		{"BucketAlreadyOwnedByYou", 409, buckets.ErrOwnedByYou},
		{"InvalidBucketName", 400, buckets.ErrInvalidName},
		{"AccessDenied", 403, buckets.ErrCreateDenied},
		{"InvalidAccessKeyId", 403, uploader.ErrBadCredentials},
		{"TooManyBuckets", 400, buckets.ErrTooManyBucket},
	}
	for _, tc := range cases {
		t.Run(tc.code, func(t *testing.T) {
			svc, _ := newTestBuckets(func(*http.Request) *http.Response { return reply(tc.status, errorXML(tc.code), nil) })
			err := svc.Create(context.Background(), testCreds, "my-new-bucket")
			if !errors.Is(err, tc.want) {
				t.Fatalf("err = %v, want %v", err, tc.want)
			}
		})
	}
}

func TestBucketsRejectMissingCredentialsWithoutCallingS3(t *testing.T) {
	svc, stub := newTestBuckets(func(*http.Request) *http.Response { return reply(200, "", nil) })
	if _, err := svc.List(context.Background(), buckets.Credentials{Region: "eu-west-1"}); err == nil {
		t.Fatal("want an error")
	}
	if len(stub.requests()) != 0 {
		t.Fatal("S3 must not be called without credentials")
	}
}
