// Package download copies finished files of stored uploads from the bucket to
// a folder on disk. Downloads run in the background, a few files at a time, and
// live in memory only: they are gone when the daemon stops.
package download

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sync"
	"time"

	"rabbithole/daemon/internal/logging"
	"rabbithole/daemon/internal/queue"
	"rabbithole/daemon/internal/uploader"
)

const (
	// minProgressInterval is the shortest time between two progress snapshots
	// of the same download: at most 10 per second.
	minProgressInterval = 100 * time.Millisecond
	// parallelFiles is how many files of one download are copied at once.
	parallelFiles = 3
)

var (
	// ErrBadDestination means the destination is not an existing, writable
	// folder given as an absolute path.
	ErrBadDestination = errors.New("The destination must be an existing folder that can be written to")
	// ErrUnknownDownload means no download has the given id.
	ErrUnknownDownload = errors.New("unknown download")
	// ErrDownloadEnded means the download already finished, failed or was canceled.
	ErrDownloadEnded = errors.New("the download already ended")
)

// State is where a download is in its life.
type State int

const (
	Queued State = iota
	Downloading
	Finished
	Failed
	Canceled
)

// ended reports whether the state is final.
func (s State) ended() bool { return s == Finished || s == Failed || s == Canceled }

// Snapshot is the state of one download at one moment.
type Snapshot struct {
	ID          string
	UploadID    string
	FileIndexes []int // the files the download resolved to, by file index
	// Name is the file name, or the folder name, the download is shown as.
	Name string
	// Destination is the file for a single file, the folder otherwise.
	Destination  string
	BytesTotal   int64
	BytesDone    int64
	FilesTotal   int
	FilesDone    int
	FilesFailed  int
	State        State
	ErrorMessage string
}

// Source reads objects from the bucket. A failure is one of the uploader
// sentinels, possibly wrapped; the body maps the failures of its reads the same
// way.
type Source interface {
	GetObject(ctx context.Context, key string) (body io.ReadCloser, size int64, err error)
}

// Opener builds the Source for the settings of a download.
type Opener func(ctx context.Context, s uploader.Settings) (Source, error)

// Files says which files of an upload a download copies. *queue.Queue does.
type Files interface {
	DownloadFiles(bucket, id string, indexes []int) ([]queue.DownloadFile, error)
}

// Manager starts downloads and publishes their snapshots.
type Manager struct {
	open  Opener
	files Files
	log   *logging.Logger
	now   func() time.Time

	base   context.Context
	cancel context.CancelFunc
	wg     sync.WaitGroup

	mu    sync.Mutex
	runs  map[string]*download
	order []string
	subs  map[*subscriber]struct{}
}

// download is a download in progress or ended. Guarded by Manager.mu.
type download struct {
	snap         Snapshot
	plan         plan
	cancel       context.CancelFunc
	userCanceled bool
	fatal        error  // first error that stops the whole download
	fileMessage  string // why the last file failed
	lastPublish  time.Time
}

// Option changes how New builds a Manager.
type Option func(*Manager)

// WithClock makes the manager read the time from now.
func WithClock(now func() time.Time) Option { return func(m *Manager) { m.now = now } }

// New returns a Manager that reads objects through open and asks files which
// files to copy.
func New(open Opener, files Files, log *logging.Logger, opts ...Option) *Manager {
	base, cancel := context.WithCancel(context.Background())
	m := &Manager{
		open: open, files: files, log: log, now: time.Now,
		base: base, cancel: cancel,
		runs: map[string]*download{}, subs: map[*subscriber]struct{}{},
	}
	for _, opt := range opts {
		opt(m)
	}
	return m
}

// Run blocks until ctx ends, then cancels every download and waits for them to
// stop. Temporary files are gone by the time it returns.
func (m *Manager) Run(ctx context.Context) {
	<-ctx.Done()
	m.cancel()
	m.wg.Wait()
}

// Start begins copying finished files of the upload uploadID, sent to
// s.Bucket, into destDir, and returns the id of the download at once. Empty
// indexes means every finished file. It returns the errors of
// queue.DownloadFiles, and ErrBadDestination.
func (m *Manager) Start(s uploader.Settings, uploadID string, indexes []int, destDir string) (string, error) {
	files, err := m.files.DownloadFiles(s.Bucket, uploadID, indexes)
	if err != nil {
		return "", err
	}
	if err := checkDestination(destDir); err != nil {
		return "", err
	}
	p, err := buildPlan(destDir, files)
	if err != nil {
		return "", err
	}
	id, err := newID()
	if err != nil {
		return "", err
	}

	ctx, cancel := context.WithCancel(m.base)
	d := &download{plan: p, cancel: cancel, snap: Snapshot{
		ID: id, UploadID: uploadID, Name: p.name, Destination: p.destination,
		BytesTotal: p.total, FilesTotal: len(p.files), State: Queued,
	}}
	for _, f := range files {
		d.snap.FileIndexes = append(d.snap.FileIndexes, f.Index)
	}
	m.mu.Lock()
	m.runs[id] = d
	m.order = append(m.order, id)
	m.publish(d)
	m.wg.Add(1)
	m.mu.Unlock()
	m.log.Info("download started", "download_id", id, "upload_id", uploadID, "files", len(files))

	go m.run(ctx, d, s)
	return id, nil
}

// checkDestination requires an absolute path to an existing folder the daemon
// can create files in.
func checkDestination(dir string) error {
	if !filepath.IsAbs(dir) {
		return ErrBadDestination
	}
	info, err := os.Stat(dir)
	if err != nil || !info.IsDir() {
		return ErrBadDestination
	}
	probe, err := os.CreateTemp(dir, ".rabbithole-probe-*")
	if err != nil {
		return ErrBadDestination
	}
	_ = probe.Close()
	_ = os.Remove(probe.Name())
	return nil
}

// Cancel stops the download id: its files in progress are dropped with their
// temporary files, and its state becomes canceled a moment later. It returns
// ErrUnknownDownload and ErrDownloadEnded.
func (m *Manager) Cancel(id string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	d, ok := m.runs[id]
	switch {
	case !ok:
		return ErrUnknownDownload
	case d.snap.State.ended() || d.userCanceled:
		return ErrDownloadEnded
	}
	d.userCanceled = true
	d.cancel()
	return nil
}

// Subscribe returns one snapshot per download of this run, then a channel of
// later changes. A reader that is slow never blocks the manager: only the
// latest pending snapshot per download is kept for it, so the final state of
// every download still arrives. The channel is closed by cancel only.
func (m *Manager) Subscribe() (initial []Snapshot, updates <-chan Snapshot, cancel func()) {
	sub := newSubscriber()
	m.mu.Lock()
	for _, id := range m.order {
		initial = append(initial, m.runs[id].view())
	}
	m.subs[sub] = struct{}{}
	m.mu.Unlock()
	go sub.pump()
	return initial, sub.out, func() {
		m.mu.Lock()
		delete(m.subs, sub)
		m.mu.Unlock()
		sub.stop()
	}
}

// view is the snapshot of d, with its own copy of the indexes.
func (d *download) view() Snapshot {
	s := d.snap
	s.FileIndexes = append([]int(nil), s.FileIndexes...)
	return s
}

// publish hands the snapshot of d to every subscriber. The caller holds m.mu.
func (m *Manager) publish(d *download) {
	d.lastPublish = m.now()
	v := d.view()
	for sub := range m.subs {
		sub.push(v)
	}
}

func newID() (string, error) {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", fmt.Errorf("generate download id: %w", err)
	}
	return hex.EncodeToString(b[:]), nil
}
