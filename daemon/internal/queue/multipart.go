package queue

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"time"

	"rabbithole/daemon/internal/uploader"
)

// abortAllTimeout bounds how long canceling an upload spends aborting its
// multipart uploads.
const abortAllTimeout = 30 * time.Second

// ErrMultipartAbort means a multipart upload left in the bucket could not be
// aborted. The files it belongs to are kept in the history, so that it can be
// aborted later.
var ErrMultipartAbort = errors.New("could not abort an unfinished multipart upload")

// MultipartAborter is implemented by a Runner that can abort a multipart upload
// in the bucket of s. Without it canceling or removing an upload leaves its
// multipart uploads, and their records, where they are.
type MultipartAborter interface {
	AbortMultipart(ctx context.Context, s uploader.Settings, key, uploadID string) error
}

// multipartCallbacks returns the callbacks that keep the multipart record of f,
// in memory and in the store, up to date.
func (r *run) multipartCallbacks(f *fileState) uploader.Callbacks {
	return uploader.Callbacks{
		MultipartRecorded: func(m uploader.Multipart) { r.multipartRecorded(f, m) },
		PartDone:          func(p uploader.CompletedPart) { r.partDone(f, p) },
		MultipartEnded:    func() { r.multipartEnded(f) },
	}
}

// multipartRecorded stores the record of a multipart upload that starts, or
// that adopted the parts S3 reported. It returns once the record is on disk:
// no part may be sent before a record exists that can abort the upload.
func (r *run) multipartRecorded(f *fileState, m uploader.Multipart) {
	q := r.q
	q.mu.Lock()
	f.multipart = &m
	rec := m
	q.journal.multipartChanged(r.u.snap.ID, f.snap.Index, &rec)
	q.mu.Unlock()
	q.journal.flush()
}

func (r *run) partDone(f *fileState, p uploader.CompletedPart) {
	q := r.q
	q.mu.Lock()
	defer q.mu.Unlock()
	if f.multipart == nil {
		return
	}
	next := *f.multipart
	next.Parts = append(slices.Clone(next.Parts), p)
	f.multipart = &next
	rec := next
	q.journal.multipartChanged(r.u.snap.ID, f.snap.Index, &rec)
}

func (r *run) multipartEnded(f *fileState) {
	q := r.q
	q.mu.Lock()
	defer q.mu.Unlock()
	f.multipart = nil
	q.journal.multipartChanged(r.u.snap.ID, f.snap.Index, nil)
}

// abortOf aborts every multipart upload recorded for the files of upload id,
// within abortAllTimeout, and keeps the records of the ones it could not abort.
func (q *Queue) abortOf(id string) {
	ctx, cancel := context.WithTimeout(context.Background(), abortAllTimeout)
	defer cancel()
	for idx, err := range q.abortRecords(ctx, id, nil) {
		q.journal.log.Warn("could not abort multipart upload", "upload_id", id, "file_index", idx, "reason", uploader.Message(err))
	}
}

// abortRecords aborts the multipart uploads recorded for the files of upload id
// whose index is in only (all of them when only is nil) and clears each record
// it aborted, or whose upload S3 no longer knows. It returns the error of each
// file whose upload could not be aborted, keeping that file's record.
func (q *Queue) abortRecords(ctx context.Context, id string, only map[int]bool) map[int]error {
	aborter, ok := q.runner.(MultipartAborter)
	if !ok {
		return nil
	}
	q.mu.Lock()
	settings := q.current
	q.mu.Unlock()

	q.journal.flush() // the records on disk are the whole truth
	records, err := q.store.Multiparts(id)
	if err != nil {
		q.journal.log.Warn("could not read multipart records", "upload_id", id, "error", err.Error())
		return nil
	}
	failed := map[int]error{}
	for idx, m := range records {
		if only != nil && !only[idx] {
			continue
		}
		err := aborter.AbortMultipart(ctx, settings, m.Key, m.UploadID)
		if err != nil && !errors.Is(err, uploader.ErrNoSuchUpload) {
			failed[idx] = err
			continue
		}
		q.journal.multipartChanged(id, idx, nil)
	}
	q.journal.flush()
	return failed
}

// abortRemoved aborts the multipart uploads of the files about to be removed
// from the history and returns the files that can go. A file whose multipart
// upload could not be aborted stays, so the upload can be aborted later; the
// error says so.
func (q *Queue) abortRemoved(ctx context.Context, id string, chosen []FileRecord) ([]FileRecord, error) {
	only := make(map[int]bool, len(chosen))
	for _, f := range chosen {
		if f.Snapshot.State != Finished {
			only[f.Snapshot.Index] = true
		}
	}
	failed := q.abortRecords(ctx, id, only)
	if len(failed) == 0 {
		return chosen, nil
	}
	var first error
	for _, err := range failed {
		first = err
		break
	}
	kept := slices.DeleteFunc(slices.Clone(chosen), func(f FileRecord) bool {
		_, bad := failed[f.Snapshot.Index]
		return bad
	})
	return kept, fmt.Errorf("%w: %w", ErrMultipartAbort, first)
}
