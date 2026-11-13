// Package queue holds the in-memory upload queue: first in, first out, one
// upload at a time, nothing persisted. An upload holds one or more files, sent
// in parallel. The queue publishes a snapshot of an upload, and of each of its
// files, to subscribers whenever they change.
package queue

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"path"
	"sync"
	"time"

	"rabbithole/daemon/internal/uploader"
)

// minProgressInterval is the shortest time between two progress snapshots of
// the same upload, or of the same file: at most 10 per second.
const minProgressInterval = 100 * time.Millisecond

var (
	// ErrInvalidPath means a path is missing, or is neither a regular readable
	// file nor a folder.
	ErrInvalidPath = errors.New("path is not a regular readable file or a folder")
	// ErrUnknownUpload means no upload has the given id.
	ErrUnknownUpload = errors.New("unknown upload")
)

// State is where an upload, or one of its files, is in its life.
type State int

const (
	Queued State = iota
	Uploading
	Finished
	Failed
)

// Snapshot is the state of one upload at one moment.
type Snapshot struct {
	ID        string
	FileName  string // base name of the first path
	LocalPath string // the first path
	// ObjectKey is the key of a single file; the key prefix, ending in "/", of a
	// folder; empty for several items and while nothing is resolved.
	ObjectKey     string
	BytesTotal    int64 // sum over the files
	BytesSent     int64
	State         State
	ErrorMessage  string
	Kind          Kind
	RootPaths     []string // every path the upload was enqueued with, in order
	FilesTotal    int
	FilesFinished int
	FilesFailed   int
	// Removed marks the last snapshot of an upload that left the history or
	// belongs to a bucket that is no longer the configured one.
	Removed   bool
	CreatedAt time.Time
	EndedAt   time.Time // zero while the upload has not ended
}

// FileSnapshot is the state of one file of an upload at one moment.
type FileSnapshot struct {
	UploadID string
	Index    int
	// RelativePath is the file name for a file listed directly, and
	// "<folder name>/<path inside it>" for a file found in a folder.
	RelativePath string
	LocalPath    string
	ObjectKey    string
	BytesTotal   int64
	BytesSent    int64
	State        State
	ErrorMessage string
	// Removed marks the last snapshot of a file that left its upload.
	Removed bool
}

// Runner performs the upload of one file.
type Runner interface {
	Run(ctx context.Context, s uploader.Settings, req uploader.Request, cb uploader.Callbacks) error
}

// FolderResolver is implemented by a Runner that can look at the destination to
// choose the name a folder lands under. Without it a folder keeps its own name
// and its files rely on the conditional write alone.
type FolderResolver interface {
	ResolveFolder(ctx context.Context, s uploader.Settings, name string) (string, error)
}

type fileState struct {
	snap        FileSnapshot
	plan        plannedFile
	lastPublish time.Time
}

type upload struct {
	snap        Snapshot
	settings    uploader.Settings
	bucket      string
	region      string
	prefix      string
	lastPublish time.Time
	parallel    int

	// items and files are kept only while the upload is queued or running; once
	// it ends they are read from the store when needed.
	items []item
	files []*fileState
}

// Queue runs enqueued uploads one after another and publishes snapshots.
type Queue struct {
	runner  Runner
	now     func() time.Time
	wake    chan struct{} // capacity 1: signals Run that work may be waiting
	store   Store
	journal *journal

	mu       sync.Mutex
	uploads  map[string]*upload
	known    []string // upload IDs in enqueue order
	waiting  []string // IDs not started yet, in FIFO order
	subs     map[*uploadSub]struct{}
	fileSubs map[string]map[*fileSub]struct{} // by upload ID
	// filtered is set by SetBucket: from then on subscribers see only the
	// uploads of bucket.
	filtered bool
	bucket   string
}

type (
	uploadSub = subscriber[string, Snapshot]
	fileSub   = subscriber[int, FileSnapshot]
)

// Option changes how New builds a Queue.
type Option func(*Queue)

// WithStore makes the queue keep its uploads in s, and report a failed write
// to log. Without it uploads live in memory only.
func WithStore(s Store, log Logger) Option {
	return func(q *Queue) {
		q.store = s
		q.journal = newJournal(s, log)
	}
}

// New returns a Queue that runs uploads with r and reads the time from now.
func New(r Runner, now func() time.Time, opts ...Option) *Queue {
	q := &Queue{
		runner:   r,
		now:      now,
		wake:     make(chan struct{}, 1),
		uploads:  make(map[string]*upload),
		subs:     make(map[*uploadSub]struct{}),
		fileSubs: make(map[string]map[*fileSub]struct{}),
	}
	WithStore(newMemStore(), nopLogger{})(q)
	for _, opt := range opts {
		opt(q)
	}
	return q
}

// Restore loads the stored uploads. An upload that was queued or running when
// the daemon last stopped was cut off: it becomes failed, with the files that
// had not finished. Call it before Run and before any subscriber arrives.
func (q *Queue) Restore() error {
	if err := q.store.FailInterrupted(InterruptedMessage, q.now()); err != nil {
		return fmt.Errorf("fail interrupted uploads: %w", err)
	}
	recs, err := q.store.Uploads()
	if err != nil {
		return fmt.Errorf("load uploads: %w", err)
	}
	q.mu.Lock()
	defer q.mu.Unlock()
	for _, rec := range recs {
		id := rec.Snapshot.ID
		q.uploads[id] = &upload{
			snap: rec.Snapshot, bucket: rec.Bucket, region: rec.Region, prefix: rec.Prefix, parallel: rec.Parallel,
		}
		q.known = append(q.known, id)
	}
	return nil
}

// SetBucket makes bucket the one whose uploads subscribers see. Every
// subscriber gets a removed snapshot for each upload of the bucket that was
// current before, then a snapshot of each upload of the new one.
func (q *Queue) SetBucket(bucket string) {
	q.mu.Lock()
	defer q.mu.Unlock()
	was, old := q.filtered, q.bucket
	if was && old == bucket {
		return
	}
	q.filtered, q.bucket = true, bucket
	for _, id := range q.known {
		if u := q.uploads[id]; was && u.bucket == old {
			snap := u.snap
			snap.Removed = true
			q.pushToSubs(snap)
		}
	}
	for _, id := range q.known {
		if u := q.uploads[id]; u.bucket == bucket {
			q.pushToSubs(u.snap)
		}
	}
}

// visible reports whether subscribers see u. The caller holds q.mu.
func (q *Queue) visible(u *upload) bool {
	return !q.filtered || u.bucket == q.bucket
}

func (q *Queue) pushToSubs(s Snapshot) {
	for sub := range q.subs {
		sub.push(s)
	}
}

// Enqueue adds an upload to the queue, capturing s for it. The whole file plan
// is built before it returns: file names and sizes are taken from disk now.
func (q *Queue) Enqueue(s uploader.Settings, req EnqueueRequest) (string, error) {
	p, err := buildPlan(req)
	if err != nil {
		return "", err
	}
	id, err := newID()
	if err != nil {
		return "", err
	}

	u := &upload{
		settings: s,
		bucket:   s.Bucket,
		region:   s.Region,
		prefix:   s.Prefix,
		items:    p.items,
		parallel: clampParallel(req.ParallelFiles),
		snap: Snapshot{
			ID:         id,
			FileName:   baseName(p.items[0].path),
			LocalPath:  p.items[0].path,
			State:      Queued,
			Kind:       p.kind,
			FilesTotal: len(p.files),
			CreatedAt:  q.now(),
		},
	}
	for _, it := range p.items {
		u.snap.RootPaths = append(u.snap.RootPaths, it.path)
	}
	for i, pf := range p.files {
		u.snap.BytesTotal += pf.size
		u.files = append(u.files, &fileState{plan: pf, snap: FileSnapshot{
			UploadID:     id,
			Index:        i,
			RelativePath: pf.relativePath,
			LocalPath:    pf.local,
			BytesTotal:   pf.size,
			State:        Queued,
		}})
	}

	// Stored before the upload can run, in one step and outside the lock, so
	// a plan of tens of thousands of files never holds up the subscribers.
	if err := q.store.CreateUpload(recordOf(u), itemRecords(u.items), fileRecords(u.files)); err != nil {
		q.journal.log.Warn("could not save upload history", "upload_id", id, "error", err.Error())
	}

	q.mu.Lock()
	q.uploads[id] = u
	q.known = append(q.known, id)
	q.waiting = append(q.waiting, id)
	q.publish(u)
	q.mu.Unlock()

	select {
	case q.wake <- struct{}{}:
	default:
	}
	return id, nil
}

// Subscribe returns one snapshot per known upload, then a channel of later
// changes. A subscriber that reads slowly never blocks the queue: the queue
// keeps only the latest pending snapshot per upload for it, so the final
// state of every upload still arrives. The channel is closed by cancel only.
func (q *Queue) Subscribe() (initial []Snapshot, updates <-chan Snapshot, cancel func()) {
	sub := newSubscriber(func(s Snapshot) string { return s.ID })

	q.mu.Lock()
	initial = make([]Snapshot, 0, len(q.known))
	for _, id := range q.known {
		if u := q.uploads[id]; q.visible(u) {
			initial = append(initial, u.snap)
		}
	}
	q.subs[sub] = struct{}{}
	q.mu.Unlock()

	go sub.pump()

	return initial, sub.out, func() {
		q.mu.Lock()
		delete(q.subs, sub)
		q.mu.Unlock()
		sub.stop()
	}
}

// SubscribeFiles is Subscribe for the files of one upload, whatever its bucket.
// The files of an upload that is not queued or running are read from the
// store. It returns ErrUnknownUpload when no upload has that id.
func (q *Queue) SubscribeFiles(id string) (initial []FileSnapshot, updates <-chan FileSnapshot, cancel func(), err error) {
	sub := newSubscriber(func(s FileSnapshot) int { return s.Index })

	var stored []FileRecord
	for {
		q.mu.Lock()
		u, ok := q.uploads[id]
		switch {
		case !ok:
			q.mu.Unlock()
			return nil, nil, nil, ErrUnknownUpload
		case u.files != nil:
			initial = filesSnapshots(u.files)
		case stored != nil:
			initial = recordSnapshots(stored)
		}
		if initial != nil {
			break // still holding q.mu
		}
		q.mu.Unlock()

		// Outside the lock: a read from disk must not hold up the queue. The
		// journal is flushed first so the read sees what the upload just did.
		q.journal.flush()
		if stored, err = q.store.Files(id); err != nil {
			return nil, nil, nil, fmt.Errorf("load files: %w", err)
		}
		if stored == nil {
			stored = []FileRecord{}
		}
	}
	if q.fileSubs[id] == nil {
		q.fileSubs[id] = make(map[*fileSub]struct{})
	}
	q.fileSubs[id][sub] = struct{}{}
	q.mu.Unlock()

	go sub.pump()

	return initial, sub.out, func() {
		q.mu.Lock()
		delete(q.fileSubs[id], sub)
		q.mu.Unlock()
		sub.stop()
	}, nil
}

// Run processes the queue in order until ctx is cancelled and the current
// upload has stopped.
func (q *Queue) Run(ctx context.Context) {
	stopWriter := make(chan struct{})
	writerDone := make(chan struct{})
	go func() {
		defer close(writerDone)
		q.journal.loop(stopWriter)
	}()
	defer func() {
		close(stopWriter)
		<-writerDone // what the last upload recorded is stored before Run returns
	}()

	for ctx.Err() == nil {
		id, ok := q.next()
		if !ok {
			select {
			case <-q.wake:
			case <-ctx.Done():
			}
			continue
		}
		q.process(ctx, id)
	}
}

func (q *Queue) next() (string, bool) {
	q.mu.Lock()
	defer q.mu.Unlock()
	if len(q.waiting) == 0 {
		return "", false
	}
	id := q.waiting[0]
	q.waiting = q.waiting[1:]
	return id, true
}

// run holds what the workers of one upload share.
type run struct {
	q      *Queue
	u      *upload
	ctx    context.Context
	cancel context.CancelFunc

	// Guarded by q.mu.
	folders   map[int]string // item index -> resolved folder name
	folderErr map[int]error  // item index -> why its folder could not be resolved
	fatal     error          // first error that stops the whole upload
}

func (q *Queue) process(ctx context.Context, id string) {
	q.mu.Lock()
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
	q.mu.Unlock()

	runCtx, cancel := context.WithCancel(ctx)
	defer cancel()
	r := &run{q: q, u: u, ctx: runCtx, cancel: cancel, folders: folders, folderErr: map[int]error{}}

	r.resolveFolders()
	r.sendFiles()
	r.finish(ctx)
}

// resolveFolders decides, once, where each folder of the upload lands.
func (r *run) resolveFolders() {
	resolver, canResolve := r.q.runner.(FolderResolver)
	for i, it := range r.u.items {
		if !it.isDir || it.resolved != "" || r.ctx.Err() != nil {
			continue
		}
		name := it.destName
		if canResolve {
			var err error
			name, err = resolver.ResolveFolder(r.ctx, r.u.settings, it.destName)
			if err != nil {
				r.q.mu.Lock()
				if uploader.IsFatal(err) {
					r.stop(err)
				} else {
					r.folderErr[i] = err
				}
				r.q.mu.Unlock()
				continue
			}
		}
		r.q.mu.Lock()
		r.folders[i] = name
		r.u.items[i].resolved = name
		r.q.journal.itemResolved(ItemUpdate{UploadID: r.u.snap.ID, Index: i, Resolved: name})
		if r.u.snap.Kind == Folder {
			r.u.snap.ObjectKey = r.u.settings.Prefix + name + "/"
			r.q.publish(r.u)
			r.q.persistUpload(r.u)
		}
		r.q.mu.Unlock()
	}
}

// stop records err as the reason the upload cannot go on and cancels the
// remaining work. The caller holds q.mu.
func (r *run) stop(err error) {
	if r.fatal == nil && r.ctx.Err() == nil {
		r.fatal = err
		r.cancel()
	}
}

// sendFiles runs the files of the upload, in plan order, parallel at a time.
func (r *run) sendFiles() {
	jobs := make(chan *fileState)
	var wg sync.WaitGroup
	for range min(r.u.parallel, len(r.u.files)) {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for f := range jobs {
				r.sendFile(f)
			}
		}()
	}
dispatch:
	for _, f := range r.u.files {
		if f.snap.State != Queued {
			continue // a retry sends only the files it put back in the queue
		}
		select {
		case jobs <- f:
		case <-r.ctx.Done():
			break dispatch
		}
	}
	close(jobs)
	wg.Wait()
}

func (r *run) sendFile(f *fileState) {
	q := r.q
	if r.ctx.Err() != nil {
		return // left as it is; finish settles every file that did not finish
	}
	if f.plan.unreadable {
		r.fail(f, uploader.ErrFileUnreadable)
		return
	}
	req, err := r.request(f)
	if err != nil {
		if r.ctx.Err() == nil {
			r.fail(f, err)
		}
		return
	}

	q.mu.Lock()
	f.snap.State = Uploading
	q.publishFile(r.u, f)
	q.mu.Unlock()

	err = q.runner.Run(r.ctx, r.u.settings, req, uploader.Callbacks{
		KeyResolved: func(key string) { r.keyResolved(f, key) },
		Progress:    func(sent int64) { r.progressed(f, sent) },
	})
	r.settle(f, err)
}

// keyResolved records the object key f is about to be written under.
func (r *run) keyResolved(f *fileState, key string) {
	q := r.q
	q.mu.Lock()
	defer q.mu.Unlock()
	f.snap.ObjectKey = key
	q.publishFile(r.u, f)
	if r.u.snap.Kind == SingleFile {
		r.u.snap.ObjectKey = key
		q.publish(r.u)
	}
}

// progressed records that sent bytes of f have gone out, and publishes the
// file and the upload when each is due.
func (r *run) progressed(f *fileState, sent int64) {
	q := r.q
	q.mu.Lock()
	defer q.mu.Unlock()
	sent = min(sent, f.snap.BytesTotal)
	if sent <= f.snap.BytesSent {
		return
	}
	r.u.snap.BytesSent += sent - f.snap.BytesSent
	f.snap.BytesSent = sent
	now := q.now()
	if now.Sub(f.lastPublish) >= minProgressInterval {
		q.publishFile(r.u, f)
	}
	if now.Sub(r.u.lastPublish) >= minProgressInterval {
		q.publish(r.u)
	}
}

// settle records how the runner's attempt at f ended.
func (r *run) settle(f *fileState, err error) {
	r.q.mu.Lock()
	defer r.q.mu.Unlock()
	switch {
	case err == nil:
		r.u.snap.BytesSent += f.snap.BytesTotal - f.snap.BytesSent
		f.snap.BytesSent = f.snap.BytesTotal
		r.setFileState(f, Finished, "")
	case uploader.IsFatal(err):
		r.stop(err)
	case r.ctx.Err() != nil:
		// Cancelled: finish settles it.
	default:
		r.setFileState(f, Failed, uploader.Message(err))
	}
}

// request builds the runner's request for f. The error is why f cannot be sent.
func (r *run) request(f *fileState) (uploader.Request, error) {
	prefix := r.u.settings.Prefix
	it := r.u.items[f.plan.item]
	if !it.isDir {
		return uploader.Request{Prefix: prefix, LocalPath: f.plan.local, Name: it.destName}, nil
	}

	r.q.mu.Lock()
	folder, ok := r.folders[f.plan.item]
	err := r.folderErr[f.plan.item]
	r.q.mu.Unlock()
	if !ok {
		if err == nil {
			err = errors.New("folder destination was not resolved")
		}
		return uploader.Request{}, err
	}
	dir := prefix + folder + "/"
	if inner := path.Dir(f.plan.inner); inner != "." {
		dir += inner + "/"
	}
	return uploader.Request{Prefix: dir, LocalPath: f.plan.local, SkipExistenceCheck: true}, nil
}

// fail marks f failed because err kept it from starting. err is never fatal:
// a fatal folder resolution error stops the upload in resolveFolders instead
// of being recorded for the folder's files.
func (r *run) fail(f *fileState, err error) {
	r.q.mu.Lock()
	defer r.q.mu.Unlock()
	r.setFileState(f, Failed, uploader.Message(err))
}

// setFileState moves f to state, keeping the upload's counters in step and
// publishing both. The caller holds q.mu.
func (r *run) setFileState(f *fileState, state State, msg string) {
	switch {
	case f.snap.State != Finished && state == Finished:
		r.u.snap.FilesFinished++
	case f.snap.State != Failed && state == Failed:
		r.u.snap.FilesFailed++
	}
	f.snap.State, f.snap.ErrorMessage = state, msg
	r.q.publishFile(r.u, f)
	r.q.publish(r.u)
	if state == Finished || state == Failed {
		r.q.persistFile(r.u, f)
		r.q.persistUpload(r.u)
	}
}

// finish settles every file that did not finish and the upload itself.
func (r *run) finish(parent context.Context) {
	q, u := r.q, r.u
	q.mu.Lock()
	defer q.mu.Unlock()

	var stopped error
	switch {
	case r.fatal != nil:
		stopped = r.fatal
	case parent.Err() != nil:
		stopped = parent.Err()
	}
	if stopped != nil {
		r.failUnfinished(uploader.Message(stopped))
	} else {
		r.settleOutcome()
	}
	u.snap.EndedAt = q.now()
	q.publish(u)
	q.persistUpload(u)
	// From here on the files are read from the store, not kept in memory.
	u.files, u.items = nil, nil
}

// failUnfinished fails the upload with msg, and every file that did not end.
// The caller holds q.mu.
func (r *run) failUnfinished(msg string) {
	for _, f := range r.u.files {
		// A file that already ended keeps its own outcome and message.
		if f.snap.State != Finished && f.snap.State != Failed {
			r.setFileState(f, Failed, msg)
		}
	}
	r.u.snap.State, r.u.snap.ErrorMessage = Failed, msg
}

// settleOutcome sets the final state of an upload that ran to the end. The
// caller holds q.mu.
func (r *run) settleOutcome() {
	u := r.u
	switch {
	case u.snap.FilesFailed == 0:
		u.snap.State = Finished
		u.snap.BytesSent = u.snap.BytesTotal
	case u.snap.Kind == SingleFile:
		u.snap.State, u.snap.ErrorMessage = Failed, u.files[0].snap.ErrorMessage
	default:
		u.snap.State = Failed
		u.snap.ErrorMessage = fmt.Sprintf("%d of %d files could not be sent", u.snap.FilesFailed, u.snap.FilesTotal)
	}
}

// recordOf is the stored form of an upload.
func recordOf(u *upload) UploadRecord {
	return UploadRecord{Snapshot: u.snap, Bucket: u.bucket, Region: u.region, Prefix: u.prefix, Parallel: u.parallel}
}

func itemRecords(items []item) []ItemRecord {
	out := make([]ItemRecord, len(items))
	for i, it := range items {
		out[i] = ItemRecord{Index: i, Path: it.path, IsDir: it.isDir, DestName: it.destName, Resolved: it.resolved}
	}
	return out
}

func fileRecord(f *fileState) FileRecord {
	return FileRecord{Snapshot: f.snap, Item: f.plan.item, Inner: f.plan.inner, Unreadable: f.plan.unreadable}
}

func fileRecords(files []*fileState) []FileRecord {
	out := make([]FileRecord, len(files))
	for i, f := range files {
		out[i] = fileRecord(f)
	}
	return out
}

func filesSnapshots(files []*fileState) []FileSnapshot {
	out := make([]FileSnapshot, 0, len(files))
	for _, f := range files {
		out = append(out, f.snap)
	}
	return out
}

func recordSnapshots(recs []FileRecord) []FileSnapshot {
	out := make([]FileSnapshot, 0, len(recs))
	for _, r := range recs {
		out = append(out, r.Snapshot)
	}
	return out
}

// persistUpload queues the upload's current state for the store. The caller
// holds q.mu. It never waits for the store.
func (q *Queue) persistUpload(u *upload) { q.journal.uploadChanged(recordOf(u)) }

// persistFile queues the file's current state for the store. The caller holds
// q.mu. It never waits for the store.
func (q *Queue) persistFile(_ *upload, f *fileState) { q.journal.fileChanged(fileRecord(f)) }

// publish hands the upload's current snapshot to every subscriber. The caller
// holds q.mu. It never blocks.
func (q *Queue) publish(u *upload) {
	u.lastPublish = q.now()
	if q.visible(u) {
		q.pushToSubs(u.snap)
	}
}

// publishFile hands the file's current snapshot to every subscriber of its
// upload. The caller holds q.mu. It never blocks.
func (q *Queue) publishFile(u *upload, f *fileState) {
	f.lastPublish = q.now()
	for sub := range q.fileSubs[u.snap.ID] {
		sub.push(f.snap)
	}
}

func newID() (string, error) {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", fmt.Errorf("generate upload id: %w", err)
	}
	return hex.EncodeToString(b[:]), nil
}
