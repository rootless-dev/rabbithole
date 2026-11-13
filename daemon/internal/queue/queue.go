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
	lastPublish time.Time
	items       []item
	files       []*fileState
	parallel    int
}

// Queue runs enqueued uploads one after another and publishes snapshots.
type Queue struct {
	runner Runner
	now    func() time.Time
	wake   chan struct{} // capacity 1: signals Run that work may be waiting

	mu       sync.Mutex
	uploads  map[string]*upload
	known    []string // upload IDs in enqueue order
	waiting  []string // IDs not started yet, in FIFO order
	subs     map[*uploadSub]struct{}
	fileSubs map[string]map[*fileSub]struct{} // by upload ID
}

type (
	uploadSub = subscriber[string, Snapshot]
	fileSub   = subscriber[int, FileSnapshot]
)

// New returns a Queue that runs uploads with r and reads the time from now.
func New(r Runner, now func() time.Time) *Queue {
	return &Queue{
		runner:   r,
		now:      now,
		wake:     make(chan struct{}, 1),
		uploads:  make(map[string]*upload),
		subs:     make(map[*uploadSub]struct{}),
		fileSubs: make(map[string]map[*fileSub]struct{}),
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
		items:    p.items,
		parallel: clampParallel(req.ParallelFiles),
		snap: Snapshot{
			ID:         id,
			FileName:   baseName(p.items[0].path),
			LocalPath:  p.items[0].path,
			State:      Queued,
			Kind:       p.kind,
			FilesTotal: len(p.files),
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
		initial = append(initial, q.uploads[id].snap)
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

// SubscribeFiles is Subscribe for the files of one upload. It returns
// ErrUnknownUpload when no upload has that id.
func (q *Queue) SubscribeFiles(id string) (initial []FileSnapshot, updates <-chan FileSnapshot, cancel func(), err error) {
	sub := newSubscriber(func(s FileSnapshot) int { return s.Index })

	q.mu.Lock()
	u, ok := q.uploads[id]
	if !ok {
		q.mu.Unlock()
		return nil, nil, nil, ErrUnknownUpload
	}
	initial = make([]FileSnapshot, 0, len(u.files))
	for _, f := range u.files {
		initial = append(initial, f.snap)
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
	q.mu.Unlock()

	runCtx, cancel := context.WithCancel(ctx)
	defer cancel()
	r := &run{q: q, u: u, ctx: runCtx, cancel: cancel, folders: map[int]string{}, folderErr: map[int]error{}}

	r.resolveFolders()
	r.sendFiles()
	r.finish(ctx)
}

// resolveFolders decides, once, where each folder of the upload lands.
func (r *run) resolveFolders() {
	resolver, canResolve := r.q.runner.(FolderResolver)
	for i, it := range r.u.items {
		if !it.isDir || r.ctx.Err() != nil {
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
		if r.u.snap.Kind == Folder {
			r.u.snap.ObjectKey = r.u.settings.Prefix + name + "/"
			r.q.publish(r.u)
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

// fail marks f failed because err kept it from starting.
func (r *run) fail(f *fileState, err error) {
	r.q.mu.Lock()
	defer r.q.mu.Unlock()
	if uploader.IsFatal(err) {
		r.stop(err)
		return
	}
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
		msg := uploader.Message(stopped)
		for _, f := range u.files {
			// A file that already ended keeps its own outcome and message.
			if f.snap.State != Finished && f.snap.State != Failed {
				r.setFileState(f, Failed, msg)
			}
		}
		u.snap.State, u.snap.ErrorMessage = Failed, msg
		q.publish(u)
		return
	}

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
	q.publish(u)
}

// publish hands the upload's current snapshot to every subscriber. The caller
// holds q.mu. It never blocks.
func (q *Queue) publish(u *upload) {
	u.lastPublish = q.now()
	for sub := range q.subs {
		sub.push(u.snap)
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
