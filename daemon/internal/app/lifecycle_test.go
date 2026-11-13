package app

import (
	"context"
	"errors"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"rabbithole/daemon/internal/logging"
	"rabbithole/daemon/internal/uploader"
)

func testLogger() (*logging.Logger, *syncBuffer) {
	buf := &syncBuffer{}
	return logging.New(buf, "info", serviceName), buf
}

// closeTrackingListener is a listener that binds nothing on disk.
type closeTrackingListener struct {
	net.Listener
	closed bool
}

func (l *closeTrackingListener) Close() error { l.closed = true; return nil }

func TestListenUnixFailsWhenTheDirectoryCannotBeCreated(t *testing.T) {
	blocker := filepath.Join(shortTempDir(t), "file")
	if err := os.WriteFile(blocker, nil, 0o600); err != nil {
		t.Fatal(err)
	}

	_, _, err := listenUnix(filepath.Join(blocker, "sub", "d.sock"), net.Listen)

	if err == nil || !strings.Contains(err.Error(), "create socket directory") {
		t.Fatalf("err = %v, want a create socket directory error", err)
	}
}

func TestListenUnixFailsWhenTheStalePathCannotBeRemoved(t *testing.T) {
	sock := filepath.Join(shortTempDir(t), "d.sock")
	if err := os.MkdirAll(filepath.Join(sock, "child"), 0o700); err != nil {
		t.Fatal(err)
	}

	_, _, err := listenUnix(sock, net.Listen)

	if err == nil || !strings.Contains(err.Error(), "remove stale socket") {
		t.Fatalf("err = %v, want a remove stale socket error", err)
	}
}

func TestListenUnixClosesTheListenerWhenTheSocketCannotBeRestricted(t *testing.T) {
	ln := &closeTrackingListener{}
	sock := filepath.Join(shortTempDir(t), "d.sock")

	_, _, err := listenUnix(sock, func(string, string) (net.Listener, error) { return ln, nil })

	if err == nil || !strings.Contains(err.Error(), "restrict socket permissions") {
		t.Fatalf("err = %v, want a restrict socket permissions error", err)
	}
	if !ln.closed {
		t.Fatal("the listener was left open")
	}
}

func TestRemoveOwnSocketIsQuietWhenTheSocketIsAlreadyGone(t *testing.T) {
	sock := filepath.Join(shortTempDir(t), "d.sock")
	if err := os.WriteFile(sock, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	created, err := os.Stat(sock)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(sock); err != nil {
		t.Fatal(err)
	}
	log, buf := testLogger()

	removeOwnSocket(log, sock, created)

	if out := buf.String(); out != "" {
		t.Fatalf("expected no log output, got %q", out)
	}
}

func TestRemoveOwnSocketWarnsWhenTheSocketCannotBeInspected(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root can read any directory")
	}
	dir := filepath.Join(shortTempDir(t), "locked")
	if err := os.Mkdir(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	sock := filepath.Join(dir, "d.sock")
	if err := os.WriteFile(sock, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	created, err := os.Stat(sock)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(dir, 0o000); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(dir, 0o700) })
	log, buf := testLogger()

	removeOwnSocket(log, sock, created)

	lines := logLines(t, buf.String())
	if len(lines) != 1 || lines[0]["msg"] != "could not inspect socket" || lines[0]["level"] != "warn" {
		t.Fatalf("log lines = %v, want one warning that the socket could not be inspected", lines)
	}
}

func TestAwaitShutdownReportsAnErrorWhenTheServerStopsByItself(t *testing.T) {
	log, buf := testLogger()
	stdinR, stdinW, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	defer stdinR.Close()
	defer stdinW.Close()
	serveErr := make(chan error, 1)
	serveErr <- errors.New("listener closed")

	code := awaitShutdown(context.Background(), log, stdinR, nil, serveErr)

	if code != exitError {
		t.Fatalf("exit code = %d, want %d", code, exitError)
	}
	lines := logLines(t, buf.String())
	if len(lines) != 1 || lines[0]["msg"] != "server stopped unexpectedly" || lines[0]["level"] != "error" {
		t.Fatalf("log lines = %v, want one error that the server stopped", lines)
	}
}

func TestRunnerReusesTheClientWhileSettingsStayTheSame(t *testing.T) {
	var built []uploader.Settings
	log, _ := testLogger()
	r := &runner{
		uploader: uploader.New(nil),
		log:      log,
		newS3: func(_ context.Context, s uploader.Settings) (uploader.S3, error) {
			built = append(built, s)
			return failingS3{}, nil
		},
	}
	first := uploader.Settings{AccessKeyID: "a", SecretAccessKey: "s", Region: "r", Bucket: "one"}
	second := first
	second.Bucket = "two"

	for _, s := range []uploader.Settings{first, first, second, second, first} {
		if _, err := r.client(context.Background(), s); err != nil {
			t.Fatal(err)
		}
	}

	want := []string{"one", "two", "one"}
	if len(built) != len(want) {
		t.Fatalf("clients built = %d, want %d", len(built), len(want))
	}
	for i, bucket := range want {
		if built[i].Bucket != bucket {
			t.Fatalf("client %d built for bucket %q, want %q", i, built[i].Bucket, bucket)
		}
	}
}

func TestRunnerDoesNotKeepAClientThatFailedToBuild(t *testing.T) {
	calls := 0
	log, _ := testLogger()
	r := &runner{
		uploader: uploader.New(nil),
		log:      log,
		newS3: func(context.Context, uploader.Settings) (uploader.S3, error) {
			calls++
			if calls == 1 {
				return nil, errors.New("boom")
			}
			return failingS3{}, nil
		},
	}
	s := uploader.Settings{AccessKeyID: "a", SecretAccessKey: "s", Region: "r", Bucket: "b"}

	if _, err := r.client(context.Background(), s); err == nil {
		t.Fatal("expected the first build to fail")
	}
	client, err := r.client(context.Background(), s)

	if err != nil || client == nil {
		t.Fatalf("second build: client = %v, err = %v; want a client", client, err)
	}
	if calls != 2 {
		t.Fatalf("factory calls = %d, want 2", calls)
	}
}

func TestFailureAfterCancellationIsLoggedAsAWarning(t *testing.T) {
	r, buf, _ := failureRunner(t, failingS3{})
	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	r.logFailure(ctx, "upload failed", "report.pdf", context.Canceled)

	lines := logLines(t, buf.String())
	if len(lines) != 1 || lines[0]["level"] != "warn" || lines[0]["file"] != "report.pdf" {
		t.Fatalf("log lines = %v, want one warning naming the file", lines)
	}
}
