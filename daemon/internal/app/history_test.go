package app

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	pb "rabbithole/daemon/internal/gen/rabbithole/v1"
	"rabbithole/daemon/internal/history"
	"rabbithole/daemon/internal/queue"
	"rabbithole/daemon/internal/uploader"
)

const (
	markerSecret = "SECRET-MARKER-9f3a61c2"
	markerKeyID  = "KEYID-MARKER-77d0b4e8"
)

// startWithArgs is start with the command line chosen by the test.
func startWithArgs(t *testing.T, args []string, opts options) *harness {
	t.Helper()
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { r.Close(); w.Close() })
	h := &harness{t: t, stdinW: w, signals: make(chan os.Signal, 1), stderr: &syncBuffer{}, done: make(chan int, 1)}
	for i, a := range args {
		if a == "--socket" {
			h.sock = args[i+1]
		}
	}
	opts.signals = h.signals
	ctx, cancel := context.WithCancel(context.Background())
	h.cancel = cancel
	t.Cleanup(cancel)
	go func() { h.done <- run(ctx, args, r, h.stderr, opts) }()
	return h
}

func (h *harness) stop() {
	h.t.Helper()
	h.stdinW.Close()
	h.expectExit(time.Now(), 0)
}

func okUpload() runnerFunc {
	return func(context.Context, uploader.Settings, uploader.Request, uploader.Callbacks) error { return nil }
}

func configureAs(t *testing.T, client pb.DaemonClient, bucket string) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), waitTimeout)
	defer cancel()
	if _, err := client.Configure(ctx, &pb.ConfigureRequest{
		AccessKeyId: markerKeyID, SecretAccessKey: markerSecret, Region: "us-east-1", Bucket: bucket, QuickUploadsPrefix: "quick/",
	}); err != nil {
		t.Fatal(err)
	}
}

// firstSnapshot returns the first upload the daemon replays to a new watcher.
func firstSnapshot(t *testing.T, client pb.DaemonClient) *pb.UploadSnapshot {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), waitTimeout)
	defer cancel()
	stream, err := client.WatchUploads(ctx, &pb.WatchUploadsRequest{})
	if err != nil {
		t.Fatal(err)
	}
	s, err := stream.Recv()
	if err != nil {
		t.Fatal(err)
	}
	return s
}

func TestParseArgsDatabaseDefaultsToHistoryDbNextToTheSocket(t *testing.T) {
	cfg, err := parseArgs([]string{"--socket", "/run/rh/d.sock"})
	if err != nil {
		t.Fatal(err)
	}
	if want := filepath.Join("/run/rh", "history.db"); cfg.database != want || cfg.socket != "/run/rh/d.sock" {
		t.Errorf("config = %+v, want database %q", cfg, want)
	}
}

func TestParseArgsDatabaseFlagOverridesTheDefault(t *testing.T) {
	cfg, err := parseArgs([]string{"--socket", "/run/rh/d.sock", "--database", "/data/my.db"})
	if err != nil {
		t.Fatal(err)
	}
	if cfg.database != "/data/my.db" {
		t.Errorf("database = %q, want /data/my.db", cfg.database)
	}
}

func TestDatabaseIsCreatedNextToTheSocketByDefault(t *testing.T) {
	dir := shortTempDir(t)
	h := startWithArgs(t, []string{"--socket", filepath.Join(dir, "d.sock")}, options{runner: okUpload()})
	h.waitListening()
	h.stop()

	if _, err := os.Stat(filepath.Join(dir, "history.db")); err != nil {
		t.Errorf("history.db was not created next to the socket: %v", err)
	}
}

func TestDatabaseFlagChoosesWhereTheHistoryLives(t *testing.T) {
	dir := shortTempDir(t)
	db := filepath.Join(dir, "elsewhere", "mine.db")
	h := startWithArgs(t, []string{"--socket", filepath.Join(dir, "d.sock"), "--database", db}, options{runner: okUpload()})
	h.waitListening()
	h.stop()

	if _, err := os.Stat(db); err != nil {
		t.Errorf("database not created at %s: %v", db, err)
	}
	if _, err := os.Stat(filepath.Join(dir, "history.db")); err == nil {
		t.Error("history.db was created although --database pointed elsewhere")
	}
}

func TestDatabaseThatCannotBeOpenedIsABootFailure(t *testing.T) {
	dir := shortTempDir(t)
	sock := filepath.Join(dir, "d.sock")
	var stderr bytes.Buffer
	code := run(context.Background(), []string{"--socket", sock, "--database", dir}, strings.NewReader(""), &stderr, options{runner: okUpload()})

	if code != 1 {
		t.Fatalf("exit code = %d, want 1", code)
	}
	lines := logLines(t, stderr.String())
	if strings.Count(stderr.String(), "\n") != 1 || len(lines) != 1 {
		t.Fatalf("stderr is not exactly one JSON line: %q", stderr.String())
	}
	if msg, _ := lines[0]["msg"].(string); lines[0]["level"] != "error" || !strings.Contains(msg, "boot failed") || !strings.Contains(msg, "database") {
		t.Errorf("line = %v, want an error that says the boot failed on the database", lines[0])
	}
	if _, err := os.Stat(sock); err == nil {
		t.Error("the socket was created although the database could not be opened")
	}
}

func TestHistoryIsReplayedAfterARestart(t *testing.T) {
	dir := shortTempDir(t)
	sock := filepath.Join(dir, "d.sock")
	file := filepath.Join(dir, "f.bin")
	if err := os.WriteFile(file, []byte("data"), 0o600); err != nil {
		t.Fatal(err)
	}

	h := startWithArgs(t, []string{"--socket", sock}, options{runner: okUpload()})
	h.waitListening()
	client := dial(t, sock)
	configureAs(t, client, "bucket-1")
	ctx, cancel := context.WithTimeout(context.Background(), waitTimeout)
	defer cancel()
	resp, err := client.EnqueueUpload(ctx, &pb.EnqueueUploadRequest{LocalPath: file})
	if err != nil {
		t.Fatal(err)
	}
	for snap := firstSnapshot(t, client); snap.GetState() != pb.UploadState_FINISHED; snap = firstSnapshot(t, client) {
		time.Sleep(10 * time.Millisecond)
	}
	h.stop()

	again := startWithArgs(t, []string{"--socket", sock}, options{runner: okUpload()})
	again.waitListening()
	client2 := dial(t, sock)
	if s := watchOnce(t, client2, 300*time.Millisecond); s != nil {
		t.Fatalf("replayed %v before Configure, want nothing", s)
	}
	configureAs(t, client2, "bucket-1")
	got := firstSnapshot(t, client2)
	if got.GetUploadId() != resp.GetUploadId() || got.GetState() != pb.UploadState_FINISHED || got.GetFileName() != "f.bin" ||
		got.GetCreatedAtMs() == 0 || got.GetEndedAtMs() == 0 || got.GetBytesTotal() != 4 || got.GetBytesSent() != 4 {
		t.Errorf("replayed %v, want the finished upload of f.bin with its times and bytes", got)
	}
	files, err := client2.WatchUploadFiles(ctx, &pb.WatchUploadFilesRequest{UploadId: resp.GetUploadId()})
	if err != nil {
		t.Fatal(err)
	}
	if f, err := files.Recv(); err != nil || f.GetRelativePath() != "f.bin" || f.GetState() != pb.UploadState_FINISHED || f.GetBytesSent() != 4 {
		t.Errorf("file = %v (err %v), want f.bin finished", f, err)
	}
	again.stop()
}

// watchOnce returns the first snapshot of a new watch stream, or nil if none
// arrives within d.
func watchOnce(t *testing.T, client pb.DaemonClient, d time.Duration) *pb.UploadSnapshot {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	stream, err := client.WatchUploads(ctx, &pb.WatchUploadsRequest{})
	if err != nil {
		t.Fatal(err)
	}
	got := make(chan *pb.UploadSnapshot, 1)
	go func() {
		if s, err := stream.Recv(); err == nil {
			got <- s
		}
	}()
	select {
	case s := <-got:
		return s
	case <-time.After(d):
		return nil
	}
}

func TestUploadCutOffByACrashIsFailedAsInterruptedWhenTheDaemonStarts(t *testing.T) {
	dir := shortTempDir(t)
	sock := filepath.Join(dir, "d.sock")
	dbPath := filepath.Join(dir, "history.db")

	// What a crashed daemon leaves behind: an upload still marked as running.
	st, err := history.Open(dbPath)
	if err != nil {
		t.Fatal(err)
	}
	rec := queue.UploadRecord{
		Snapshot: queue.Snapshot{ID: "cut-off", FileName: "big.bin", LocalPath: "/x/big.bin", State: queue.Uploading, FilesTotal: 1,
			RootPaths: []string{"/x/big.bin"}, CreatedAt: time.UnixMilli(1_700_000_000_000)},
		Bucket: "bucket-1", Region: "us-east-1", Prefix: "quick/", Parallel: 4,
	}
	file := queue.FileRecord{Snapshot: queue.FileSnapshot{UploadID: "cut-off", Index: 0, RelativePath: "big.bin", LocalPath: "/x/big.bin", State: queue.Uploading}}
	if err := st.CreateUpload(rec, []queue.ItemRecord{{Path: "/x/big.bin", DestName: "big.bin"}}, []queue.FileRecord{file}); err != nil {
		t.Fatal(err)
	}
	if err := st.Close(); err != nil {
		t.Fatal(err)
	}

	h := startWithArgs(t, []string{"--socket", sock}, options{runner: okUpload()})
	h.waitListening()
	client := dial(t, sock)
	configureAs(t, client, "bucket-1")

	got := firstSnapshot(t, client)
	if got.GetUploadId() != "cut-off" || got.GetState() != pb.UploadState_FAILED || got.GetErrorMessage() != "Upload interrupted" || got.GetEndedAtMs() == 0 {
		t.Errorf("replayed %v, want the upload failed with %q", got, "Upload interrupted")
	}
	ctx, cancel := context.WithTimeout(context.Background(), waitTimeout)
	defer cancel()
	files, err := client.WatchUploadFiles(ctx, &pb.WatchUploadFilesRequest{UploadId: "cut-off"})
	if err != nil {
		t.Fatal(err)
	}
	if f, err := files.Recv(); err != nil || f.GetState() != pb.UploadState_FAILED || f.GetErrorMessage() != "Upload interrupted" {
		t.Errorf("file = %v (err %v), want failed with %q", f, err, "Upload interrupted")
	}
	h.stop()
}

func TestCredentialsNeverReachTheDatabaseFile(t *testing.T) {
	dir := shortTempDir(t)
	sock := filepath.Join(dir, "d.sock")
	file := filepath.Join(dir, "f.bin")
	if err := os.WriteFile(file, []byte("data"), 0o600); err != nil {
		t.Fatal(err)
	}
	h := startWithArgs(t, []string{"--socket", sock}, options{runner: okUpload()})
	h.waitListening()
	client := dial(t, sock)
	configureAs(t, client, "bucket-marker")
	ctx, cancel := context.WithTimeout(context.Background(), waitTimeout)
	defer cancel()
	if _, err := client.EnqueueUpload(ctx, &pb.EnqueueUploadRequest{LocalPath: file}); err != nil {
		t.Fatal(err)
	}
	for snap := firstSnapshot(t, client); snap.GetState() != pb.UploadState_FINISHED; snap = firstSnapshot(t, client) {
		time.Sleep(10 * time.Millisecond)
	}
	h.stop()

	entries, err := filepath.Glob(filepath.Join(dir, "history.db*"))
	if err != nil || len(entries) == 0 {
		t.Fatalf("no database files found: %v", err)
	}
	var all []byte
	for _, name := range entries {
		b, err := os.ReadFile(name)
		if err != nil {
			t.Fatal(err)
		}
		all = append(all, b...)
	}
	if !bytes.Contains(all, []byte("bucket-marker")) {
		t.Fatal("the database does not even hold the bucket, so this search proves nothing")
	}
	for _, secret := range []string{markerSecret, markerKeyID} {
		if bytes.Contains(all, []byte(secret)) {
			t.Errorf("the database holds %q", secret)
		}
		if strings.Contains(h.stderr.String(), secret) {
			t.Errorf("the log holds %q", secret)
		}
	}
}
