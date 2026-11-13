package download

import (
	"errors"
	"fmt"
	"os"
	"path"
	"path/filepath"
	"strings"

	"rabbithole/daemon/internal/queue"
	"rabbithole/daemon/internal/uploader"
)

// maxNameAttempts caps how many suffixes are tried for a taken name.
const maxNameAttempts = 1000

// errUnsafePath marks a stored relative path that is empty, absolute or would
// leave the destination.
var errUnsafePath = errors.New("unsafe relative path")

// plannedFile is one file of a download with the place it lands.
type plannedFile struct {
	index int
	key   string
	size  int64
	final string // absolute path the file is renamed to; empty when err is set
	err   error  // why the file cannot be downloaded at all
}

// plan is what a download will do, decided once at its start.
type plan struct {
	files       []plannedFile
	name        string   // what the download is shown as
	destination string   // the file for a single file, the folder otherwise
	folders     []string // the new top-level folders, to prune when they stay empty
	total       int64
}

// splitRelative checks a stored relative path and returns its components. The
// path comes from stored data and is not trusted: anything empty, absolute or
// with a "." or ".." component is refused.
func splitRelative(rel string) ([]string, error) {
	if rel == "" || strings.ContainsRune(rel, 0) {
		return nil, errUnsafePath
	}
	parts := strings.Split(rel, "/")
	for _, p := range parts {
		if p == "" || p == "." || p == ".." {
			return nil, errUnsafePath
		}
	}
	return parts, nil
}

// within reports whether target is below dir.
func within(dir, target string) bool {
	rel, err := filepath.Rel(dir, target)
	return err == nil && rel != "." && rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator))
}

// topLevels returns the first component of every usable path, in order of
// appearance, and whether it is a folder (some path goes below it).
func topLevels(parts [][]string) (names []string, isDir map[string]bool) {
	isDir = map[string]bool{}
	for _, p := range parts {
		if p == nil {
			continue
		}
		if _, seen := isDir[p[0]]; !seen {
			names = append(names, p[0])
			isDir[p[0]] = false
		}
		if len(p) > 1 {
			isDir[p[0]] = true
		}
	}
	return names, isDir
}

// buildPlan decides where each file lands under destDir. A top-level name that
// is taken, on disk or by another file of the download, gets a numeric suffix,
// chosen here once; nothing existing is ever overwritten.
func buildPlan(destDir string, files []queue.DownloadFile) (plan, error) {
	parts := make([][]string, len(files))
	for i, f := range files {
		parts[i], _ = splitRelative(f.RelativePath)
	}
	names, isDir := topLevels(parts)
	landed, err := resolveNames(destDir, names, isDir)
	if err != nil {
		return plan{}, err
	}

	p := plan{files: make([]plannedFile, len(files))}
	for i, f := range files {
		pf := plannedFile{index: f.Index, key: f.ObjectKey, size: f.Size}
		if parts[i] == nil {
			pf.err = errUnsafePath
		} else if pf.final = filepath.Join(append([]string{destDir, landed[parts[i][0]]}, parts[i][1:]...)...); !within(destDir, pf.final) {
			pf.final, pf.err = "", errUnsafePath
		}
		p.files[i] = pf
		p.total += f.Size
	}
	p.name, p.destination = describe(destDir, names, isDir, landed)
	for _, n := range names {
		if isDir[n] {
			p.folders = append(p.folders, filepath.Join(destDir, landed[n]))
		}
	}
	return p, nil
}

// describe names the download and says where its result is: the one file or
// folder when there is a single top-level name, the destination otherwise.
func describe(destDir string, names []string, isDir map[string]bool, landed map[string]string) (name, destination string) {
	if len(names) == 1 {
		return names[0], filepath.Join(destDir, landed[names[0]])
	}
	if len(names) == 0 {
		return "files", destDir
	}
	return fmt.Sprintf("%d items", len(names)), destDir
}

// resolveNames picks, for each top-level name, the name it lands under.
func resolveNames(destDir string, names []string, isDir map[string]bool) (map[string]string, error) {
	landed := make(map[string]string, len(names))
	claimed := map[string]bool{}
	for _, n := range names {
		free, err := freeName(destDir, n, isDir[n], claimed)
		if err != nil {
			return nil, err
		}
		landed[n] = free
		claimed[free] = true
	}
	return landed, nil
}

// freeName returns name when nothing is called that in dir, otherwise the
// first "name 2.ext" (or "folder 2") that is free. A folder name is never
// split at a dot.
func freeName(dir, name string, folder bool, claimed map[string]bool) (string, error) {
	stem, ext := name, ""
	if !folder {
		ext = path.Ext(name)
		stem = strings.TrimSuffix(name, ext)
		if stem == "" { // a dot file such as ".bashrc"
			stem, ext = name, ""
		}
	}
	candidate := name
	for n := 2; n <= maxNameAttempts+1; n++ {
		if !claimed[candidate] && !exists(filepath.Join(dir, candidate)) {
			return candidate, nil
		}
		candidate = fmt.Sprintf("%s %d%s", stem, n, ext)
	}
	return "", uploader.ErrNoFreeName
}

// exists reports whether anything, a dangling link included, has this path.
func exists(p string) bool {
	_, err := os.Lstat(p)
	return err == nil || !errors.Is(err, os.ErrNotExist)
}
