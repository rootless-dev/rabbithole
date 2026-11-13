package server_test

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"

	"google.golang.org/grpc/codes"

	pb "rabbithole/daemon/internal/gen/rabbithole/v1"
	"rabbithole/daemon/internal/queue"
	"rabbithole/daemon/internal/uploader"
)

func configFor(bucket string) *pb.ConfigureRequest {
	c := validConfig()
	c.Bucket = bucket
	return c
}

// enqueueDirect puts an upload on the queue as if Enqueue had been called while
// the daemon was configured for bucket.
func enqueueDirect(t *testing.T, e *env, bucket, name string) string {
	t.Helper()
	id, err := e.queue.Enqueue(uploader.Settings{Bucket: bucket, Region: "r", Prefix: "q/"},
		queue.EnqueueRequest{Paths: []string{writeFile(t, name, "x")}})
	if err != nil {
		t.Fatal(err)
	}
	return id
}

// watcher reads a WatchUploads stream in one goroutine, so a test can wait for
// the next snapshot with a deadline without ever calling Recv twice at once.
type watcher struct{ ch chan *pb.UploadSnapshot }

func watchUploads(t *testing.T, e *env) *watcher {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	stream, err := e.client.WatchUploads(ctx, &pb.WatchUploadsRequest{})
	if err != nil {
		t.Fatal(err)
	}
	w := &watcher{ch: make(chan *pb.UploadSnapshot, 256)}
	go func() {
		defer close(w.ch)
		for {
			s, err := stream.Recv()
			if err != nil {
				return
			}
			w.ch <- s
		}
	}()
	return w
}

// recvWithin returns the next snapshot, or false when none arrives within d.
func recvWithin(t *testing.T, w *watcher, d time.Duration) (*pb.UploadSnapshot, bool) {
	t.Helper()
	select {
	case s, ok := <-w.ch:
		if !ok {
			t.Fatal("watch stream ended")
		}
		return s, true
	case <-time.After(d):
		return nil, false
	}
}

func TestWatchReplaysNothingBeforeConfigure(t *testing.T) {
	e := newEnv(t, noopRunner())
	enqueueDirect(t, e, "my-bucket", "a.txt")
	stream := watchUploads(t, e)

	if s, ok := recvWithin(t, stream, 300*time.Millisecond); ok {
		t.Fatalf("received %v before Configure, want nothing", s)
	}
	if _, err := e.client.Configure(ctxT(t), configFor("my-bucket")); err != nil {
		t.Fatal(err)
	}
	if s, ok := recvWithin(t, stream, testTimeout); !ok || s.GetRemoved() || s.GetCreatedAtMs() == 0 {
		t.Errorf("after Configure received %v (ok %v), want the stored upload with its creation time", s, ok)
	}
}

func TestChangingTheBucketRemovesTheOldUploadsForEveryWatcher(t *testing.T) {
	e := newEnv(t, noopRunner())
	if _, err := e.client.Configure(ctxT(t), configFor("bucket-a")); err != nil {
		t.Fatal(err)
	}
	a := enqueueDirect(t, e, "bucket-a", "a.txt")
	b := enqueueDirect(t, e, "bucket-b", "b.txt")
	var streams []*watcher
	for range 2 {
		stream := watchUploads(t, e)
		if s, ok := recvWithin(t, stream, testTimeout); !ok || s.GetUploadId() != a {
			t.Fatalf("replay = %v, want upload a only", s)
		}
		streams = append(streams, stream)
	}

	if _, err := e.client.Configure(ctxT(t), configFor("bucket-b")); err != nil {
		t.Fatal(err)
	}

	for i, stream := range streams {
		first, _ := recvWithin(t, stream, testTimeout)
		second, _ := recvWithin(t, stream, testTimeout)
		if first.GetUploadId() != a || !first.GetRemoved() || second.GetUploadId() != b || second.GetRemoved() {
			t.Errorf("watcher %d got %v then %v, want a removed then b", i, first, second)
		}
	}
}

// failedUpload enqueues an upload of two files, of which the one named bad
// fails, runs the queue, and returns the upload id once it failed.
func failedUpload(t *testing.T, e *env) string {
	t.Helper()
	if _, err := e.client.Configure(ctxT(t), validConfig()); err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	for _, n := range []string{"good", "bad"} {
		if err := os.WriteFile(filepath.Join(dir, n), []byte("x"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	e.startQueue(t)
	stream := watchUploads(t, e)
	resp, err := e.client.EnqueueUpload(ctxT(t), &pb.EnqueueUploadRequest{LocalPath: dir})
	if err != nil {
		t.Fatal(err)
	}
	waitForState(t, stream, resp.GetUploadId(), pb.UploadState_FAILED)
	return resp.GetUploadId()
}

func waitForState(t *testing.T, stream *watcher, id string, want pb.UploadState) *pb.UploadSnapshot {
	t.Helper()
	for {
		s, ok := recvWithin(t, stream, testTimeout)
		if !ok {
			t.Fatalf("timed out waiting for upload %s to reach %v", id, want)
		}
		if s.GetUploadId() == id && s.GetState() == want {
			return s
		}
	}
}

func TestRetryUploadSendsTheFailedFileAgainAndFinishesTheSameUpload(t *testing.T) {
	var failing atomic.Bool
	failing.Store(true)
	e := newEnv(t, runnerFunc(func(_ context.Context, _ uploader.Settings, req uploader.Request, _ uploader.Callbacks) error {
		if failing.Load() && filepath.Base(req.LocalPath) == "bad" {
			return errors.New("boom")
		}
		return nil
	}))
	id := failedUpload(t, e)
	stream := watchUploads(t, e)
	failing.Store(false)

	if _, err := e.client.RetryUpload(ctxT(t), &pb.RetryUploadRequest{UploadId: id}); err != nil {
		t.Fatal(err)
	}

	done := waitForState(t, stream, id, pb.UploadState_FINISHED)
	if done.GetFilesFinished() != 2 || done.GetFilesFailed() != 0 || done.GetEndedAtMs() == 0 {
		t.Errorf("finished upload = %v, want 2 files finished and an end time", done)
	}
}

func TestRetryUploadStatuses(t *testing.T) {
	e := newEnv(t, runnerFunc(func(_ context.Context, _ uploader.Settings, req uploader.Request, _ uploader.Callbacks) error {
		if filepath.Base(req.LocalPath) == "bad" {
			return errors.New("boom")
		}
		return nil
	}))
	// Not configured yet.
	_, err := e.client.RetryUpload(ctxT(t), &pb.RetryUploadRequest{UploadId: "x"})
	wantCode(t, err, codes.FailedPrecondition)

	id := failedUpload(t, e)
	files, err := e.client.WatchUploadFiles(ctxT(t), &pb.WatchUploadFilesRequest{UploadId: id})
	if err != nil {
		t.Fatal(err)
	}
	var good, bad int32
	for range 2 {
		f, err := files.Recv()
		if err != nil {
			t.Fatal(err)
		}
		if f.GetState() == pb.UploadState_FINISHED {
			good = f.GetIndex()
		} else {
			bad = f.GetIndex()
		}
	}

	tests := []struct {
		name string
		req  *pb.RetryUploadRequest
		want codes.Code
	}{
		{"unknown upload", &pb.RetryUploadRequest{UploadId: "nope"}, codes.NotFound},
		{"unknown file index", &pb.RetryUploadRequest{UploadId: id, FileIndexes: []int32{42}}, codes.NotFound},
		{"file that did not fail", &pb.RetryUploadRequest{UploadId: id, FileIndexes: []int32{good}}, codes.FailedPrecondition},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			_, err := e.client.RetryUpload(ctxT(t), tt.req)
			wantCode(t, err, tt.want)
		})
	}

	// Another bucket.
	if _, err := e.client.Configure(ctxT(t), configFor("other-bucket")); err != nil {
		t.Fatal(err)
	}
	_, err = e.client.RetryUpload(ctxT(t), &pb.RetryUploadRequest{UploadId: id, FileIndexes: []int32{bad}})
	wantCode(t, err, codes.FailedPrecondition)
}

func TestRetryUploadOfAnUploadThatDidNotFailIsRefused(t *testing.T) {
	e := newEnv(t, noopRunner())
	if _, err := e.client.Configure(ctxT(t), validConfig()); err != nil {
		t.Fatal(err)
	}
	resp, err := e.client.EnqueueUpload(ctxT(t), &pb.EnqueueUploadRequest{LocalPath: writeFile(t, "a.txt", "x")})
	if err != nil {
		t.Fatal(err)
	}
	// Not started: the upload is still queued.
	_, err = e.client.RetryUpload(ctxT(t), &pb.RetryUploadRequest{UploadId: resp.GetUploadId()})
	wantCode(t, err, codes.FailedPrecondition)
}
