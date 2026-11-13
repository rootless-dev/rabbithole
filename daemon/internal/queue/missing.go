package queue

import "errors"

// FinishedFile is a file that finished, in an upload at rest, with what is
// needed to find its object in the bucket.
type FinishedFile struct {
	UploadID  string
	Index     int
	ObjectKey string
	// Inner is the slash path of the file inside the folder it was found in;
	// empty for a file that was handed over directly. The object key ends with
	// it, so what precedes it is the destination of the folder.
	Inner string
}

// FinishedFiles returns the finished files of the uploads of bucket that are
// neither queued nor running nor being changed. Files that finish later are not
// in it.
func (q *Queue) FinishedFiles(bucket string) ([]FinishedFile, error) {
	ids := q.uploadsWithFinishedFiles(bucket)
	q.journal.flush() // the reads must see what these uploads last did
	var out []FinishedFile
	for _, id := range ids {
		files, err := q.store.Files(id)
		if err != nil {
			return nil, err
		}
		for _, f := range files {
			if hasObject(f) {
				out = append(out, finishedFile(f))
			}
		}
	}
	return out, nil
}

// uploadsWithFinishedFiles returns the ids of the uploads of bucket that hold
// finished files and are at rest: not queued, not running, not being changed.
func (q *Queue) uploadsWithFinishedFiles(bucket string) []string {
	q.mu.Lock()
	defer q.mu.Unlock()
	var ids []string
	for _, id := range q.known {
		u := q.uploads[id]
		if u.bucket == bucket && u.snap.FilesFinished > 0 && u.snap.State != Queued && u.snap.State != Uploading && !u.busy {
			ids = append(ids, id)
		}
	}
	return ids
}

func finishedFile(f FileRecord) FinishedFile {
	return FinishedFile{UploadID: f.Snapshot.UploadID, Index: f.Snapshot.Index, ObjectKey: f.Snapshot.ObjectKey, Inner: f.Inner}
}

// ForgetMissing removes from the history the files whose object the bucket
// reported absent, and returns how many it removed. A file is left alone when
// it is no longer finished under the same key, or its upload is now queued,
// running, being changed, removed, or of another bucket. Uploads that lose
// every file are removed; the others are recounted. Failed files stay.
func (q *Queue) ForgetMissing(bucket string, missing []FinishedFile) (int, error) {
	byUpload := map[string]map[FinishedFile]bool{}
	var order []string
	for _, m := range missing {
		if byUpload[m.UploadID] == nil {
			byUpload[m.UploadID] = map[FinishedFile]bool{}
			order = append(order, m.UploadID)
		}
		byUpload[m.UploadID][m] = true
	}

	removed := 0
	for _, id := range order {
		n, err := q.forgetMissingOf(bucket, id, byUpload[id])
		removed += n
		if err != nil {
			return removed, err
		}
	}
	return removed, nil
}

func (q *Queue) forgetMissingOf(bucket, id string, missing map[FinishedFile]bool) (int, error) {
	files, err := q.claim(id, bucket)
	if errors.Is(err, ErrUnknownUpload) || errors.Is(err, ErrUploadActive) || errors.Is(err, ErrOtherBucket) {
		return 0, nil // not ours to touch now
	}
	if err != nil {
		return 0, err
	}
	defer q.release(id)

	var gone []FileRecord
	for _, f := range files {
		if hasObject(f) && missing[finishedFile(f)] {
			gone = append(gone, f)
		}
	}
	if len(gone) == 0 {
		return 0, nil
	}
	if err := q.forget(id, gone, files); err != nil {
		return 0, err
	}
	return len(gone), nil
}
