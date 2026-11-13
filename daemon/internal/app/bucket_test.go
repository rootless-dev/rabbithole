package app

import (
	"context"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	pb "rabbithole/daemon/internal/gen/rabbithole/v1"
	"rabbithole/daemon/internal/uploader"
)

// bucketS3 is an S3 that remembers what was written to it, records the delete
// batches it receives, and can block its listings until the context ends.
type bucketS3 struct {
	fakeS3
	mu        sync.Mutex
	keys      map[string]bool
	batches   [][]string
	listCalls int
	blockList bool
	inList    chan struct{} // closed when a blocked listing starts
	failBatch int           // the 1-based batch that fails with ErrDeleteDenied, 0 for none
}

func newBucketS3() *bucketS3 {
	return &bucketS3{keys: map[string]bool{}, inList: make(chan struct{})}
}

func (b *bucketS3) ObjectExists(_ context.Context, key string) (bool, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.keys[key], nil
}

func (b *bucketS3) PutObject(_ context.Context, key string, body io.Reader, _ int64) error {
	if _, err := io.Copy(io.Discard, body); err != nil {
		return err
	}
	b.mu.Lock()
	b.keys[key] = true
	b.mu.Unlock()
	return nil
}

func (b *bucketS3) DeleteObjects(_ context.Context, keys []string) ([]string, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.batches = append(b.batches, slices.Clone(keys))
	if b.failBatch == len(b.batches) {
		return nil, uploader.ErrDeleteDenied
	}
	for _, k := range keys {
		delete(b.keys, k)
	}
	return keys, nil
}

func (b *bucketS3) ListKeys(ctx context.Context, prefix string, visit func(string)) error {
	b.mu.Lock()
	b.listCalls++
	block := b.blockList
	var found []string
	for k := range b.keys {
		if strings.HasPrefix(k, prefix) {
			found = append(found, k)
		}
	}
	b.mu.Unlock()
	if block {
		select {
		case <-b.inList:
		default:
			close(b.inList)
		}
		<-ctx.Done()
		return ctx.Err()
	}
	for _, k := range found {
		visit(k)
	}
	return nil
}

func (b *bucketS3) has(key string) bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.keys[key]
}

func (b *bucketS3) drop(key string) {
	b.mu.Lock()
	defer b.mu.Unlock()
	delete(b.keys, key)
}

func (b *bucketS3) batchSizes() []int {
	b.mu.Lock()
	defer b.mu.Unlock()
	var sizes []int
	for _, batch := range b.batches {
		sizes = append(sizes, len(batch))
	}
	return sizes
}

func TestRunnerDeletesInBatchesOfAThousand(t *testing.T) {
	b := newBucketS3()
	r, _, settings := failureRunner(t, b)
	keys := make([]string, 2500)
	for i := range keys {
		keys[i] = fmt.Sprintf("p/k%04d", i)
	}

	deleted, err := r.DeleteObjects(context.Background(), settings, keys)

	if err != nil || len(deleted) != 2500 {
		t.Fatalf("deleted %d, err %v; want all", len(deleted), err)
	}
	if got := b.batchSizes(); fmt.Sprint(got) != "[1000 1000 500]" {
		t.Fatalf("batch sizes = %v, want [1000 1000 500]", got)
	}
}

func TestRunnerDeleteFailureLogsOneLineWithoutCredentials(t *testing.T) {
	b := newBucketS3()
	b.failBatch = 2
	r, buf, settings := failureRunner(t, b)
	keys := make([]string, 1500)
	for i := range keys {
		keys[i] = fmt.Sprintf("p/k%04d", i)
	}

	deleted, err := r.DeleteObjects(context.Background(), settings, keys)

	if err == nil || len(deleted) != 1000 {
		t.Fatalf("deleted %d, err %v; want the first batch deleted and an error", len(deleted), err)
	}
	lines := logLines(t, buf.String())
	if len(lines) != 1 || lines[0]["msg"] != "delete from bucket failed" || lines[0]["level"] != "error" ||
		lines[0]["reason"] != uploader.Message(uploader.ErrDeleteDenied) {
		t.Fatalf("log lines = %v, want one delete failure with the readable reason", lines)
	}
	if out := buf.String(); strings.Contains(out, leakTestKeyID) || strings.Contains(out, leakTestSecret) {
		t.Fatalf("log output leaks credentials: %s", out)
	}
}

// sendFile uploads a small file through the daemon at sock and waits for it to
// finish. It returns the upload id.
func sendFile(t *testing.T, client pb.DaemonClient, name string) string {
	t.Helper()
	file := filepath.Join(shortTempDir(t), name)
	if err := os.WriteFile(file, []byte("data"), 0o600); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), waitTimeout)
	defer cancel()
	resp, err := client.EnqueueUpload(ctx, &pb.EnqueueUploadRequest{LocalPath: file})
	if err != nil {
		t.Fatal(err)
	}
	stream, err := client.WatchUploads(ctx, &pb.WatchUploadsRequest{})
	if err != nil {
		t.Fatal(err)
	}
	for {
		s, err := stream.Recv()
		if err != nil {
			t.Fatal(err)
		}
		if s.GetUploadId() == resp.GetUploadId() && s.GetState() == pb.UploadState_FINISHED {
			return resp.GetUploadId()
		}
	}
}

// replayedIDs returns the ids of the uploads a new watcher is replayed: every
// snapshot that arrives before the stream has been quiet for a moment.
func replayedIDs(t *testing.T, client pb.DaemonClient) []string {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 300*time.Millisecond)
	defer cancel()
	stream, err := client.WatchUploads(ctx, &pb.WatchUploadsRequest{})
	if err != nil {
		t.Fatal(err)
	}
	var ids []string
	for {
		s, err := stream.Recv()
		if err != nil {
			return ids
		}
		ids = append(ids, s.GetUploadId())
	}
}

func startWithBucket(t *testing.T, b *bucketS3) (*harness, pb.DaemonClient) {
	t.Helper()
	sock := filepath.Join(shortTempDir(t), "d.sock")
	h := start(t, sock, options{newS3: func(context.Context, uploader.Settings) (uploader.S3, error) { return b, nil }})
	h.waitListening()
	return h, dial(t, sock)
}

func waitFor(t *testing.T, what string, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(waitTimeout)
	for time.Now().Before(deadline) {
		if cond() {
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for %s", what)
}

func TestDaemonRemovesFromTheHistoryAFileThatVanishedFromTheBucket(t *testing.T) {
	b := newBucketS3()
	h, client := startWithBucket(t, b)
	configureAs(t, client, "bucket-1")
	kept := sendFile(t, client, "kept.txt")
	sendFile(t, client, "gone.txt")
	b.drop("quick/gone.txt")

	// An upload ending triggers a pass too; a new Configure makes sure one runs now.
	configureAs(t, client, "bucket-1")

	waitFor(t, "the vanished upload to leave the history", func() bool {
		return slices.Equal(replayedIDs(t, client), []string{kept})
	})
	if !b.has("quick/kept.txt") {
		t.Fatal("the object that is still there was deleted")
	}
	h.stop()
	if !strings.Contains(h.stderr.String(), `"msg":"history reconciled"`) {
		t.Fatalf("no reconciliation line in the log: %s", h.stderr.String())
	}
	if out := h.stderr.String(); strings.Contains(out, markerSecret) {
		t.Fatalf("log leaks the secret: %s", out)
	}
}

func TestDaemonRemoveUploadDeletesTheObjectAndForgetsTheUpload(t *testing.T) {
	b := newBucketS3()
	h, client := startWithBucket(t, b)
	configureAs(t, client, "bucket-1")
	id := sendFile(t, client, "doomed.txt")
	if !b.has("quick/doomed.txt") {
		t.Fatal("test setup: the object was not written")
	}

	ctx, cancel := context.WithTimeout(context.Background(), waitTimeout)
	defer cancel()
	if _, err := client.RemoveUpload(ctx, &pb.RemoveUploadRequest{UploadId: id, DeleteFromBucket: true}); err != nil {
		t.Fatal(err)
	}

	if b.has("quick/doomed.txt") {
		t.Fatal("the object is still in the bucket")
	}
	if sizes := b.batchSizes(); fmt.Sprint(sizes) != "[1]" {
		t.Fatalf("delete batches = %v, want one batch of the one key", sizes)
	}
	h.stop()
}

func TestShutdownIsPromptWhileTheReconciliationIsListing(t *testing.T) {
	b := newBucketS3()
	h, client := startWithBucket(t, b)
	configureAs(t, client, "bucket-1")
	sendFile(t, client, "a.txt")
	b.mu.Lock()
	b.blockList = true
	b.mu.Unlock()
	configureAs(t, client, "bucket-1")
	select {
	case <-b.inList:
	case <-time.After(waitTimeout):
		t.Fatal("the reconciliation never started listing")
	}

	since := time.Now()
	h.stdinW.Close()
	h.expectExit(since, 0)
}
