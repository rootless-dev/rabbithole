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

	"github.com/aws/smithy-go"

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

func TestObjectExistsTreatsNotFoundAsFalse(t *testing.T) {
	c, stub := newTestClient(t, func(r *http.Request) *http.Response { return reply(404, "", nil) })
	exists, err := c.ObjectExists(context.Background(), "a/b.txt")
	if err != nil || exists {
		t.Fatalf("ObjectExists = %v, %v; want false, nil", exists, err)
	}
	reqs := stub.requests()
	if len(reqs) != 1 || reqs[0].Method != http.MethodHead {
		t.Fatalf("expected a single HEAD request, got %d", len(reqs))
	}
}

func TestObjectExistsTrueOn200(t *testing.T) {
	c, _ := newTestClient(t, func(r *http.Request) *http.Response { return reply(200, "", nil) })
	exists, err := c.ObjectExists(context.Background(), "a/b.txt")
	if err != nil || !exists {
		t.Fatalf("ObjectExists = %v, %v; want true, nil", exists, err)
	}
}

func TestObjectExistsForbiddenOn403(t *testing.T) {
	c, _ := newTestClient(t, func(r *http.Request) *http.Response { return reply(403, "", nil) })
	exists, err := c.ObjectExists(context.Background(), "a/b.txt")
	if exists || !errors.Is(err, uploader.ErrForbidden) {
		t.Fatalf("ObjectExists = %v, %v; want false, ErrForbidden", exists, err)
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
