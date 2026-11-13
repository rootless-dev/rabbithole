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

// scriptedRunner fails the files whose base name is in fail, records every
// call, and, like the real uploader, fails a file that is no longer on disk.
type scriptedRunner struct {
	mu       sync.Mutex
	fail     map[string]bool
	calls    []string          // base names, in call order
	prefixes map[string]string // last request prefix by base name

	resolveErr   error
	resolveName  string // empty: the folder keeps its own name
	resolveCalls int
}

func newScriptedRunner(failing ...string) *scriptedRunner {
	r := &scriptedRunner{prefixes: map[string]string{}}
	r.setFail(failing...)
	return r
}

func (r *scriptedRunner) setFail(names ...string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.fail = map[string]bool{}
	for _, n := range names {
		r.fail[n] = true
	}
}

func (r *scriptedRunner) Run(_ context.Context, _ uploader.Settings, req uploader.Request, _ uploader.Callbacks) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	name := filepath.Base(req.LocalPath)
	r.calls = append(r.calls, name)
	r.prefixes[name] = req.Prefix
	if _, err := os.Stat(req.LocalPath); err != nil {
		return fmt.Errorf("%w: %v", uploader.ErrFileUnreadable, err)
	}
	if r.fail[name] {
		return errors.New("boom")
	}
	return nil
}

func (r *scriptedRunner) ResolveFolder(_ context.Context, _ uploader.Settings, name string) (string, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.resolveCalls++
	if r.resolveErr != nil {
		return "", r.resolveErr
	}
	if r.resolveName != "" {
		return r.resolveName, nil
	}
	return name, nil
}

func (r *scriptedRunner) count(name string) int {
	r.mu.Lock()
	defer r.mu.Unlock()
	n := 0
	for _, c := range r.calls {
		if c == name {
			n++
		}
	}
	return n
}

// recordingLogger keeps the warnings it receives.
type recordingLogger struct {
	mu    sync.Mutex
	lines []string
}

func (l *recordingLogger) Warn(msg string, kv ...any) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.lines = append(l.lines, fmt.Sprint(append([]any{msg}, kv...)...))
}

func (l *recordingLogger) count() int {
	l.mu.Lock()
	defer l.mu.Unlock()
	return len(l.lines)
}

// spyStore wraps a store, counts what is written to it, and can be made to
// fail every write.
type spyStore struct {
	Store
	mu          sync.Mutex
	creates     int
	createdRows int
	savedFiles  int
	filesReads  int
	failWrites  error
}

func (s *spyStore) CreateUpload(rec UploadRecord, items []ItemRecord, files []FileRecord) error {
	s.mu.Lock()
	s.creates++
	s.createdRows += len(files)
	failure := s.failWrites
	s.mu.Unlock()
	if failure != nil {
		return failure
	}
	return s.Store.CreateUpload(rec, items, files)
}

func (s *spyStore) Save(c Changes) error {
	s.mu.Lock()
	s.savedFiles += len(c.Files)
	failure := s.failWrites
	s.mu.Unlock()
	if failure != nil {
		return failure
	}
	return s.Store.Save(c)
}

func (s *spyStore) Files(id string) ([]FileRecord, error) {
	s.mu.Lock()
	s.filesReads++
	s.mu.Unlock()
	return s.Store.Files(id)
}

func (s *spyStore) stats() (creates, createdRows, savedFiles, filesReads int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.creates, s.createdRows, s.savedFiles, s.filesReads
}

func settingsFor(bucket string) uploader.Settings {
	return uploader.Settings{Bucket: bucket, Region: "us-east-1", Prefix: "pfx/"}
}

// storedQueue returns a queue on store st and runs it until the test ends.
func storedQueue(t *testing.T, st Store, r Runner, log Logger) *Queue {
	t.Helper()
	q := New(r, newFakeClock().Now, WithStore(st, log))
	if err := q.Restore(); err != nil {
		t.Fatal(err)
	}
	return q
}

// filesOf returns the files of an upload as a subscriber sees them.
func filesOf(t *testing.T, q *Queue, id string) []FileSnapshot {
	t.Helper()
	initial, _, cancel, err := q.SubscribeFiles(id)
	if err != nil {
		t.Fatal(err)
	}
	cancel()
	return initial
}

func indexOfFile(t *testing.T, files []FileSnapshot, rel string) int {
	t.Helper()
	for _, f := range files {
		if f.RelativePath == rel {
			return f.Index
		}
	}
	t.Fatalf("no file %q in %+v", rel, files)
	return -1
}

// failedFolder runs a folder upload of the files a, b and c until it ends,
// with b and c failing, and returns the queue, its runner and the upload id.
func failedFolder(t *testing.T) (*Queue, *scriptedRunner, string, <-chan Snapshot) {
	t.Helper()
	root := tree(t, "d/a", "d/b", "d/c")
	r := newScriptedRunner("b", "c")
	q := storedQueue(t, newMemStore(), r, nopLogger{})
	_, updates, cancel := q.Subscribe()
	t.Cleanup(cancel)
	id, err := q.Enqueue(settingsFor("bucket-1"), req(filepath.Join(root, "d")))
	if err != nil {
		t.Fatal(err)
	}
	startRun(t, q)
	last := collectUntil(t, updates, isTerminal)
	if got := last[len(last)-1]; got.State != Failed || got.FilesFailed != 2 || got.FilesFinished != 1 {
		t.Fatalf("first run ended as %+v, want failed with 2 failed and 1 finished", got)
	}
	return q, r, id, updates
}

func TestRetryWithoutIndexesSendsEveryFailedFileAgainAndOnlyThose(t *testing.T) {
	q, r, id, updates := failedFolder(t)
	r.setFail()

	if err := q.Retry(settingsFor("bucket-1"), id, nil); err != nil {
		t.Fatal(err)
	}
	last := collectUntil(t, updates, isTerminal)
	got := last[len(last)-1]

	if got.ID != id || got.State != Finished || got.FilesFinished != 3 || got.FilesFailed != 0 || got.ErrorMessage != "" {
		t.Errorf("after retry = %+v, want the same upload finished with 3 files finished", got)
	}
	if got.BytesSent != got.BytesTotal || got.BytesTotal != 3 {
		t.Errorf("bytes = %d of %d, want 3 of 3", got.BytesSent, got.BytesTotal)
	}
	if r.count("a") != 1 || r.count("b") != 2 || r.count("c") != 2 {
		t.Errorf("calls a/b/c = %d/%d/%d, want 1/2/2: a finished file is not sent again", r.count("a"), r.count("b"), r.count("c"))
	}
	for _, f := range filesOf(t, q, id) {
		if f.State != Finished || f.ErrorMessage != "" || f.BytesSent != f.BytesTotal {
			t.Errorf("file %+v, want finished with nothing left over", f)
		}
	}
}

func TestRetryOfSelectedFilesLeavesTheOthersFailed(t *testing.T) {
	q, r, id, updates := failedFolder(t)
	r.setFail("c") // b would succeed now, c still fails
	b := indexOfFile(t, filesOf(t, q, id), "d/b")

	if err := q.Retry(settingsFor("bucket-1"), id, []int{b}); err != nil {
		t.Fatal(err)
	}
	last := collectUntil(t, updates, isTerminal)
	got := last[len(last)-1]

	if got.State != Failed || got.FilesFinished != 2 || got.FilesFailed != 1 || got.ErrorMessage != "1 of 3 files could not be sent" {
		t.Errorf("after retry = %+v, want failed with 2 finished and 1 failed", got)
	}
	if r.count("b") != 2 || r.count("c") != 1 {
		t.Errorf("calls b/c = %d/%d, want 2/1: only the listed file is sent again", r.count("b"), r.count("c"))
	}
	states := map[string]State{}
	for _, f := range filesOf(t, q, id) {
		states[f.RelativePath] = f.State
	}
	want := map[string]State{"d/a": Finished, "d/b": Finished, "d/c": Failed}
	for rel, st := range want {
		if states[rel] != st {
			t.Errorf("state of %s = %v, want %v", rel, states[rel], st)
		}
	}
}

func TestRetryPutsTheUploadBackAtTheEndOfTheQueueWithItsId(t *testing.T) {
	st := newMemStore()
	first := New(okRunner(), newFakeClock().Now, WithStore(st, nopLogger{}))
	failedID, err := first.Enqueue(settingsFor("bucket-1"), req(writeFile(t, "old.txt", 1)))
	if err != nil {
		t.Fatal(err)
	}
	// The daemon restarts: the stored upload was cut off, so it is failed.
	q := storedQueue(t, st, okRunner(), nopLogger{})
	waitingID, err := q.Enqueue(settingsFor("bucket-1"), req(writeFile(t, "new.txt", 1)))
	if err != nil {
		t.Fatal(err)
	}

	if err := q.Retry(settingsFor("bucket-1"), failedID, nil); err != nil {
		t.Fatal(err)
	}

	q.mu.Lock()
	defer q.mu.Unlock()
	if want := []string{waitingID, failedID}; !slices.Equal(q.waiting, want) {
		t.Errorf("waiting = %v, want %v", q.waiting, want)
	}
	if got := q.uploads[failedID].snap; got.State != Queued || got.ErrorMessage != "" || !got.EndedAt.IsZero() {
		t.Errorf("retried upload = %+v, want queued with no error and not ended", got)
	}
}

func TestRetryRefusals(t *testing.T) {
	q, _, id, _ := failedFolder(t)
	a := indexOfFile(t, filesOf(t, q, id), "d/a")

	finished := writeFile(t, "ok.txt", 1)
	okID, err := q.Enqueue(settingsFor("bucket-1"), req(finished))
	if err != nil {
		t.Fatal(err)
	}
	// Wait until the second upload ends.
	deadline := time.Now().Add(guard)
	for time.Now().Before(deadline) {
		q.mu.Lock()
		done := q.uploads[okID].snap.State == Finished
		q.mu.Unlock()
		if done {
			break
		}
		time.Sleep(5 * time.Millisecond)
	}

	tests := []struct {
		name    string
		bucket  string
		id      string
		indexes []int
		want    error
	}{
		{"unknown upload", "bucket-1", "nope", nil, ErrUnknownUpload},
		{"upload that did not fail", "bucket-1", okID, nil, ErrUploadNotFailed},
		{"file that did not fail", "bucket-1", id, []int{a}, ErrFileNotFailed},
		{"file index that does not exist", "bucket-1", id, []int{99}, ErrUnknownFile},
		{"negative file index", "bucket-1", id, []int{-1}, ErrUnknownFile},
		{"upload of another bucket", "bucket-2", id, nil, ErrOtherBucket},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := q.Retry(settingsFor(tt.bucket), tt.id, tt.indexes)
			if !errors.Is(err, tt.want) {
				t.Fatalf("Retry = %v, want %v", err, tt.want)
			}
		})
	}

	q.mu.Lock()
	snap := q.uploads[id].snap
	q.mu.Unlock()
	if snap.State != Failed || snap.FilesFailed != 2 {
		t.Errorf("after refused retries = %+v, want the upload untouched", snap)
	}
}

func TestRetryKeepsAResolvedFolderAndResolvesAnUnresolvedOne(t *testing.T) {
	root := tree(t, "d/a")
	r := newScriptedRunner("a")
	r.resolveName = "d-resolved"
	q := storedQueue(t, newMemStore(), r, nopLogger{})
	_, updates, cancel := q.Subscribe()
	defer cancel()
	id, err := q.Enqueue(settingsFor("bucket-1"), req(filepath.Join(root, "d")))
	if err != nil {
		t.Fatal(err)
	}
	startRun(t, q)
	collectUntil(t, updates, isTerminal)

	r.setFail()
	r.resolveName = "must-not-be-used"
	if err := q.Retry(settingsFor("bucket-1"), id, nil); err != nil {
		t.Fatal(err)
	}
	collectUntil(t, updates, isTerminal)

	r.mu.Lock()
	calls, prefix := r.resolveCalls, r.prefixes["a"]
	r.mu.Unlock()
	if calls != 1 || prefix != "pfx/d-resolved/" {
		t.Errorf("resolve calls = %d, prefix = %q, want 1 and %q: the resolved folder is kept", calls, prefix, "pfx/d-resolved/")
	}
}

func TestRetryResolvesAFolderThatNeverWas(t *testing.T) {
	root := tree(t, "d/a")
	r := newScriptedRunner()
	r.resolveErr = errors.New("listing failed")
	q := storedQueue(t, newMemStore(), r, nopLogger{})
	_, updates, cancel := q.Subscribe()
	defer cancel()
	id, err := q.Enqueue(settingsFor("bucket-1"), req(filepath.Join(root, "d")))
	if err != nil {
		t.Fatal(err)
	}
	startRun(t, q)
	collectUntil(t, updates, isTerminal)

	r.mu.Lock()
	r.resolveErr, r.resolveName = nil, "d-2"
	r.mu.Unlock()
	if err := q.Retry(settingsFor("bucket-1"), id, nil); err != nil {
		t.Fatal(err)
	}
	last := collectUntil(t, updates, isTerminal)

	r.mu.Lock()
	calls, prefix := r.resolveCalls, r.prefixes["a"]
	r.mu.Unlock()
	if got := last[len(last)-1]; got.State != Finished || calls != 2 || prefix != "pfx/d-2/" {
		t.Errorf("state = %v, resolve calls = %d, prefix = %q, want finished, 2 and %q", got.State, calls, prefix, "pfx/d-2/")
	}
}

func TestRetryOfAFileThatDisappearedFailsAgainAsUnreadable(t *testing.T) {
	root := tree(t, "d/a", "d/b")
	r := newScriptedRunner("b")
	q := storedQueue(t, newMemStore(), r, nopLogger{})
	_, updates, cancel := q.Subscribe()
	defer cancel()
	id, err := q.Enqueue(settingsFor("bucket-1"), req(filepath.Join(root, "d")))
	if err != nil {
		t.Fatal(err)
	}
	startRun(t, q)
	collectUntil(t, updates, isTerminal)

	if err := os.Remove(filepath.Join(root, "d", "b")); err != nil {
		t.Fatal(err)
	}
	if err := q.Retry(settingsFor("bucket-1"), id, nil); err != nil {
		t.Fatal(err)
	}
	last := collectUntil(t, updates, isTerminal)

	if got := last[len(last)-1]; got.State != Failed || got.FilesFailed != 1 {
		t.Errorf("after retry = %+v, want failed with 1 failed file", got)
	}
	b := filesOf(t, q, id)[indexOfFile(t, filesOf(t, q, id), "d/b")]
	if want := uploader.Message(uploader.ErrFileUnreadable); b.State != Failed || b.ErrorMessage != want {
		t.Errorf("file b = %+v, want failed with %q", b, want)
	}
}

func TestUploadsCutOffByARestartFailAsInterruptedAndCanBeRetried(t *testing.T) {
	root := tree(t, "d/a", "d/b", "d/c")
	st := newMemStore()

	// First life of the daemon: the upload is stored, then the process dies.
	first := New(newScriptedRunner(), newFakeClock().Now, WithStore(st, nopLogger{}))
	id, err := first.Enqueue(settingsFor("bucket-1"), req(filepath.Join(root, "d")))
	if err != nil {
		t.Fatal(err)
	}
	// One file had already finished, one was in the middle of its upload.
	recs, _ := st.Uploads()
	files, _ := st.Files(id)
	recs[0].Snapshot.State, recs[0].Snapshot.FilesFinished = Uploading, 1
	files[0].Snapshot.State, files[0].Snapshot.BytesSent = Finished, 1
	files[1].Snapshot.State = Uploading
	if err := st.Save(Changes{Uploads: recs, Files: files}); err != nil {
		t.Fatal(err)
	}

	// Second life.
	clock := newFakeClock()
	r := newScriptedRunner()
	q := New(r, clock.Now, WithStore(st, nopLogger{}))
	if err := q.Restore(); err != nil {
		t.Fatal(err)
	}
	initial, updates, cancel := q.Subscribe()
	defer cancel()

	if len(initial) != 1 {
		t.Fatalf("replayed %d uploads, want 1", len(initial))
	}
	if got := initial[0]; got.ID != id || got.State != Failed || got.ErrorMessage != "Upload interrupted" || !got.EndedAt.Equal(clock.Now()) {
		t.Errorf("restored upload = %+v, want failed with %q, ended now", got, "Upload interrupted")
	}
	wantStates := map[string]State{"d/a": Finished, "d/b": Failed, "d/c": Failed}
	for _, f := range filesOf(t, q, id) {
		if f.State != wantStates[f.RelativePath] {
			t.Errorf("file %s = %v, want %v", f.RelativePath, f.State, wantStates[f.RelativePath])
		}
		if f.State == Failed && f.ErrorMessage != "Upload interrupted" {
			t.Errorf("file %s message = %q, want %q", f.RelativePath, f.ErrorMessage, "Upload interrupted")
		}
		if f.State == Finished && f.ErrorMessage != "" {
			t.Errorf("finished file %s has message %q", f.RelativePath, f.ErrorMessage)
		}
	}

	startRun(t, q)
	if err := q.Retry(settingsFor("bucket-1"), id, nil); err != nil {
		t.Fatal(err)
	}
	last := collectUntil(t, updates, isTerminal)
	if got := last[len(last)-1]; got.State != Finished || got.FilesFinished != 3 {
		t.Errorf("after retry = %+v, want finished with 3 files", got)
	}
	if r.count("a") != 0 || r.count("b") != 1 || r.count("c") != 1 {
		t.Errorf("calls a/b/c = %d/%d/%d, want 0/1/1", r.count("a"), r.count("b"), r.count("c"))
	}
}

func TestReplayShowsOnlyUploadsOfTheCurrentBucketOldestFirst(t *testing.T) {
	st := newMemStore()
	q := storedQueue(t, st, newScriptedRunner(), nopLogger{})
	var ids = map[string]string{}
	for _, c := range []struct{ name, bucket string }{{"1", "A"}, {"2", "B"}, {"3", "A"}} {
		id, err := q.Enqueue(settingsFor(c.bucket), req(writeFile(t, c.name+".txt", 1)))
		if err != nil {
			t.Fatal(err)
		}
		ids[c.name] = id
	}

	if initial, _, cancel := q.Subscribe(); len(initial) != 3 {
		t.Errorf("before SetBucket %d uploads replayed, want all 3", len(initial))
		cancel()
	} else {
		cancel()
	}

	q.SetBucket("A")
	initial, _, cancel := q.Subscribe()
	defer cancel()
	var got []string
	for _, s := range initial {
		got = append(got, s.ID)
	}
	if want := []string{ids["1"], ids["3"]}; !slices.Equal(got, want) {
		t.Errorf("replayed %v, want %v", got, want)
	}

	// A restarted daemon replays the same.
	again := storedQueue(t, st, newScriptedRunner(), nopLogger{})
	again.SetBucket("B")
	initial2, _, cancel2 := again.Subscribe()
	defer cancel2()
	if len(initial2) != 1 || initial2[0].ID != ids["2"] {
		t.Errorf("after restart replayed %+v, want only upload 2", initial2)
	}
}

func TestChangingTheBucketRemovesTheOldUploadsThenShowsTheNewOnes(t *testing.T) {
	q := storedQueue(t, newMemStore(), newScriptedRunner(), nopLogger{})
	var a1, a2, b1 string
	for _, c := range []struct {
		dst    *string
		bucket string
	}{{&a1, "A"}, {&b1, "B"}, {&a2, "A"}} {
		id, err := q.Enqueue(settingsFor(c.bucket), req(writeFile(t, "f.txt", 1)))
		if err != nil {
			t.Fatal(err)
		}
		*c.dst = id
	}
	q.SetBucket("A")
	_, updates, cancel := q.Subscribe()
	defer cancel()

	q.SetBucket("B")
	var got []string
	for range 3 {
		select {
		case s := <-updates:
			got = append(got, fmt.Sprintf("%s removed=%v", s.ID, s.Removed))
		case <-time.After(guard):
			t.Fatalf("timed out; got %v", got)
		}
	}
	want := []string{a1 + " removed=true", a2 + " removed=true", b1 + " removed=false"}
	if !slices.Equal(got, want) {
		t.Errorf("snapshots = %v, want %v", got, want)
	}

	q.SetBucket("B") // same bucket: nothing to say
	select {
	case s := <-updates:
		t.Errorf("unexpected snapshot %+v after setting the same bucket", s)
	case <-time.After(50 * time.Millisecond):
	}
}

func TestProgressOfAnUploadOfAnotherBucketIsNotPublished(t *testing.T) {
	q := storedQueue(t, newMemStore(), okRunner(), nopLogger{})
	q.SetBucket("B")
	_, updates, cancel := q.Subscribe()
	defer cancel()
	if _, err := q.Enqueue(settingsFor("A"), req(writeFile(t, "f.txt", 1))); err != nil {
		t.Fatal(err)
	}
	startRun(t, q)
	select {
	case s := <-updates:
		t.Errorf("a subscriber of bucket B saw %+v of an upload to bucket A", s)
	case <-time.After(200 * time.Millisecond):
	}
}

func TestFilesAreReadFromTheStoreOnceTheUploadEnded(t *testing.T) {
	root := tree(t, "d/a", "d/b")
	spy := &spyStore{Store: newMemStore()}
	r := newScriptedRunner("b")
	q := storedQueue(t, spy, r, nopLogger{})
	_, updates, cancel := q.Subscribe()
	defer cancel()
	id, err := q.Enqueue(settingsFor("bucket-1"), req(filepath.Join(root, "d")))
	if err != nil {
		t.Fatal(err)
	}
	startRun(t, q)
	collectUntil(t, updates, isTerminal)

	q.mu.Lock()
	inMemory := q.uploads[id].files
	q.mu.Unlock()
	if inMemory != nil {
		t.Errorf("%d file states still in memory after the upload ended", len(inMemory))
	}

	files := filesOf(t, q, id)
	if len(files) != 2 || files[0].State != Finished || files[1].State != Failed || files[1].ErrorMessage != "Upload failed" {
		t.Errorf("files = %+v, want a finished and a failed one with its message", files)
	}
	if _, _, _, reads := spy.stats(); reads == 0 {
		t.Error("the files were not read from the store")
	}
}

func TestFilesOfARunningUploadAreKeptInMemory(t *testing.T) {
	release := make(chan struct{})
	started := make(chan struct{})
	r := runnerFunc(func(ctx context.Context, _ uploader.Settings, _ uploader.Request, _ uploader.Callbacks) error {
		close(started)
		select {
		case <-release:
		case <-ctx.Done():
		}
		return nil
	})
	spy := &spyStore{Store: newMemStore()}
	q := storedQueue(t, spy, r, nopLogger{})
	id, err := q.Enqueue(settingsFor("bucket-1"), req(writeFile(t, "f.txt", 1)))
	if err != nil {
		t.Fatal(err)
	}
	startRun(t, q)
	<-started

	if files := filesOf(t, q, id); len(files) != 1 || files[0].State != Uploading {
		t.Errorf("files = %+v, want the one running file", files)
	}
	if _, _, _, reads := spy.stats(); reads != 0 {
		t.Errorf("%d reads of the store, want none for a running upload", reads)
	}
	close(release)
}

func TestInitialInsertIsOneBatchAndProgressIsNotWritten(t *testing.T) {
	names := make([]string, 300)
	for i := range names {
		names[i] = fmt.Sprintf("d/f%03d", i)
	}
	root := tree(t, names...)
	spy := &spyStore{Store: newMemStore()}
	q := storedQueue(t, spy, okRunner(), nopLogger{})
	_, updates, cancel := q.Subscribe()
	defer cancel()
	if _, err := q.Enqueue(settingsFor("bucket-1"), req(filepath.Join(root, "d"))); err != nil {
		t.Fatal(err)
	}
	if creates, rows, _, _ := spy.stats(); creates != 1 || rows != 300 {
		t.Errorf("creates = %d with %d files, want one call with 300", creates, rows)
	}
	startRun(t, q)
	collectUntil(t, updates, isTerminal)

	// Each file is written once, when it ends: progress callbacks write nothing.
	q.journal.flush()
	if _, _, saved, _ := spy.stats(); saved != 300 {
		t.Errorf("%d file rows saved, want exactly 300 (one per file, none for progress)", saved)
	}
}

func TestProgressCallbacksWriteNothing(t *testing.T) {
	r := runnerFunc(func(_ context.Context, _ uploader.Settings, _ uploader.Request, cb uploader.Callbacks) error {
		for i := int64(1); i <= 400; i++ {
			cb.Progress(i)
		}
		return nil
	})
	spy := &spyStore{Store: newMemStore()}
	q := storedQueue(t, spy, r, nopLogger{})
	_, updates, cancel := q.Subscribe()
	defer cancel()
	if _, err := q.Enqueue(settingsFor("bucket-1"), req(writeFile(t, "big.bin", 500))); err != nil {
		t.Fatal(err)
	}
	startRun(t, q)
	collectUntil(t, updates, isTerminal)
	q.journal.flush()
	if _, _, saved, _ := spy.stats(); saved != 1 {
		t.Errorf("%d file rows saved, want 1: only the end of the file is written", saved)
	}
}

func TestAFailedWriteIsLoggedAndTheUploadGoesOn(t *testing.T) {
	spy := &spyStore{Store: newMemStore(), failWrites: errors.New("disk full")}
	log := &recordingLogger{}
	q := storedQueue(t, spy, okRunner(), log)
	_, updates, cancel := q.Subscribe()
	defer cancel()
	if _, err := q.Enqueue(settingsFor("bucket-1"), req(writeFile(t, "f.txt", 1))); err != nil {
		t.Fatal(err)
	}
	startRun(t, q)
	last := collectUntil(t, updates, isTerminal)

	if got := last[len(last)-1]; got.State != Finished {
		t.Errorf("state = %v, want finished despite the failed writes", got.State)
	}
	if log.count() == 0 {
		t.Error("no warning logged for the failed writes")
	}
}

func TestDiscardRemovesAnEndedUploadAndTellsSubscribers(t *testing.T) {
	q, _, id, updates := failedFolder(t)

	if err := q.Discard(id); err != nil {
		t.Fatal(err)
	}
	got := collectUntil(t, updates, func(s Snapshot) bool { return s.Removed })
	if last := got[len(got)-1]; last.ID != id || !last.Removed {
		t.Errorf("last snapshot = %+v, want the removed upload", last)
	}
	if _, _, cancel, err := q.SubscribeFiles(id); !errors.Is(err, ErrUnknownUpload) {
		if cancel != nil {
			cancel()
		}
		t.Errorf("SubscribeFiles after discard = %v, want ErrUnknownUpload", err)
	}
	if err := q.Discard(id); !errors.Is(err, ErrUnknownUpload) {
		t.Errorf("second Discard = %v, want ErrUnknownUpload", err)
	}
}
