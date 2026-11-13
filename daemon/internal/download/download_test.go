package download

import (
	"bytes"
	"context"
	"errors"
	"io"
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

// fakeSource serves objects from memory. A key in errs fails at GetObject, one
// in cutAfter fails halfway through its body, and one in hang stops halfway
// and waits for the context to end.
type fakeSource struct {
	mu       sync.Mutex
	objects  map[string]string
	errs     map[string]error
	cutAfter map[string]error
	hang     map[string]bool
	started  chan string // receives the key of each body that began to be read
	gets     []string
}

func newSource(objects map[string]string) *fakeSource {
	return &fakeSource{objects: objects, errs: map[string]error{}, cutAfter: map[string]error{}, hang: map[string]bool{}, started: make(chan string, 100)}
}

func (s *fakeSource) GetObject(ctx context.Context, key string) (io.ReadCloser, int64, error) {
	s.mu.Lock()
	s.gets = append(s.gets, key)
	err, content := s.errs[key], s.objects[key]
	s.mu.Unlock()
	if err != nil {
		return nil, 0, err
	}
	return &fakeBody{src: s, ctx: ctx, key: key, data: []byte(content)}, int64(len(content)), nil
}

type fakeBody struct {
	src  *fakeSource
	ctx  context.Context
	key  string
	data []byte
	pos  int
	half bool
}

func (b *fakeBody) Read(p []byte) (int, error) {
	half := len(b.data) / 2
	if b.pos >= half && !b.half && (b.src.hang[b.key] || b.src.cutAfter[b.key] != nil) {
		b.half = true
		b.src.started <- b.key
	}
	if b.half {
		if err := b.src.cutAfter[b.key]; err != nil {
			return 0, err
		}
		<-b.ctx.Done()
		return 0, b.ctx.Err()
	}
	if b.pos >= len(b.data) {
		return 0, io.EOF
	}
	end := len(b.data)
	if b.src.hang[b.key] || b.src.cutAfter[b.key] != nil {
		end = half
	}
	n := copy(p, b.data[b.pos:end])
	b.pos += n
	return n, nil
}

func (b *fakeBody) Close() error { return nil }

type fakeFiles struct {
	files   []queue.DownloadFile
	err     error
	bucket  string
	id      string
	indexes []int
}

func (f *fakeFiles) DownloadFiles(bucket, id string, indexes []int) ([]queue.DownloadFile, error) {
	f.bucket, f.id, f.indexes = bucket, id, indexes
	return f.files, f.err
}

func file(index int, rel, key string, size int) queue.DownloadFile {
	return queue.DownloadFile{Index: index, RelativePath: rel, ObjectKey: key, Size: int64(size)}
}

type env struct {
	m     *Manager
	src   *fakeSource
	files *fakeFiles
	dest  string
}

func newEnv(t *testing.T, objects map[string]string, files ...queue.DownloadFile) *env {
	t.Helper()
	src := newSource(objects)
	ff := &fakeFiles{files: files}
	var log bytes.Buffer
	m := New(func(context.Context, uploader.Settings) (Source, error) { return src, nil }, ff, logging.New(&log, "debug", "test"))
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { m.Run(ctx); close(done) }()
	t.Cleanup(func() { cancel(); <-done })
	return &env{m: m, src: src, files: ff, dest: t.TempDir()}
}

func (e *env) start(t *testing.T, indexes ...int) string {
	t.Helper()
	id, err := e.m.Start(uploader.Settings{Bucket: "b1"}, "up-1", indexes, e.dest)
	if err != nil {
		t.Fatal(err)
	}
	return id
}

// ended waits for the final snapshot of download id.
func (e *env) ended(t *testing.T, id string) Snapshot {
	t.Helper()
	initial, updates, cancel := e.m.Subscribe()
	defer cancel()
	for _, s := range initial {
		if s.ID == id && s.State.ended() {
			return s
		}
	}
	timeout := time.After(5 * time.Second)
	for {
		select {
		case s := <-updates:
			if s.ID == id && s.State.ended() {
				return s
			}
		case <-timeout:
			t.Fatal("download did not end")
		}
	}
}

func readFile(t *testing.T, path string) string {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

// tree lists every file and folder below dir, as slash paths.
func tree(t *testing.T, dir string) []string {
	t.Helper()
	var out []string
	_ = filepath.WalkDir(dir, func(p string, _ os.DirEntry, _ error) error {
		if rel, _ := filepath.Rel(dir, p); rel != "." {
			out = append(out, filepath.ToSlash(rel))
		}
		return nil
	})
	return out
}

func TestSingleFileLandsDirectlyInTheDestination(t *testing.T) {
	e := newEnv(t, map[string]string{"quick/a.txt": "hello world"}, file(3, "a.txt", "quick/a.txt", 11))

	id := e.start(t, 3)
	got := e.ended(t, id)

	if readFile(t, filepath.Join(e.dest, "a.txt")) != "hello world" {
		t.Fatal("content differs")
	}
	if got.State != Finished || got.Name != "a.txt" || got.Destination != filepath.Join(e.dest, "a.txt") {
		t.Fatalf("snapshot = %+v", got)
	}
	if got.FilesTotal != 1 || got.FilesDone != 1 || got.BytesTotal != 11 || got.BytesDone != 11 || !slices.Equal(got.FileIndexes, []int{3}) {
		t.Fatalf("counters = %+v", got)
	}
	if e.files.bucket != "b1" || e.files.id != "up-1" || !slices.Equal(e.files.indexes, []int{3}) {
		t.Fatalf("asked for %q %q %v", e.files.bucket, e.files.id, e.files.indexes)
	}
	if names := tree(t, e.dest); !slices.Equal(names, []string{"a.txt"}) {
		t.Fatalf("destination = %v, want only the file (no temporary file left)", names)
	}
}

func TestFolderRecreatesNestedPathsUnderTheFolderName(t *testing.T) {
	e := newEnv(t, map[string]string{"k/1": "one", "k/2": "two", "k/3": "three"},
		file(0, "photos/a.jpg", "k/1", 3), file(1, "photos/2026/b.jpg", "k/2", 3), file(2, "photos/2026/may/c.jpg", "k/3", 5))

	got := e.ended(t, e.start(t))

	for rel, want := range map[string]string{"photos/a.jpg": "one", "photos/2026/b.jpg": "two", "photos/2026/may/c.jpg": "three"} {
		if readFile(t, filepath.Join(e.dest, filepath.FromSlash(rel))) != want {
			t.Fatalf("%s has the wrong content", rel)
		}
	}
	if got.State != Finished || got.Name != "photos" || got.Destination != filepath.Join(e.dest, "photos") || got.FilesDone != 3 {
		t.Fatalf("snapshot = %+v", got)
	}
}

func TestSeveralFilesLandSideBySideAndTheResultIsTheDestination(t *testing.T) {
	e := newEnv(t, map[string]string{"k/1": "one", "k/2": "two"}, file(0, "a.txt", "k/1", 3), file(1, "b.txt", "k/2", 3))

	got := e.ended(t, e.start(t))

	if names := tree(t, e.dest); !slices.Equal(names, []string{"a.txt", "b.txt"}) {
		t.Fatalf("destination = %v", names)
	}
	if got.Destination != e.dest || got.Name != "2 items" {
		t.Fatalf("snapshot = %+v", got)
	}
}

func TestATakenNameGetsANumericSuffixAndNothingIsOverwritten(t *testing.T) {
	e := newEnv(t, map[string]string{"k/1": "new", "k/2": "new file", "k/3": "new nested"},
		file(0, "a.txt", "k/1", 3), file(1, "photos/x.txt", "k/3", 10))
	mustWrite(t, filepath.Join(e.dest, "a.txt"), "mine")
	mustWrite(t, filepath.Join(e.dest, "a 2.txt"), "also mine")
	mustWrite(t, filepath.Join(e.dest, "photos", "x.txt"), "my photo")

	got := e.ended(t, e.start(t))

	for path, want := range map[string]string{
		"a.txt": "mine", "a 2.txt": "also mine", "a 3.txt": "new", "photos/x.txt": "my photo", "photos 2/x.txt": "new nested",
	} {
		if readFile(t, filepath.Join(e.dest, filepath.FromSlash(path))) != want {
			t.Fatalf("%s = %q, want %q", path, readFile(t, filepath.Join(e.dest, filepath.FromSlash(path))), want)
		}
	}
	if got.State != Finished {
		t.Fatalf("state = %v", got.State)
	}
}

func TestASingleFileWithATakenNameReportsTheSuffixedPath(t *testing.T) {
	e := newEnv(t, map[string]string{"k/1": "x"}, file(0, "report.tar.gz", "k/1", 1))
	mustWrite(t, filepath.Join(e.dest, "report.tar.gz"), "mine")

	got := e.ended(t, e.start(t))

	if got.Destination != filepath.Join(e.dest, "report.tar 2.gz") || readFile(t, got.Destination) != "x" {
		t.Fatalf("destination = %q", got.Destination)
	}
}

func mustWrite(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestStoredPathsThatEscapeTheDestinationAreRefused(t *testing.T) {
	for _, rel := range []string{"../evil.txt", "/abs/evil.txt", "a/../../evil.txt", "a/./b", "a//b", "", ".."} {
		t.Run(rel, func(t *testing.T) {
			e := newEnv(t, map[string]string{"k/1": "evil"}, file(0, rel, "k/1", 4))

			got := e.ended(t, e.start(t))

			if got.State != Failed || got.ErrorMessage != unsafeMessage {
				t.Fatalf("state %v message %q, want failed with %q", got.State, got.ErrorMessage, unsafeMessage)
			}
			if len(e.src.gets) != 0 {
				t.Fatal("an unsafe file must not even be fetched")
			}
			if names := tree(t, filepath.Dir(e.dest)); slices.ContainsFunc(names, func(n string) bool { return strings.Contains(n, "evil") }) {
				t.Fatalf("something was written outside the destination: %v", names)
			}
			if names := tree(t, e.dest); len(names) != 0 {
				t.Fatalf("destination = %v, want empty", names)
			}
		})
	}
}

func TestOneUnsafePathDoesNotStopTheOtherFiles(t *testing.T) {
	e := newEnv(t, map[string]string{"k/1": "good", "k/2": "bad"}, file(0, "ok.txt", "k/1", 4), file(1, "../bad.txt", "k/2", 3))

	got := e.ended(t, e.start(t))

	if got.State != Failed || got.ErrorMessage != "1 of 2 files could not be downloaded" || got.FilesDone != 1 || got.FilesFailed != 1 {
		t.Fatalf("snapshot = %+v", got)
	}
	if readFile(t, filepath.Join(e.dest, "ok.txt")) != "good" {
		t.Fatal("the safe file must still arrive")
	}
}

func TestAFailureHalfwayLeavesNothingBehind(t *testing.T) {
	e := newEnv(t, map[string]string{"k/1": "0123456789"}, file(0, "d/big.bin", "k/1", 10))
	e.src.cutAfter["k/1"] = uploader.ErrNoNetwork

	got := e.ended(t, e.start(t))

	if got.State != Failed || got.ErrorMessage != "No internet connection" {
		t.Fatalf("snapshot = %+v", got)
	}
	if names := tree(t, e.dest); len(names) != 0 {
		t.Fatalf("destination = %v, want nothing: no partial file, no empty folder", names)
	}
}

func TestCancelStopsTheDownloadAndRemovesTheTemporaryFile(t *testing.T) {
	e := newEnv(t, map[string]string{"k/1": "0123456789"}, file(0, "d/big.bin", "k/1", 10))
	e.src.hang["k/1"] = true
	id := e.start(t)
	<-e.src.started
	if names := tree(t, e.dest); len(names) != 2 || !strings.HasSuffix(names[1], ".part") {
		t.Fatalf("while downloading: %v, want the folder and a .part file", names)
	}

	if err := e.m.Cancel(id); err != nil {
		t.Fatal(err)
	}
	got := e.ended(t, id)

	if got.State != Canceled || got.ErrorMessage != "" {
		t.Fatalf("snapshot = %+v", got)
	}
	if names := tree(t, e.dest); len(names) != 0 {
		t.Fatalf("destination = %v, want nothing", names)
	}
	if err := e.m.Cancel(id); !errors.Is(err, ErrDownloadEnded) {
		t.Fatalf("second cancel = %v, want ErrDownloadEnded", err)
	}
}

func TestCancelUnknownDownload(t *testing.T) {
	e := newEnv(t, nil, file(0, "a", "k", 1))
	if err := e.m.Cancel("nope"); !errors.Is(err, ErrUnknownDownload) {
		t.Fatalf("err = %v, want ErrUnknownDownload", err)
	}
}

func TestCancelOfAFinishedDownloadIsRefused(t *testing.T) {
	e := newEnv(t, map[string]string{"k": "x"}, file(0, "a", "k", 1))
	id := e.start(t)
	e.ended(t, id)
	if err := e.m.Cancel(id); !errors.Is(err, ErrDownloadEnded) {
		t.Fatalf("err = %v, want ErrDownloadEnded", err)
	}
}

func TestShutdownCancelsRunningDownloadsAndLeavesNoTemporaryFiles(t *testing.T) {
	src := newSource(map[string]string{"k/1": "0123456789"})
	src.hang["k/1"] = true
	var log bytes.Buffer
	m := New(func(context.Context, uploader.Settings) (Source, error) { return src, nil },
		&fakeFiles{files: []queue.DownloadFile{file(0, "d/big.bin", "k/1", 10)}}, logging.New(&log, "debug", "test"))
	ctx, cancel := context.WithCancel(context.Background())
	stopped := make(chan struct{})
	go func() { m.Run(ctx); close(stopped) }()
	dest := t.TempDir()
	id, err := m.Start(uploader.Settings{Bucket: "b1"}, "up-1", nil, dest)
	if err != nil {
		t.Fatal(err)
	}
	<-src.started

	cancel()
	select {
	case <-stopped:
	case <-time.After(time.Second):
		t.Fatal("Run did not return within a second of shutdown")
	}
	if names := tree(t, dest); len(names) != 0 {
		t.Fatalf("destination = %v, want nothing", names)
	}
	initial, _, stop := m.Subscribe()
	defer stop()
	if len(initial) != 1 || initial[0].ID != id || initial[0].State != Canceled {
		t.Fatalf("snapshots = %+v, want the download canceled", initial)
	}
}

func TestFailuresOfOneFileDoNotStopTheOthers(t *testing.T) {
	e := newEnv(t, map[string]string{"k/1": "one", "k/3": "three"},
		file(0, "d/a", "k/1", 3), file(1, "d/b", "k/2", 3), file(2, "d/c", "k/3", 5))
	e.src.errs["k/2"] = uploader.ErrObjectNotFound

	got := e.ended(t, e.start(t))

	if got.State != Failed || got.ErrorMessage != "1 of 3 files could not be downloaded" || got.FilesDone != 2 || got.FilesFailed != 1 {
		t.Fatalf("snapshot = %+v", got)
	}
	if names := tree(t, e.dest); !slices.Equal(names, []string{"d", "d/a", "d/c"}) {
		t.Fatalf("destination = %v", names)
	}
}

func TestASingleFileFailureUsesItsOwnMessage(t *testing.T) {
	tests := []struct {
		name string
		err  error
		want string
	}{
		{"gone from the bucket", uploader.ErrObjectNotFound, "The file is no longer in the bucket"},
		{"anything else", errors.New("boom"), "The file could not be downloaded"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e := newEnv(t, nil, file(0, "a.txt", "k/1", 3))
			e.src.errs["k/1"] = tt.err
			got := e.ended(t, e.start(t))
			if got.State != Failed || got.ErrorMessage != tt.want {
				t.Fatalf("snapshot = %+v, want failed with %q", got, tt.want)
			}
		})
	}
}

func TestAnErrorThatHitsEveryFileStopsTheDownloadWithTheServiceMessage(t *testing.T) {
	tests := []struct {
		err  error
		want string
	}{
		{uploader.ErrReadDenied, "AWS denied permission to read from the bucket: the access key needs the s3:GetObject permission"},
		{uploader.ErrBadCredentials, "AWS rejected the access key"},
		{uploader.ErrNoNetwork, "No internet connection"},
		{uploader.ErrBucketNotFound, "Bucket not found"},
		{uploader.ErrBucketInaccessible, "AWS blocked access to this bucket: check that the bucket name is yours"},
		{uploader.ErrWrongRegion, "The bucket is in a different region"},
	}
	for _, tt := range tests {
		t.Run(tt.want, func(t *testing.T) {
			e := newEnv(t, map[string]string{"k/2": "two"}, file(0, "d/a", "k/1", 3), file(1, "d/b", "k/2", 3))
			e.src.errs["k/1"] = tt.err
			got := e.ended(t, e.start(t))
			if got.State != Failed || got.ErrorMessage != tt.want {
				t.Fatalf("snapshot = %+v, want failed with %q", got, tt.want)
			}
		})
	}
}

func TestStartRefusals(t *testing.T) {
	tests := []struct {
		name string
		prep func(e *env) string
		want error
	}{
		{"upload errors pass through", func(e *env) string { e.files.err = queue.ErrNoFinishedFiles; return e.dest }, queue.ErrNoFinishedFiles},
		{"unknown upload", func(e *env) string { e.files.err = queue.ErrUnknownUpload; return e.dest }, queue.ErrUnknownUpload},
		{"relative destination", func(e *env) string { return "relative/dir" }, ErrBadDestination},
		{"missing destination", func(e *env) string { return filepath.Join(e.dest, "nope") }, ErrBadDestination},
		{"destination is a file", func(e *env) string {
			p := filepath.Join(e.dest, "f")
			mustWrite(t, p, "x")
			return p
		}, ErrBadDestination},
		{"empty destination", func(e *env) string { return "" }, ErrBadDestination},
		{"read-only destination", func(e *env) string {
			if os.Geteuid() == 0 {
				t.Skip("root can write anywhere")
			}
			dir := filepath.Join(e.dest, "ro")
			if err := os.Mkdir(dir, 0o500); err != nil {
				t.Fatal(err)
			}
			return dir
		}, ErrBadDestination},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e := newEnv(t, nil, file(0, "a", "k", 1))
			dest := tt.prep(e)
			id, err := e.m.Start(uploader.Settings{Bucket: "b1"}, "up-1", nil, dest)
			if !errors.Is(err, tt.want) || id != "" {
				t.Fatalf("id %q err %v, want %v", id, err, tt.want)
			}
			if initial, _, cancel := e.m.Subscribe(); len(initial) != 0 {
				t.Fatalf("a refused download must not be listed: %+v", initial)
			} else {
				cancel()
			}
		})
	}
}

func TestStreamReplaysEarlierDownloadsThenStreamsChanges(t *testing.T) {
	e := newEnv(t, map[string]string{"k/1": "one", "k/2": "two"}, file(0, "a", "k/1", 3))
	first := e.start(t)
	e.ended(t, first)

	initial, updates, cancel := e.m.Subscribe()
	defer cancel()
	if len(initial) != 1 || initial[0].ID != first || initial[0].State != Finished {
		t.Fatalf("initial = %+v, want the finished download", initial)
	}
	e.files.files = []queue.DownloadFile{file(0, "b", "k/2", 3)}
	second := e.start(t)
	seen := map[State]bool{}
	timeout := time.After(5 * time.Second)
	for !seen[Finished] {
		select {
		case s := <-updates:
			if s.ID == second {
				seen[s.State] = true
			}
		case <-timeout:
			t.Fatalf("states seen = %v, want the second download to finish", seen)
		}
	}
}

func TestSlowStreamReaderStillGetsTheFinalStateAndNeverBlocksTheDownload(t *testing.T) {
	var files []queue.DownloadFile
	objects := map[string]string{}
	for i := range 40 {
		key := "k/" + string(rune('a'+i%26)) + string(rune('A'+i/26))
		objects[key] = "x"
		files = append(files, file(i, "d/f"+key[2:], key, 1))
	}
	e := newEnv(t, objects, files...)
	_, updates, cancel := e.m.Subscribe()
	defer cancel() // reads nothing while the download runs

	id := e.start(t)
	deadline := time.After(5 * time.Second)
	for {
		select {
		case s := <-updates:
			if s.ID == id && s.State == Finished {
				if s.FilesDone != 40 {
					t.Fatalf("final snapshot = %+v", s)
				}
				return
			}
		case <-deadline:
			t.Fatal("the final state never arrived")
		}
	}
}

func TestProgressIsThrottledToTenSnapshotsPerSecond(t *testing.T) {
	var now time.Time = time.Unix(1000, 0)
	var mu sync.Mutex
	clock := func() time.Time { mu.Lock(); defer mu.Unlock(); return now }
	src := newSource(map[string]string{"k": strings.Repeat("x", 1000)})
	m := New(func(context.Context, uploader.Settings) (Source, error) { return src, nil },
		&fakeFiles{files: []queue.DownloadFile{file(0, "a", "k", 1000)}}, logging.New(io.Discard, "debug", "test"), WithClock(clock))
	d := &download{snap: Snapshot{ID: "x", BytesTotal: 1000}}
	_, updates, cancel := m.Subscribe()
	defer cancel()

	for range 50 { // 50 progress reports within the same fake instant
		m.progressed(d, 1)
	}
	mu.Lock()
	now = now.Add(150 * time.Millisecond)
	mu.Unlock()
	m.progressed(d, 1)

	var got []Snapshot
	for {
		select {
		case s := <-updates:
			got = append(got, s)
			continue
		case <-time.After(100 * time.Millisecond):
		}
		break
	}
	if d.snap.BytesDone != 51 {
		t.Fatalf("bytes done = %d, want 51", d.snap.BytesDone)
	}
	if len(got) == 0 || len(got) > 2 || got[len(got)-1].BytesDone != 51 {
		t.Fatalf("snapshots = %d (last %+v), want at most one per 100 ms with the latest value", len(got), got)
	}
}
