package queue

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path"
	"path/filepath"
	"strings"

	"rabbithole/daemon/internal/uploader"
)

// Kind is what the user handed over as one upload.
type Kind int

const (
	SingleFile Kind = iota
	Folder
	Multiple
)

// ErrNoFiles means the paths of an upload hold nothing to send.
var ErrNoFiles = errors.New("there are no files to send")

// EnqueueRequest describes one upload: the files and folders that make it up
// and how to send them.
type EnqueueRequest struct {
	Paths []string
	// SkipPatterns are shell globs tested against each single element name found
	// while walking a folder. They never apply to a path listed in Paths.
	SkipPatterns []string
	// ParallelFiles is how many files are sent at once: 0 selects
	// defaultParallelFiles, anything else is clamped to 1..maxParallelFiles.
	ParallelFiles int
}

const (
	defaultParallelFiles = 4
	maxParallelFiles     = 16
)

func clampParallel(n int) int {
	if n == 0 {
		return defaultParallelFiles
	}
	return min(max(n, 1), maxParallelFiles)
}

// item is one path the upload was enqueued with.
type item struct {
	path     string
	isDir    bool
	destName string // name inside this upload, unique among its items
	resolved string // for a folder, the name it landed under at the destination; empty until known
}

// plannedFile is one file the upload will send.
type plannedFile struct {
	item         int
	inner        string // slash path inside the folder; empty for a file listed directly
	local        string
	size         int64
	relativePath string
	unreadable   bool // a directory or entry the walk could not read
}

// plan is everything an upload will send, decided before it is enqueued.
type plan struct {
	kind  Kind
	items []item
	files []plannedFile
}

func buildPlan(req EnqueueRequest) (plan, error) {
	if len(req.Paths) == 0 {
		return plan{}, fmt.Errorf("%w: no paths given", ErrInvalidPath)
	}

	var p plan
	seen := map[string]bool{}
	used := map[string]bool{}
	for _, raw := range req.Paths {
		clean := filepath.Clean(raw)
		if seen[clean] {
			continue
		}
		seen[clean] = true

		info, err := statListed(raw)
		if err != nil {
			return plan{}, err
		}

		it := item{path: raw, isDir: info.IsDir(), destName: uniqueName(baseName(raw), info.IsDir(), used)}
		used[it.destName] = true
		p.items = append(p.items, it)
		idx := len(p.items) - 1

		if !it.isDir {
			p.files = append(p.files, plannedFile{item: idx, local: raw, size: info.Size(), relativePath: it.destName})
			continue
		}
		p.files = append(p.files, walkFolder(raw, idx, it.destName, req.SkipPatterns)...)
	}

	if len(p.files) == 0 {
		return plan{}, ErrNoFiles
	}
	p.kind = kindOf(p.items)
	return p, nil
}

// statListed checks a path the upload was enqueued with: it must be a folder
// or a regular file that can be opened.
func statListed(raw string) (os.FileInfo, error) {
	info, err := os.Stat(raw)
	if err != nil {
		return nil, fmt.Errorf("%w: %v", ErrInvalidPath, err)
	}
	switch {
	case info.IsDir():
	case info.Mode().IsRegular():
		f, err := os.Open(raw)
		if err != nil {
			return nil, fmt.Errorf("%w: %v", ErrInvalidPath, err)
		}
		_ = f.Close()
	default:
		return nil, fmt.Errorf("%w: %s is neither a file nor a folder", ErrInvalidPath, raw)
	}
	return info, nil
}

func kindOf(items []item) Kind {
	switch {
	case len(items) != 1:
		return Multiple
	case items[0].isDir:
		return Folder
	default:
		return SingleFile
	}
}

// walkFolder lists the regular files under root. Symlinks and other special
// files are left out and never followed. A part of the tree that cannot be read
// becomes an entry marked unreadable, so it fails visibly instead of vanishing.
func walkFolder(root string, itemIdx int, destName string, skip []string) []plannedFile {
	w := &folderWalk{root: resolveListedSymlink(root), item: itemIdx, destName: destName, skip: skip}
	_ = filepath.WalkDir(w.root, w.visit)
	return w.files
}

// resolveListedSymlink returns what root points at when root is a symlink.
// WalkDir does not enter a symlink, but a listed symlink to a folder is the
// user's explicit choice.
func resolveListedSymlink(root string) string {
	info, err := os.Lstat(root)
	if err != nil || info.Mode()&fs.ModeSymlink == 0 {
		return root
	}
	resolved, err := filepath.EvalSymlinks(root)
	if err != nil {
		return root
	}
	return resolved
}

// folderWalk collects the files of one folder of an upload.
type folderWalk struct {
	root     string
	item     int
	destName string
	skip     []string
	files    []plannedFile
}

// visit is the fs.WalkDirFunc of the walk.
func (w *folderWalk) visit(p string, d fs.DirEntry, err error) error {
	if err != nil {
		w.add(p, 0, true)
		return nil
	}
	if p == w.root {
		return nil
	}
	if matchesAny(w.skip, d.Name()) {
		if d.IsDir() {
			return filepath.SkipDir
		}
		return nil
	}
	if !d.Type().IsRegular() {
		return nil // a folder to descend into, a symlink or a special file
	}
	info, err := d.Info()
	if err != nil {
		w.add(p, 0, true)
		return nil
	}
	w.add(p, info.Size(), false)
	return nil
}

func (w *folderWalk) add(local string, size int64, unreadable bool) {
	pf := plannedFile{item: w.item, local: local, size: size, unreadable: unreadable, relativePath: w.destName}
	if rel, err := filepath.Rel(w.root, local); err == nil && rel != "." {
		pf.inner = filepath.ToSlash(rel)
		pf.relativePath = w.destName + "/" + pf.inner
	}
	w.files = append(w.files, pf)
}

func matchesAny(patterns []string, name string) bool {
	for _, pat := range patterns {
		if ok, err := path.Match(pat, name); err == nil && ok {
			return true
		}
	}
	return false
}

func baseName(p string) string {
	if abs, err := filepath.Abs(p); err == nil {
		p = abs
	}
	name := filepath.Base(p)
	if name == string(filepath.Separator) {
		return "root"
	}
	return name
}

// uniqueName returns name, or name-2, name-3, ... (before the extension for a
// file) when name is already used by another item of the same upload.
func uniqueName(name string, isDir bool, used map[string]bool) string {
	if !used[name] {
		return name
	}
	ext := ""
	if !isDir {
		ext = uploader.Ext(name)
	}
	base := strings.TrimSuffix(name, ext)
	for n := 2; ; n++ {
		if candidate := fmt.Sprintf("%s-%d%s", base, n, ext); !used[candidate] {
			return candidate
		}
	}
}
