package reconcile

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"rabbithole/daemon/internal/logging"
	"rabbithole/daemon/internal/queue"
	"rabbithole/daemon/internal/uploader"
)

const (
	wait       = 5 * time.Second
	testBucket = "bucket-1"
	testPrefix = "pfx/"
	secretText = "SECRET-MARKER-reconcile"
)

// fakeBucket is the bucket the uploads go to and the listings read from.
type fakeBucket struct {
	mu       sync.Mutex
	keys     map[string]bool
	listed   []string // prefixes, in the order they were listed
	listErr  error    // fails every listing
	partial  bool     // with listErr: visit the keys first, as a listing cut short would
	onList   func(prefix string)
	failName map[string]bool // base names the runner fails to send
	holdName string          // base name whose upload blocks until release is closed
	release  chan struct{}
}

func newBucket() *fakeBucket {
	return &fakeBucket{keys: map[string]bool{}, failName: map[string]bool{}}
}

func (b *fakeBucket) Run(ctx context.Context, _ uploader.Settings, req uploader.Request, cb uploader.Callbacks) error {
	name := filepath.Base(req.LocalPath)
	if name == b.holdName {
		select {
		case <-b.release:
		case <-ctx.Done():
			return ctx.Err()
		}
	}
	if b.failName[name] {
		return errors.New("boom")
	}
	key := req.Prefix + name
	b.mu.Lock()
	b.keys[key] = true
	b.mu.Unlock()
	cb.KeyResolved(key)
	return nil
}

func (b *fakeBucket) remove(keys ...string) {
	b.mu.Lock()
	defer b.mu.Unlock()
	for _, k := range keys {
		delete(b.keys, k)
	}
}

func (b *fakeBucket) put(keys ...string) {
	b.mu.Lock()
	defer b.mu.Unlock()
	for _, k := range keys {
		b.keys[k] = true
	}
}

func (b *fakeBucket) listings() []string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return slices.Clone(b.listed)
}

func (b *fakeBucket) ListKeys(_ context.Context, _ uploader.Settings, prefix string, visit func(string)) error {
	b.mu.Lock()
	b.listed = append(b.listed, prefix)
	hook, failure, partial := b.onList, b.listErr, b.partial
	var found []string
	for k := range b.keys {
		if strings.HasPrefix(k, prefix) {
			found = append(found, k)
		}
	}
	b.mu.Unlock()

	if hook != nil {
		hook(prefix)
	}
	if failure != nil && !partial {
		return failure
	}
	slices.Sort(found)
	for _, k := range found {
		visit(k)
	}
	return failure
}

type syncBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (b *syncBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.Write(p)
}

func (b *syncBuffer) lines(t *testing.T, msg string) []map[string]any {
	t.Helper()
	b.mu.Lock()
	defer b.mu.Unlock()
	var out []map[string]any
	for _, l := range strings.Split(strings.TrimSpace(b.buf.String()), "\n") {
		if l == "" {
			continue
		}
		var m map[string]any
		if err := json.Unmarshal([]byte(l), &m); err != nil {
			t.Fatalf("log line is not JSON: %q", l)
		}
		if m["msg"] == msg {
			out = append(out, m)
		}
	}
	return out
}

type env struct {
	t      *testing.T
	q      *queue.Queue
	bucket *fakeBucket
	rec    *Reconciler
	logs   *syncBuffer
	files  string // where the local files live
}

func newEnv(t *testing.T) *env {
	t.Helper()
	b := newBucket()
	q := queue.New(b, time.Now)
	logs := &syncBuffer{}
	rec := New(q, b, logging.New(logs, "info", "test"))
	e := &env{t: t, q: q, bucket: b, rec: rec, logs: logs, files: t.TempDir()}

	ctx, cancel := context.WithCancel(context.Background())
	var wg sync.WaitGroup
	wg.Add(2)
	go func() { defer wg.Done(); q.Run(ctx) }()
	go func() { defer wg.Done(); rec.Run(ctx) }()
	t.Cleanup(func() {
		cancel()
		wg.Wait()
	})
	return e
}

func (e *env) settings() uploader.Settings {
	return uploader.Settings{AccessKeyID: "id", SecretAccessKey: secretText, Region: "us-east-1", Bucket: testBucket, Prefix: testPrefix}
}

func (e *env) write(rel string) string {
	e.t.Helper()
	p := filepath.Join(e.files, filepath.FromSlash(rel))
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		e.t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte("x"), 0o600); err != nil {
		e.t.Fatal(err)
	}
	return p
}

// send enqueues the paths as one upload and waits for it to end.
func (e *env) send(paths ...string) string {
	e.t.Helper()
	id := e.start(paths...)
	e.waitEnded(id)
	return id
}

func (e *env) start(paths ...string) string {
	e.t.Helper()
	id, err := e.q.Enqueue(e.settings(), queue.EnqueueRequest{Paths: paths})
	if err != nil {
		e.t.Fatal(err)
	}
	return id
}

func (e *env) snapshots() map[string]queue.Snapshot {
	initial, _, cancel := e.q.Subscribe()
	cancel()
	out := map[string]queue.Snapshot{}
	for _, s := range initial {
		out[s.ID] = s
	}
	return out
}

func (e *env) waitEnded(id string) {
	e.t.Helper()
	deadline := time.Now().Add(wait)
	for time.Now().Before(deadline) {
		if s, ok := e.snapshots()[id]; ok && (s.State == queue.Finished || s.State == queue.Failed) {
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	e.t.Fatalf("upload %s did not end", id)
}

// passes is how many passes have been logged so far.
func (e *env) passes() int { return len(e.logs.lines(e.t, "history reconciled")) }

// reconcile asks for a pass and waits until it has been logged.
func (e *env) reconcile() map[string]any {
	e.t.Helper()
	before := e.passes()
	e.rec.Configure(e.settings())
	return e.waitPass(before + 1)
}

func (e *env) waitPass(n int) map[string]any {
	e.t.Helper()
	deadline := time.Now().Add(wait)
	for time.Now().Before(deadline) {
		if lines := e.logs.lines(e.t, "history reconciled"); len(lines) >= n {
			return lines[n-1]
		}
		time.Sleep(5 * time.Millisecond)
	}
	e.t.Fatalf("pass %d was not logged", n)
	return nil
}

func TestAVanishedFileIsRemovedAndTheUploadRecounted(t *testing.T) {
	e := newEnv(t)
	e.write("d/a")
	e.write("d/b")
	folder := e.send(filepath.Join(e.files, "d"))
	e.bucket.remove("pfx/d/b")

	line := e.reconcile()

	up := e.snapshots()[folder]
	if up.FilesTotal != 1 || up.FilesFinished != 1 || up.BytesTotal != 1 || up.State != queue.Finished || up.Removed {
		t.Fatalf("folder upload = %+v, want one finished file left", up)
	}
	if line["checked"] != float64(2) || line["removed"] != float64(1) {
		t.Fatalf("log line = %v, want 2 checked and 1 removed", line)
	}
}

func TestAnUploadThatLosesEveryFileIsRemoved(t *testing.T) {
	e := newEnv(t)
	id := e.send(e.write("d/a"), e.write("d/b"))
	_, updates, cancel := e.q.Subscribe()
	defer cancel()
	e.bucket.remove("pfx/a", "pfx/b")

	e.reconcile()

	if _, ok := e.snapshots()[id]; ok {
		t.Fatal("upload still listed")
	}
	timeout := time.After(wait)
	for {
		select {
		case s := <-updates:
			if s.ID == id && s.Removed {
				return
			}
		case <-timeout:
			t.Fatal("subscribers never saw the upload removed")
		}
	}
}

func TestFailedFilesAreNeverTouchedAndKeepTheirUpload(t *testing.T) {
	e := newEnv(t)
	e.bucket.failName["c"] = true
	id := e.send(e.write("d/a"), e.write("d/c"))
	e.bucket.remove("pfx/a")

	line := e.reconcile()

	up, ok := e.snapshots()[id]
	if !ok || up.FilesTotal != 1 || up.FilesFailed != 1 || up.FilesFinished != 0 || up.State != queue.Failed {
		t.Fatalf("upload = %+v (listed %v), want it kept with its failed file", up, ok)
	}
	if line["removed"] != float64(1) {
		t.Fatalf("log line = %v, want 1 removed", line)
	}
}

func TestObjectsThatAreNotInTheHistoryAreIgnored(t *testing.T) {
	e := newEnv(t)
	id := e.send(e.write("a"))
	e.bucket.put("pfx/foreign.bin", "pfx/d/other", "elsewhere/x")

	line := e.reconcile()

	if up := e.snapshots()[id]; up.FilesTotal != 1 || up.FilesFinished != 1 {
		t.Fatalf("upload = %+v, want it untouched", up)
	}
	if len(e.snapshots()) != 1 {
		t.Fatal("a foreign object was added to the history")
	}
	if line["checked"] != float64(1) || line["removed"] != float64(0) {
		t.Fatalf("log line = %v", line)
	}
}

func TestAFailedListingChangesNothing(t *testing.T) {
	e := newEnv(t)
	id := e.send(e.write("a"))
	e.bucket.remove("pfx/a")
	e.bucket.listErr = uploader.ErrNoNetwork

	line := e.reconcile()

	if _, ok := e.snapshots()[id]; !ok {
		t.Fatal("upload removed although the listing failed")
	}
	if line["removed"] != float64(0) || line["unverified"] != float64(1) || line["reason"] != "No internet connection" {
		t.Fatalf("log line = %v, want 1 unverified and the readable reason", line)
	}
}

func TestAListingCutShortChangesNothing(t *testing.T) {
	e := newEnv(t)
	e.send(e.write("a"))
	e.send(e.write("b"))
	e.bucket.remove("pfx/b") // looks missing in what the cut-short listing returned
	e.bucket.listErr, e.bucket.partial = errors.New("connection reset"), true

	line := e.reconcile()

	if len(e.snapshots()) != 2 {
		t.Fatalf("uploads = %d, want both kept after a partial listing", len(e.snapshots()))
	}
	if line["removed"] != float64(0) || line["reason"] != "listing failed" {
		t.Fatalf("log line = %v", line)
	}
}

func TestAnUploadThatIsRunningIsNotListedOrTouched(t *testing.T) {
	e := newEnv(t)
	e.send(e.write("a"))
	e.bucket.holdName, e.bucket.release = "slow", make(chan struct{})
	defer close(e.bucket.release)
	running := e.start(e.write("slow"))
	deadline := time.Now().Add(wait)
	for e.snapshots()[running].State != queue.Uploading && time.Now().Before(deadline) {
		time.Sleep(5 * time.Millisecond)
	}

	e.reconcile()

	if up := e.snapshots()[running]; up.State != queue.Uploading {
		t.Fatalf("running upload = %+v, want it untouched", up)
	}
	if got := e.bucket.listings(); !slices.Equal(got, []string{"pfx/"}) || len(e.snapshots()) != 2 {
		t.Fatalf("listings = %v; only the finished upload may be checked", got)
	}
}

func TestAFileThatFinishesDuringAPassIsNotJudgedByTheOlderListing(t *testing.T) {
	e := newEnv(t)
	e.send(e.write("a"))
	var fresh string
	e.bucket.onList = func(string) {
		// The upload ends while the pass is listing, and the listing taken
		// before that does not contain its object.
		if fresh == "" {
			fresh = e.send(e.write("fresh"))
			e.bucket.remove("pfx/fresh")
		}
	}

	e.reconcile()
	e.bucket.onList = nil
	e.reconcile() // a second pass lists afresh and finds the object absent

	if _, ok := e.snapshots()[fresh]; ok {
		t.Fatal("the next pass should find the object absent")
	}
	// What matters is the first pass: it must have left the fresh upload alone.
	if lines := e.logs.lines(t, "history reconciled"); lines[0]["checked"] != float64(1) || lines[0]["removed"] != float64(0) {
		t.Fatalf("first pass = %v, want it to check only the file that was there when it started", lines[0])
	}
}

func TestTriggersDuringAPassCollapseIntoOneFollowUp(t *testing.T) {
	e := newEnv(t)
	e.send(e.write("a"))
	inList, release := make(chan struct{}), make(chan struct{})
	var once sync.Once
	e.bucket.onList = func(string) {
		once.Do(func() { close(inList) })
		<-release
	}

	e.rec.Configure(e.settings())
	<-inList
	for range 10 {
		e.rec.Trigger()
	}
	close(release)
	e.waitPass(2)

	time.Sleep(100 * time.Millisecond)
	if n := e.passes(); n != 2 {
		t.Fatalf("passes = %d, want the one running plus a single follow-up", n)
	}
}

func TestNothingRunsBeforeTheDaemonIsConfigured(t *testing.T) {
	e := newEnv(t)
	e.send(e.write("a"))

	e.rec.Trigger()
	time.Sleep(100 * time.Millisecond)

	if n := e.passes(); n != 0 || len(e.bucket.listings()) != 0 {
		t.Fatalf("passes = %d, listings = %v; want none without settings", n, e.bucket.listings())
	}
}

func TestOneListingPerFolderDestinationAndOnePerQuickUploadsPrefix(t *testing.T) {
	e := newEnv(t)
	for i := range 5 {
		e.send(e.write("single" + string(rune('a'+i))))
	}
	for i := range 20 {
		e.write("photos/day/f" + string(rune('a'+i)))
	}
	e.write("photos/top")
	e.send(filepath.Join(e.files, "photos"))

	line := e.reconcile()

	got := e.bucket.listings()
	slices.Sort(got)
	if want := []string{"pfx/", "pfx/photos/"}; !slices.Equal(got, want) {
		t.Fatalf("listings = %v, want %v", got, want)
	}
	if line["checked"] != float64(26) || line["removed"] != float64(0) {
		t.Fatalf("log line = %v, want 26 checked", line)
	}
}

func TestPassStopsWhenTheDaemonShutsDown(t *testing.T) {
	b := newBucket()
	q := queue.New(b, time.Now)
	rec := New(q, b, logging.New(&syncBuffer{}, "info", "test"))
	root := t.TempDir()
	file := filepath.Join(root, "a")
	if err := os.WriteFile(file, []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	qctx, qcancel := context.WithCancel(context.Background())
	defer qcancel()
	go q.Run(qctx)
	s := uploader.Settings{Bucket: testBucket, Region: "r", Prefix: testPrefix}
	id, err := q.Enqueue(s, queue.EnqueueRequest{Paths: []string{file}})
	if err != nil {
		t.Fatal(err)
	}
	for {
		initial, _, cancel := q.Subscribe()
		cancel()
		if len(initial) == 1 && initial[0].ID == id && initial[0].State == queue.Finished {
			break
		}
		time.Sleep(5 * time.Millisecond)
	}
	b.remove("pfx/a")

	inList := make(chan struct{})
	ctx, cancel := context.WithCancel(context.Background())
	lister := listerFunc(func(ctx context.Context, _ uploader.Settings, _ string, _ func(string)) error {
		close(inList)
		<-ctx.Done()
		return ctx.Err()
	})
	rec.lister = lister
	done := make(chan struct{})
	go func() { rec.Run(ctx); close(done) }()
	rec.Configure(s)
	<-inList

	start := time.Now()
	cancel()
	select {
	case <-done:
	case <-time.After(wait):
		t.Fatal("Run did not return after the context ended")
	}
	if took := time.Since(start); took > 500*time.Millisecond {
		t.Fatalf("stopping took %v", took)
	}
	initial, _, c := q.Subscribe()
	c()
	if len(initial) != 1 {
		t.Fatal("an upload was removed by a pass that was cut off")
	}
}

type listerFunc func(ctx context.Context, s uploader.Settings, prefix string, visit func(string)) error

func (f listerFunc) ListKeys(ctx context.Context, s uploader.Settings, prefix string, visit func(string)) error {
	return f(ctx, s, prefix, visit)
}

func TestPassLogsOneLineWithoutCredentialsOrErrorText(t *testing.T) {
	e := newEnv(t)
	e.send(e.write("a"))
	e.bucket.listErr = errors.New("request signed with " + secretText)

	e.reconcile()

	if n := len(e.logs.lines(t, "history reconciled")); n != 1 {
		t.Fatalf("lines = %d, want 1", n)
	}
	e.logs.mu.Lock()
	out := e.logs.buf.String()
	e.logs.mu.Unlock()
	if strings.Contains(out, secretText) {
		t.Fatalf("log leaks credentials or error text: %s", out)
	}
}

func TestListingPrefix(t *testing.T) {
	tests := []struct {
		name string
		f    queue.FinishedFile
		want string
	}{
		{"single file", queue.FinishedFile{ObjectKey: "quick/a.txt"}, "quick/"},
		{"file at the top of a folder", queue.FinishedFile{ObjectKey: "quick/photos/a.jpg", Inner: "a.jpg"}, "quick/photos/"},
		{"file in a sub-folder", queue.FinishedFile{ObjectKey: "quick/photos/day/a.jpg", Inner: "day/a.jpg"}, "quick/photos/"},
		{"no folder in the key", queue.FinishedFile{ObjectKey: "a.txt"}, ""},
	}
	for _, tt := range tests {
		if got := listingPrefix(tt.f); got != tt.want {
			t.Errorf("%s: prefix = %q, want %q", tt.name, got, tt.want)
		}
	}
}
