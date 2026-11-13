package queue

import (
	"context"
	"errors"
	"fmt"

	"rabbithole/daemon/internal/uploader"
)

var (
	// ErrNotPausable means the upload is neither queued nor running.
	ErrNotPausable = errors.New("only a queued or running upload can be paused")
	// ErrNotResumable means the upload was not paused by the user.
	ErrNotResumable = errors.New("only an upload paused by the user can be resumed")
	// ErrNotCancelable means the upload is neither queued, running nor paused.
	ErrNotCancelable = errors.New("only a queued, running or paused upload can be canceled")
)

// stopReason is why a run was stopped before its files were done.
type stopReason int

const (
	stopNone stopReason = iota
	stopPause
	stopCancel
	stopHold
)

// requestStop stops the run for reason. A pause or a cancel takes over from a
// hold that is already stopping the run. It reports whether the run now stops
// for reason; a run that is ending on its own, or for another reason of the
// user, is left alone. The caller holds q.mu.
func (r *run) requestStop(reason stopReason) bool {
	if r.fatal != nil || r.reason != stopNone && !(r.reason == stopHold && reason != stopHold) {
		return false
	}
	first := r.reason == stopNone
	r.reason = reason
	if first {
		r.cancel()
	}
	return true
}

// hasPending reports whether any file of the run still has to be sent. The
// caller holds q.mu.
func (r *run) hasPending() bool {
	for _, f := range r.u.files {
		if f.snap.State == Queued || f.snap.State == Uploading {
			return true
		}
	}
	return false
}

// hasCanceledFiles reports whether any file of the run is canceled, which is
// what is left of a canceled upload when only some of its files were retried.
// The caller holds q.mu.
func (r *run) hasCanceledFiles() bool {
	for _, f := range r.u.files {
		if f.snap.State == Canceled {
			return true
		}
	}
	return false
}

// stopApplies reports whether the stop that was asked for changes how the run
// ends: it does not when every file was done before the request got through.
// The caller holds q.mu.
func (r *run) stopApplies() bool {
	return r.reason != stopNone && r.hasPending()
}

// settleStopped gives the upload and its unfinished files the state their
// stop asks for. The caller holds q.mu.
func (r *run) settleStopped() {
	u := r.u
	switch r.reason {
	case stopPause:
		r.q.markFiles(u, Paused)
		u.snap.State, u.snap.PauseReason = Paused, PausedByUser
	case stopCancel:
		r.q.markFiles(u, Canceled)
		u.snap.State, u.snap.ErrorMessage = Canceled, ""
	case stopHold:
		for _, f := range u.files {
			if f.snap.State == Uploading {
				f.snap.State = Queued
				r.q.publishFile(u, f)
			}
		}
		u.snap.State = Queued
	}
}

// endRun ends the bookkeeping of a run. An upload that a hold stopped keeps its
// files and goes back to the front of the queue; any other leaves memory, and
// its files are read from the store when needed. The caller holds q.mu.
func (q *Queue) endRun(r *run) {
	u := r.u
	u.run, q.running = nil, nil
	if u.snap.State == Queued {
		q.waiting = append([]string{u.snap.ID}, q.waiting...)
		return
	}
	u.files, u.items = nil, nil
}

// markFiles moves every queued or running file of u to state, storing and
// publishing each. The caller holds q.mu.
func (q *Queue) markFiles(u *upload, to State) {
	for _, f := range u.files {
		if f.snap.State == Queued || f.snap.State == Uploading {
			f.snap.State, f.snap.ErrorMessage = to, ""
			q.publishFile(u, f)
			q.persistFile(u, f)
		}
	}
}

// start takes the upload at the head of the queue and makes it the one that
// runs, unless uploads are on hold or none waits.
func (q *Queue) start(ctx context.Context) (*run, bool) {
	q.mu.Lock()
	defer q.mu.Unlock()
	if q.held || len(q.waiting) == 0 {
		return nil, false
	}
	id := q.waiting[0]
	q.waiting = q.waiting[1:]
	u := q.uploads[id]
	u.snap.State = Uploading
	q.publish(u)
	q.persistUpload(u)
	folders := map[int]string{}
	for i, it := range u.items {
		if it.resolved != "" {
			folders[i] = it.resolved
		}
	}

	runCtx, cancel := context.WithCancel(ctx)
	r := &run{q: q, u: u, ctx: runCtx, cancel: cancel, folders: folders, folderErr: map[int]error{}}
	u.run, q.running = r, r
	return r, true
}

// view is the snapshot subscribers see: while uploads are on hold, every queued
// or running upload is shown as paused on hold. The caller holds q.mu.
func (q *Queue) view(u *upload) Snapshot {
	s := u.snap
	if q.held && (s.State == Queued || s.State == Uploading) {
		s.State, s.PauseReason = Paused, PausedOnHold
	}
	return s
}

// fileView is view for one file.
func (q *Queue) fileView(f *fileState) FileSnapshot {
	s := f.snap
	if q.held && (s.State == Queued || s.State == Uploading) {
		s.State = Paused
	}
	return s
}

// fileViews is the snapshot of every file of u as subscribers see them. The
// caller holds q.mu.
func (q *Queue) fileViews(u *upload) []FileSnapshot {
	out := make([]FileSnapshot, 0, len(u.files))
	for _, f := range u.files {
		out = append(out, q.fileView(f))
	}
	return out
}

// SetHold holds every upload, or lets them go on. While held nothing starts;
// the running upload stops, keeping what it sent, and goes back to the head of
// the queue. Every queued or running upload is shown as paused on hold, and
// goes back to queued, in its original order, when the hold ends. The hold is
// not stored.
func (q *Queue) SetHold(held bool) {
	q.mu.Lock()
	defer q.mu.Unlock()
	if q.held == held {
		return
	}
	q.held = held
	if held && q.running != nil {
		q.running.requestStop(stopHold)
	}
	for _, id := range q.known {
		u := q.uploads[id]
		if u.snap.State != Queued && u.snap.State != Uploading {
			continue
		}
		q.publish(u)
		for _, f := range u.files {
			q.publishFile(u, f)
		}
	}
	if !held {
		select {
		case q.wake <- struct{}{}:
		default:
		}
	}
}

// SetSettings gives the queue the settings in force, which it needs to abort
// multipart uploads when an upload is canceled or removed.
func (q *Queue) SetSettings(s uploader.Settings) {
	q.mu.Lock()
	defer q.mu.Unlock()
	q.current = s
}

// controllable returns the upload id when it exists, belongs to bucket and no
// removal is changing its files. The caller holds q.mu.
func (q *Queue) controllable(id, bucket string) (*upload, error) {
	u, ok := q.uploads[id]
	switch {
	case !ok:
		return nil, ErrUnknownUpload
	case u.busy:
		return nil, ErrUploadActive
	case u.bucket != bucket:
		return nil, ErrOtherBucket
	}
	return u, nil
}

// Pause stops the queued or running upload id, keeping what was sent, and
// leaves it paused by the user until Resume. The queue moves on to the next
// upload. A running upload stops as soon as its requests are cancelled.
func (q *Queue) Pause(bucket, id string) error {
	q.mu.Lock()
	defer q.mu.Unlock()
	u, err := q.controllable(id, bucket)
	if err != nil {
		return err
	}
	switch u.snap.State {
	case Uploading:
		if u.run == nil || !u.run.requestStop(stopPause) {
			return ErrNotPausable
		}
	case Queued:
		q.waiting = sortedWithout(q.waiting, id)
		q.markFiles(u, Paused)
		u.snap.State, u.snap.PauseReason = Paused, PausedByUser
		q.publish(u)
		q.persistUpload(u)
		u.files, u.items = nil, nil
	default:
		return ErrNotPausable
	}
	return nil
}

// Resume puts an upload the user paused back at the end of the queue, using s.
// Its finished files are not sent again; the others continue where they
// stopped.
func (q *Queue) Resume(s uploader.Settings, id string) error {
	if err := q.checkResumable(s.Bucket, id); err != nil {
		return err
	}
	q.journal.flush() // the reads must see what the upload recorded
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
	if err := q.checkResumableLocked(s.Bucket, id); err != nil {
		return err
	}
	chosen := map[int]bool{}
	for _, f := range files {
		if f.Snapshot.State == Paused {
			chosen[f.Snapshot.Index] = true
		}
	}
	q.requeue(q.uploads[id], s, items, files, chosen, parts)
	select {
	case q.wake <- struct{}{}:
	default:
	}
	return nil
}

func (q *Queue) checkResumable(bucket, id string) error {
	q.mu.Lock()
	defer q.mu.Unlock()
	return q.checkResumableLocked(bucket, id)
}

func (q *Queue) checkResumableLocked(bucket, id string) error {
	u, err := q.controllable(id, bucket)
	switch {
	case err != nil:
		return err
	case u.snap.State != Paused || u.snap.PauseReason != PausedByUser:
		return ErrNotResumable
	}
	return nil
}

// Cancel stops the queued, running or paused upload id for good. Its files that
// did not finish become canceled, and its multipart uploads are aborted;
// finished files stay finished. A running upload stops as soon as its requests
// are cancelled, and ends as canceled a moment later.
func (q *Queue) Cancel(bucket, id string) error {
	q.mu.Lock()
	u, err := q.controllable(id, bucket)
	if err != nil {
		q.mu.Unlock()
		return err
	}
	switch u.snap.State {
	case Uploading:
		stopped := u.run != nil && u.run.requestStop(stopCancel)
		q.mu.Unlock()
		if !stopped {
			return ErrNotCancelable
		}
		return nil // the run aborts the multipart uploads when it has stopped
	case Queued:
		q.waiting = sortedWithout(q.waiting, id)
		q.markFiles(u, Canceled)
		q.settleCanceled(u)
		u.files, u.items = nil, nil
		q.mu.Unlock()
	case Paused:
		q.mu.Unlock()
		if err := q.cancelPaused(bucket, id); err != nil {
			return err
		}
	default:
		q.mu.Unlock()
		return ErrNotCancelable
	}
	q.abortOf(id)
	return nil
}

// settleCanceled makes u a canceled upload. The caller holds q.mu.
func (q *Queue) settleCanceled(u *upload) {
	u.snap.State, u.snap.PauseReason, u.snap.ErrorMessage = Canceled, NotPaused, ""
	u.snap.EndedAt = q.now()
	q.publish(u)
	q.persistUpload(u)
}

// cancelPaused cancels an upload at rest, whose files are in the store.
func (q *Queue) cancelPaused(bucket, id string) error {
	q.journal.flush()
	files, err := q.store.Files(id)
	if err != nil {
		return fmt.Errorf("load files: %w", err)
	}

	q.mu.Lock()
	defer q.mu.Unlock()
	u, err := q.controllable(id, bucket)
	switch {
	case err != nil:
		return err
	case u.snap.State != Paused:
		return ErrNotCancelable
	}
	for _, rec := range files {
		if rec.Snapshot.State != Paused {
			continue
		}
		rec.Snapshot.State = Canceled
		q.journal.fileChanged(rec)
		for sub := range q.fileSubs[id] {
			sub.push(rec.Snapshot)
		}
	}
	q.settleCanceled(u)
	return nil
}

// ResumeInterrupted puts back in the queue, as Retry would, every upload of
// s.Bucket that the start-up marked as interrupted, and returns how many it
// put back. Uploads that fail to go back are logged and left failed.
func (q *Queue) ResumeInterrupted(s uploader.Settings) int {
	q.mu.Lock()
	var ids []string
	for _, id := range q.known {
		u := q.uploads[id]
		if u.bucket == s.Bucket && u.snap.State == Failed && u.snap.ErrorMessage == InterruptedMessage {
			ids = append(ids, id)
		}
	}
	q.mu.Unlock()

	resumed := 0
	for _, id := range ids {
		if err := q.Retry(s, id, nil); err != nil {
			q.journal.log.Warn("could not resume interrupted upload", "upload_id", id, "error", err.Error())
			continue
		}
		resumed++
	}
	return resumed
}
