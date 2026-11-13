package queue

import (
	"context"
	"fmt"
	"slices"
)

// DeleteFunc deletes objects from the bucket by exact key. It returns the keys
// that are gone; when it fails part-way these are the ones deleted before.
type DeleteFunc func(ctx context.Context, keys []string) (deleted []string, err error)

// Remove takes files of the upload id out of the history: the listed ones, or
// every file when indexes is empty. The upload keeps the files that remain,
// with its counters, byte totals and state recomputed; when none remains the
// upload goes too. Subscribers see a removed snapshot for each file removed
// and for the upload when it goes, otherwise a normal snapshot of the upload.
//
// With del, the objects of the finished files are deleted first, by the exact
// key recorded for each, and only the files whose object is gone are forgotten;
// if del fails, those files stay and its error is returned after the others
// have been forgotten. Without del nothing outside the history is touched.
//
// It refuses an upload that is queued or running (ErrUploadActive), one sent to
// a bucket other than bucket (ErrOtherBucket), an unknown upload
// (ErrUnknownUpload) and an unknown index (ErrUnknownFile).
func (q *Queue) Remove(ctx context.Context, bucket, id string, indexes []int, del DeleteFunc) error {
	files, err := q.claim(id, bucket)
	if err != nil {
		return err
	}
	defer q.release(id)

	chosen, err := chooseFiles(files, indexes)
	if err != nil {
		return err
	}
	if del == nil {
		return q.forget(id, chosen, files)
	}
	forgotten, deleteErr := deleteObjects(ctx, del, chosen)
	if err := q.forget(id, forgotten, files); err != nil {
		return err
	}
	return deleteErr
}

// claim marks the upload as busy, so that nothing else changes its files while
// they are removed, and returns its files. The upload must be at rest and
// belong to bucket. The caller releases it.
func (q *Queue) claim(id, bucket string) ([]FileRecord, error) {
	q.mu.Lock()
	err := q.claimLocked(id, bucket)
	q.mu.Unlock()
	if err != nil {
		return nil, err
	}

	q.journal.flush() // the read must see what the upload last did
	files, err := q.store.Files(id)
	if err != nil {
		q.release(id)
		return nil, fmt.Errorf("load files: %w", err)
	}
	return files, nil
}

func (q *Queue) claimLocked(id, bucket string) error {
	u, ok := q.uploads[id]
	switch {
	case !ok:
		return ErrUnknownUpload
	case u.snap.State == Queued || u.snap.State == Uploading || u.busy:
		return ErrUploadActive
	case u.bucket != bucket:
		return ErrOtherBucket
	}
	u.busy = true
	return nil
}

func (q *Queue) release(id string) {
	q.mu.Lock()
	defer q.mu.Unlock()
	if u, ok := q.uploads[id]; ok {
		u.busy = false
	}
}

// chooseFiles returns the files with the listed indexes, in upload order, or
// every file when none is listed.
func chooseFiles(files []FileRecord, indexes []int) ([]FileRecord, error) {
	if len(indexes) == 0 {
		return files, nil
	}
	known := indexSet(files) // by file index, which is not always the position
	wanted := make(map[int]bool, len(indexes))
	for _, idx := range indexes {
		if !known[idx] {
			return nil, fmt.Errorf("%w: index %d", ErrUnknownFile, idx)
		}
		wanted[idx] = true
	}
	return slices.DeleteFunc(slices.Clone(files), func(f FileRecord) bool {
		return !wanted[f.Snapshot.Index]
	}), nil
}

// indexSet returns the file indexes of files as a set, so that looking one up
// does not depend on how many files an upload has.
func indexSet(files []FileRecord) map[int]bool {
	set := make(map[int]bool, len(files))
	for _, f := range files {
		set[f.Snapshot.Index] = true
	}
	return set
}

// deleteObjects deletes the objects of the finished files among chosen and
// returns the files to forget: when del succeeds every chosen file, otherwise
// those whose object is gone. A file that never finished has no object.
func deleteObjects(ctx context.Context, del DeleteFunc, chosen []FileRecord) ([]FileRecord, error) {
	var keys []string
	for _, f := range chosen {
		if hasObject(f) {
			keys = append(keys, f.Snapshot.ObjectKey)
		}
	}
	if len(keys) == 0 {
		return chosen, nil
	}
	deleted, err := del(ctx, keys)
	if err == nil {
		return chosen, nil
	}
	gone := map[string]bool{}
	for _, k := range deleted {
		gone[k] = true
	}
	var forgotten []FileRecord
	for _, f := range chosen {
		if hasObject(f) && gone[f.Snapshot.ObjectKey] {
			forgotten = append(forgotten, f)
		}
	}
	return forgotten, err
}

// hasObject reports whether the file left an object in the bucket.
func hasObject(f FileRecord) bool {
	return f.Snapshot.State == Finished && f.Snapshot.ObjectKey != ""
}

// forget removes the files from the stored upload, and from what subscribers
// see. all is every file the upload has. The upload must be claimed.
func (q *Queue) forget(id string, forgotten, all []FileRecord) error {
	gone := indexSet(forgotten)
	remaining := slices.DeleteFunc(slices.Clone(all), func(f FileRecord) bool {
		return gone[f.Snapshot.Index]
	})
	if len(forgotten) == 0 && len(remaining) > 0 {
		return nil
	}

	q.mu.Lock()
	rec := recordOf(q.uploads[id])
	q.mu.Unlock()
	rec.Snapshot = recount(rec.Snapshot, remaining)

	// The store first, so a failed write leaves what subscribers see unchanged.
	if err := q.storeRemoval(id, rec, forgotten, len(remaining) == 0); err != nil {
		return err
	}

	q.mu.Lock()
	defer q.mu.Unlock()
	u := q.uploads[id]
	if len(remaining) == 0 {
		delete(q.uploads, id)
		q.known = sortedWithout(q.known, id)
		rec.Snapshot.Removed = true
		if q.visible(u) {
			q.pushToSubs(rec.Snapshot)
		}
	} else {
		u.snap = rec.Snapshot
		q.publish(u)
	}
	for _, f := range forgotten {
		snap := f.Snapshot
		snap.Removed = true
		for sub := range q.fileSubs[id] {
			sub.push(snap)
		}
	}
	return nil
}

func (q *Queue) storeRemoval(id string, rec UploadRecord, forgotten []FileRecord, whole bool) error {
	if whole {
		if err := q.store.DeleteUpload(id); err != nil {
			return fmt.Errorf("delete upload: %w", err)
		}
		return nil
	}
	indexes := make([]int, len(forgotten))
	for i, f := range forgotten {
		indexes[i] = f.Snapshot.Index
	}
	if err := q.store.DeleteFiles(id, indexes); err != nil {
		return fmt.Errorf("delete files: %w", err)
	}
	if err := q.store.Save(Changes{Uploads: []UploadRecord{rec}}); err != nil {
		return fmt.Errorf("save upload: %w", err)
	}
	return nil
}

// failedFilesMessage is the error message of an upload with several files of
// which some could not be sent.
func failedFilesMessage(failed, total int) string {
	return fmt.Sprintf("%d of %d files could not be sent", failed, total)
}

// recount returns old with its file counters, byte totals and state recomputed
// from the files that remain, all of which are at rest. An upload with no
// failed file is finished. A failed one keeps its error message, unless that
// message only counted the files, in which case it counts them again.
func recount(old Snapshot, remaining []FileRecord) Snapshot {
	next := old
	next.FilesTotal, next.FilesFinished, next.FilesFailed = len(remaining), 0, 0
	next.BytesTotal, next.BytesSent = 0, 0
	for _, f := range remaining {
		next.BytesTotal += f.Snapshot.BytesTotal
		next.BytesSent += f.Snapshot.BytesSent
		switch f.Snapshot.State {
		case Finished:
			next.FilesFinished++
		case Failed:
			next.FilesFailed++
		}
	}
	switch {
	case next.FilesFailed == 0:
		next.State, next.ErrorMessage = Finished, ""
		next.BytesSent = next.BytesTotal
	case old.ErrorMessage == failedFilesMessage(old.FilesFailed, old.FilesTotal):
		next.State, next.ErrorMessage = Failed, failedFilesMessage(next.FilesFailed, next.FilesTotal)
	default:
		next.State = Failed
	}
	return next
}
