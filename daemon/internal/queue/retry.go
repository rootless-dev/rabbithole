package queue

import (
	"errors"
	"fmt"
	"time"

	"rabbithole/daemon/internal/uploader"
)

var (
	// ErrUnknownFile means the upload has no file with a given index.
	ErrUnknownFile = errors.New("unknown file")
	// ErrUploadNotFailed means the upload is neither failed nor canceled.
	ErrUploadNotFailed = errors.New("upload did not fail")
	// ErrFileNotFailed means a file that was asked for neither failed nor was
	// canceled.
	ErrFileNotFailed = errors.New("file did not fail")
	// ErrUploadPaused means the upload is paused, so it cannot be removed.
	ErrUploadPaused = errors.New("upload is paused")
	// ErrOtherBucket means the upload was sent to a bucket other than the
	// configured one.
	ErrOtherBucket = errors.New("upload belongs to another bucket")
	// ErrUploadActive means the upload is queued or running.
	ErrUploadActive = errors.New("upload is queued or running")
)

// Retry sends failed files of the failed or canceled upload id again, inside the
// same upload, using s. Without indexes it retries every failed or canceled
// file; with indexes, exactly those files, and each must have failed or been
// canceled. The upload goes back to the end of the queue; files that finished
// are not sent again, and a multipart file continues where it stopped.
func (q *Queue) Retry(s uploader.Settings, id string, indexes []int) error {
	if err := q.checkRetryable(s, id); err != nil {
		return err
	}

	// Read outside the lock, after what the upload recorded is stored.
	q.journal.flush()
	items, err := q.store.Items(id)
	if err != nil {
		return fmt.Errorf("load items: %w", err)
	}
	files, err := q.store.Files(id)
	if err != nil {
		return fmt.Errorf("load files: %w", err)
	}
	parts, err := q.store.Multiparts(id)
	if err != nil {
		return fmt.Errorf("load multipart records: %w", err)
	}

	q.mu.Lock()
	defer q.mu.Unlock()
	if err := q.checkRetryableLocked(s, id); err != nil {
		return err // the upload changed while its files were being read
	}
	chosen, err := chooseFailed(files, indexes)
	if err != nil {
		return err
	}
	q.requeue(q.uploads[id], s, items, files, chosen, parts)
	select {
	case q.wake <- struct{}{}:
	default:
	}
	return nil
}

func (q *Queue) checkRetryable(s uploader.Settings, id string) error {
	q.mu.Lock()
	defer q.mu.Unlock()
	return q.checkRetryableLocked(s, id)
}

func (q *Queue) checkRetryableLocked(s uploader.Settings, id string) error {
	u, ok := q.uploads[id]
	switch {
	case !ok:
		return ErrUnknownUpload
	case u.busy:
		return ErrUploadActive
	case u.snap.State != Failed && u.snap.State != Canceled:
		return ErrUploadNotFailed
	case u.bucket != s.Bucket:
		return ErrOtherBucket
	}
	return nil
}

// chooseFailed returns the indexes of the files to send again: the listed
// ones, or every failed or canceled one when none is listed.
func chooseFailed(files []FileRecord, indexes []int) (map[int]bool, error) {
	chosen := map[int]bool{}
	state := map[int]State{} // by file index, which is not always the position
	for _, f := range files {
		state[f.Snapshot.Index] = f.Snapshot.State
		if len(indexes) == 0 && retryable(f.Snapshot.State) {
			chosen[f.Snapshot.Index] = true
		}
	}
	for _, idx := range indexes {
		st, ok := state[idx]
		switch {
		case !ok:
			return nil, fmt.Errorf("%w: index %d", ErrUnknownFile, idx)
		case !retryable(st):
			return nil, fmt.Errorf("%w: index %d", ErrFileNotFailed, idx)
		}
		chosen[idx] = true
	}
	return chosen, nil
}

// retryable reports whether a file in state is sent again by a retry.
func retryable(state State) bool { return state == Failed || state == Canceled }

// requeue puts the chosen files back in the queue and the upload at its end.
// parts are the multipart records of the files, by index, that the chosen
// files continue from. The caller holds q.mu.
func (q *Queue) requeue(u *upload, s uploader.Settings, items []ItemRecord, files []FileRecord, chosen map[int]bool, parts map[int]uploader.Multipart) {
	keepResolved := u.prefix == s.Prefix
	u.settings, u.region, u.prefix = s, s.Region, s.Prefix
	u.items = restoreItems(items, keepResolved)
	u.files = restoreFiles(files, chosen, parts)
	// The key of a single file is set again when the file is sent, and the key
	// prefix of a folder when it is resolved again.
	if u.snap.Kind == SingleFile || u.snap.Kind == Folder && u.items[0].resolved == "" {
		u.snap.ObjectKey = ""
	}

	u.snap.FilesFinished, u.snap.FilesFailed, u.snap.BytesSent = 0, 0, 0
	for _, f := range u.files {
		u.snap.BytesSent += f.snap.BytesSent
		switch f.snap.State {
		case Finished:
			u.snap.FilesFinished++
		case Failed:
			u.snap.FilesFailed++
		}
	}
	u.snap.State, u.snap.PauseReason, u.snap.ErrorMessage, u.snap.EndedAt = Queued, NotPaused, "", time.Time{}

	q.waiting = append(q.waiting, u.snap.ID)
	q.publish(u)
	q.persistUpload(u)
	for _, f := range u.files {
		if chosen[f.snap.Index] {
			q.persistFile(u, f)
			q.publishFile(u, f)
		}
	}
}

func restoreItems(recs []ItemRecord, keepResolved bool) []item {
	items := make([]item, len(recs))
	for i, r := range recs {
		items[i] = item{path: r.Path, isDir: r.IsDir, destName: r.DestName}
		if keepResolved {
			items[i].resolved = r.Resolved
		}
	}
	return items
}

// restoreFiles rebuilds the in-memory files of an upload; the chosen ones go
// back to the queue with nothing sent, and carry the multipart record in parts
// they continue from.
func restoreFiles(recs []FileRecord, chosen map[int]bool, parts map[int]uploader.Multipart) []*fileState {
	files := make([]*fileState, len(recs))
	for i, r := range recs {
		f := &fileState{
			snap: r.Snapshot,
			plan: plannedFile{
				item:         r.Item,
				inner:        r.Inner,
				local:        r.Snapshot.LocalPath,
				size:         r.Snapshot.BytesTotal,
				relativePath: r.Snapshot.RelativePath,
				unreadable:   r.Unreadable,
			},
		}
		if chosen[r.Snapshot.Index] {
			f.snap.State, f.snap.ErrorMessage, f.snap.ObjectKey, f.snap.BytesSent = Queued, "", "", 0
			if m, ok := parts[r.Snapshot.Index]; ok {
				f.multipart = &m
			}
		}
		files[i] = f
	}
	return files
}

// Discard removes an upload that is not queued or running from the queue and
// the store, and tells every subscriber that sees it with a removed snapshot.
func (q *Queue) Discard(id string) error {
	q.mu.Lock()
	u, ok := q.uploads[id]
	switch {
	case !ok:
		q.mu.Unlock()
		return ErrUnknownUpload
	case u.snap.State == Paused:
		q.mu.Unlock()
		return ErrUploadPaused
	case u.snap.State == Queued || u.snap.State == Uploading:
		q.mu.Unlock()
		return ErrUploadActive
	}
	delete(q.uploads, id)
	q.known = sortedWithout(q.known, id)
	if q.visible(u) {
		snap := u.snap
		snap.Removed = true
		q.pushToSubs(snap)
	}
	q.mu.Unlock()

	if err := q.store.DeleteUpload(id); err != nil {
		return fmt.Errorf("delete upload: %w", err)
	}
	return nil
}
