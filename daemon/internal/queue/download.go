package queue

import (
	"errors"
	"fmt"
	"slices"
)

// ErrNoFinishedFiles means none of the chosen files of an upload finished, so
// there is nothing in the bucket to copy.
var ErrNoFinishedFiles = errors.New("none of the files is finished")

// DownloadFile is a finished file of an upload, as a download needs it.
type DownloadFile struct {
	Index int
	// RelativePath is the file name for a file listed directly, and
	// "<folder name>/<path inside it>" for a file found in a folder. It was
	// built from names on disk and is stored data: callers must not trust it.
	RelativePath string
	ObjectKey    string
	Size         int64
}

// DownloadFiles returns the finished files of upload id that a download may
// copy: those with the listed indexes, or every finished one when indexes is
// empty. A listed file that did not finish is left out. It returns
// ErrUnknownUpload, ErrUnknownFile (an index the upload does not have),
// ErrOtherBucket (an upload sent to a bucket other than bucket) and
// ErrNoFinishedFiles.
func (q *Queue) DownloadFiles(bucket, id string, indexes []int) ([]DownloadFile, error) {
	files, err := q.snapshotsOf(bucket, id)
	if err != nil {
		return nil, err
	}
	chosen, err := chooseSnapshots(files, indexes)
	if err != nil {
		return nil, err
	}
	var out []DownloadFile
	for _, f := range chosen {
		if f.State == Finished && f.ObjectKey != "" {
			out = append(out, DownloadFile{Index: f.Index, RelativePath: f.RelativePath, ObjectKey: f.ObjectKey, Size: f.BytesTotal})
		}
	}
	if len(out) == 0 {
		return nil, ErrNoFinishedFiles
	}
	return out, nil
}

// snapshotsOf returns the file snapshots of an upload of bucket, from memory
// while the upload is queued or running and from the store otherwise.
func (q *Queue) snapshotsOf(bucket, id string) ([]FileSnapshot, error) {
	q.mu.Lock()
	u, ok := q.uploads[id]
	switch {
	case !ok:
		q.mu.Unlock()
		return nil, ErrUnknownUpload
	case u.bucket != bucket:
		q.mu.Unlock()
		return nil, ErrOtherBucket
	case u.files != nil:
		defer q.mu.Unlock()
		return filesSnapshots(u.files), nil
	}
	q.mu.Unlock()

	q.journal.flush() // the read must see what the upload last did
	recs, err := q.store.Files(id)
	if err != nil {
		return nil, fmt.Errorf("load files: %w", err)
	}
	return recordSnapshots(recs), nil
}

// chooseSnapshots returns the snapshots with the listed indexes, in upload
// order, or all of them when none is listed.
func chooseSnapshots(files []FileSnapshot, indexes []int) ([]FileSnapshot, error) {
	if len(indexes) == 0 {
		return files, nil
	}
	known := map[int]bool{}
	for _, f := range files {
		known[f.Index] = true
	}
	wanted := map[int]bool{}
	for _, idx := range indexes {
		if !known[idx] {
			return nil, fmt.Errorf("%w: index %d", ErrUnknownFile, idx)
		}
		wanted[idx] = true
	}
	return slices.DeleteFunc(slices.Clone(files), func(f FileSnapshot) bool { return !wanted[f.Index] }), nil
}
