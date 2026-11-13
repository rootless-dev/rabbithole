package server_test

import (
	"context"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	pb "rabbithole/daemon/internal/gen/rabbithole/v1"
	"rabbithole/daemon/internal/history"
	"rabbithole/daemon/internal/logging"
	"rabbithole/daemon/internal/queue"
	"rabbithole/daemon/internal/uploader"
)

// gateRunner blocks the files named in hang until their context ends, and
// records every file it was asked to send.
type gateRunner struct {
	mu    sync.Mutex
	hang  map[string]bool
	calls []string
}

func (g *gateRunner) Run(ctx context.Context, _ uploader.Settings, req uploader.Request, cb uploader.Callbacks) error {
	name := filepath.Base(req.LocalPath)
	g.mu.Lock()
	g.calls = append(g.calls, name)
	hang := g.hang[name]
	g.mu.Unlock()
	cb.KeyResolved(req.Prefix + name)
	if hang {
		<-ctx.Done()
		return ctx.Err()
	}
	return nil
}

func (g *gateRunner) setHang(names ...string) {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.hang = map[string]bool{}
	for _, n := range names {
		g.hang[n] = true
	}
}

func (g *gateRunner) called() []string {
	g.mu.Lock()
	defer g.mu.Unlock()
	return append([]string(nil), g.calls...)
}

func uploadFile(t *testing.T, e *env, name string) string {
	t.Helper()
	resp, err := e.client.EnqueueUpload(ctxT(t), &pb.EnqueueUploadRequest{LocalPath: writeFile(t, name, "x")})
	if err != nil {
		t.Fatal(err)
	}
	return resp.GetUploadId()
}

func waitSnap(t *testing.T, e *env, id string, match func(*pb.UploadSnapshot) bool) *pb.UploadSnapshot {
	t.Helper()
	stream, err := e.client.WatchUploads(ctxT(t), &pb.WatchUploadsRequest{})
	if err != nil {
		t.Fatal(err)
	}
	return recvUntil(t, stream, id, match)
}

func inState(state pb.UploadState) func(*pb.UploadSnapshot) bool {
	return func(s *pb.UploadSnapshot) bool { return s.GetState() == state }
}

func TestPauseResumeCancelBeforeConfigureFailPrecondition(t *testing.T) {
	e := newEnv(t, noopRunner())
	_, err := e.client.PauseUpload(ctxT(t), &pb.PauseUploadRequest{UploadId: "x"})
	wantCode(t, err, codes.FailedPrecondition)
	_, err = e.client.ResumeUpload(ctxT(t), &pb.ResumeUploadRequest{UploadId: "x"})
	wantCode(t, err, codes.FailedPrecondition)
	_, err = e.client.CancelUpload(ctxT(t), &pb.CancelUploadRequest{UploadId: "x"})
	wantCode(t, err, codes.FailedPrecondition)
}

func TestPauseResumeCancelRefusals(t *testing.T) {
	e := newEnvWith(t, noopRunner())
	e.startQueue(t)
	if _, err := e.client.Configure(ctxT(t), validConfig()); err != nil {
		t.Fatal(err)
	}
	finished := uploadFile(t, e, "done.txt")
	waitSnap(t, e, finished, inState(pb.UploadState_FINISHED))
	other := enqueueDirect(t, e, "other-bucket", "o.txt") // the bucket check comes before the state check

	tests := []struct {
		name string
		call func() error
		code codes.Code
		msg  string
	}{
		{"pause unknown", func() error {
			_, err := e.client.PauseUpload(ctxT(t), &pb.PauseUploadRequest{UploadId: "nope"})
			return err
		}, codes.NotFound, "unknown upload"},
		{"resume unknown", func() error {
			_, err := e.client.ResumeUpload(ctxT(t), &pb.ResumeUploadRequest{UploadId: "nope"})
			return err
		}, codes.NotFound, "unknown upload"},
		{"cancel unknown", func() error {
			_, err := e.client.CancelUpload(ctxT(t), &pb.CancelUploadRequest{UploadId: "nope"})
			return err
		}, codes.NotFound, "unknown upload"},
		{"pause finished", func() error {
			_, err := e.client.PauseUpload(ctxT(t), &pb.PauseUploadRequest{UploadId: finished})
			return err
		}, codes.FailedPrecondition, "Only a queued or running upload can be paused"},
		{"resume finished", func() error {
			_, err := e.client.ResumeUpload(ctxT(t), &pb.ResumeUploadRequest{UploadId: finished})
			return err
		}, codes.FailedPrecondition, "Only an upload paused by you can be resumed"},
		{"cancel finished", func() error {
			_, err := e.client.CancelUpload(ctxT(t), &pb.CancelUploadRequest{UploadId: finished})
			return err
		}, codes.FailedPrecondition, "Only a queued, running or paused upload can be canceled"},
		{"pause other bucket", func() error {
			_, err := e.client.PauseUpload(ctxT(t), &pb.PauseUploadRequest{UploadId: other})
			return err
		}, codes.FailedPrecondition, "This upload belongs to another bucket"},
		{"resume other bucket", func() error {
			_, err := e.client.ResumeUpload(ctxT(t), &pb.ResumeUploadRequest{UploadId: other})
			return err
		}, codes.FailedPrecondition, "This upload belongs to another bucket"},
		{"cancel other bucket", func() error {
			_, err := e.client.CancelUpload(ctxT(t), &pb.CancelUploadRequest{UploadId: other})
			return err
		}, codes.FailedPrecondition, "This upload belongs to another bucket"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := tt.call()
			wantCode(t, err, tt.code)
			if got := status.Convert(err).Message(); got != tt.msg {
				t.Fatalf("message = %q, want %q", got, tt.msg)
			}
		})
	}
}

func TestPauseThenResumeThroughGRPC(t *testing.T) {
	g := &gateRunner{}
	g.setHang("a.txt")
	e := newEnvWith(t, g)
	e.startQueue(t)
	if _, err := e.client.Configure(ctxT(t), validConfig()); err != nil {
		t.Fatal(err)
	}
	id := uploadFile(t, e, "a.txt")
	waitSnap(t, e, id, inState(pb.UploadState_UPLOADING))

	if _, err := e.client.PauseUpload(ctxT(t), &pb.PauseUploadRequest{UploadId: id}); err != nil {
		t.Fatal(err)
	}
	paused := waitSnap(t, e, id, inState(pb.UploadState_PAUSED))
	if paused.GetPauseReason() != pb.PauseReason_PAUSED_BY_USER {
		t.Fatalf("pause reason = %v, want PAUSED_BY_USER", paused.GetPauseReason())
	}
	if _, err := e.client.PauseUpload(ctxT(t), &pb.PauseUploadRequest{UploadId: id}); status.Code(err) != codes.FailedPrecondition {
		t.Fatalf("pausing twice = %v, want FailedPrecondition", err)
	}

	g.setHang()
	if _, err := e.client.ResumeUpload(ctxT(t), &pb.ResumeUploadRequest{UploadId: id}); err != nil {
		t.Fatal(err)
	}
	done := waitSnap(t, e, id, inState(pb.UploadState_FINISHED))
	if done.GetPauseReason() != pb.PauseReason_PAUSE_REASON_UNSPECIFIED {
		t.Fatalf("a finished upload carries pause reason %v", done.GetPauseReason())
	}
}

func TestCancelThroughGRPCThenRetry(t *testing.T) {
	g := &gateRunner{}
	g.setHang("a.txt")
	e := newEnvWith(t, g)
	e.startQueue(t)
	if _, err := e.client.Configure(ctxT(t), validConfig()); err != nil {
		t.Fatal(err)
	}
	id := uploadFile(t, e, "a.txt")
	waitSnap(t, e, id, inState(pb.UploadState_UPLOADING))

	if _, err := e.client.CancelUpload(ctxT(t), &pb.CancelUploadRequest{UploadId: id}); err != nil {
		t.Fatal(err)
	}
	canceled := waitSnap(t, e, id, inState(pb.UploadState_CANCELED))
	if canceled.GetEndedAtMs() == 0 {
		t.Fatal("a canceled upload has no end time")
	}

	g.setHang()
	if _, err := e.client.RetryUpload(ctxT(t), &pb.RetryUploadRequest{UploadId: id}); err != nil {
		t.Fatalf("RetryUpload of a canceled upload: %v", err)
	}
	waitSnap(t, e, id, inState(pb.UploadState_FINISHED))
}

func TestSetOptionsHoldsAndReleasesUploads(t *testing.T) {
	e := newEnvWith(t, noopRunner()) // the queue is not started: uploads wait
	if _, err := e.client.Configure(ctxT(t), validConfig()); err != nil {
		t.Fatal(err)
	}
	id := uploadFile(t, e, "a.txt")

	if _, err := e.client.SetOptions(ctxT(t), &pb.SetOptionsRequest{HoldUploads: true, SpeedLimitBytesPerSecond: 5, VerifyUploads: true}); err != nil {
		t.Fatal(err)
	}
	held := waitSnap(t, e, id, inState(pb.UploadState_PAUSED))
	if held.GetPauseReason() != pb.PauseReason_PAUSED_ON_HOLD {
		t.Fatalf("pause reason = %v, want PAUSED_ON_HOLD", held.GetPauseReason())
	}

	if _, err := e.client.SetOptions(ctxT(t), &pb.SetOptionsRequest{}); err != nil {
		t.Fatal(err)
	}
	back := waitSnap(t, e, id, inState(pb.UploadState_QUEUED))
	if back.GetPauseReason() != pb.PauseReason_PAUSE_REASON_UNSPECIFIED {
		t.Fatalf("pause reason after the hold = %v", back.GetPauseReason())
	}
}

// interruptedEnv serves a queue restored from a history that holds one upload
// of my-bucket that a previous run left running, with the daemon not yet
// configured.
func interruptedEnv(t *testing.T, r queue.Runner) (*env, string) {
	t.Helper()
	store, err := history.Open(filepath.Join(t.TempDir(), "history.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = store.Close() })
	log := logging.New(&syncBuffer{}, "debug", "rabbitholed")

	before := queue.New(r, time.Now, queue.WithStore(store, log))
	if err := before.Restore(); err != nil {
		t.Fatal(err)
	}
	id, err := before.Enqueue(uploader.Settings{Bucket: "my-bucket", Region: "us-east-1", Prefix: "quick/"},
		queue.EnqueueRequest{Paths: []string{writeFile(t, "cut.txt", "x")}})
	if err != nil {
		t.Fatal(err) // the queue never runs, as if the daemon died with it queued
	}

	q := queue.New(r, time.Now, queue.WithStore(store, log))
	if err := q.Restore(); err != nil {
		t.Fatal(err)
	}
	e := newEnvOn(t, q)
	e.startQueue(t)
	return e, id
}

func TestConfigureResumesInterruptedUploadsWhenAskedTo(t *testing.T) {
	g := &gateRunner{}
	e, id := interruptedEnv(t, g)
	cfg := validConfig()
	cfg.ResumeInterrupted = true

	if _, err := e.client.Configure(ctxT(t), cfg); err != nil {
		t.Fatal(err)
	}

	waitSnap(t, e, id, inState(pb.UploadState_FINISHED))
	if got := g.called(); len(got) != 1 || got[0] != "cut.txt" {
		t.Fatalf("files sent = %v, want the interrupted file once", got)
	}
}

func TestConfigureLeavesInterruptedUploadsFailedWhenNotAskedAndActsOnlyOnTheFirstConfigure(t *testing.T) {
	g := &gateRunner{}
	e, id := interruptedEnv(t, g)

	if _, err := e.client.Configure(ctxT(t), validConfig()); err != nil {
		t.Fatal(err)
	}
	failed := waitSnap(t, e, id, inState(pb.UploadState_FAILED))
	if failed.GetErrorMessage() != queue.InterruptedMessage {
		t.Fatalf("message = %q", failed.GetErrorMessage())
	}

	// A later Configure asking for it is too late: it acts once per run, on the first.
	later := validConfig()
	later.ResumeInterrupted = true
	if _, err := e.client.Configure(ctxT(t), later); err != nil {
		t.Fatal(err)
	}
	time.Sleep(100 * time.Millisecond)
	if got := g.called(); len(got) != 0 {
		t.Fatalf("files sent = %v, want none", got)
	}
}

func TestInvalidConfigureDoesNotUseUpTheResumeOnce(t *testing.T) {
	g := &gateRunner{}
	e, id := interruptedEnv(t, g)
	bad := validConfig()
	bad.Bucket = ""
	bad.ResumeInterrupted = true
	if _, err := e.client.Configure(ctxT(t), bad); status.Code(err) != codes.InvalidArgument {
		t.Fatalf("err = %v, want InvalidArgument", err)
	}

	good := validConfig()
	good.ResumeInterrupted = true
	if _, err := e.client.Configure(ctxT(t), good); err != nil {
		t.Fatal(err)
	}

	waitSnap(t, e, id, inState(pb.UploadState_FINISHED))
}
