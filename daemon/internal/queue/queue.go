// Package queue holds the in-memory upload queue: first in, first out, one
// upload at a time, nothing persisted. It publishes a snapshot of an upload
// to subscribers whenever the upload changes.
package queue

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"time"

	"rabbithole/daemon/internal/uploader"
)

// minProgressInterval is the shortest time between two progress snapshots of
// the same upload: at most 10 per second.
const minProgressInterval = 100 * time.Millisecond

// ErrInvalidPath means the path is not a regular, readable file.
var ErrInvalidPath = errors.New("path is not a regular readable file")

// State is where an upload is in its life.
type State int

const (
	Queued State = iota
	Uploading
	Finished
	Failed
)

// Snapshot is the state of one upload at one moment.
type Snapshot struct {
	ID           string
	FileName     string
	LocalPath    string
	ObjectKey    string // empty while Queued; the last key the uploader resolved afterwards
	BytesTotal   int64
	BytesSent    int64
	State        State
	ErrorMessage string
}

// Runner performs one upload.
type Runner interface {
	Run(ctx context.Context, s uploader.Settings, req uploader.Request, cb uploader.Callbacks) error
}

type upload struct {
	snap        Snapshot
	settings    uploader.Settings
	lastPublish time.Time
}

// Queue runs enqueued uploads one after another and publishes snapshots.
type Queue struct {
	runner Runner
	now    func() time.Time
	wake   chan struct{} // capacity 1: signals Run that work may be waiting

	mu      sync.Mutex
	uploads map[string]*upload
	known   []string // upload IDs in enqueue order
	waiting []string // IDs not started yet, in FIFO order
	subs    map[*subscriber]struct{}
}

// New returns a Queue that runs uploads with r and reads the time from now.
func New(r Runner, now func() time.Time) *Queue {
	return &Queue{
		runner:  r,
		now:     now,
		wake:    make(chan struct{}, 1),
		uploads: make(map[string]*upload),
		subs:    make(map[*subscriber]struct{}),
	}
}

// Enqueue adds the file at localPath to the queue, capturing s for this upload.
// The file name and size are taken from the file now.
func (q *Queue) Enqueue(s uploader.Settings, localPath string) (string, error) {
	info, err := os.Stat(localPath)
	if err != nil {
		return "", fmt.Errorf("%w: %v", ErrInvalidPath, err)
	}
	if !info.Mode().IsRegular() {
		return "", fmt.Errorf("%w: %s is not a regular file", ErrInvalidPath, localPath)
	}
	f, err := os.Open(localPath)
	if err != nil {
		return "", fmt.Errorf("%w: %v", ErrInvalidPath, err)
	}
	_ = f.Close()

	id, err := newID()
	if err != nil {
		return "", err
	}
	u := &upload{
		settings: s,
		snap: Snapshot{
			ID:         id,
			FileName:   filepath.Base(localPath),
			LocalPath:  localPath,
			BytesTotal: info.Size(),
			State:      Queued,
		},
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
	sub := newSubscriber()

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

func (q *Queue) process(ctx context.Context, id string) {
	q.mu.Lock()
	u := q.uploads[id]
	u.snap.State = Uploading
	q.publish(u)
	settings, path := u.settings, u.snap.LocalPath
	prefix := u.settings.Prefix
	q.mu.Unlock()

	err := q.runner.Run(ctx, settings, uploader.Request{Prefix: prefix, LocalPath: path}, uploader.Callbacks{
		KeyResolved: func(key string) {
			q.mu.Lock()
			defer q.mu.Unlock()
			u.snap.ObjectKey = key
			q.publish(u)
		},
		Progress: func(sent int64) {
			q.mu.Lock()
			defer q.mu.Unlock()
			sent = min(sent, u.snap.BytesTotal)
			if sent <= u.snap.BytesSent {
				return
			}
			u.snap.BytesSent = sent
			if q.now().Sub(u.lastPublish) >= minProgressInterval {
				q.publish(u)
			}
		},
	})

	q.mu.Lock()
	defer q.mu.Unlock()
	if err != nil {
		u.snap.State = Failed
		u.snap.ErrorMessage = uploader.Message(err)
	} else {
		u.snap.State = Finished
		u.snap.BytesSent = u.snap.BytesTotal
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

func newID() (string, error) {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", fmt.Errorf("generate upload id: %w", err)
	}
	return hex.EncodeToString(b[:]), nil
}

// subscriber keeps the latest pending snapshot per upload and delivers them,
// in order of first pending change, as fast as its reader takes them.
type subscriber struct {
	out  chan Snapshot
	wake chan struct{} // capacity 1
	done chan struct{}
	once sync.Once

	mu      sync.Mutex
	pending map[string]Snapshot
	order   []string
}

func newSubscriber() *subscriber {
	return &subscriber{
		out:     make(chan Snapshot),
		wake:    make(chan struct{}, 1),
		done:    make(chan struct{}),
		pending: make(map[string]Snapshot),
	}
}

func (s *subscriber) push(snap Snapshot) {
	s.mu.Lock()
	if _, queued := s.pending[snap.ID]; !queued {
		s.order = append(s.order, snap.ID)
	}
	s.pending[snap.ID] = snap
	s.mu.Unlock()

	select {
	case s.wake <- struct{}{}:
	default:
	}
}

func (s *subscriber) pop() (Snapshot, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if len(s.order) == 0 {
		return Snapshot{}, false
	}
	id := s.order[0]
	s.order = s.order[1:]
	snap := s.pending[id]
	delete(s.pending, id)
	return snap, true
}

func (s *subscriber) pump() {
	defer close(s.out)
	for {
		snap, ok := s.pop()
		if !ok {
			select {
			case <-s.wake:
			case <-s.done:
				return
			}
			continue
		}
		select {
		case s.out <- snap:
		case <-s.done:
			return
		}
	}
}

func (s *subscriber) stop() { s.once.Do(func() { close(s.done) }) }
