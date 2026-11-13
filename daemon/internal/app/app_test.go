package app

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	awshttp "github.com/aws/aws-sdk-go-v2/aws/transport/http"
	"github.com/aws/smithy-go"
	smithyhttp "github.com/aws/smithy-go/transport/http"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"

	pb "rabbithole/daemon/internal/gen/rabbithole/v1"
	"rabbithole/daemon/internal/logging"
	"rabbithole/daemon/internal/uploader"
)

const (
	shutdownBound = 1500 * time.Millisecond
	waitTimeout   = 10 * time.Second
)

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

// runnerFunc adapts a function to queue.Runner.
type runnerFunc func(ctx context.Context, s uploader.Settings, req uploader.Request, cb uploader.Callbacks) error

func (f runnerFunc) Run(ctx context.Context, s uploader.Settings, req uploader.Request, cb uploader.Callbacks) error {
	return f(ctx, s, req, cb)
}

// harness runs the app in a goroutine against a short temp directory.
type harness struct {
	t       *testing.T
	sock    string
	stdinW  *os.File
	signals chan os.Signal
	stderr  *syncBuffer
	done    chan int
	cancel  context.CancelFunc
}

func shortTempDir(t *testing.T) string {
	t.Helper()
	dir, err := os.MkdirTemp("/tmp", "rh")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	return dir
}

func start(t *testing.T, sock string, opts options) *harness {
	t.Helper()
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { r.Close(); w.Close() })

	h := &harness{
		t:       t,
		sock:    sock,
		stdinW:  w,
		signals: make(chan os.Signal, 1),
		stderr:  &syncBuffer{},
		done:    make(chan int, 1),
	}
	opts.signals = h.signals
	ctx, cancel := context.WithCancel(context.Background())
	h.cancel = cancel
	t.Cleanup(cancel)
	go func() { h.done <- run(ctx, []string{"--socket", sock}, r, h.stderr, opts) }()
	return h
}

// waitListening blocks until the socket accepts connections.
func (h *harness) waitListening() {
	h.t.Helper()
	deadline := time.Now().Add(waitTimeout)
	for time.Now().Before(deadline) {
		select {
		case code := <-h.done:
			h.t.Fatalf("app exited early with %d: %s", code, h.stderr.String())
		default:
		}
		if c, err := net.Dial("unix", h.sock); err == nil {
			c.Close()
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	h.t.Fatalf("socket never accepted connections; stderr: %s", h.stderr.String())
}

// expectExit waits for run to return and checks it did so within the bound
// of the moment the trigger fired.
func (h *harness) expectExit(since time.Time, want int) {
	h.t.Helper()
	select {
	case code := <-h.done:
		if elapsed := time.Since(since); elapsed > shutdownBound {
			h.t.Fatalf("took %v to exit, want at most %v", elapsed, shutdownBound)
		}
		if code != want {
			h.t.Fatalf("exit code = %d, want %d; stderr: %s", code, want, h.stderr.String())
		}
	case <-time.After(waitTimeout):
		h.t.Fatal("run did not return")
	}
}

func dial(t *testing.T, sock string) pb.DaemonClient {
	t.Helper()
	conn, err := grpc.NewClient("unix://"+sock, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { conn.Close() })
	return pb.NewDaemonClient(conn)
}

func TestMissingSocketFlagPrintsOneJSONLineAndExits2(t *testing.T) {
	var stderr bytes.Buffer
	code := Run(context.Background(), nil, strings.NewReader(""), &stderr)
	if code != 2 {
		t.Fatalf("exit code = %d, want 2", code)
	}
	out := stderr.String()
	if strings.Count(out, "\n") != 1 || !strings.HasSuffix(out, "\n") {
		t.Fatalf("stderr is not exactly one line: %q", out)
	}
	var rec map[string]any
	if err := json.Unmarshal([]byte(out), &rec); err != nil {
		t.Fatalf("stderr is not valid JSON: %v: %q", err, out)
	}
	for _, k := range []string{"time", "level", "msg", "service"} {
		if _, ok := rec[k]; !ok {
			t.Errorf("missing field %q in %q", k, out)
		}
	}
}

func TestUnknownFlagPrintsOneJSONLineAndExits2(t *testing.T) {
	var stderr bytes.Buffer
	code := Run(context.Background(), []string{"--bogus"}, strings.NewReader(""), &stderr)
	if code != 2 {
		t.Fatalf("exit code = %d, want 2", code)
	}
	if strings.Count(stderr.String(), "\n") != 1 {
		t.Fatalf("stderr is not exactly one line: %q", stderr.String())
	}
}

func TestSocketModeIs0600(t *testing.T) {
	sock := filepath.Join(shortTempDir(t), "d.sock")
	h := start(t, sock, options{})
	h.waitListening()

	info, err := os.Stat(sock)
	if err != nil {
		t.Fatal(err)
	}
	if perm := info.Mode().Perm(); perm != 0o600 {
		t.Fatalf("socket mode = %o, want 600", perm)
	}
	h.stdinW.Close()
	h.expectExit(time.Now(), 0)
}

func TestSocketIsCreatedWithMode0600FromTheStart(t *testing.T) {
	sock := filepath.Join(shortTempDir(t), "d.sock")
	var modeAtListen os.FileMode
	listen := func(network, address string) (net.Listener, error) {
		ln, err := net.Listen(network, address)
		if err == nil {
			if info, statErr := os.Stat(address); statErr == nil {
				modeAtListen = info.Mode().Perm()
			}
		}
		return ln, err
	}
	h := start(t, sock, options{listen: listen})
	h.waitListening()
	h.stdinW.Close()
	h.expectExit(time.Now(), 0)
	if modeAtListen != 0o600 {
		t.Fatalf("socket mode right after listen = %o, want 600", modeAtListen)
	}
}

func TestSocketDirectoryIsForcedTo0700(t *testing.T) {
	dir := filepath.Join(shortTempDir(t), "sub")
	if err := os.Mkdir(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	h := start(t, filepath.Join(dir, "d.sock"), options{})
	h.waitListening()
	h.stdinW.Close()
	h.expectExit(time.Now(), 0)

	info, err := os.Stat(dir)
	if err != nil {
		t.Fatal(err)
	}
	if perm := info.Mode().Perm(); perm != 0o700 {
		t.Fatalf("socket directory mode = %o, want 700", perm)
	}
}

func TestSocketReplacedByAnotherFileIsLeftInPlaceOnExit(t *testing.T) {
	sock := filepath.Join(shortTempDir(t), "d.sock")
	h := start(t, sock, options{})
	h.waitListening()

	// A newer daemon takes over the path while this one is still running.
	if err := os.Remove(sock); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(sock, []byte("newer daemon"), 0o600); err != nil {
		t.Fatal(err)
	}
	h.stdinW.Close()
	h.expectExit(time.Now(), 0)

	got, err := os.ReadFile(sock)
	if err != nil || string(got) != "newer daemon" {
		t.Fatalf("replacement socket was touched: %q, %v", got, err)
	}
}

func TestSocketDirectoryIsCreated(t *testing.T) {
	sock := filepath.Join(shortTempDir(t), "sub", "d.sock")
	h := start(t, sock, options{})
	h.waitListening()
	h.stdinW.Close()
	h.expectExit(time.Now(), 0)
}

func TestStaleSocketFileIsReplaced(t *testing.T) {
	sock := filepath.Join(shortTempDir(t), "d.sock")
	if err := os.WriteFile(sock, []byte("stale"), 0o600); err != nil {
		t.Fatal(err)
	}
	h := start(t, sock, options{})
	h.waitListening()
	h.stdinW.Close()
	h.expectExit(time.Now(), 0)
}

func TestSocketIsRemovedOnExit(t *testing.T) {
	sock := filepath.Join(shortTempDir(t), "d.sock")
	h := start(t, sock, options{})
	h.waitListening()
	h.stdinW.Close()
	h.expectExit(time.Now(), 0)
	if _, err := os.Stat(sock); !os.IsNotExist(err) {
		t.Fatalf("socket still present after exit: %v", err)
	}
}

func TestExitsWithin1500msOfStdinEOF(t *testing.T) {
	sock := filepath.Join(shortTempDir(t), "d.sock")
	h := start(t, sock, options{})
	h.waitListening()

	since := time.Now()
	h.stdinW.Close()
	h.expectExit(since, 0)
}

func TestExitsWithin1500msOfSIGTERM(t *testing.T) {
	sock := filepath.Join(shortTempDir(t), "d.sock")
	h := start(t, sock, options{})
	h.waitListening()

	since := time.Now()
	h.signals <- syscall.SIGTERM
	h.expectExit(since, 0)
}

func TestExitsWithin1500msOfContextCancel(t *testing.T) {
	sock := filepath.Join(shortTempDir(t), "d.sock")
	h := start(t, sock, options{})
	h.waitListening()

	since := time.Now()
	h.cancel()
	h.expectExit(since, 0)
}

func TestShutdownDeadlineWhenAbortHangs(t *testing.T) {
	sock := filepath.Join(shortTempDir(t), "d.sock")
	started := make(chan struct{})
	release := make(chan struct{})
	t.Cleanup(func() { close(release) })
	stuck := runnerFunc(func(ctx context.Context, _ uploader.Settings, _ uploader.Request, _ uploader.Callbacks) error {
		close(started)
		<-release // ignores ctx, like an abort call that never returns
		return nil
	})
	h := start(t, sock, options{runner: stuck})
	h.waitListening()

	file := filepath.Join(shortTempDir(t), "f.bin")
	if err := os.WriteFile(file, []byte("data"), 0o600); err != nil {
		t.Fatal(err)
	}
	client := dial(t, sock)
	ctx, cancel := context.WithTimeout(context.Background(), waitTimeout)
	defer cancel()
	if _, err := client.Configure(ctx, &pb.ConfigureRequest{
		AccessKeyId: "id", SecretAccessKey: "secret", Region: "us-east-1", Bucket: "b", QuickUploadsPrefix: "quick-uploads/",
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := client.EnqueueUpload(ctx, &pb.EnqueueUploadRequest{LocalPath: file}); err != nil {
		t.Fatal(err)
	}
	// An open watch stream keeps GracefulStop waiting until the timer fires.
	stream, err := client.WatchUploads(ctx, &pb.WatchUploadsRequest{})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := stream.Recv(); err != nil {
		t.Fatal(err)
	}
	select {
	case <-started:
	case <-time.After(waitTimeout):
		t.Fatal("runner never started")
	}

	since := time.Now()
	h.stdinW.Close()
	h.expectExit(since, 0)
}

func TestNoTCPListener(t *testing.T) {
	sock := filepath.Join(shortTempDir(t), "d.sock")
	var (
		mu       sync.Mutex
		networks []string
		lns      []net.Listener
	)
	listen := func(network, addr string) (net.Listener, error) {
		ln, err := net.Listen(network, addr)
		mu.Lock()
		networks = append(networks, network)
		if ln != nil {
			lns = append(lns, ln)
		}
		mu.Unlock()
		return ln, err
	}
	h := start(t, sock, options{listen: listen})
	h.waitListening()

	mu.Lock()
	defer mu.Unlock()
	if len(networks) != 1 || networks[0] != "unix" {
		t.Fatalf("listened on %v, want exactly [unix]", networks)
	}
	if _, ok := lns[0].(*net.UnixListener); !ok {
		t.Fatalf("listener is %T, want *net.UnixListener", lns[0])
	}
	h.stdinW.Close()
	h.expectExit(time.Now(), 0)
}

func TestListenFailurePrintsOneJSONLineAndExits1(t *testing.T) {
	sock := filepath.Join(shortTempDir(t), "d.sock")
	var stderr bytes.Buffer
	listen := func(string, string) (net.Listener, error) { return nil, io.ErrClosedPipe }
	code := run(context.Background(), []string{"--socket", sock}, strings.NewReader(""), &stderr, options{listen: listen})
	if code != 1 {
		t.Fatalf("exit code = %d, want 1", code)
	}
	if strings.Count(stderr.String(), "\n") != 1 {
		t.Fatalf("stderr is not exactly one line: %q", stderr.String())
	}
	lines := logLines(t, stderr.String())
	if len(lines) != 1 {
		t.Fatalf("stderr holds %d JSON lines, want 1: %q", len(lines), stderr.String())
	}
	line := lines[0]
	if line["level"] != "error" || line["service"] != serviceName {
		t.Errorf("level = %v, service = %v; want error, %s", line["level"], line["service"], serviceName)
	}
	if msg, _ := line["msg"].(string); !strings.Contains(msg, io.ErrClosedPipe.Error()) {
		t.Errorf("msg = %q, want it to carry the listen error %q", msg, io.ErrClosedPipe)
	}
	if _, ok := line["time"]; !ok {
		t.Errorf("missing time field: %v", line)
	}
}

func TestRunnerBuildsClientFromJobSettingsThenUploads(t *testing.T) {
	file := filepath.Join(shortTempDir(t), "f.bin")
	if err := os.WriteFile(file, []byte("data"), 0o600); err != nil {
		t.Fatal(err)
	}
	var gotSettings uploader.Settings
	factory := func(_ context.Context, s uploader.Settings) (uploader.S3, error) {
		gotSettings = s
		return fakeS3{}, nil
	}
	r := &runner{uploader: uploader.New(time.Now), newS3: factory, log: logging.New(io.Discard, "info", serviceName)}
	want := uploader.Settings{AccessKeyID: "id", SecretAccessKey: "secret", Region: "r", Bucket: "b", Prefix: "p/"}

	var key string
	err := r.Run(context.Background(), want, uploader.Request{Prefix: "p/", LocalPath: file},
		uploader.Callbacks{KeyResolved: func(k string) { key = k }})
	if err != nil {
		t.Fatal(err)
	}
	if gotSettings != want {
		t.Fatalf("factory got %v, want %v", gotSettings, want)
	}
	if !strings.HasPrefix(key, "p/") {
		t.Fatalf("resolved key = %q, want prefix p/", key)
	}
}

const helperSocketEnv = "RABBITHOLE_TEST_HELPER_SOCKET"

// TestHelperDaemon is not a test: when the parent test re-executes this
// binary with helperSocketEnv set, it runs the real daemon entrypoint so the
// parent can observe the process's real stderr.
func TestHelperDaemon(t *testing.T) {
	sock := os.Getenv(helperSocketEnv)
	if sock == "" {
		t.Skip("helper process only")
	}
	os.Exit(Run(context.Background(), []string{"--socket", sock}, os.Stdin, os.Stderr))
}

func TestGRPCLibraryNeverWritesNonJSONToStderr(t *testing.T) {
	sock := filepath.Join(shortTempDir(t), "d.sock")
	cmd := exec.Command(os.Args[0], "-test.run=^TestHelperDaemon$")
	cmd.Env = append(os.Environ(),
		helperSocketEnv+"="+sock,
		// Make the default gRPC logger as chatty as it can be.
		"GRPC_GO_LOG_SEVERITY_LEVEL=info",
		"GRPC_GO_LOG_VERBOSITY_LEVEL=99",
	)
	stdin, err := cmd.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	stderr := &syncBuffer{}
	cmd.Stderr = stderr
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	exited := make(chan struct{})
	go func() { _ = cmd.Wait(); close(exited) }()
	t.Cleanup(func() {
		select {
		case <-exited:
		default:
			_ = cmd.Process.Kill()
			<-exited
		}
	})

	deadline := time.Now().Add(waitTimeout)
	for {
		if c, err := net.Dial("unix", sock); err == nil {
			c.Close()
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("daemon never listened; stderr: %s", stderr.String())
		}
		time.Sleep(5 * time.Millisecond)
	}

	// Garbage instead of an HTTP/2 preface, then an abrupt disconnect.
	if c, err := net.Dial("unix", sock); err == nil {
		_, _ = c.Write([]byte("this is not http2 \x00\xff\x01 garbage\r\n\r\n"))
		_ = c.Close()
	}
	// A truncated preface followed by a disconnect.
	if c, err := net.Dial("unix", sock); err == nil {
		_, _ = c.Write([]byte("PRI * HTTP/2.0\r\n\r\nSM"))
		_ = c.Close()
	}
	// A real client that connects, makes a call and drops the connection.
	conn, err := grpc.NewClient("unix://"+sock, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	_, _ = pb.NewDaemonClient(conn).Configure(ctx, &pb.ConfigureRequest{})
	cancel()
	conn.Close()
	time.Sleep(200 * time.Millisecond) // let the server notice the closed connections

	_ = stdin.Close()
	select {
	case <-exited:
	case <-time.After(waitTimeout):
		t.Fatal("daemon did not exit")
	}

	out := stderr.String()
	lines := logLines(t, out) // fails on any line that is not JSON
	if len(lines) == 0 {
		t.Fatalf("expected the daemon's own JSON log lines, got none: %q", out)
	}
}

const (
	leakTestKeyID  = "AKIATESTKEYID123456"
	leakTestSecret = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYTESTSECRET"
)

// failingS3 is a fakeS3 whose part upload and abort fail with scripted errors.
type failingS3 struct {
	fakeS3
	putErr   error
	partErr  error
	abortErr error
}

func (f failingS3) PutObject(context.Context, string, io.Reader, int64) error { return f.putErr }
func (f failingS3) UploadPart(context.Context, string, string, int32, io.Reader, int64) (string, error) {
	return "", f.partErr
}
func (f failingS3) AbortMultipart(context.Context, string, string) error { return f.abortErr }

// awsFailure is an error shaped like the SDK's: it carries an API code and an
// HTTP status, and its text echoes the credentials the way a request dump would.
func awsFailure(code string, status int) error {
	api := &smithy.GenericAPIError{Code: code, Message: "request for " + leakTestKeyID + " signed with " + leakTestSecret}
	return &awshttp.ResponseError{ResponseError: &smithyhttp.ResponseError{
		Response: &smithyhttp.Response{Response: &http.Response{StatusCode: status}},
		Err:      api,
	}}
}

func logLines(t *testing.T, out string) []map[string]any {
	t.Helper()
	var lines []map[string]any
	for _, l := range strings.Split(strings.TrimSpace(out), "\n") {
		if l == "" {
			continue
		}
		var m map[string]any
		if err := json.Unmarshal([]byte(l), &m); err != nil {
			t.Fatalf("log line is not JSON: %q", l)
		}
		lines = append(lines, m)
	}
	return lines
}

func failureRunner(t *testing.T, s3 uploader.S3) (*runner, *syncBuffer, uploader.Settings) {
	t.Helper()
	buf := &syncBuffer{}
	r := &runner{
		uploader: uploader.New(time.Now),
		newS3:    func(context.Context, uploader.Settings) (uploader.S3, error) { return s3, nil },
		log:      logging.New(buf, "info", serviceName),
	}
	settings := uploader.Settings{AccessKeyID: leakTestKeyID, SecretAccessKey: leakTestSecret, Region: "r", Bucket: "b", Prefix: "p/"}
	return r, buf, settings
}

func TestFailedUploadLogsOneJSONLineWithDiagnosticFields(t *testing.T) {
	cause := awsFailure("SlowDown", 503)
	r, buf, settings := failureRunner(t, failingS3{putErr: cause})
	file := filepath.Join(shortTempDir(t), "report.pdf")
	if err := os.WriteFile(file, []byte("data"), 0o600); err != nil {
		t.Fatal(err)
	}

	err := r.Run(context.Background(), settings, uploader.Request{Prefix: "p/", LocalPath: file}, uploader.Callbacks{})
	if err == nil {
		t.Fatal("expected the upload to fail")
	}
	lines := logLines(t, buf.String())
	if len(lines) != 1 {
		t.Fatalf("got %d log lines, want exactly 1: %s", len(lines), buf.String())
	}
	line := lines[0]
	want := map[string]any{
		"level": "error", "msg": "upload failed", "service": serviceName,
		"file": "report.pdf", "reason": "Upload failed", "aws_code": "SlowDown", "http_status": float64(503),
	}
	for k, v := range want {
		if line[k] != v {
			t.Errorf("field %q = %v, want %v (line: %v)", k, line[k], v, line)
		}
	}
	if out := buf.String(); strings.Contains(out, leakTestKeyID) || strings.Contains(out, leakTestSecret) {
		t.Fatalf("log output leaks credentials: %s", out)
	}
}

func TestFailedUploadWithoutAWSDetailsOmitsThem(t *testing.T) {
	r, buf, settings := failureRunner(t, failingS3{putErr: uploader.ErrNoNetwork})
	file := filepath.Join(shortTempDir(t), "a.txt")
	if err := os.WriteFile(file, []byte("data"), 0o600); err != nil {
		t.Fatal(err)
	}
	_ = r.Run(context.Background(), settings, uploader.Request{Prefix: "p/", LocalPath: file}, uploader.Callbacks{})
	lines := logLines(t, buf.String())
	if len(lines) != 1 {
		t.Fatalf("got %d log lines, want 1: %s", len(lines), buf.String())
	}
	if _, ok := lines[0]["aws_code"]; ok {
		t.Errorf("aws_code present without an AWS error: %v", lines[0])
	}
	if _, ok := lines[0]["http_status"]; ok {
		t.Errorf("http_status present without an AWS error: %v", lines[0])
	}
	if lines[0]["reason"] != "No internet connection" {
		t.Errorf("reason = %v", lines[0]["reason"])
	}
}

func TestFailedClientConstructionLogsTheUploadFailure(t *testing.T) {
	buf := &syncBuffer{}
	r := &runner{
		uploader: uploader.New(time.Now),
		newS3:    func(context.Context, uploader.Settings) (uploader.S3, error) { return nil, errors.New("bad settings") },
		log:      logging.New(buf, "info", serviceName),
	}
	err := r.Run(context.Background(), uploader.Settings{}, uploader.Request{LocalPath: "/x/y.txt"}, uploader.Callbacks{})
	if err == nil {
		t.Fatal("expected an error")
	}
	lines := logLines(t, buf.String())
	if len(lines) != 1 || lines[0]["msg"] != "upload failed" || lines[0]["file"] != "y.txt" {
		t.Fatalf("unexpected log output: %s", buf.String())
	}
}

func TestFailedMultipartAbortIsLogged(t *testing.T) {
	r, buf, settings := failureRunner(t, failingS3{partErr: uploader.ErrNoNetwork, abortErr: awsFailure("InternalError", 500)})
	file := filepath.Join(shortTempDir(t), "big.bin")
	if err := os.WriteFile(file, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Truncate(file, 16*uploader.MiB); err != nil {
		t.Fatal(err)
	}

	_ = r.Run(context.Background(), settings, uploader.Request{Prefix: "p/", LocalPath: file}, uploader.Callbacks{})
	lines := logLines(t, buf.String())
	if len(lines) != 2 {
		t.Fatalf("got %d log lines, want the abort failure and the upload failure: %s", len(lines), buf.String())
	}
	abort := lines[0]
	if abort["msg"] != "multipart abort failed" || abort["file"] != "big.bin" ||
		abort["aws_code"] != "InternalError" || abort["http_status"] != float64(500) {
		t.Errorf("unexpected abort line: %v", abort)
	}
	if lines[1]["msg"] != "upload failed" {
		t.Errorf("unexpected second line: %v", lines[1])
	}
	if out := buf.String(); strings.Contains(out, leakTestKeyID) || strings.Contains(out, leakTestSecret) {
		t.Fatalf("log output leaks credentials: %s", out)
	}
}

// fakeS3 accepts every write and reports no existing objects.
type fakeS3 struct{}

func (fakeS3) ObjectExists(context.Context, string) (bool, error) { return false, nil }
func (fakeS3) PutObject(_ context.Context, _ string, body io.Reader, _ int64) error {
	_, err := io.Copy(io.Discard, body)
	return err
}
func (fakeS3) PrefixExists(context.Context, string) (bool, error)      { return false, nil }
func (fakeS3) CreateMultipart(context.Context, string) (string, error) { return "id", nil }
func (fakeS3) UploadPart(_ context.Context, _, _ string, _ int32, body io.Reader, _ int64) (string, error) {
	_, err := io.Copy(io.Discard, body)
	return "etag", err
}
func (fakeS3) CompleteMultipart(context.Context, string, string, []uploader.CompletedPart) error {
	return nil
}
func (fakeS3) AbortMultipart(context.Context, string, string) error { return nil }
