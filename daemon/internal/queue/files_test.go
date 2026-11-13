package queue

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"sync"
	"testing"
	"time"

	"rabbithole/daemon/internal/uploader"
)

// folderRunner is a runnerFunc that also resolves folder names.
type folderRunner struct {
	runnerFunc
	resolve func(ctx context.Context, s uploader.Settings, name string) (string, error)
}

func (f folderRunner) ResolveFolder(ctx context.Context, s uploader.Settings, name string) (string, error) {
	return f.resolve(ctx, s, name)
}

func isTerminal(s Snapshot) bool { return s.State == Finished || s.State == Failed }

// runToEnd runs one upload and returns its last snapshot and the final snapshot of each file.
func runToEnd(t *testing.T, r Runner, r2 EnqueueRequest) (Snapshot, []FileSnapshot) {
	t.Helper()
	q := New(r, newFakeClock().Now)
	_, updates, cancel := q.Subscribe()
	defer cancel()
	id, err := q.Enqueue(uploader.Settings{Prefix: "pfx/"}, r2)
	if err != nil {
		t.Fatal(err)
	}
	startRun(t, q)
	got := collectUntil(t, updates, isTerminal)
	files, _, cancelFiles, err := q.SubscribeFiles(id)
	if err != nil {
		t.Fatal(err)
	}
	cancelFiles()
	return got[len(got)-1], files
}

func states(files []FileSnapshot) []State {
	var out []State
	for _, f := range files {
		out = append(out, f.State)
	}
	return out
}

func TestFolderFilesLandUnderTheResolvedFolder(t *testing.T) {
	root := tree(t, "photos/a.jpg", "photos/sub/deep/b.jpg")
	var mu sync.Mutex
	reqs := map[string]uploader.Request{}
	r := folderRunner{
		runnerFunc: func(_ context.Context, _ uploader.Settings, req uploader.Request, cb uploader.Callbacks) error {
			mu.Lock()
			reqs[filepath.Base(req.LocalPath)] = req
			mu.Unlock()
			cb.KeyResolved(req.Prefix + filepath.Base(req.LocalPath))
			return nil
		},
		resolve: func(_ context.Context, s uploader.Settings, name string) (string, error) {
			if s.Prefix != "pfx/" || name != "photos" {
				t.Errorf("resolve(%q, %q)", s.Prefix, name)
			}
			return "photos-20261112-131005", nil
		},
	}
	last, files := runToEnd(t, r, req(filepath.Join(root, "photos")))

	if last.State != Finished || last.ObjectKey != "pfx/photos-20261112-131005/" || last.Kind != Folder {
		t.Errorf("last = %+v", last)
	}
	mu.Lock()
	defer mu.Unlock()
	if got := reqs["a.jpg"]; got.Prefix != "pfx/photos-20261112-131005/" || !got.SkipExistenceCheck || got.Name != "" {
		t.Errorf("a.jpg request = %+v", got)
	}
	if got := reqs["b.jpg"]; got.Prefix != "pfx/photos-20261112-131005/sub/deep/" || !got.SkipExistenceCheck {
		t.Errorf("b.jpg request = %+v", got)
	}
	if files[1].ObjectKey != "pfx/photos-20261112-131005/sub/deep/b.jpg" {
		t.Errorf("file key = %q", files[1].ObjectKey)
	}
}

func TestFilesListedDirectlyUseTheirDestinationName(t *testing.T) {
	root := tree(t, "one/a.txt", "two/a.txt")
	var mu sync.Mutex
	var reqs []uploader.Request
	r := runnerFunc(func(_ context.Context, _ uploader.Settings, req uploader.Request, cb uploader.Callbacks) error {
		mu.Lock()
		reqs = append(reqs, req)
		mu.Unlock()
		cb.KeyResolved(req.Prefix + req.Name)
		return nil
	})
	last, files := runToEnd(t, r, EnqueueRequest{
		Paths:         []string{filepath.Join(root, "one", "a.txt"), filepath.Join(root, "two", "a.txt")},
		ParallelFiles: 1,
	})
	if last.State != Finished || last.ObjectKey != "" || last.Kind != Multiple {
		t.Errorf("last = %+v", last)
	}
	if files[0].ObjectKey != "pfx/a.txt" || files[1].ObjectKey != "pfx/a-2.txt" {
		t.Errorf("keys = %q, %q", files[0].ObjectKey, files[1].ObjectKey)
	}
	for _, req := range reqs {
		if req.SkipExistenceCheck || req.Prefix != "pfx/" {
			t.Errorf("request = %+v", req)
		}
	}
}

func TestSingleFileObjectKeyComesFromTheRunner(t *testing.T) {
	root := tree(t, "a.txt")
	r := runnerFunc(func(_ context.Context, _ uploader.Settings, _ uploader.Request, cb uploader.Callbacks) error {
		cb.KeyResolved("pfx/a-stamp.txt")
		return nil
	})
	last, _ := runToEnd(t, r, req(filepath.Join(root, "a.txt")))
	if last.ObjectKey != "pfx/a-stamp.txt" || last.Kind != SingleFile {
		t.Errorf("last = %+v", last)
	}
}

func TestFilesRunInParallelAndProgressIsSummed(t *testing.T) {
	root := t.TempDir()
	var paths []string
	for i := range 5 {
		paths = append(paths, writeFile2(t, root, fmt.Sprintf("f%d", i), 100))
	}
	const parallel = 3

	var mu sync.Mutex
	running, maxRunning := 0, 0
	started := make(chan struct{}, 5)
	release := make(chan struct{})
	half := make(chan struct{}, 5)
	r := runnerFunc(func(ctx context.Context, _ uploader.Settings, _ uploader.Request, cb uploader.Callbacks) error {
		mu.Lock()
		running++
		maxRunning = max(maxRunning, running)
		mu.Unlock()
		started <- struct{}{}
		cb.Progress(50)
		half <- struct{}{}
		<-release
		mu.Lock()
		running--
		mu.Unlock()
		return nil
	})
	q := New(r, newFakeClock().Now)
	_, updates, cancel := q.Subscribe()
	defer cancel()
	id, err := q.Enqueue(uploader.Settings{}, EnqueueRequest{Paths: paths, ParallelFiles: parallel})
	if err != nil {
		t.Fatal(err)
	}
	startRun(t, q)

	for range parallel {
		<-started
		<-half
	}
	q.mu.Lock()
	snap := q.uploads[id].snap
	q.mu.Unlock()
	if snap.BytesTotal != 500 || snap.BytesSent != 150 {
		t.Errorf("while three files are half sent: total %d, sent %d; want 500, 150", snap.BytesTotal, snap.BytesSent)
	}
	select {
	case <-started:
		t.Fatal("a fourth file started while three were still running")
	default:
	}

	close(release)
	got := collectUntil(t, updates, isTerminal)
	last := got[len(got)-1]
	if last.State != Finished || last.BytesSent != 500 || last.FilesFinished != 5 || last.FilesFailed != 0 || last.FilesTotal != 5 {
		t.Errorf("last = %+v", last)
	}
	mu.Lock()
	defer mu.Unlock()
	if maxRunning != parallel {
		t.Errorf("max concurrent files = %d, want %d", maxRunning, parallel)
	}
}

func writeFile2(t *testing.T, dir, name string, size int) string {
	t.Helper()
	p := filepath.Join(dir, name)
	if err := os.WriteFile(p, make([]byte, size), 0o600); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestFilesStartInPlanOrder(t *testing.T) {
	root := tree(t, "d/a", "d/b", "d/c")
	var mu sync.Mutex
	var order []string
	r := runnerFunc(func(_ context.Context, _ uploader.Settings, req uploader.Request, _ uploader.Callbacks) error {
		mu.Lock()
		order = append(order, filepath.Base(req.LocalPath))
		mu.Unlock()
		return nil
	})
	runToEnd(t, r, EnqueueRequest{Paths: []string{filepath.Join(root, "d")}, ParallelFiles: 1})
	if !slices.Equal(order, []string{"a", "b", "c"}) {
		t.Errorf("order = %v", order)
	}
}

func TestNonFatalFailureFailsOnlyThatFile(t *testing.T) {
	root := tree(t, "d/a", "d/b", "d/c")
	r := runnerFunc(func(_ context.Context, _ uploader.Settings, req uploader.Request, _ uploader.Callbacks) error {
		if filepath.Base(req.LocalPath) == "b" {
			return fmt.Errorf("put: %w", uploader.ErrNoFreeName)
		}
		return nil
	})
	last, files := runToEnd(t, r, EnqueueRequest{Paths: []string{filepath.Join(root, "d")}, ParallelFiles: 1})

	if !slices.Equal(states(files), []State{Finished, Failed, Finished}) {
		t.Errorf("file states = %v", states(files))
	}
	if files[1].ErrorMessage != uploader.Message(uploader.ErrNoFreeName) {
		t.Errorf("file message = %q", files[1].ErrorMessage)
	}
	if last.State != Failed || last.ErrorMessage != "1 of 3 files could not be sent" ||
		last.FilesFinished != 2 || last.FilesFailed != 1 {
		t.Errorf("last = %+v", last)
	}
}

func TestSingleFileFailureKeepsTheFileMessage(t *testing.T) {
	root := tree(t, "a")
	r := runnerFunc(func(context.Context, uploader.Settings, uploader.Request, uploader.Callbacks) error {
		return uploader.ErrFileUnreadable
	})
	last, _ := runToEnd(t, r, req(filepath.Join(root, "a")))
	if last.State != Failed || last.ErrorMessage != "File could not be read" {
		t.Errorf("last = %+v", last)
	}
}

func TestFatalFailureStopsTheUploadAndFailsEveryUnfinishedFile(t *testing.T) {
	root := tree(t, "d/a", "d/b", "d/c", "d/d")
	started := make(chan struct{}, 4)
	r := runnerFunc(func(ctx context.Context, _ uploader.Settings, req uploader.Request, _ uploader.Callbacks) error {
		switch filepath.Base(req.LocalPath) {
		case "a":
			return nil
		case "b":
			<-started // c is running too
			return fmt.Errorf("put: %w", uploader.ErrBadCredentials)
		case "c":
			started <- struct{}{}
			<-ctx.Done()
			return ctx.Err()
		}
		t.Errorf("file %s should never start", filepath.Base(req.LocalPath))
		return nil
	})
	q := New(r, newFakeClock().Now)
	_, updates, cancel := q.Subscribe()
	defer cancel()
	id, err := q.Enqueue(uploader.Settings{}, EnqueueRequest{Paths: []string{filepath.Join(root, "d")}, ParallelFiles: 2})
	if err != nil {
		t.Fatal(err)
	}
	startRun(t, q)
	got := collectUntil(t, updates, isTerminal)
	last := got[len(got)-1]

	want := uploader.Message(uploader.ErrBadCredentials)
	if last.State != Failed || last.ErrorMessage != want || last.FilesFinished != 1 || last.FilesFailed != 3 {
		t.Errorf("last = %+v", last)
	}
	files, _, cancelFiles, _ := q.SubscribeFiles(id)
	cancelFiles()
	if !slices.Equal(states(files), []State{Finished, Failed, Failed, Failed}) {
		t.Fatalf("file states = %v", states(files))
	}
	for _, f := range files[1:] {
		if f.ErrorMessage != want {
			t.Errorf("file %s message = %q, want %q", f.RelativePath, f.ErrorMessage, want)
		}
	}
}

func TestEveryFatalErrorKindFailsTheUploadWithItsOwnMessage(t *testing.T) {
	for _, fatal := range []error{
		uploader.ErrBadCredentials, uploader.ErrBucketNotFound, uploader.ErrBucketInaccessible, uploader.ErrWrongRegion,
		uploader.ErrNoNetwork, uploader.ErrForbidden, uploader.ErrWriteDenied,
	} {
		t.Run(fatal.Error(), func(t *testing.T) {
			root := tree(t, "d/a", "d/b")
			r := runnerFunc(func(context.Context, uploader.Settings, uploader.Request, uploader.Callbacks) error {
				return fmt.Errorf("wrapped: %w", fatal)
			})
			last, files := runToEnd(t, r, req(filepath.Join(root, "d")))
			if last.ErrorMessage != uploader.Message(fatal) || last.State != Failed {
				t.Errorf("last = %+v", last)
			}
			for _, f := range files {
				if f.State != Failed || f.ErrorMessage != uploader.Message(fatal) {
					t.Errorf("file = %+v", f)
				}
			}
		})
	}
}

func TestUnreadableEntryFailsWithoutCallingTheRunner(t *testing.T) {
	root := tree(t, "d/a")
	q := New(okRunner(), newFakeClock().Now)
	var calls int
	q.runner = runnerFunc(func(context.Context, uploader.Settings, uploader.Request, uploader.Callbacks) error {
		calls++
		return nil
	})
	_, updates, cancel := q.Subscribe()
	defer cancel()
	id, err := q.Enqueue(uploader.Settings{}, req(filepath.Join(root, "d")))
	if err != nil {
		t.Fatal(err)
	}
	// Mark the second entry the way the walk does for a directory it cannot read.
	q.mu.Lock()
	u := q.uploads[id]
	u.files = append(u.files, &fileState{
		plan: plannedFile{local: filepath.Join(root, "d", "locked"), unreadable: true, item: 0, inner: "locked"},
		snap: FileSnapshot{UploadID: id, Index: 1, RelativePath: "d/locked", State: Queued},
	})
	u.snap.FilesTotal = 2
	q.mu.Unlock()
	startRun(t, q)
	last := collectUntil(t, updates, isTerminal)
	got := last[len(last)-1]
	if calls != 1 || got.ErrorMessage != "1 of 2 files could not be sent" {
		t.Errorf("calls = %d, last = %+v", calls, got)
	}
}

func TestFolderResolutionFailureIsFatalOnlyForFatalErrors(t *testing.T) {
	root := tree(t, "keep/a", "bad/b", "bad/c")
	resolve := func(err error) func(context.Context, uploader.Settings, string) (string, error) {
		return func(_ context.Context, _ uploader.Settings, name string) (string, error) {
			if name == "bad" {
				return "", err
			}
			return name, nil
		}
	}
	ok := runnerFunc(okRunner())
	paths := []string{filepath.Join(root, "keep"), filepath.Join(root, "bad")}

	t.Run("non-fatal fails that folder only", func(t *testing.T) {
		last, files := runToEnd(t, folderRunner{ok, resolve(uploader.ErrNoFreeName)}, EnqueueRequest{Paths: paths})
		if !slices.Equal(states(files), []State{Finished, Failed, Failed}) || last.ErrorMessage != "2 of 3 files could not be sent" {
			t.Errorf("states = %v, last = %+v", states(files), last)
		}
	})
	t.Run("fatal stops the upload", func(t *testing.T) {
		last, files := runToEnd(t, folderRunner{ok, resolve(uploader.ErrForbidden)}, EnqueueRequest{Paths: paths})
		if !slices.Equal(states(files), []State{Failed, Failed, Failed}) || last.ErrorMessage != uploader.Message(uploader.ErrForbidden) {
			t.Errorf("states = %v, last = %+v", states(files), last)
		}
	})
}

func TestShutdownMidUploadFailsItLikeASingleFileDoes(t *testing.T) {
	root := tree(t, "d/a", "d/b")
	started := make(chan struct{})
	var once sync.Once
	r := runnerFunc(func(ctx context.Context, _ uploader.Settings, _ uploader.Request, _ uploader.Callbacks) error {
		once.Do(func() { close(started) })
		<-ctx.Done()
		return ctx.Err()
	})
	q := New(r, newFakeClock().Now)
	_, updates, cancelSub := q.Subscribe()
	defer cancelSub()
	if _, err := q.Enqueue(uploader.Settings{}, req(filepath.Join(root, "d"))); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { q.Run(ctx); close(done) }()
	<-started
	cancel()
	<-done
	got := collectUntil(t, updates, isTerminal)
	if last := got[len(got)-1]; last.State != Failed || last.ErrorMessage != uploader.Message(context.Canceled) {
		t.Errorf("last = %+v", last)
	}
}

func TestFileProgressIsThrottledPerFile(t *testing.T) {
	root := tree(t, "a")
	clock := newFakeClock()
	step := newStepper()
	r := runnerFunc(func(_ context.Context, _ uploader.Settings, _ uploader.Request, cb uploader.Callbacks) error {
		cb.KeyResolved("k")
		step.pause()
		for i := int64(1); i <= 5; i++ {
			clock.Advance(time.Millisecond)
			cb.Progress(i)
		}
		step.pause()
		return nil
	})
	q := New(r, clock.Now)
	id, err := q.Enqueue(uploader.Settings{}, req(filepath.Join(root, "a")))
	if err != nil {
		t.Fatal(err)
	}
	// Give the file one byte of room so progress is meaningful.
	q.mu.Lock()
	q.uploads[id].files[0].snap.BytesTotal = 100
	q.mu.Unlock()
	_, fileUpdates, cancelFiles, _ := q.SubscribeFiles(id)
	defer cancelFiles()
	startRun(t, q)
	collectUntil(t, fileUpdates, func(f FileSnapshot) bool { return f.ObjectKey == "k" })
	step.resume(t)
	<-step.reached
	q.mu.Lock()
	for sub := range q.fileSubs[id] {
		sub.mu.Lock()
		if n := len(sub.order); n != 0 {
			t.Errorf("%d file snapshots published for 5 progress calls inside 100 ms, want 0", n)
		}
		sub.mu.Unlock()
	}
	q.mu.Unlock()
	step.proceed <- struct{}{}
	collectUntil(t, fileUpdates, func(f FileSnapshot) bool { return f.State == Finished })
}

func TestSubscribeFilesReplaysEveryFileThenStreamsChanges(t *testing.T) {
	root := tree(t, "d/a", "d/b", "d/c")
	q := New(okRunner(), newFakeClock().Now)
	id, err := q.Enqueue(uploader.Settings{}, req(filepath.Join(root, "d")))
	if err != nil {
		t.Fatal(err)
	}
	initial, updates, cancel, err := q.SubscribeFiles(id)
	if err != nil {
		t.Fatal(err)
	}
	defer cancel()
	if len(initial) != 3 {
		t.Fatalf("initial = %+v", initial)
	}
	for i, f := range initial {
		if f.UploadID != id || f.Index != i || f.State != Queued || f.BytesTotal != 1 {
			t.Errorf("initial[%d] = %+v", i, f)
		}
	}
	if initial[1].RelativePath != "d/b" || initial[1].LocalPath != filepath.Join(root, "d", "b") {
		t.Errorf("initial[1] = %+v", initial[1])
	}
	startRun(t, q)
	finished := map[int]bool{}
	collectUntil(t, updates, func(f FileSnapshot) bool {
		if f.State == Finished {
			finished[f.Index] = true
		}
		return len(finished) == 3
	})
}

func TestSubscribeFilesUnknownUpload(t *testing.T) {
	q := New(okRunner(), newFakeClock().Now)
	if _, _, _, err := q.SubscribeFiles("nope"); !errors.Is(err, ErrUnknownUpload) {
		t.Errorf("err = %v, want ErrUnknownUpload", err)
	}
}

func TestSlowFileSubscriberNeverBlocksAndGetsTerminalStates(t *testing.T) {
	root := tree(t, "d/a", "d/b", "d/c")
	clock := newFakeClock()
	r := runnerFunc(func(_ context.Context, _ uploader.Settings, _ uploader.Request, cb uploader.Callbacks) error {
		cb.KeyResolved("k")
		for i := int64(1); i <= 1000; i++ {
			clock.Advance(time.Second)
			cb.Progress(min(i, 1)) // size is 1 byte; the rest must be ignored
		}
		return nil
	})
	q := New(r, clock.Now)
	id, err := q.Enqueue(uploader.Settings{}, req(filepath.Join(root, "d")))
	if err != nil {
		t.Fatal(err)
	}
	_, slow, cancelSlow, _ := q.SubscribeFiles(id)
	defer cancelSlow()
	_, updates, cancel := q.Subscribe()
	defer cancel()
	startRun(t, q)
	collectUntil(t, updates, isTerminal) // the queue finished without anyone reading slow

	finals := map[int]FileSnapshot{}
	collectUntil(t, slow, func(f FileSnapshot) bool {
		finals[f.Index] = f
		n := 0
		for _, s := range finals {
			if s.State == Finished {
				n++
			}
		}
		return n == 3
	})
}

func TestSettingsPrefixIsUsedForFolderKeys(t *testing.T) {
	root := tree(t, "photos/a.jpg")
	r := runnerFunc(okRunner())
	last, _ := runToEnd(t, r, req(filepath.Join(root, "photos"))) // no resolver: the folder keeps its name
	if last.ObjectKey != "pfx/photos/" {
		t.Errorf("ObjectKey = %q", last.ObjectKey)
	}
}
