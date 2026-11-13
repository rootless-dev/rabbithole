package queue

import (
	"errors"
	"os"
	"path/filepath"
	"slices"
	"testing"

	"rabbithole/daemon/internal/uploader"
)

// tree creates files (slash paths relative to a new directory, content "x")
// and returns the directory.
func tree(t *testing.T, files ...string) string {
	t.Helper()
	root := t.TempDir()
	for _, f := range files {
		p := filepath.Join(root, filepath.FromSlash(f))
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte("x"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	return root
}

func relativePaths(p plan) []string {
	var out []string
	for _, f := range p.files {
		out = append(out, f.relativePath)
	}
	return out
}

func TestPlanOfOneFile(t *testing.T) {
	root := tree(t, "a.txt")
	p, err := buildPlan(req(filepath.Join(root, "a.txt")))
	if err != nil {
		t.Fatal(err)
	}
	if p.kind != SingleFile || !slices.Equal(relativePaths(p), []string{"a.txt"}) || p.files[0].size != 1 {
		t.Errorf("plan = %+v", p)
	}
}

func TestPlanOfOneFolderKeepsFolderNameAndSubpaths(t *testing.T) {
	root := tree(t, "photos/b.jpg", "photos/a.jpg", "photos/sub/c.jpg")
	p, err := buildPlan(req(filepath.Join(root, "photos")))
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"photos/a.jpg", "photos/b.jpg", "photos/sub/c.jpg"}
	if p.kind != Folder || !slices.Equal(relativePaths(p), want) {
		t.Errorf("kind = %v, paths = %v, want %v", p.kind, relativePaths(p), want)
	}
	if p.files[2].inner != "sub/c.jpg" {
		t.Errorf("inner = %q", p.files[2].inner)
	}
}

func TestPlanOfSeveralItemsIsMultiple(t *testing.T) {
	root := tree(t, "a.txt", "dir/b.txt")
	p, err := buildPlan(req(filepath.Join(root, "a.txt"), filepath.Join(root, "dir")))
	if err != nil {
		t.Fatal(err)
	}
	if p.kind != Multiple || !slices.Equal(relativePaths(p), []string{"a.txt", "dir/b.txt"}) {
		t.Errorf("kind = %v, paths = %v", p.kind, relativePaths(p))
	}
}

func TestPlanSkipPatternsApplyToWalkedNamesOnly(t *testing.T) {
	root := tree(t, "proj/keep.go", "proj/debug.tmp", "proj/node_modules/x/y.js", "proj/src/.DS_Store", "proj/src/main.go")
	p, err := buildPlan(EnqueueRequest{
		Paths:        []string{filepath.Join(root, "proj")},
		SkipPatterns: []string{"*.tmp", "node_modules", ".DS_Store", "[bad"}, // the last one is invalid and ignored
	})
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"proj/keep.go", "proj/src/main.go"}
	if !slices.Equal(relativePaths(p), want) {
		t.Errorf("paths = %v, want %v", relativePaths(p), want)
	}
}

func TestPlanSkipPatternsNeverApplyToListedPaths(t *testing.T) {
	root := tree(t, "debug.tmp", "node_modules/x.js")
	p, err := buildPlan(EnqueueRequest{
		Paths:        []string{filepath.Join(root, "debug.tmp"), filepath.Join(root, "node_modules")},
		SkipPatterns: []string{"*.tmp", "node_modules"},
	})
	if err != nil {
		t.Fatal(err)
	}
	if want := []string{"debug.tmp", "node_modules/x.js"}; !slices.Equal(relativePaths(p), want) {
		t.Errorf("paths = %v, want %v", relativePaths(p), want)
	}
}

func TestPlanLeavesSymlinksOut(t *testing.T) {
	root := tree(t, "d/real.txt", "outside/secret.txt")
	if err := os.Symlink(filepath.Join(root, "outside", "secret.txt"), filepath.Join(root, "d", "link.txt")); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join(root, "outside"), filepath.Join(root, "d", "linkdir")); err != nil {
		t.Fatal(err)
	}
	p, err := buildPlan(req(filepath.Join(root, "d")))
	if err != nil {
		t.Fatal(err)
	}
	if want := []string{"d/real.txt"}; !slices.Equal(relativePaths(p), want) {
		t.Errorf("paths = %v, want %v", relativePaths(p), want)
	}
}

func TestPlanCountsIdenticalPathsOnce(t *testing.T) {
	root := tree(t, "a.txt")
	a := filepath.Join(root, "a.txt")
	p, err := buildPlan(req(a, a, filepath.Join(root, ".", "a.txt")))
	if err != nil {
		t.Fatal(err)
	}
	if len(p.files) != 1 || p.kind != SingleFile {
		t.Errorf("plan = %+v", p)
	}
}

func TestPlanRejectsNothingToSend(t *testing.T) {
	root := tree(t, "empty/.keep.tmp")
	if err := os.MkdirAll(filepath.Join(root, "void", "deeper"), 0o755); err != nil {
		t.Fatal(err)
	}
	for name, r := range map[string]EnqueueRequest{
		"empty folder":        req(filepath.Join(root, "void")),
		"everything skipped":  {Paths: []string{filepath.Join(root, "empty")}, SkipPatterns: []string{"*.tmp"}},
		"folder of only dirs": req(filepath.Join(root, "void", "deeper")),
	} {
		if _, err := buildPlan(r); !errors.Is(err, ErrNoFiles) {
			t.Errorf("%s: err = %v, want ErrNoFiles", name, err)
		}
	}
}

func TestPlanRejectsInvalidPaths(t *testing.T) {
	root := tree(t, "a.txt")
	for name, r := range map[string]EnqueueRequest{
		"no paths":     {},
		"empty path":   req(""),
		"missing":      req(filepath.Join(root, "nope")),
		"one is bad":   req(filepath.Join(root, "a.txt"), filepath.Join(root, "nope")),
		"nil paths":    {Paths: nil},
		"empty string": req("", filepath.Join(root, "a.txt")),
	} {
		if _, err := buildPlan(r); !errors.Is(err, ErrInvalidPath) {
			t.Errorf("%s: err = %v, want ErrInvalidPath", name, err)
		}
	}
}

func TestPlanRejectsASocket(t *testing.T) {
	if _, err := buildPlan(req("/dev/null")); !errors.Is(err, ErrInvalidPath) {
		t.Errorf("err = %v, want ErrInvalidPath", err)
	}
}

func TestPlanKeepsAnUnreadableFolderAsAFailingEntry(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root can read everything")
	}
	root := tree(t, "d/ok.txt", "d/locked/hidden.txt")
	locked := filepath.Join(root, "d", "locked")
	if err := os.Chmod(locked, 0); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(locked, 0o755) })

	p, err := buildPlan(req(filepath.Join(root, "d")))
	if err != nil {
		t.Fatal(err)
	}
	if want := []string{"d/locked", "d/ok.txt"}; !slices.Equal(relativePaths(p), want) {
		t.Fatalf("paths = %v, want %v", relativePaths(p), want)
	}
	if !p.files[0].unreadable || p.files[1].unreadable {
		t.Errorf("unreadable flags = %v, %v", p.files[0].unreadable, p.files[1].unreadable)
	}
}

func TestPlanGivesClashingNamesDistinctDestinations(t *testing.T) {
	root := tree(t, "one/a.txt", "two/a.txt", "three/a.txt", "one/photos/p.jpg", "two/photos/q.jpg")
	p, err := buildPlan(req(
		filepath.Join(root, "one", "a.txt"), filepath.Join(root, "two", "a.txt"), filepath.Join(root, "three", "a.txt"),
		filepath.Join(root, "one", "photos"), filepath.Join(root, "two", "photos"),
	))
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"a.txt", "a-2.txt", "a-3.txt", "photos/p.jpg", "photos-2/q.jpg"}
	if !slices.Equal(relativePaths(p), want) {
		t.Errorf("paths = %v, want %v", relativePaths(p), want)
	}
	if p.items[1].destName != "a-2.txt" || p.items[4].destName != "photos-2" {
		t.Errorf("items = %+v", p.items)
	}
}

func TestPlanNameClashSkipsNamesAlreadyTaken(t *testing.T) {
	root := tree(t, "x/a.txt", "y/a-2.txt", "z/a.txt")
	p, err := buildPlan(req(
		filepath.Join(root, "x", "a.txt"), filepath.Join(root, "y", "a-2.txt"), filepath.Join(root, "z", "a.txt"),
	))
	if err != nil {
		t.Fatal(err)
	}
	if want := []string{"a.txt", "a-2.txt", "a-3.txt"}; !slices.Equal(relativePaths(p), want) {
		t.Errorf("paths = %v, want %v", relativePaths(p), want)
	}
}

func TestClampParallel(t *testing.T) {
	for in, want := range map[int]int{0: 4, -3: 1, 1: 1, 7: 7, 16: 16, 17: 16, 1000: 16} {
		if got := clampParallel(in); got != want {
			t.Errorf("clampParallel(%d) = %d, want %d", in, got, want)
		}
	}
}

func TestEnqueueFillsTheSnapshot(t *testing.T) {
	root := tree(t, "a.txt", "dir/b.txt", "dir/c.txt")
	a, dir := filepath.Join(root, "a.txt"), filepath.Join(root, "dir")
	q := New(okRunner(), newFakeClock().Now)
	id, err := q.Enqueue(uploader.Settings{Prefix: "pfx/"}, req(a, dir, a))
	if err != nil {
		t.Fatal(err)
	}
	initial, _, cancel := q.Subscribe()
	defer cancel()
	got := initial[0]
	if got.ID != id || got.Kind != Multiple || got.FileName != "a.txt" || got.LocalPath != a ||
		!slices.Equal(got.RootPaths, []string{a, dir}) || got.FilesTotal != 3 ||
		got.BytesTotal != 3 || got.ObjectKey != "" || got.State != Queued {
		t.Errorf("snapshot = %+v", got)
	}
	if q.uploads[id].parallel != 4 {
		t.Errorf("parallel = %d, want the default 4", q.uploads[id].parallel)
	}
}
