package server_test

import (
	"bytes"
	"context"
	"errors"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/status"
	"google.golang.org/grpc/test/bufconn"

	pb "rabbithole/daemon/internal/gen/rabbithole/v1"
	"rabbithole/daemon/internal/logging"
	"rabbithole/daemon/internal/queue"
	"rabbithole/daemon/internal/server"
	"rabbithole/daemon/internal/uploader"
)

const testTimeout = 10 * time.Second

// runnerFunc adapts a function to queue.Runner.
type runnerFunc func(ctx context.Context, s uploader.Settings, req uploader.Request, cb uploader.Callbacks) error

func (f runnerFunc) Run(ctx context.Context, s uploader.Settings, req uploader.Request, cb uploader.Callbacks) error {
	return f(ctx, s, req, cb)
}

// syncBuffer is a bytes.Buffer safe for concurrent use.
type syncBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (b *syncBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.Write(p)
}

func (b *syncBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.String()
}

type env struct {
	client pb.DaemonClient
	server *server.Server // the same server the client talks to, for calling handlers directly
	queue  *queue.Queue
	logs   *syncBuffer
}

// fakeStream is the server side of a watch stream: it records what is sent and
// reports the context it is given, so a test can end the stream without gRPC.
type fakeStream[T any] struct {
	grpc.ServerStream
	ctx  context.Context
	sent chan T
	// failOn, when above zero, makes the failOn-th Send fail with errSendFailed.
	failOn int
	calls  int
}

var errSendFailed = errors.New("send failed")

func newFakeStream[T any](ctx context.Context) *fakeStream[T] {
	return &fakeStream[T]{ctx: ctx, sent: make(chan T, 64)}
}

func (s *fakeStream[T]) Context() context.Context { return s.ctx }

func (s *fakeStream[T]) Send(v T) error {
	s.calls++
	if s.calls == s.failOn {
		return errSendFailed
	}
	s.sent <- v
	return nil
}

func TestWatchReturnsTheErrorOfAFailedSend(t *testing.T) {
	for name, failOn := range map[string]int{"replayed snapshot": 1, "live update": 2} {
		t.Run(name, func(t *testing.T) {
			e := newEnv(t, noopRunner())
			if _, err := e.server.Configure(ctxT(t), validConfig()); err != nil {
				t.Fatal(err)
			}
			enqueue := func() {
				if _, err := e.server.EnqueueUpload(ctxT(t), &pb.EnqueueUploadRequest{LocalPath: writeFile(t, "a.txt", "x")}); err != nil {
					t.Error(err)
				}
			}
			enqueue()
			stream := newFakeStream[*pb.UploadSnapshot](ctxT(t))
			stream.failOn = failOn
			done := make(chan error, 1)
			go func() { done <- e.server.WatchUploads(&pb.WatchUploadsRequest{}, stream) }()
			if failOn == 2 {
				<-stream.sent // the replay is out, so the handler is waiting for updates
				enqueue()
			}
			select {
			case err := <-done:
				if !errors.Is(err, errSendFailed) {
					t.Fatalf("handler returned %v, want the send error", err)
				}
			case <-time.After(testTimeout):
				t.Fatal("handler did not return after a failed send")
			}
		})
	}
}

// assertHandlerReturnsWhenClientGoesAway runs a watch handler on a fake stream,
// waits for its first message, ends the stream's context, and requires the
// handler itself to return with the context's error.
func assertHandlerReturnsWhenClientGoesAway[T any](t *testing.T, handler func(stream *fakeStream[T]) error) {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	stream := newFakeStream[T](ctx)
	done := make(chan error, 1)
	go func() { done <- handler(stream) }()

	select {
	case <-stream.sent:
	case err := <-done:
		t.Fatalf("handler returned before the client went away: %v", err)
	case <-time.After(testTimeout):
		t.Fatal("handler sent nothing")
	}
	cancel()
	select {
	case err := <-done:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("handler returned %v, want context.Canceled", err)
		}
	case <-time.After(testTimeout):
		t.Fatal("handler did not return after the client went away")
	}
}

// startQueue runs the queue until the test ends. Tests call it when they want
// enqueued uploads to start; until then uploads stay Queued.
func (e *env) startQueue(t *testing.T) {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		defer close(done)
		e.queue.Run(ctx)
	}()
	t.Cleanup(func() {
		cancel()
		<-done
	})
}

func newEnv(t *testing.T, r queue.Runner) *env {
	t.Helper()
	logs := &syncBuffer{}
	q := queue.New(r, time.Now)
	srv := server.New(q, logging.New(logs, "debug", "rabbitholed"))

	lis := bufconn.Listen(1 << 20)
	gs := grpc.NewServer()
	pb.RegisterDaemonServer(gs, srv)
	go func() { _ = gs.Serve(lis) }()

	conn, err := grpc.NewClient("passthrough:///bufnet",
		grpc.WithContextDialer(func(context.Context, string) (net.Conn, error) { return lis.Dial() }),
		grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	t.Cleanup(func() {
		_ = conn.Close()
		gs.Stop()
	})
	return &env{client: pb.NewDaemonClient(conn), server: srv, queue: q, logs: logs}
}

func noopRunner() queue.Runner {
	return runnerFunc(func(context.Context, uploader.Settings, uploader.Request, uploader.Callbacks) error { return nil })
}

func validConfig() *pb.ConfigureRequest {
	return &pb.ConfigureRequest{
		AccessKeyId:        "AKIATESTKEYID",
		SecretAccessKey:    "test-secret-value",
		Region:             "us-east-1",
		Bucket:             "my-bucket",
		QuickUploadsPrefix: "quick",
	}
}

func writeFile(t *testing.T, name, content string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), name)
	if err := os.WriteFile(p, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
	return p
}

func ctxT(t *testing.T) context.Context {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), testTimeout)
	t.Cleanup(cancel)
	return ctx
}

func wantCode(t *testing.T, err error, want codes.Code) {
	t.Helper()
	if got := status.Code(err); got != want {
		t.Fatalf("code = %v (err %v), want %v", got, err, want)
	}
}

func TestEnqueueBeforeConfigureFailsPrecondition(t *testing.T) {
	e := newEnv(t, noopRunner())
	_, err := e.client.EnqueueUpload(ctxT(t), &pb.EnqueueUploadRequest{LocalPath: writeFile(t, "a.txt", "x")})
	wantCode(t, err, codes.FailedPrecondition)
}

func TestConfigureRejectsEmptyFields(t *testing.T) {
	tests := []struct {
		name   string
		mutate func(*pb.ConfigureRequest)
		want   codes.Code
	}{
		{"empty access key", func(r *pb.ConfigureRequest) { r.AccessKeyId = "" }, codes.InvalidArgument},
		{"empty secret", func(r *pb.ConfigureRequest) { r.SecretAccessKey = "" }, codes.InvalidArgument},
		{"empty region", func(r *pb.ConfigureRequest) { r.Region = "" }, codes.InvalidArgument},
		{"empty bucket", func(r *pb.ConfigureRequest) { r.Bucket = "" }, codes.InvalidArgument},
		{"empty prefix", func(r *pb.ConfigureRequest) { r.QuickUploadsPrefix = "" }, codes.InvalidArgument},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			e := newEnv(t, noopRunner())
			req := validConfig()
			tc.mutate(req)
			_, err := e.client.Configure(ctxT(t), req)
			wantCode(t, err, tc.want)
		})
	}
}

func TestEnqueueInvalidPath(t *testing.T) {
	e := newEnv(t, noopRunner())
	if _, err := e.client.Configure(ctxT(t), validConfig()); err != nil {
		t.Fatal(err)
	}
	for name, path := range map[string]string{
		"directory":    t.TempDir(),
		"missing file": filepath.Join(t.TempDir(), "missing.txt"),
	} {
		t.Run(name, func(t *testing.T) {
			_, err := e.client.EnqueueUpload(ctxT(t), &pb.EnqueueUploadRequest{LocalPath: path})
			wantCode(t, err, codes.InvalidArgument)
		})
	}
}

func TestEnqueueReturnsUploadID(t *testing.T) {
	e := newEnv(t, noopRunner())
	if _, err := e.client.Configure(ctxT(t), validConfig()); err != nil {
		t.Fatal(err)
	}
	resp, err := e.client.EnqueueUpload(ctxT(t), &pb.EnqueueUploadRequest{LocalPath: writeFile(t, "a.txt", "x")})
	if err != nil {
		t.Fatal(err)
	}
	if resp.GetUploadId() == "" {
		t.Fatal("upload id is empty")
	}
	initial, _, cancel := e.queue.Subscribe()
	cancel()
	if len(initial) != 1 || initial[0].ID != resp.GetUploadId() {
		t.Fatalf("queue snapshots = %+v, want one with id %q", initial, resp.GetUploadId())
	}
}

// recvUntil reads snapshots for id until match returns true.
func recvUntil(t *testing.T, stream pb.Daemon_WatchUploadsClient, id string, match func(*pb.UploadSnapshot) bool) *pb.UploadSnapshot {
	t.Helper()
	for {
		snap, err := stream.Recv()
		if err != nil {
			t.Fatalf("recv while waiting for %s: %v", id, err)
		}
		if snap.GetUploadId() == id && match(snap) {
			return snap
		}
	}
}

func TestWatchStreamsSnapshotsInOrder(t *testing.T) {
	release := make(chan struct{})
	runner := runnerFunc(func(ctx context.Context, _ uploader.Settings, req uploader.Request, cb uploader.Callbacks) error {
		if filepath.Base(req.LocalPath) == "bad.txt" {
			return uploader.ErrBadCredentials
		}
		cb.KeyResolved("quick/ok.txt")
		select {
		case <-release:
			return nil
		case <-ctx.Done():
			return ctx.Err()
		}
	})
	e := newEnv(t, runner)
	if _, err := e.client.Configure(ctxT(t), validConfig()); err != nil {
		t.Fatal(err)
	}
	okPath := writeFile(t, "ok.txt", "hello")
	badPath := writeFile(t, "bad.txt", "12345678")
	okResp, err := e.client.EnqueueUpload(ctxT(t), &pb.EnqueueUploadRequest{LocalPath: okPath})
	if err != nil {
		t.Fatal(err)
	}
	badResp, err := e.client.EnqueueUpload(ctxT(t), &pb.EnqueueUploadRequest{LocalPath: badPath})
	if err != nil {
		t.Fatal(err)
	}

	stream, err := e.client.WatchUploads(ctxT(t), &pb.WatchUploadsRequest{})
	if err != nil {
		t.Fatal(err)
	}
	// The queue is not running yet, so the replay holds both uploads as QUEUED.
	first := recvUntil(t, stream, okResp.GetUploadId(), func(*pb.UploadSnapshot) bool { return true })
	want := &pb.UploadSnapshot{
		UploadId:   okResp.GetUploadId(),
		FileName:   "ok.txt",
		LocalPath:  okPath,
		BytesTotal: 5,
		State:      pb.UploadState_QUEUED,
	}
	assertSnapshot(t, first, want)

	e.startQueue(t)

	// ok.txt blocks in the runner once its key is resolved, so UPLOADING with
	// the key is observable before it finishes.
	uploading := recvUntil(t, stream, okResp.GetUploadId(), func(s *pb.UploadSnapshot) bool {
		return s.GetState() == pb.UploadState_UPLOADING && s.GetObjectKey() != ""
	})
	want.State, want.ObjectKey = pb.UploadState_UPLOADING, "quick/ok.txt"
	assertSnapshot(t, uploading, want)

	close(release)
	finished := recvUntil(t, stream, okResp.GetUploadId(), func(s *pb.UploadSnapshot) bool {
		return s.GetState() == pb.UploadState_FINISHED
	})
	want.State, want.BytesSent = pb.UploadState_FINISHED, 5
	assertSnapshot(t, finished, want)

	failed := recvUntil(t, stream, badResp.GetUploadId(), func(s *pb.UploadSnapshot) bool {
		return s.GetState() == pb.UploadState_FAILED
	})
	assertSnapshot(t, failed, &pb.UploadSnapshot{
		UploadId:     badResp.GetUploadId(),
		FileName:     "bad.txt",
		LocalPath:    badPath,
		BytesTotal:   8,
		State:        pb.UploadState_FAILED,
		ErrorMessage: uploader.Message(uploader.ErrBadCredentials),
	})
}

func assertSnapshot(t *testing.T, got, want *pb.UploadSnapshot) {
	t.Helper()
	if got.GetUploadId() != want.GetUploadId() ||
		got.GetFileName() != want.GetFileName() ||
		got.GetLocalPath() != want.GetLocalPath() ||
		got.GetObjectKey() != want.GetObjectKey() ||
		got.GetBytesTotal() != want.GetBytesTotal() ||
		got.GetBytesSent() != want.GetBytesSent() ||
		got.GetState() != want.GetState() ||
		got.GetErrorMessage() != want.GetErrorMessage() {
		t.Fatalf("snapshot = %v, want %v", got, want)
	}
}

func TestWatchReplaysExistingUploadsOnSubscribe(t *testing.T) {
	e := newEnv(t, noopRunner())
	if _, err := e.client.Configure(ctxT(t), validConfig()); err != nil {
		t.Fatal(err)
	}
	var ids []string
	for _, name := range []string{"one.txt", "two.txt", "three.txt"} {
		resp, err := e.client.EnqueueUpload(ctxT(t), &pb.EnqueueUploadRequest{LocalPath: writeFile(t, name, "x")})
		if err != nil {
			t.Fatal(err)
		}
		ids = append(ids, resp.GetUploadId())
	}

	stream, err := e.client.WatchUploads(ctxT(t), &pb.WatchUploadsRequest{})
	if err != nil {
		t.Fatal(err)
	}
	for _, id := range ids {
		snap, err := stream.Recv()
		if err != nil {
			t.Fatal(err)
		}
		if snap.GetUploadId() != id || snap.GetState() != pb.UploadState_QUEUED {
			t.Fatalf("replayed %v, want %s queued", snap, id)
		}
	}
}

func TestWatchEndsWhenClientContextEnds(t *testing.T) {
	e := newEnv(t, noopRunner())
	if _, err := e.server.Configure(ctxT(t), validConfig()); err != nil {
		t.Fatal(err)
	}
	if _, err := e.server.EnqueueUpload(ctxT(t), &pb.EnqueueUploadRequest{LocalPath: writeFile(t, "a.txt", "x")}); err != nil {
		t.Fatal(err)
	}
	assertHandlerReturnsWhenClientGoesAway(t, func(stream *fakeStream[*pb.UploadSnapshot]) error {
		return e.server.WatchUploads(&pb.WatchUploadsRequest{}, stream)
	})
}

func TestSettingsCapturedAtEnqueue(t *testing.T) {
	seen := make(chan uploader.Settings, 2)
	runner := runnerFunc(func(_ context.Context, s uploader.Settings, _ uploader.Request, _ uploader.Callbacks) error {
		seen <- s
		return nil
	})
	e := newEnv(t, runner)

	a, b := validConfig(), validConfig()
	a.Bucket, b.Bucket = "bucket-a", "bucket-b"
	b.QuickUploadsPrefix = "other"

	for _, cfg := range []*pb.ConfigureRequest{a, b} {
		if _, err := e.client.Configure(ctxT(t), cfg); err != nil {
			t.Fatal(err)
		}
		if _, err := e.client.EnqueueUpload(ctxT(t), &pb.EnqueueUploadRequest{LocalPath: writeFile(t, "f.txt", "x")}); err != nil {
			t.Fatal(err)
		}
	}
	e.startQueue(t)

	for _, want := range []uploader.Settings{
		{AccessKeyID: a.AccessKeyId, SecretAccessKey: a.SecretAccessKey, Region: a.Region, Bucket: "bucket-a", Prefix: "quick"},
		{AccessKeyID: b.AccessKeyId, SecretAccessKey: b.SecretAccessKey, Region: b.Region, Bucket: "bucket-b", Prefix: "other"},
	} {
		select {
		case got := <-seen:
			if got != want {
				t.Fatalf("runner saw %+v, want %+v", got, want)
			}
		case <-time.After(testTimeout):
			t.Fatal("timed out waiting for the runner")
		}
	}
}

func TestSecretNeverLogged(t *testing.T) {
	runner := runnerFunc(func(_ context.Context, _ uploader.Settings, _ uploader.Request, _ uploader.Callbacks) error {
		return errors.New("boom")
	})
	e := newEnv(t, runner)
	e.startQueue(t)

	cfg := validConfig()
	if _, err := e.client.Configure(ctxT(t), cfg); err != nil {
		t.Fatal(err)
	}
	// Both failure and success paths of Enqueue must stay clean too.
	_, err := e.client.EnqueueUpload(ctxT(t), &pb.EnqueueUploadRequest{LocalPath: filepath.Join(t.TempDir(), "missing")})
	wantCode(t, err, codes.InvalidArgument)
	if _, err := e.client.EnqueueUpload(ctxT(t), &pb.EnqueueUploadRequest{LocalPath: writeFile(t, "a.txt", "x")}); err != nil {
		t.Fatal(err)
	}

	logs := e.logs.String()
	if logs == "" {
		t.Fatal("server logged nothing; the test would pass vacuously")
	}
	for _, secret := range []string{cfg.AccessKeyId, cfg.SecretAccessKey} {
		if strings.Contains(logs, secret) {
			t.Fatalf("logs contain a credential %q:\n%s", secret, logs)
		}
		if strings.Contains(err.Error(), secret) {
			t.Fatalf("status error contains a credential %q: %v", secret, err)
		}
	}
}
