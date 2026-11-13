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

// keyedRunner is a scriptedRunner that, like the real uploader, reports the key
// of each file it sends: the request prefix followed by the file name.
type keyedRunner struct{ *scriptedRunner }

func (r keyedRunner) Run(ctx context.Context, s uploader.Settings, req uploader.Request, cb uploader.Callbacks) error {
	err := r.scriptedRunner.Run(ctx, s, req, cb)
	if err == nil && cb.KeyResolved != nil {
		cb.KeyResolved(req.Prefix + filepath.Base(req.LocalPath))
	}
	return err
}

// deleteSpy is a DeleteFunc that records its calls. failAfter, when positive,
// makes it delete only that many keys of a call and then fail.
type deleteSpy struct {
	mu        sync.Mutex
	calls     [][]string
	failAfter int
	err       error
}

func (d *deleteSpy) del(_ context.Context, keys []string) ([]string, error) {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.calls = append(d.calls, slices.Clone(keys))
	if d.err != nil {
		return keys[:min(d.failAfter, len(keys))], d.err
	}
	return keys, nil
}

// endedUpload is a folder upload d/{a,b,c} that ran to the end under bucket-1.
type endedUpload struct {
	q       *Queue
	store   *memStore
	id      string
	updates <-chan Snapshot
	index   map[string]int // file index by name
}

// endFolder runs the folder to the end, with the named files failing.
func endFolder(t *testing.T, failing ...string) *endedUpload {
	t.Helper()
	root := tree(t, "d/a", "d/b", "d/c")
	st := newMemStore()
	q := storedQueue(t, st, keyedRunner{newScriptedRunner(failing...)}, nopLogger{})
	_, updates, cancel := q.Subscribe()
	t.Cleanup(cancel)
	id, err := q.Enqueue(settingsFor("bucket-1"), req(filepath.Join(root, "d")))
	if err != nil {
		t.Fatal(err)
	}
	startRun(t, q)
	collectUntil(t, updates, isTerminal)

	e := &endedUpload{q: q, store: st, id: id, updates: updates, index: map[string]int{}}
	for _, f := range filesOf(t, q, id) {
		e.index[filepath.Base(f.LocalPath)] = f.Index
	}
	return e
}

func (e *endedUpload) indexes(names ...string) []int {
	out := make([]int, len(names))
	for i, n := range names {
		out[i] = e.index[n]
	}
	return out
}

// snapshot returns the upload as a new subscriber sees it, or false when gone.
func (e *endedUpload) snapshot(t *testing.T) (Snapshot, bool) {
	t.Helper()
	initial, _, cancel := e.q.Subscribe()
	cancel()
	for _, s := range initial {
		if s.ID == e.id {
			return s, true
		}
	}
	return Snapshot{}, false
}

func (e *endedUpload) fileNames(t *testing.T) []string {
	t.Helper()
	var names []string
	for _, f := range filesOf(t, e.q, e.id) {
		names = append(names, filepath.Base(f.LocalPath))
	}
	return names
}

func TestRemoveWholeUploadWithoutDeletingFromTheBucketCallsNothing(t *testing.T) {
	e := endFolder(t)

	if err := e.q.Remove(context.Background(), "bucket-1", e.id, nil, nil); err != nil {
		t.Fatal(err)
	}

	got := collectUntil(t, e.updates, func(s Snapshot) bool { return s.Removed })
	if last := got[len(got)-1]; last.ID != e.id || !last.Removed {
		t.Fatalf("last snapshot = %+v, want the removed upload", last)
	}
	if _, ok := e.snapshot(t); ok {
		t.Fatal("upload still listed")
	}
	if recs, _ := e.store.Uploads(); len(recs) != 0 {
		t.Fatalf("store still holds %d uploads", len(recs))
	}
}

func TestRemoveWholeUploadDeletesTheExactKeysOfItsFinishedFiles(t *testing.T) {
	e := endFolder(t, "c")
	spy := &deleteSpy{}

	if err := e.q.Remove(context.Background(), "bucket-1", e.id, nil, spy.del); err != nil {
		t.Fatal(err)
	}

	if len(spy.calls) != 1 {
		t.Fatalf("delete calls = %d, want 1", len(spy.calls))
	}
	// The failed file has no object; the finished ones sit under the folder's own prefix.
	slices.Sort(spy.calls[0])
	if want := []string{"pfx/d/a", "pfx/d/b"}; !slices.Equal(spy.calls[0], want) {
		t.Fatalf("keys deleted = %v, want %v", spy.calls[0], want)
	}
	if _, ok := e.snapshot(t); ok {
		t.Fatal("upload still listed")
	}
}

func TestRemoveSelectedFilesRecountsTheUploadAndTellsSubscribers(t *testing.T) {
	e := endFolder(t, "b", "c")
	_, fileUpdates, cancel, err := e.q.SubscribeFiles(e.id)
	if err != nil {
		t.Fatal(err)
	}
	defer cancel()
	spy := &deleteSpy{}

	if err := e.q.Remove(context.Background(), "bucket-1", e.id, e.indexes("a"), spy.del); err != nil {
		t.Fatal(err)
	}

	if len(spy.calls) != 1 || !slices.Equal(spy.calls[0], []string{"pfx/d/a"}) {
		t.Fatalf("delete calls = %v, want one call with pfx/d/a", spy.calls)
	}
	snap, ok := e.snapshot(t)
	if !ok || snap.FilesTotal != 2 || snap.FilesFinished != 0 || snap.FilesFailed != 2 || snap.BytesTotal != 2 ||
		snap.State != Failed || snap.ErrorMessage != "2 of 2 files could not be sent" || snap.Removed {
		t.Fatalf("upload after removal = %+v", snap)
	}
	if names := e.fileNames(t); !slices.Equal(names, []string{"b", "c"}) {
		t.Fatalf("files left = %v, want [b c]", names)
	}
	got := collectUntil(t, fileUpdates, func(f FileSnapshot) bool { return f.Removed })
	if last := got[len(got)-1]; last.Index != e.index["a"] || last.UploadID != e.id {
		t.Fatalf("removed file snapshot = %+v, want file a", last)
	}
	publishedAfter := collectUntil(t, e.updates, func(s Snapshot) bool { return s.FilesTotal == 2 })
	if last := publishedAfter[len(publishedAfter)-1]; last.Removed || last.ID != e.id {
		t.Fatalf("published %+v, want a normal snapshot of the upload", last)
	}
}

func TestRemovingTheOnlyFailedFilesMakesTheUploadFinished(t *testing.T) {
	e := endFolder(t, "b", "c")

	if err := e.q.Remove(context.Background(), "bucket-1", e.id, e.indexes("b", "c"), nil); err != nil {
		t.Fatal(err)
	}

	snap, ok := e.snapshot(t)
	if !ok || snap.State != Finished || snap.ErrorMessage != "" || snap.FilesTotal != 1 || snap.FilesFinished != 1 ||
		snap.FilesFailed != 0 || snap.BytesTotal != 1 || snap.BytesSent != 1 {
		t.Fatalf("upload after removal = %+v, want finished with the one file left", snap)
	}
}

func TestRemovingEveryFileRemovesTheUpload(t *testing.T) {
	e := endFolder(t)

	if err := e.q.Remove(context.Background(), "bucket-1", e.id, e.indexes("a", "b", "c"), nil); err != nil {
		t.Fatal(err)
	}

	if _, ok := e.snapshot(t); ok {
		t.Fatal("upload still listed")
	}
	if recs, _ := e.store.Uploads(); len(recs) != 0 {
		t.Fatalf("store still holds %d uploads", len(recs))
	}
}

func TestRemovalIsStoredAndSurvivesARestart(t *testing.T) {
	e := endFolder(t, "c")
	if err := e.q.Remove(context.Background(), "bucket-1", e.id, e.indexes("a"), nil); err != nil {
		t.Fatal(err)
	}

	q2 := storedQueue(t, e.store, newScriptedRunner(), nopLogger{})
	q2.SetBucket("bucket-1")
	initial, _, cancel := q2.Subscribe()
	cancel()

	if len(initial) != 1 || initial[0].FilesTotal != 2 || initial[0].FilesFinished != 1 || initial[0].FilesFailed != 1 {
		t.Fatalf("restored uploads = %+v, want one with 2 files", initial)
	}
	files := filesOf(t, q2, e.id)
	if len(files) != 2 || files[0].Index != e.index["b"] {
		t.Fatalf("restored files = %+v, want b and c under their own indexes", files)
	}
}

func TestRemoveBySecondIndexAfterAFirstRemovalUsesIndexesNotPositions(t *testing.T) {
	e := endFolder(t)
	if err := e.q.Remove(context.Background(), "bucket-1", e.id, e.indexes("a"), nil); err != nil {
		t.Fatal(err)
	}

	spy := &deleteSpy{}
	if err := e.q.Remove(context.Background(), "bucket-1", e.id, e.indexes("c"), spy.del); err != nil {
		t.Fatal(err)
	}

	if len(spy.calls) != 1 || !slices.Equal(spy.calls[0], []string{"pfx/d/c"}) {
		t.Fatalf("delete calls = %v, want only pfx/d/c", spy.calls)
	}
	if names := e.fileNames(t); !slices.Equal(names, []string{"b"}) {
		t.Fatalf("files left = %v, want [b]", names)
	}
}

func TestPartialDeleteForgetsOnlyTheFilesWhoseObjectsAreGone(t *testing.T) {
	e := endFolder(t)
	boom := errors.New("denied")
	spy := &deleteSpy{failAfter: 1, err: boom}

	err := e.q.Remove(context.Background(), "bucket-1", e.id, nil, spy.del)

	if !errors.Is(err, boom) {
		t.Fatalf("err = %v, want the delete error", err)
	}
	snap, ok := e.snapshot(t)
	if !ok || snap.FilesTotal != 2 || snap.State != Finished {
		t.Fatalf("upload after a partial delete = %+v, want 2 files left", snap)
	}
	if names := e.fileNames(t); len(names) != 2 || slices.Contains(names, filepath.Base(spy.calls[0][0])) {
		t.Fatalf("files left = %v; the file deleted first (%s) must be gone", names, spy.calls[0][0])
	}
}

func TestFailedDeleteKeepsFilesThatHaveNoObjectToo(t *testing.T) {
	e := endFolder(t, "c")
	spy := &deleteSpy{err: errors.New("no network")}

	if err := e.q.Remove(context.Background(), "bucket-1", e.id, nil, spy.del); err == nil {
		t.Fatal("expected the delete error")
	}

	if snap, _ := e.snapshot(t); snap.FilesTotal != 3 {
		t.Fatalf("files = %d, want all 3 kept", snap.FilesTotal)
	}
}

func TestRemoveRefusals(t *testing.T) {
	e := endFolder(t)

	tests := []struct {
		name    string
		bucket  string
		id      string
		indexes []int
		want    error
	}{
		{"unknown upload", "bucket-1", "nope", nil, ErrUnknownUpload},
		{"unknown file", "bucket-1", e.id, []int{99}, ErrUnknownFile},
		{"other bucket", "bucket-2", e.id, nil, ErrOtherBucket},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			spy := &deleteSpy{}
			err := e.q.Remove(context.Background(), tt.bucket, tt.id, tt.indexes, spy.del)
			if !errors.Is(err, tt.want) {
				t.Fatalf("err = %v, want %v", err, tt.want)
			}
			if len(spy.calls) != 0 {
				t.Fatal("a refused removal must not delete anything")
			}
		})
	}
}

func TestRemoveRefusesAQueuedUpload(t *testing.T) {
	q := storedQueue(t, newMemStore(), okRunner(), nopLogger{})
	id, err := q.Enqueue(settingsFor("bucket-1"), req(writeFile(t, "q.txt", 1)))
	if err != nil {
		t.Fatal(err)
	}
	spy := &deleteSpy{}

	if err := q.Remove(context.Background(), "bucket-1", id, nil, spy.del); !errors.Is(err, ErrUploadActive) {
		t.Fatalf("err = %v, want ErrUploadActive", err)
	}
	if len(spy.calls) != 0 {
		t.Fatal("a refused removal must not delete anything")
	}
}

func TestRemoveRefusesARunningUpload(t *testing.T) {
	started, release := make(chan struct{}), make(chan struct{})
	q := storedQueue(t, newMemStore(), runnerFunc(func(context.Context, uploader.Settings, uploader.Request, uploader.Callbacks) error {
		close(started)
		<-release
		return nil
	}), nopLogger{})
	id, err := q.Enqueue(settingsFor("bucket-1"), req(writeFile(t, "r.txt", 1)))
	if err != nil {
		t.Fatal(err)
	}
	startRun(t, q)
	<-started
	defer close(release)

	if err := q.Remove(context.Background(), "bucket-1", id, nil, nil); !errors.Is(err, ErrUploadActive) {
		t.Fatalf("err = %v, want ErrUploadActive", err)
	}
}

func TestUploadBeingRemovedCannotBeRetriedOrRemovedAgain(t *testing.T) {
	e := endFolder(t, "c")
	inDelete, release := make(chan struct{}), make(chan struct{})
	done := make(chan error, 1)
	go func() {
		done <- e.q.Remove(context.Background(), "bucket-1", e.id, nil, func(_ context.Context, keys []string) ([]string, error) {
			close(inDelete)
			<-release
			return keys, nil
		})
	}()
	<-inDelete

	if err := e.q.Retry(settingsFor("bucket-1"), e.id, nil); !errors.Is(err, ErrUploadActive) {
		t.Errorf("Retry during a removal = %v, want ErrUploadActive", err)
	}
	if err := e.q.Remove(context.Background(), "bucket-1", e.id, nil, nil); !errors.Is(err, ErrUploadActive) {
		t.Errorf("second Remove during a removal = %v, want ErrUploadActive", err)
	}
	if files, err := e.q.FinishedFiles("bucket-1"); err != nil || len(files) != 0 {
		t.Errorf("FinishedFiles during a removal = %v, %v; want nothing", files, err)
	}
	close(release)
	if err := <-done; err != nil {
		t.Fatal(err)
	}
}

func TestOnEndedIsCalledOncePerUploadThatEnds(t *testing.T) {
	ended := make(chan struct{}, 4)
	q := New(okRunner(), newFakeClock().Now, WithOnEnded(func() { ended <- struct{}{} }))
	for range 2 {
		if _, err := q.Enqueue(settingsFor("b"), req(writeFile(t, "f.txt", 1))); err != nil {
			t.Fatal(err)
		}
	}
	startRun(t, q)

	for range 2 {
		select {
		case <-ended:
		case <-time.After(guard):
			t.Fatal("the hook was not called for an upload that ended")
		}
	}
	select {
	case <-ended:
		t.Fatal("the hook was called more than once per upload")
	case <-time.After(50 * time.Millisecond):
	}
}

func TestFinishedFilesListsOnlyFinishedFilesOfUploadsAtRest(t *testing.T) {
	e := endFolder(t, "c")

	files, err := e.q.FinishedFiles("bucket-1")
	if err != nil {
		t.Fatal(err)
	}

	got := map[string]string{}
	for _, f := range files {
		got[f.ObjectKey] = f.Inner
	}
	if len(got) != 2 || got["pfx/d/a"] != "a" || got["pfx/d/b"] != "b" {
		t.Fatalf("finished files = %+v, want a and b with their inner paths", files)
	}
	if other, _ := e.q.FinishedFiles("bucket-2"); len(other) != 0 {
		t.Fatalf("another bucket's files = %+v, want none", other)
	}
}

func TestForgetMissingRemovesOnlyTheNamedFinishedFilesAndRecounts(t *testing.T) {
	e := endFolder(t, "c")
	files, _ := e.q.FinishedFiles("bucket-1")
	var gone []FinishedFile
	for _, f := range files {
		if f.ObjectKey == "pfx/d/a" {
			gone = append(gone, f)
		}
	}

	n, err := e.q.ForgetMissing("bucket-1", gone)

	if err != nil || n != 1 {
		t.Fatalf("removed %d, err %v; want 1", n, err)
	}
	snap, _ := e.snapshot(t)
	if snap.FilesTotal != 2 || snap.FilesFinished != 1 || snap.FilesFailed != 1 || snap.State != Failed {
		t.Fatalf("upload after = %+v", snap)
	}
	if names := e.fileNames(t); !slices.Equal(names, []string{"b", "c"}) {
		t.Fatalf("files left = %v", names)
	}
}

func TestForgetMissingIgnoresAFileWhoseKeyChanged(t *testing.T) {
	e := endFolder(t)
	stale := FinishedFile{UploadID: e.id, Index: e.index["a"], ObjectKey: "pfx/d/other"}

	if n, err := e.q.ForgetMissing("bucket-1", []FinishedFile{stale}); err != nil || n != 0 {
		t.Fatalf("removed %d, err %v; want nothing", n, err)
	}
}

func TestForgetMissingLeavesAnUploadOfAnotherBucketAlone(t *testing.T) {
	e := endFolder(t)
	files, _ := e.q.FinishedFiles("bucket-1")

	if n, err := e.q.ForgetMissing("bucket-2", files); err != nil || n != 0 {
		t.Fatalf("removed %d, err %v; want nothing", n, err)
	}
}

func TestForgetMissingRemovesAnUploadThatLosesItsLastFile(t *testing.T) {
	e := endFolder(t)
	files, _ := e.q.FinishedFiles("bucket-1")

	n, err := e.q.ForgetMissing("bucket-1", files)

	if err != nil || n != 3 {
		t.Fatalf("removed %d, err %v; want 3", n, err)
	}
	if _, ok := e.snapshot(t); ok {
		t.Fatal("upload still listed")
	}
}

func TestForgetMissingSkipsAnUploadThatWasQueuedAgainMeanwhile(t *testing.T) {
	e := endFolder(t, "c")
	files, _ := e.q.FinishedFiles("bucket-1")
	// A retry puts the upload back in the queue before the removal arrives. The
	// runner is held so the upload stays running.
	hold := make(chan struct{})
	defer close(hold)
	e.q.runner = runnerFunc(func(ctx context.Context, _ uploader.Settings, _ uploader.Request, _ uploader.Callbacks) error {
		select {
		case <-hold:
		case <-ctx.Done():
		}
		return nil
	})
	if err := e.q.Retry(settingsFor("bucket-1"), e.id, nil); err != nil {
		t.Fatal(err)
	}

	if n, err := e.q.ForgetMissing("bucket-1", files); err != nil || n != 0 {
		t.Fatalf("removed %d, err %v; want nothing from an upload that is not at rest", n, err)
	}
}
