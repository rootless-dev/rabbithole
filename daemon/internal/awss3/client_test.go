package awss3

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"strings"
	"sync"
	"testing"

	awshttp "github.com/aws/aws-sdk-go-v2/aws/transport/http"
	"github.com/aws/smithy-go"
	smithyhttp "github.com/aws/smithy-go/transport/http"

	"rabbithole/daemon/internal/uploader"
)

func TestMapError(t *testing.T) {
	api := func(code string) error {
		return &smithy.GenericAPIError{Code: code, Message: "boom"}
	}
	tests := []struct {
		name string
		err  error
		want error
	}{
		{"no such bucket", api("NoSuchBucket"), uploader.ErrBucketNotFound},
		{"invalid access key", api("InvalidAccessKeyId"), uploader.ErrBadCredentials},
		{"signature mismatch", api("SignatureDoesNotMatch"), uploader.ErrBadCredentials},
		{"precondition failed", api("PreconditionFailed"), uploader.ErrPreconditionFailed},
		{"conditional request conflict", api("ConditionalRequestConflict"), uploader.ErrPreconditionFailed},
		{"access denied on a write", api("AccessDenied"), uploader.ErrWriteDenied},
		{"network error", &net.OpError{Op: "dial", Net: "tcp", Err: errors.New("connection refused")}, uploader.ErrNoNetwork},
		{"wrapped api error", fmt.Errorf("operation error S3: PutObject: %w", api("NoSuchBucket")), uploader.ErrBucketNotFound},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := mapError(tt.err)
			if !errors.Is(got, tt.want) {
				t.Fatalf("mapError(%v) = %v, want %v", tt.err, got, tt.want)
			}
		})
	}
}

func TestMapErrorLeavesOtherErrorsAlone(t *testing.T) {
	if got := mapError(nil); got != nil {
		t.Fatalf("mapError(nil) = %v, want nil", got)
	}
	unknown := &smithy.GenericAPIError{Code: "InternalError", Message: "boom"}
	if got := mapError(unknown); got != error(unknown) {
		t.Fatalf("unknown API error was changed: %v", got)
	}
	if got := mapError(context.Canceled); !errors.Is(got, context.Canceled) || errors.Is(got, uploader.ErrNoNetwork) {
		t.Fatalf("context.Canceled must pass through, got %v", got)
	}
}

func TestErrorDetails(t *testing.T) {
	api := &smithy.GenericAPIError{Code: "SlowDown", Message: "secret-looking text"}
	withStatus := &awshttp.ResponseError{
		ResponseError: &smithyhttp.ResponseError{
			Response: &smithyhttp.Response{Response: &http.Response{StatusCode: 503}},
			Err:      api,
		},
	}
	tests := []struct {
		name       string
		err        error
		wantCode   string
		wantStatus int
	}{
		{"nil", nil, "", 0},
		{"plain error", errors.New("boom"), "", 0},
		{"api error only", fmt.Errorf("wrapped: %w", api), "SlowDown", 0},
		{"api error with status", fmt.Errorf("wrapped: %w", withStatus), "SlowDown", 503},
		{"mapped sentinel keeps details", mapError(withStatus), "SlowDown", 503},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			code, status := ErrorDetails(tt.err)
			if code != tt.wantCode || status != tt.wantStatus {
				t.Fatalf("ErrorDetails = %q, %d; want %q, %d", code, status, tt.wantCode, tt.wantStatus)
			}
		})
	}
}

// stubTransport answers every request with respond and records the requests.
type stubTransport struct {
	mu      sync.Mutex
	reqs    []*http.Request
	bodies  []string
	respond func(r *http.Request) *http.Response
}

func (s *stubTransport) Do(r *http.Request) (*http.Response, error) {
	var body []byte
	if r.Body != nil {
		// Read fully so the SDK's body handling and checksums run.
		body, _ = io.ReadAll(r.Body)
	}
	s.mu.Lock()
	s.reqs = append(s.reqs, r)
	s.bodies = append(s.bodies, string(body))
	s.mu.Unlock()
	return s.respond(r), nil
}

func (s *stubTransport) lastBody() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.bodies[len(s.bodies)-1]
}

func (s *stubTransport) requests() []*http.Request {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]*http.Request(nil), s.reqs...)
}

func reply(status int, body string, headers map[string]string) *http.Response {
	h := http.Header{}
	for k, v := range headers {
		h.Set(k, v)
	}
	return &http.Response{
		StatusCode: status,
		Status:     fmt.Sprintf("%d %s", status, http.StatusText(status)),
		Header:     h,
		Body:       io.NopCloser(strings.NewReader(body)),
	}
}

func newTestClient(t *testing.T, respond func(r *http.Request) *http.Response) (uploader.S3, *stubTransport) {
	t.Helper()
	stub := &stubTransport{respond: respond}
	c, err := newClient(uploader.Settings{
		AccessKeyID:     "AKIDEXAMPLE",
		SecretAccessKey: "secret-example",
		Region:          "us-east-1",
		Bucket:          "my-bucket",
	}, stub)
	if err != nil {
		t.Fatalf("newClient: %v", err)
	}
	return c, stub
}

func errorXML(code string) string {
	return `<?xml version="1.0" encoding="UTF-8"?><Error><Code>` + code + `</Code><Message>x</Message></Error>`
}

// listXML builds a ListObjectsV2 response holding the given keys.
func listXML(keys ...string) string {
	var b strings.Builder
	b.WriteString(`<?xml version="1.0" encoding="UTF-8"?><ListBucketResult><Name>my-bucket</Name><MaxKeys>1</MaxKeys><IsTruncated>false</IsTruncated>`)
	fmt.Fprintf(&b, "<KeyCount>%d</KeyCount>", len(keys))
	for _, k := range keys {
		b.WriteString("<Contents><Key>" + k + "</Key><Size>1</Size></Contents>")
	}
	b.WriteString("</ListBucketResult>")
	return b.String()
}

func TestObjectExistsListsWithTheKeyAsPrefix(t *testing.T) {
	c, stub := newTestClient(t, func(r *http.Request) *http.Response { return reply(200, listXML("a/b.txt"), nil) })
	exists, err := c.ObjectExists(context.Background(), "a/b.txt")
	if err != nil || !exists {
		t.Fatalf("ObjectExists = %v, %v; want true, nil", exists, err)
	}
	reqs := stub.requests()
	if len(reqs) != 1 || reqs[0].Method != http.MethodGet {
		t.Fatalf("expected a single GET request, got %d", len(reqs))
	}
	q := reqs[0].URL.Query()
	if q.Get("list-type") != "2" || q.Get("prefix") != "a/b.txt" || q.Get("max-keys") != "1" {
		t.Fatalf("unexpected list query: %v", q)
	}
}

func TestObjectExistsFalseWhenKeyAbsent(t *testing.T) {
	c, _ := newTestClient(t, func(r *http.Request) *http.Response { return reply(200, listXML(), nil) })
	exists, err := c.ObjectExists(context.Background(), "a/b.txt")
	if err != nil || exists {
		t.Fatalf("ObjectExists = %v, %v; want false, nil", exists, err)
	}
}

func TestObjectExistsFalseWhenOnlyALongerKeyMatches(t *testing.T) {
	c, _ := newTestClient(t, func(r *http.Request) *http.Response { return reply(200, listXML("a/b.txt.bak"), nil) })
	exists, err := c.ObjectExists(context.Background(), "a/b.txt")
	if err != nil || exists {
		t.Fatalf("ObjectExists = %v, %v; want false, nil", exists, err)
	}
}

func TestObjectExistsMapsErrors(t *testing.T) {
	tests := []struct {
		name   string
		status int
		code   string
		want   error
	}{
		{"access denied", 403, "AccessDenied", uploader.ErrForbidden},
		{"invalid access key", 403, "InvalidAccessKeyId", uploader.ErrBadCredentials},
		{"signature mismatch", 403, "SignatureDoesNotMatch", uploader.ErrBadCredentials},
		{"no such bucket", 404, "NoSuchBucket", uploader.ErrBucketNotFound},
		{"permanent redirect", 301, "PermanentRedirect", uploader.ErrWrongRegion},
		{"authorization header malformed", 400, "AuthorizationHeaderMalformed", uploader.ErrWrongRegion},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			c, _ := newTestClient(t, func(r *http.Request) *http.Response { return reply(tt.status, errorXML(tt.code), nil) })
			exists, err := c.ObjectExists(context.Background(), "a/b.txt")
			if exists || !errors.Is(err, tt.want) {
				t.Fatalf("ObjectExists = %v, %v; want false, %v", exists, err, tt.want)
			}
		})
	}
}

func TestObjectExistsNeverSendsHead(t *testing.T) {
	for _, resp := range []func() *http.Response{
		func() *http.Response { return reply(200, listXML("k"), nil) },
		func() *http.Response { return reply(200, listXML(), nil) },
		func() *http.Response { return reply(403, errorXML("AccessDenied"), nil) },
		func() *http.Response { return reply(404, errorXML("NoSuchBucket"), nil) },
	} {
		c, stub := newTestClient(t, func(r *http.Request) *http.Response { return resp() })
		_, _ = c.ObjectExists(context.Background(), "k")
		for _, r := range stub.requests() {
			if r.Method == http.MethodHead {
				t.Fatalf("ObjectExists sent a HEAD request: %s", r.URL)
			}
		}
	}
}

func TestWrongRegionMapsOnWriteCalls(t *testing.T) {
	c, _ := newTestClient(t, func(r *http.Request) *http.Response { return reply(301, errorXML("PermanentRedirect"), nil) })
	err := c.PutObject(context.Background(), "k", strings.NewReader("x"), 1)
	if !errors.Is(err, uploader.ErrWrongRegion) {
		t.Fatalf("PutObject error = %v, want ErrWrongRegion", err)
	}
}

func TestPutObjectSendsIfNoneMatch(t *testing.T) {
	c, stub := newTestClient(t, func(r *http.Request) *http.Response {
		return reply(200, "", map[string]string{"ETag": `"abc"`})
	})
	// A non-seekable reader mirrors what the uploader may hand over.
	body := io.LimitReader(strings.NewReader("hello"), 5)
	if err := c.PutObject(context.Background(), "a/b.txt", body, 5); err != nil {
		t.Fatalf("PutObject: %v", err)
	}
	reqs := stub.requests()
	if len(reqs) != 1 || reqs[0].Method != http.MethodPut {
		t.Fatalf("expected a single PUT, got %d requests", len(reqs))
	}
	if got := reqs[0].Header.Get("If-None-Match"); got != "*" {
		t.Fatalf("If-None-Match = %q, want *", got)
	}
}

// onlyRead hides every method of the wrapped reader except Read, so it is
// neither seekable nor sized, like the uploader's counting reader.
type onlyRead struct{ r io.Reader }

func (o onlyRead) Read(p []byte) (int, error) { return o.r.Read(p) }

func TestNonSeekableBodiesAreSentVerbatim(t *testing.T) {
	payload := strings.Repeat("rabbithole", 1000)
	size := int64(len(payload))
	c, stub := newTestClient(t, func(r *http.Request) *http.Response {
		return reply(200, "", map[string]string{"ETag": `"e"`})
	})
	ctx := context.Background()

	calls := map[string]func() error{
		"PutObject": func() error { return c.PutObject(ctx, "k", onlyRead{strings.NewReader(payload)}, size) },
		"UploadPart": func() error {
			_, err := c.UploadPart(ctx, "k", "up-1", 1, onlyRead{strings.NewReader(payload)}, size)
			return err
		},
	}
	for name, call := range calls {
		t.Run(name, func(t *testing.T) {
			before := len(stub.requests())
			if err := call(); err != nil {
				t.Fatalf("%s: %v", name, err)
			}
			reqs := stub.requests()
			if len(reqs) != before+1 {
				t.Fatalf("expected one request, got %d", len(reqs)-before)
			}
			r := reqs[len(reqs)-1]
			if r.URL.Scheme != "https" {
				t.Fatalf("request must use TLS, got %s", r.URL)
			}
			// net/http sends Request.ContentLength as the Content-Length header.
			if r.ContentLength != size {
				t.Fatalf("ContentLength = %d, want %d", r.ContentLength, size)
			}
			if got := stub.lastBody(); got != payload {
				t.Fatalf("body differs from input: got %d bytes, want %d", len(got), len(payload))
			}
			if got := r.Header.Get("X-Amz-Content-Sha256"); got != "UNSIGNED-PAYLOAD" {
				t.Fatalf("X-Amz-Content-Sha256 = %q, want UNSIGNED-PAYLOAD", got)
			}
		})
	}
}

func TestRetryNeverResendsNonSeekableBody(t *testing.T) {
	c, stub := newTestClient(t, func(r *http.Request) *http.Response {
		return reply(503, `<?xml version="1.0"?><Error><Code>SlowDown</Code><Message>x</Message></Error>`, nil)
	})
	err := c.PutObject(context.Background(), "k", onlyRead{strings.NewReader("hello")}, 5)
	if err == nil {
		t.Fatal("expected an error")
	}
	if n := len(stub.requests()); n != 1 {
		t.Fatalf("expected exactly 1 attempt, got %d", n)
	}
}

func TestConflictStatusesMapToPreconditionFailed(t *testing.T) {
	for _, tc := range []struct {
		status int
		code   string
	}{{412, "PreconditionFailed"}, {409, "ConditionalRequestConflict"}} {
		t.Run(tc.code, func(t *testing.T) {
			c, _ := newTestClient(t, func(r *http.Request) *http.Response {
				return reply(tc.status, `<?xml version="1.0"?><Error><Code>`+tc.code+`</Code><Message>x</Message></Error>`, nil)
			})
			err := c.PutObject(context.Background(), "k", onlyRead{strings.NewReader("hello")}, 5)
			if !errors.Is(err, uploader.ErrPreconditionFailed) {
				t.Fatalf("got %v, want ErrPreconditionFailed", err)
			}
		})
	}
}

func TestPutObjectMapsPreconditionFailed(t *testing.T) {
	c, _ := newTestClient(t, func(r *http.Request) *http.Response {
		return reply(412, `<?xml version="1.0"?><Error><Code>PreconditionFailed</Code><Message>x</Message></Error>`, nil)
	})
	err := c.PutObject(context.Background(), "a/b.txt", strings.NewReader("hello"), 5)
	if !errors.Is(err, uploader.ErrPreconditionFailed) {
		t.Fatalf("PutObject error = %v, want ErrPreconditionFailed", err)
	}
}

func TestPutObjectMapsAccessDeniedToWriteDenied(t *testing.T) {
	c, _ := newTestClient(t, func(r *http.Request) *http.Response {
		return reply(403, `<?xml version="1.0"?><Error><Code>AccessDenied</Code><Message>x</Message></Error>`, nil)
	})
	err := c.PutObject(context.Background(), "a/b.txt", strings.NewReader("hello"), 5)
	if !errors.Is(err, uploader.ErrWriteDenied) {
		t.Fatalf("PutObject error = %v, want ErrWriteDenied", err)
	}
}

func TestMultipartFlow(t *testing.T) {
	c, stub := newTestClient(t, func(r *http.Request) *http.Response {
		q := r.URL.Query()
		switch {
		case r.Method == http.MethodPost && q.Has("uploads"):
			return reply(200, `<?xml version="1.0"?><InitiateMultipartUploadResult><Bucket>my-bucket</Bucket><Key>k</Key><UploadId>up-1</UploadId></InitiateMultipartUploadResult>`, nil)
		case r.Method == http.MethodPut && q.Has("partNumber"):
			return reply(200, "", map[string]string{"ETag": `"etag-` + q.Get("partNumber") + `"`})
		case r.Method == http.MethodPost && q.Has("uploadId"):
			return reply(200, `<?xml version="1.0"?><CompleteMultipartUploadResult><Bucket>my-bucket</Bucket><Key>k</Key><ETag>"final"</ETag></CompleteMultipartUploadResult>`, nil)
		case r.Method == http.MethodDelete && q.Has("uploadId"):
			return reply(204, "", nil)
		}
		return reply(500, "", nil)
	})
	ctx := context.Background()

	id, err := c.CreateMultipart(ctx, "k")
	if err != nil || id != "up-1" {
		t.Fatalf("CreateMultipart = %q, %v", id, err)
	}
	etag, err := c.UploadPart(ctx, "k", id, 1, strings.NewReader("part"), 4)
	if err != nil || etag != `"etag-1"` {
		t.Fatalf("UploadPart = %q, %v", etag, err)
	}
	if err := c.CompleteMultipart(ctx, "k", id, []uploader.CompletedPart{{Number: 1, ETag: etag}}); err != nil {
		t.Fatalf("CompleteMultipart: %v", err)
	}
	if err := c.AbortMultipart(ctx, "k", id); err != nil {
		t.Fatalf("AbortMultipart: %v", err)
	}

	var completeSeen bool
	for _, r := range stub.requests() {
		if r.Method == http.MethodPost && r.URL.Query().Has("uploadId") {
			completeSeen = true
			if got := r.Header.Get("If-None-Match"); got != "*" {
				t.Fatalf("CompleteMultipartUpload If-None-Match = %q, want *", got)
			}
		}
	}
	if !completeSeen {
		t.Fatal("no CompleteMultipartUpload request seen")
	}
}

func TestCompleteMultipartMapsPreconditionFailed(t *testing.T) {
	c, _ := newTestClient(t, func(r *http.Request) *http.Response {
		return reply(412, `<?xml version="1.0"?><Error><Code>PreconditionFailed</Code><Message>x</Message></Error>`, nil)
	})
	err := c.CompleteMultipart(context.Background(), "k", "up-1", []uploader.CompletedPart{{Number: 1, ETag: `"e"`}})
	if !errors.Is(err, uploader.ErrPreconditionFailed) {
		t.Fatalf("CompleteMultipart error = %v, want ErrPreconditionFailed", err)
	}
}

func TestNewRejectsIncompleteSettings(t *testing.T) {
	_, err := New(context.Background(), uploader.Settings{})
	if err == nil {
		t.Fatal("New with empty settings must fail")
	}
}
