package queue

import (
	"context"
	"errors"
	"path/filepath"
	"slices"
	"sync"
	"testing"
	"time"

	"rabbithole/daemon/internal/uploader"
)

type abortCall struct {
	bucket   string
	key      string
	uploadID string
}

// ctlRunner is a Runner the tests steer: files named in hang block until their
// context ends or release is closed; files with a record report a multipart
// upload the way the real uploader does. It also aborts multipart uploads.
type ctlRunner struct {
	mu       sync.Mutex
	hang     map[string]bool
	release  chan struct{}
	started  chan string
	calls    []string
	reqs     map[string][]uploader.Request
	record   map[string]uploader.Multipart
	failWith map[string]error
	aborts   []abortCall
	abortErr error
}

func newCtl() *ctlRunner {
	return &ctlRunner{
		hang:     map[string]bool{},
		release:  make(chan struct{}),
		started:  make(chan string, 64),
		reqs:     map[string][]uploader.Request{},
		record:   map[string]uploader.Multipart{},
		failWith: map[string]error{},
	}
}

func (r *ctlRunner) Run(ctx context.Context, _ uploader.Settings, req uploader.Request, cb uploader.Callbacks) error {
	name := filepath.Base(req.LocalPath)
	r.mu.Lock()
	r.calls = append(r.calls, name)
	r.reqs[name] = append(r.reqs[name], req)
	hang, rec, hasRec, failErr := r.hang[name], r.record[name], false, r.failWith[name]
	_, hasRec = r.record[name]
	r.mu.Unlock()

	if cb.KeyResolved != nil {
		cb.KeyResolved(req.Prefix + name)
	}
	if hasRec && req.Resume == nil {
		start := rec
		start.Parts = nil // a fresh multipart upload has no part yet
		cb.MultipartRecorded(start)
		for _, p := range rec.Parts {
			cb.PartDone(p)
		}
	}
	r.started <- name
	if hang {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-r.release:
		}
	}
	if failErr != nil {
		return failErr
	}
	if hasRec {
		cb.MultipartEnded()
	}
	return nil
}

func (r *ctlRunner) AbortMultipart(_ context.Context, s uploader.Settings, key, uploadID string) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.aborts = append(r.aborts, abortCall{s.Bucket, key, uploadID})
	return r.abortErr
}

func (r *ctlRunner) setHang(names ...string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.hang = map[string]bool{}
	for _, n := range names {
		r.hang[n] = true
	}
}

func (r *ctlRunner) callList() []string {
	r.mu.Lock()
	defer r.mu.Unlock()
	return slices.Clone(r.calls)
}

func (r *ctlRunner) abortList() []abortCall {
	r.mu.Lock()
	defer r.mu.Unlock()
	return slices.Clone(r.aborts)
}

func (r *ctlRunner) requests(name string) []uploader.Request {
	r.mu.Lock()
	defer r.mu.Unlock()
	return slices.Clone(r.reqs[name])
}

// awaitStarted blocks until the runner starts the file called name.
func (r *ctlRunner) awaitStarted(t *testing.T, name string) {
	t.Helper()
	for {
		select {
		case got := <-r.started:
			if got == name {
				return
			}
		case <-time.After(guard):
			t.Fatalf("file %q never started; calls: %v", name, r.callList())
		}
	}
}

// ctlQueue is a queue over st with settings for bucket-1 in force, and its
// runner already running.
func ctlQueue(t *testing.T, st Store, r Runner) *Queue {
	t.Helper()
	q := storedQueue(t, st, r, nopLogger{})
	q.SetSettings(settingsFor("bucket-1"))
	startRun(t, q)
	return q
}

func snapOf(t *testing.T, q *Queue, id string) Snapshot {
	t.Helper()
	initial, _, cancel := q.Subscribe()
	cancel()
	for _, s := range initial {
		if s.ID == id {
			return s
		}
	}
	t.Fatalf("upload %s is not known", id)
	return Snapshot{}
}

// waitState waits until upload id is shown in state.
func waitState(t *testing.T, q *Queue, id string, want State) Snapshot {
	t.Helper()
	deadline := time.Now().Add(guard)
	for {
		s := snapOf(t, q, id)
		if s.State == want {
			return s
		}
		if time.Now().After(deadline) {
			t.Fatalf("upload %s is %v (%+v), want %v", id, s.State, s, want)
		}
		time.Sleep(2 * time.Millisecond)
	}
}

func fileStates(t *testing.T, q *Queue, id string) map[string]State {
	t.Helper()
	out := map[string]State{}
	for _, f := range filesOf(t, q, id) {
		out[filepath.Base(f.LocalPath)] = f.State
	}
	return out
}

func enqueueTree(t *testing.T, q *Queue, parallel int, files ...string) string {
	t.Helper()
	root := tree(t, files...)
	id, err := q.Enqueue(settingsFor("bucket-1"), EnqueueRequest{Paths: []string{filepath.Join(root, "d")}, ParallelFiles: parallel})
	if err != nil {
		t.Fatal(err)
	}
	return id
}

func enqueueOne(t *testing.T, q *Queue, name string) string {
	t.Helper()
	id, err := q.Enqueue(settingsFor("bucket-1"), req(writeFile(t, name, 1)))
	if err != nil {
		t.Fatal(err)
	}
	return id
}

func TestPauseStopsTheRunningUploadAndTheQueueMovesOn(t *testing.T) {
	r := newCtl()
	r.setHang("a.bin")
	q := ctlQueue(t, newMemStore(), r)
	a := enqueueOne(t, q, "a.bin")
	b := enqueueOne(t, q, "b.bin")
	r.awaitStarted(t, "a.bin")

	if err := q.Pause("bucket-1", a); err != nil {
		t.Fatal(err)
	}

	s := waitState(t, q, a, Paused)
	if s.PauseReason != PausedByUser || !s.EndedAt.IsZero() {
		t.Fatalf("paused upload = %+v, want reason by-user and no end time", s)
	}
	if got := fileStates(t, q, a); got["a.bin"] != Paused {
		t.Fatalf("file states = %v, want the unfinished file paused", got)
	}
	waitState(t, q, b, Finished) // the queue moved on to the next upload
	if err := q.Pause("bucket-1", a); !errors.Is(err, ErrNotPausable) {
		t.Fatalf("pausing a paused upload = %v, want ErrNotPausable", err)
	}
}

func TestPausingAQueuedUploadKeepsItFromStarting(t *testing.T) {
	r := newCtl()
	r.setHang("a.bin")
	q := ctlQueue(t, newMemStore(), r)
	enqueueOne(t, q, "a.bin")
	b := enqueueOne(t, q, "b.bin")
	r.awaitStarted(t, "a.bin")

	if err := q.Pause("bucket-1", b); err != nil {
		t.Fatal(err)
	}
	close(r.release)

	waitState(t, q, b, Paused)
	time.Sleep(50 * time.Millisecond)
	if slices.Contains(r.callList(), "b.bin") {
		t.Fatalf("a paused upload was sent: %v", r.callList())
	}
	if got := fileStates(t, q, b); got["b.bin"] != Paused {
		t.Fatalf("file states = %v, want the file paused", got)
	}
}

func TestResumeContinuesWhereTheUploadStoppedAtTheEndOfTheQueue(t *testing.T) {
	r := newCtl()
	r.setHang("b", "x")
	q := ctlQueue(t, newMemStore(), r)
	u1 := enqueueTree(t, q, 1, "d/a", "d/b", "d/c")
	enqueueOne(t, q, "x")
	u3 := enqueueOne(t, q, "y")
	r.awaitStarted(t, "b")
	if err := q.Pause("bucket-1", u1); err != nil {
		t.Fatal(err)
	}
	r.awaitStarted(t, "x") // x runs while u3 waits behind it
	r.setHang("x")         // b does not hang the second time

	if err := q.Resume(settingsFor("bucket-1"), u1); err != nil {
		t.Fatal(err)
	}
	snap := snapOf(t, q, u1)
	if snap.State != Queued || snap.PauseReason != NotPaused {
		t.Fatalf("resumed upload = %+v, want queued and not paused", snap)
	}
	close(r.release)
	waitState(t, q, u1, Finished)
	waitState(t, q, u3, Finished)

	if got := r.callList(); !slices.Equal(got, []string{"a", "b", "x", "y", "b", "c"}) {
		t.Fatalf("calls = %v, want a and b, then x, y, and only then u1's b and c (a is not sent again)", got)
	}
}

func TestPausedUploadSurvivesARestartAndCanBeResumed(t *testing.T) {
	st := newMemStore()
	r := newCtl()
	r.setHang("b")
	q := ctlQueue(t, st, r)
	id := enqueueTree(t, q, 1, "d/a", "d/b")
	r.awaitStarted(t, "b")
	if err := q.Pause("bucket-1", id); err != nil {
		t.Fatal(err)
	}
	waitState(t, q, id, Paused)
	q.journal.flush()

	r2 := newCtl()
	q2 := ctlQueue(t, st, r2) // the daemon starts again on the same history
	s := snapOf(t, q2, id)
	if s.State != Paused || s.PauseReason != PausedByUser || s.FilesFinished != 1 {
		t.Fatalf("after the restart the upload is %+v, want paused by the user with one finished file", s)
	}
	if got := fileStates(t, q2, id); got["a"] != Finished || got["b"] != Paused {
		t.Fatalf("file states after the restart = %v", got)
	}
	time.Sleep(50 * time.Millisecond)
	if len(r2.callList()) != 0 {
		t.Fatalf("a paused upload was sent after the restart: %v", r2.callList())
	}

	if err := q2.Resume(settingsFor("bucket-1"), id); err != nil {
		t.Fatal(err)
	}
	waitState(t, q2, id, Finished)
	if got := r2.callList(); !slices.Equal(got, []string{"b"}) {
		t.Fatalf("calls after the resume = %v, want only the unfinished file", got)
	}
}

func TestPauseResumeCancelRefusals(t *testing.T) {
	r := newCtl()
	q := ctlQueue(t, newMemStore(), r)
	finished := enqueueOne(t, q, "done.bin")
	waitState(t, q, finished, Finished)
	r.failWith["bad.bin"] = errors.New("boom")
	failed := enqueueOne(t, q, "bad.bin")
	waitState(t, q, failed, Failed)
	r.setHang("slow.bin")
	slow := enqueueOne(t, q, "slow.bin")
	r.awaitStarted(t, "slow.bin")
	queued := enqueueOne(t, q, "wait.bin")

	bucket1, bucket2 := "bucket-1", "bucket-2"
	cases := []struct {
		name string
		call func() error
		want error
	}{
		{"pause unknown", func() error { return q.Pause(bucket1, "nope") }, ErrUnknownUpload},
		{"pause finished", func() error { return q.Pause(bucket1, finished) }, ErrNotPausable},
		{"pause failed", func() error { return q.Pause(bucket1, failed) }, ErrNotPausable},
		{"pause other bucket", func() error { return q.Pause(bucket2, slow) }, ErrOtherBucket},
		{"resume unknown", func() error { return q.Resume(settingsFor(bucket1), "nope") }, ErrUnknownUpload},
		{"resume finished", func() error { return q.Resume(settingsFor(bucket1), finished) }, ErrNotResumable},
		{"resume failed", func() error { return q.Resume(settingsFor(bucket1), failed) }, ErrNotResumable},
		{"resume running", func() error { return q.Resume(settingsFor(bucket1), slow) }, ErrNotResumable},
		{"resume queued", func() error { return q.Resume(settingsFor(bucket1), queued) }, ErrNotResumable},
		{"resume other bucket", func() error { return q.Resume(settingsFor(bucket2), slow) }, ErrOtherBucket},
		{"cancel unknown", func() error { return q.Cancel(bucket1, "nope") }, ErrUnknownUpload},
		{"cancel finished", func() error { return q.Cancel(bucket1, finished) }, ErrNotCancelable},
		{"cancel failed", func() error { return q.Cancel(bucket1, failed) }, ErrNotCancelable},
		{"cancel other bucket", func() error { return q.Cancel(bucket2, slow) }, ErrOtherBucket},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if err := tc.call(); !errors.Is(err, tc.want) {
				t.Fatalf("err = %v, want %v", err, tc.want)
			}
		})
	}
	close(r.release)
}

func TestCancelRunningUploadAbortsItsMultipartUploadsAndKeepsFinishedFiles(t *testing.T) {
	r := newCtl()
	r.setHang("b")
	r.record["b"] = uploader.Multipart{Key: "pfx/b", UploadID: "up-b", PartSize: 8, FileSize: 1, Parts: []uploader.CompletedPart{{Number: 1, ETag: "e1"}}}
	st := newMemStore()
	q := ctlQueue(t, st, r)
	id := enqueueTree(t, q, 1, "d/a", "d/b", "d/c")
	r.awaitStarted(t, "b")

	if err := q.Cancel("bucket-1", id); err != nil {
		t.Fatal(err)
	}

	s := waitState(t, q, id, Canceled)
	if s.EndedAt.IsZero() || s.FilesFinished != 1 {
		t.Fatalf("canceled upload = %+v, want an end time and its one finished file", s)
	}
	if got := fileStates(t, q, id); got["a"] != Finished || got["b"] != Canceled || got["c"] != Canceled {
		t.Fatalf("file states = %v, want a finished and the rest canceled", got)
	}
	// The abort runs after the state is published, so wait for it.
	deadline := time.Now().Add(guard)
	for len(r.abortList()) == 0 && time.Now().Before(deadline) {
		time.Sleep(2 * time.Millisecond)
	}
	if got := r.abortList(); !slices.Equal(got, []abortCall{{"bucket-1", "pfx/b", "up-b"}}) {
		t.Fatalf("aborts = %v, want the multipart upload of b", got)
	}
	if recs, _ := st.Multiparts(id); len(recs) != 0 {
		t.Fatalf("records left after the abort: %v", recs)
	}
	if got := r.callList(); slices.Contains(got, "c") {
		t.Fatalf("c was sent after the cancel: %v", got)
	}
}

func TestCancelQueuedAndPausedUploadsAbortTheirRecordedMultipartUploads(t *testing.T) {
	r := newCtl()
	r.setHang("p.bin", "h.bin")
	r.record["p.bin"] = uploader.Multipart{Key: "pfx/p.bin", UploadID: "up-p", PartSize: 8, FileSize: 1}
	st := newMemStore()
	q := ctlQueue(t, st, r)
	paused := enqueueOne(t, q, "p.bin")
	enqueueOne(t, q, "h.bin")
	queued := enqueueOne(t, q, "q.bin")
	r.awaitStarted(t, "p.bin") // p.bin runs and reports its multipart upload

	if err := q.Pause("bucket-1", paused); err != nil {
		t.Fatal(err)
	}
	waitState(t, q, paused, Paused)
	r.awaitStarted(t, "h.bin") // the queue moved on; q.bin keeps waiting behind it
	if recs, _ := q.store.Multiparts(paused); len(recs) != 1 {
		t.Fatalf("records after a pause = %v, want the multipart upload kept", recs)
	}
	if len(r.abortList()) != 0 {
		t.Fatalf("a pause aborted %v", r.abortList())
	}

	if err := q.Cancel("bucket-1", paused); err != nil {
		t.Fatal(err)
	}
	if err := q.Cancel("bucket-1", queued); err != nil {
		t.Fatal(err)
	}

	if got := r.abortList(); !slices.Equal(got, []abortCall{{"bucket-1", "pfx/p.bin", "up-p"}}) {
		t.Fatalf("aborts = %v, want the paused upload's multipart upload", got)
	}
	if s := snapOf(t, q, paused); s.State != Canceled {
		t.Fatalf("paused upload after a cancel = %+v", s)
	}
	if got := fileStates(t, q, paused); got["p.bin"] != Canceled {
		t.Fatalf("file states = %v, want the paused file canceled", got)
	}
	if s := snapOf(t, q, queued); s.State != Canceled {
		t.Fatalf("queued upload after a cancel = %+v", s)
	}
	if got := r.callList(); slices.Contains(got, "q.bin") {
		t.Fatalf("a canceled upload was sent: %v", got)
	}
}

func TestCanceledUploadIsRetriedLikeAFailedOneAndRemovedLikeOne(t *testing.T) {
	r := newCtl()
	r.setHang("b")
	q := ctlQueue(t, newMemStore(), r)
	id := enqueueTree(t, q, 1, "d/a", "d/b", "d/c")
	r.awaitStarted(t, "b")
	if err := q.Cancel("bucket-1", id); err != nil {
		t.Fatal(err)
	}
	waitState(t, q, id, Canceled)

	// Only b: the upload is canceled while c stays canceled.
	r.setHang()
	if err := q.Retry(settingsFor("bucket-1"), id, []int{indexOfFile(t, filesOf(t, q, id), "d/b")}); err != nil {
		t.Fatal(err)
	}
	s := waitState(t, q, id, Canceled)
	if got := fileStates(t, q, id); got["a"] != Finished || got["b"] != Finished || got["c"] != Canceled {
		t.Fatalf("file states = %v, want c still canceled after retrying only b (upload %+v)", got, s)
	}

	if err := q.Retry(settingsFor("bucket-1"), id, nil); err != nil {
		t.Fatal(err)
	}
	waitState(t, q, id, Finished)
	if got := r.callList(); !slices.Equal(got, []string{"a", "b", "b", "c"}) {
		t.Fatalf("calls = %v, want a once, b twice (cut, then retried) and c once", got)
	}

}

func TestCanceledUploadCanBeRemoved(t *testing.T) {
	r := newCtl()
	r.setHang("a.bin")
	q := ctlQueue(t, newMemStore(), r)
	enqueueOne(t, q, "a.bin")
	canceled := enqueueOne(t, q, "z.bin")
	r.awaitStarted(t, "a.bin")
	if err := q.Cancel("bucket-1", canceled); err != nil {
		t.Fatal(err)
	}

	if err := q.Remove(context.Background(), "bucket-1", canceled, nil, nil); err != nil {
		t.Fatalf("removing a canceled upload: %v", err)
	}
	if _, ok := lookup(q, canceled); ok {
		t.Fatal("the canceled upload is still in the history")
	}
}

func lookup(q *Queue, id string) (Snapshot, bool) {
	initial, _, cancel := q.Subscribe()
	cancel()
	for _, s := range initial {
		if s.ID == id {
			return s, true
		}
	}
	return Snapshot{}, false
}

func TestHoldStopsTheRunningUploadAndNothingStartsUntilItEnds(t *testing.T) {
	r := newCtl()
	r.setHang("a.bin")
	q := ctlQueue(t, newMemStore(), r)
	a := enqueueOne(t, q, "a.bin")
	b := enqueueOne(t, q, "b.bin")
	r.awaitStarted(t, "a.bin")

	q.SetHold(true)

	for _, id := range []string{a, b} {
		s := snapOf(t, q, id)
		if s.State != Paused || s.PauseReason != PausedOnHold {
			t.Fatalf("upload %s during a hold = %+v, want paused on hold", id, s)
		}
	}
	for _, f := range filesOf(t, q, b) {
		if f.State != Paused {
			t.Fatalf("file of a held upload = %+v, want paused", f)
		}
	}
	time.Sleep(60 * time.Millisecond)
	if got := r.callList(); !slices.Equal(got, []string{"a.bin"}) {
		t.Fatalf("calls during the hold = %v, want only the first attempt of a.bin", got)
	}

	r.setHang()
	q.SetHold(false)
	waitState(t, q, a, Finished)
	waitState(t, q, b, Finished)
	if got := r.callList(); !slices.Equal(got, []string{"a.bin", "a.bin", "b.bin"}) {
		t.Fatalf("calls = %v, want a.bin sent again before b.bin", got)
	}
}

func TestHeldUploadsKeepTheirOrderAndUploadsPausedByTheUserStayPaused(t *testing.T) {
	r := newCtl()
	q := ctlQueue(t, newMemStore(), r)
	q.SetHold(true)
	first := enqueueOne(t, q, "first.bin") // enqueued during the hold
	mine := enqueueOne(t, q, "mine.bin")
	last := enqueueOne(t, q, "last.bin")
	if s := snapOf(t, q, first); s.State != Paused || s.PauseReason != PausedOnHold {
		t.Fatalf("upload enqueued during a hold = %+v, want accepted and paused on hold", s)
	}
	if err := q.Pause("bucket-1", mine); err != nil {
		t.Fatal(err)
	}
	if s := snapOf(t, q, mine); s.State != Paused || s.PauseReason != PausedByUser {
		t.Fatalf("user-paused upload during a hold = %+v, want it still paused by the user", s)
	}
	time.Sleep(50 * time.Millisecond)
	if got := r.callList(); len(got) != 0 {
		t.Fatalf("something was sent during the hold: %v", got)
	}

	q.SetHold(false)

	waitState(t, q, first, Finished)
	waitState(t, q, last, Finished)
	if s := snapOf(t, q, mine); s.State != Paused || s.PauseReason != PausedByUser {
		t.Fatalf("user-paused upload after the hold = %+v, want it still paused by the user", s)
	}
	if got := r.callList(); !slices.Equal(got, []string{"first.bin", "last.bin"}) {
		t.Fatalf("calls = %v, want the original order without the paused upload", got)
	}
}

func TestHoldIsNotStored(t *testing.T) {
	st := newMemStore()
	q := storedQueue(t, st, newCtl(), nopLogger{})
	q.SetSettings(settingsFor("bucket-1"))
	q.SetHold(true)
	id := enqueueOne(t, q, "a.bin") // never runs: no Run loop

	q2 := storedQueue(t, st, newCtl(), nopLogger{})
	s := snapOf(t, q2, id)
	if s.State != Failed || s.ErrorMessage != InterruptedMessage {
		t.Fatalf("after a restart the held upload is %+v, want it interrupted like any queued upload, not paused", s)
	}
}

func TestReleasingAHoldTwiceOrHoldingTwiceChangesNothing(t *testing.T) {
	r := newCtl()
	q := ctlQueue(t, newMemStore(), r)
	q.SetHold(false)
	q.SetHold(true)
	q.SetHold(true)
	id := enqueueOne(t, q, "a.bin")
	q.SetHold(false)
	q.SetHold(false)
	waitState(t, q, id, Finished)
}

func TestResumeInterruptedPutsBackOnlyTheInterruptedUploadsOfTheBucket(t *testing.T) {
	st := newMemStore()
	r0 := newCtl()
	q0 := storedQueue(t, st, r0, nopLogger{})
	q0.SetSettings(settingsFor("bucket-1"))
	interrupted := enqueueOne(t, q0, "cut.bin")
	otherBucket, err := q0.Enqueue(settingsFor("bucket-2"), req(writeFile(t, "elsewhere.bin", 1)))
	if err != nil {
		t.Fatal(err)
	}
	// q0 never runs: both uploads are stored as queued, which a restart reads as cut off.

	r := newCtl()
	r.failWith["bad.bin"] = errors.New("boom")
	q := ctlQueue(t, st, r)
	failed := enqueueOne(t, q, "bad.bin")
	waitState(t, q, failed, Failed)
	r.setHang("hold.bin")
	userPaused := enqueueOne(t, q, "hold.bin")
	r.awaitStarted(t, "hold.bin")
	if err := q.Pause("bucket-1", userPaused); err != nil {
		t.Fatal(err)
	}
	waitState(t, q, userPaused, Paused)
	r.setHang()
	if s := snapOf(t, q, interrupted); s.State != Failed || s.ErrorMessage != InterruptedMessage {
		t.Fatalf("restored upload = %+v, want failed as interrupted", s)
	}

	if n := q.ResumeInterrupted(settingsFor("bucket-1")); n != 1 {
		t.Fatalf("resumed %d uploads, want 1", n)
	}

	waitState(t, q, interrupted, Finished)
	if s := snapOf(t, q, failed); s.State != Failed {
		t.Fatalf("an upload that failed on its own was resumed: %+v", s)
	}
	if s := snapOf(t, q, userPaused); s.State != Paused || s.PauseReason != PausedByUser {
		t.Fatalf("an upload paused by the user was resumed: %+v", s)
	}
	if s := snapOf(t, q, otherBucket); s.State != Failed {
		t.Fatalf("an upload of another bucket was resumed: %+v", s)
	}
	if n := q.ResumeInterrupted(settingsFor("bucket-1")); n != 0 {
		t.Fatalf("a second pass resumed %d uploads, want none left", n)
	}
}

func TestReconciliationInputsLeavePausedUploadsAlone(t *testing.T) {
	r := newCtl()
	r.setHang("b")
	q := ctlQueue(t, newMemStore(), r)
	id := enqueueTree(t, q, 1, "d/a", "d/b")
	r.awaitStarted(t, "b")
	if err := q.Pause("bucket-1", id); err != nil {
		t.Fatal(err)
	}
	waitState(t, q, id, Paused)

	files, err := q.FinishedFiles("bucket-1")
	if err != nil {
		t.Fatal(err)
	}
	if len(files) != 0 {
		t.Fatalf("FinishedFiles = %+v, want none from a paused upload", files)
	}
	gone := []FinishedFile{{UploadID: id, Index: indexOfFile(t, filesOf(t, q, id), "d/a"), ObjectKey: "pfx/d/a"}}
	if n, err := q.ForgetMissing("bucket-1", gone); err != nil || n != 0 {
		t.Fatalf("ForgetMissing = %d, %v; want a paused upload left alone", n, err)
	}
	if s := snapOf(t, q, id); s.FilesFinished != 1 || s.FilesTotal != 2 {
		t.Fatalf("paused upload changed: %+v", s)
	}
}

func TestRemoveRefusesAPausedUpload(t *testing.T) {
	r := newCtl()
	r.setHang("b")
	q := ctlQueue(t, newMemStore(), r)
	id := enqueueTree(t, q, 1, "d/a", "d/b")
	r.awaitStarted(t, "b")
	if err := q.Pause("bucket-1", id); err != nil {
		t.Fatal(err)
	}
	waitState(t, q, id, Paused)

	if err := q.Remove(context.Background(), "bucket-1", id, nil, nil); !errors.Is(err, ErrUploadPaused) {
		t.Fatalf("err = %v, want ErrUploadPaused", err)
	}
}
