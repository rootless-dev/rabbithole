package queue

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"rabbithole/daemon/internal/uploader"
)

// guard bounds every blocking wait so a broken queue fails the test instead of hanging it.
const guard = 5 * time.Second

type fakeClock struct {
	mu sync.Mutex
	t  time.Time
}

func newFakeClock() *fakeClock { return &fakeClock{t: time.Unix(1_700_000_000, 0)} }

func (c *fakeClock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.t
}

func (c *fakeClock) Advance(d time.Duration) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.t = c.t.Add(d)
}

type runnerFunc func(ctx context.Context, s uploader.Settings, req uploader.Request, cb uploader.Callbacks) error

func (f runnerFunc) Run(ctx context.Context, s uploader.Settings, req uploader.Request, cb uploader.Callbacks) error {
	return f(ctx, s, req, cb)
}

func okRunner() runnerFunc {
	return func(context.Context, uploader.Settings, uploader.Request, uploader.Callbacks) error { return nil }
}

// req is an enqueue request for the given paths with every default.
func req(paths ...string) EnqueueRequest { return EnqueueRequest{Paths: paths} }

func writeFile(t *testing.T, name string, size int) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), name)
	if err := os.WriteFile(p, make([]byte, size), 0o600); err != nil {
		t.Fatal(err)
	}
	return p
}

// startRun runs the queue until the test ends.
func startRun(t *testing.T, q *Queue) {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		q.Run(ctx)
		close(done)
	}()
	t.Cleanup(func() {
		cancel()
		select {
		case <-done:
		case <-time.After(guard):
			t.Error("Run did not return after cancel")
		}
	})
}

// collectUntil reads snapshots until stop returns true for one, and returns all read.
func collectUntil[T any](t *testing.T, ch <-chan T, stop func(T) bool) []T {
	t.Helper()
	var got []T
	for {
		select {
		case s, ok := <-ch:
			if !ok {
				t.Fatalf("channel closed early; got %+v", got)
			}
			got = append(got, s)
			if stop(s) {
				return got
			}
		case <-time.After(guard):
			t.Fatalf("timed out waiting; got %+v", got)
		}
	}
}

func finishedCount(n int) func() func(Snapshot) bool {
	return func() func(Snapshot) bool {
		seen := 0
		return func(s Snapshot) bool {
			if s.State == Finished {
				seen++
			}
			return seen == n
		}
	}
}

func TestFIFOOrderOneAtATime(t *testing.T) {
	var mu sync.Mutex
	var order []string
	running, maxRunning := 0, 0
	r := runnerFunc(func(_ context.Context, _ uploader.Settings, req uploader.Request, _ uploader.Callbacks) error {
		mu.Lock()
		running++
		maxRunning = max(maxRunning, running)
		order = append(order, filepath.Base(req.LocalPath))
		mu.Unlock()
		mu.Lock()
		running--
		mu.Unlock()
		return nil
	})
	q := New(r, newFakeClock().Now)
	_, updates, cancel := q.Subscribe()
	defer cancel()
	for _, n := range []string{"a", "b", "c"} {
		if _, err := q.Enqueue(uploader.Settings{}, req(writeFile(t, n, 1))); err != nil {
			t.Fatal(err)
		}
	}
	startRun(t, q)
	collectUntil(t, updates, finishedCount(3)())

	mu.Lock()
	defer mu.Unlock()
	if fmt.Sprint(order) != "[a b c]" {
		t.Errorf("order = %v, want [a b c]", order)
	}
	if maxRunning != 1 {
		t.Errorf("max concurrent = %d, want 1", maxRunning)
	}
}

// stepper lets a fake runner and the test advance in lockstep. A subscriber
// coalesces snapshots it has not delivered yet, so a test that needs to see
// each intermediate state must hold the runner until it has read it.
type stepper struct{ reached, proceed chan struct{} }

func newStepper() *stepper {
	return &stepper{reached: make(chan struct{}), proceed: make(chan struct{})}
}

// pause is called by the runner: it blocks until the test calls resume.
func (s *stepper) pause() {
	s.reached <- struct{}{}
	<-s.proceed
}

// resume is called by the test: it waits for the runner to pause, then releases it.
func (s *stepper) resume(t *testing.T) {
	t.Helper()
	select {
	case <-s.reached:
	case <-time.After(guard):
		t.Fatal("runner never reached its pause point")
	}
	s.proceed <- struct{}{}
}

func TestSnapshotSequenceSuccess(t *testing.T) {
	clock := newFakeClock()
	step := newStepper()
	r := runnerFunc(func(_ context.Context, _ uploader.Settings, _ uploader.Request, cb uploader.Callbacks) error {
		cb.KeyResolved("backup/a.bin")
		step.pause()
		clock.Advance(time.Second)
		cb.Progress(5)
		step.pause()
		return nil
	})
	q := New(r, clock.Now)
	_, updates, cancel := q.Subscribe()
	defer cancel()
	path := writeFile(t, "a.bin", 10)
	id, err := q.Enqueue(uploader.Settings{}, req(path))
	if err != nil {
		t.Fatal(err)
	}
	// Read the queued snapshot before Run starts so nothing can coalesce it away.
	got := collectUntil(t, updates, func(s Snapshot) bool { return s.State == Queued })
	startRun(t, q)
	got = append(got, collectUntil(t, updates, func(s Snapshot) bool { return s.State == Uploading && s.ObjectKey != "" })...)
	step.resume(t)
	got = append(got, collectUntil(t, updates, func(s Snapshot) bool { return s.State == Uploading && s.BytesSent == 5 })...)
	step.resume(t)
	got = append(got, collectUntil(t, updates, func(s Snapshot) bool { return s.State == Finished })...)

	first := got[0]
	if first.ID != id || first.State != Queued || first.ObjectKey != "" || first.FileName != "a.bin" ||
		first.LocalPath != path || first.BytesTotal != 10 || first.BytesSent != 0 {
		t.Errorf("first snapshot = %+v", first)
	}
	var sawKey, sawProgress bool
	for _, s := range got {
		if s.State == Uploading && s.ObjectKey == "backup/a.bin" {
			sawKey = true
		}
		if s.State == Uploading && s.BytesSent == 5 {
			sawProgress = true
		}
		if s.BytesSent > s.BytesTotal {
			t.Errorf("bytes_sent above total: %+v", s)
		}
	}
	if !sawKey || !sawProgress {
		t.Errorf("sawKey=%v sawProgress=%v in %+v", sawKey, sawProgress, got)
	}
	last := got[len(got)-1]
	if last.State != Finished || last.BytesSent != last.BytesTotal || last.ObjectKey != "backup/a.bin" {
		t.Errorf("last snapshot = %+v", last)
	}
}

func TestSnapshotSequenceFailure(t *testing.T) {
	runErr := fmt.Errorf("put: %w", uploader.ErrNoNetwork)
	r := runnerFunc(func(_ context.Context, _ uploader.Settings, _ uploader.Request, cb uploader.Callbacks) error {
		cb.KeyResolved("backup/a.bin")
		return runErr
	})
	q := New(r, newFakeClock().Now)
	_, updates, cancel := q.Subscribe()
	defer cancel()
	if _, err := q.Enqueue(uploader.Settings{}, req(writeFile(t, "a.bin", 10))); err != nil {
		t.Fatal(err)
	}
	startRun(t, q)
	got := collectUntil(t, updates, func(s Snapshot) bool { return s.State == Failed })
	last := got[len(got)-1]
	if last.ErrorMessage != uploader.Message(runErr) {
		t.Errorf("ErrorMessage = %q, want %q", last.ErrorMessage, uploader.Message(runErr))
	}
	if last.ObjectKey != "backup/a.bin" {
		t.Errorf("ObjectKey = %q, want last known key", last.ObjectKey)
	}
}

func TestProgressThrottledToTenPerSecond(t *testing.T) {
	clock := newFakeClock()
	step := newStepper()
	r := runnerFunc(func(_ context.Context, _ uploader.Settings, _ uploader.Request, cb uploader.Callbacks) error {
		cb.KeyResolved("k")
		step.pause() // the test has read everything published so far
		for i := int64(1); i <= 50; i++ {
			clock.Advance(time.Millisecond) // 50 ms in total, inside the 100 ms window
			cb.Progress(i)
		}
		step.pause() // the test checks that nothing was published
		clock.Advance(100 * time.Millisecond)
		cb.Progress(60)
		step.pause() // the test reads the progress snapshot
		return nil
	})
	q := New(r, clock.Now)
	_, updates, cancel := q.Subscribe()
	defer cancel()
	if _, err := q.Enqueue(uploader.Settings{}, req(writeFile(t, "a.bin", 100))); err != nil {
		t.Fatal(err)
	}
	startRun(t, q)
	collectUntil(t, updates, func(s Snapshot) bool { return s.State == Uploading && s.ObjectKey == "k" })
	step.resume(t)

	// 50 progress calls inside the window: the subscriber must have nothing pending.
	select {
	case <-step.reached:
	case <-time.After(guard):
		t.Fatal("runner never finished its progress calls")
	}
	q.mu.Lock()
	for sub := range q.subs {
		sub.mu.Lock()
		if n := len(sub.order); n != 0 {
			t.Errorf("%d snapshots published for 50 progress calls inside 100 ms, want 0", n)
		}
		sub.mu.Unlock()
	}
	q.mu.Unlock()
	step.proceed <- struct{}{}

	got := collectUntil(t, updates, func(s Snapshot) bool { return s.State == Uploading && s.BytesSent > 0 })
	if last := got[len(got)-1]; last.BytesSent != 60 {
		t.Errorf("progress after the window = %+v, want bytes_sent 60", last)
	}
	step.resume(t)
	got = collectUntil(t, updates, func(s Snapshot) bool { return s.State == Finished })
	if last := got[len(got)-1]; last.BytesSent != 100 {
		t.Errorf("final snapshot = %+v, want bytes_sent 100", last)
	}
}

func TestSubscribeReplaysKnownUploads(t *testing.T) {
	q := New(okRunner(), newFakeClock().Now)
	a, _ := q.Enqueue(uploader.Settings{}, req(writeFile(t, "a", 1)))
	b, _ := q.Enqueue(uploader.Settings{}, req(writeFile(t, "b", 1)))

	initial, updates, cancel := q.Subscribe()
	defer cancel()
	if len(initial) != 2 || initial[0].ID != a || initial[1].ID != b {
		t.Fatalf("initial = %+v, want [a b]", initial)
	}
	for _, s := range initial {
		if s.State != Queued {
			t.Errorf("initial snapshot not queued: %+v", s)
		}
	}
	select {
	case s := <-updates:
		t.Fatalf("unexpected update before any change: %+v", s)
	default:
	}
	startRun(t, q)
	got := collectUntil(t, updates, finishedCount(2)())
	if got[0].State == Queued {
		t.Errorf("replayed state republished as an update: %+v", got[0])
	}
}

func TestSlowSubscriberNeverBlocksRunner(t *testing.T) {
	clock := newFakeClock()
	r := runnerFunc(func(_ context.Context, _ uploader.Settings, _ uploader.Request, cb uploader.Callbacks) error {
		cb.KeyResolved("k")
		for i := int64(1); i <= 1000; i++ {
			clock.Advance(time.Second)
			cb.Progress(i)
		}
		return nil
	})
	q := New(r, clock.Now)
	_, slow, cancelSlow := q.Subscribe() // never read during the uploads
	defer cancelSlow()
	_, fast, cancelFast := q.Subscribe()
	defer cancelFast()
	a, _ := q.Enqueue(uploader.Settings{}, req(writeFile(t, "a", 2000)))
	b, _ := q.Enqueue(uploader.Settings{}, req(writeFile(t, "b", 2000)))
	startRun(t, q)

	// The fast subscriber seeing both uploads finish proves the runner was not blocked.
	collectUntil(t, fast, finishedCount(2)())

	// The slow subscriber starts reading now and still gets the final state of each upload.
	finals := map[string]Snapshot{}
	var finishOrder []string
	collectUntil(t, slow, func(s Snapshot) bool {
		finals[s.ID] = s
		if s.State == Finished {
			finishOrder = append(finishOrder, s.ID)
		}
		return len(finishOrder) == 2
	})
	for _, id := range []string{a, b} {
		if finals[id].State != Finished || finals[id].BytesSent != finals[id].BytesTotal {
			t.Errorf("slow subscriber final for %s = %+v", id, finals[id])
		}
	}
	// The channel stays open: nothing more arrives, but it is not closed.
	select {
	case s, ok := <-slow:
		if !ok {
			t.Error("slow subscriber channel was closed")
		} else {
			t.Errorf("unexpected extra snapshot: %+v", s)
		}
	default:
	}
}

func TestSlowSubscriberMemoryBoundedByUploads(t *testing.T) {
	clock := newFakeClock()
	r := runnerFunc(func(_ context.Context, _ uploader.Settings, _ uploader.Request, cb uploader.Callbacks) error {
		cb.KeyResolved("k")
		for i := int64(1); i <= 500; i++ {
			clock.Advance(time.Second)
			cb.Progress(i)
		}
		return nil
	})
	q := New(r, clock.Now)
	_, fast, cancelFast := q.Subscribe()
	defer cancelFast()
	if _, err := q.Enqueue(uploader.Settings{}, req(writeFile(t, "a", 1000))); err != nil {
		t.Fatal(err)
	}
	// Subscribe after enqueue so the slow subscriber starts with one queued upload.
	_, slow, cancelSlow := q.Subscribe()
	defer cancelSlow()
	startRun(t, q)
	collectUntil(t, fast, finishedCount(1)())

	got := collectUntil(t, slow, func(s Snapshot) bool { return s.State == Finished })
	if len(got) > 3 {
		t.Errorf("slow subscriber received %d snapshots for one upload, want a coalesced handful", len(got))
	}
}

func TestEnqueueRejectsEmptyFolderAndMissingFile(t *testing.T) {
	q := New(okRunner(), newFakeClock().Now)
	if _, err := q.Enqueue(uploader.Settings{}, req(t.TempDir())); !errors.Is(err, ErrNoFiles) {
		t.Errorf("empty folder: err = %v, want ErrNoFiles", err)
	}
	missing := filepath.Join(t.TempDir(), "nope")
	if _, err := q.Enqueue(uploader.Settings{}, req(missing)); !errors.Is(err, ErrInvalidPath) {
		t.Errorf("missing: err = %v, want ErrInvalidPath", err)
	}
	if initial, _, cancel := q.Subscribe(); len(initial) != 0 {
		t.Errorf("rejected paths were queued: %+v", initial)
	} else {
		cancel()
	}
}

func TestZeroByteFileAccepted(t *testing.T) {
	q := New(okRunner(), newFakeClock().Now) // the runner makes no Progress call, like the uploader
	_, updates, cancel := q.Subscribe()
	defer cancel()
	if _, err := q.Enqueue(uploader.Settings{}, req(writeFile(t, "empty", 0))); err != nil {
		t.Fatal(err)
	}
	startRun(t, q)
	got := collectUntil(t, updates, func(s Snapshot) bool { return s.State == Finished })
	last := got[len(got)-1]
	if last.BytesTotal != 0 || last.BytesSent != 0 {
		t.Errorf("zero byte snapshot = %+v", last)
	}
}

func TestSettingsCapturedAtEnqueue(t *testing.T) {
	var mu sync.Mutex
	seen := map[string]uploader.Settings{}
	r := runnerFunc(func(_ context.Context, s uploader.Settings, req uploader.Request, _ uploader.Callbacks) error {
		mu.Lock()
		defer mu.Unlock()
		seen[filepath.Base(req.LocalPath)] = s
		return nil
	})
	q := New(r, newFakeClock().Now)
	_, updates, cancel := q.Subscribe()
	defer cancel()
	s1 := uploader.Settings{Bucket: "one", Prefix: "p1"}
	s2 := uploader.Settings{Bucket: "two", Prefix: "p2"}
	q.Enqueue(s1, req(writeFile(t, "a", 1)))
	q.Enqueue(s2, req(writeFile(t, "b", 1)))
	startRun(t, q)
	collectUntil(t, updates, finishedCount(2)())

	mu.Lock()
	defer mu.Unlock()
	if seen["a"] != s1 || seen["b"] != s2 {
		t.Errorf("settings per job = %v, want a=%v b=%v", seen, s1, s2)
	}
}

func TestRequestCarriesPrefixAndPath(t *testing.T) {
	var got uploader.Request
	r := runnerFunc(func(_ context.Context, _ uploader.Settings, req uploader.Request, _ uploader.Callbacks) error {
		got = req
		return nil
	})
	q := New(r, newFakeClock().Now)
	_, updates, cancel := q.Subscribe()
	defer cancel()
	path := writeFile(t, "a", 1)
	q.Enqueue(uploader.Settings{Prefix: "pfx"}, req(path))
	startRun(t, q)
	collectUntil(t, updates, finishedCount(1)())
	if got.Prefix != "pfx" || got.LocalPath != path {
		t.Errorf("request = %+v", got)
	}
}

func TestRunCancelsCurrentUpload(t *testing.T) {
	started := make(chan struct{})
	r := runnerFunc(func(ctx context.Context, _ uploader.Settings, _ uploader.Request, _ uploader.Callbacks) error {
		close(started)
		<-ctx.Done()
		return ctx.Err()
	})
	q := New(r, newFakeClock().Now)
	if _, err := q.Enqueue(uploader.Settings{}, req(writeFile(t, "a", 1))); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		q.Run(ctx)
		close(done)
	}()
	select {
	case <-started:
	case <-time.After(guard):
		t.Fatal("runner never started")
	}
	cancel()
	select {
	case <-done:
	case <-time.After(guard):
		t.Fatal("Run did not return after cancel")
	}
}

func TestCancelSubscriptionClosesChannel(t *testing.T) {
	q := New(okRunner(), newFakeClock().Now)
	_, updates, cancel := q.Subscribe()
	cancel()
	cancel() // idempotent
	select {
	case _, ok := <-updates:
		if ok {
			t.Error("received a snapshot after cancel")
		}
	case <-time.After(guard):
		t.Fatal("channel not closed after cancel")
	}
}
