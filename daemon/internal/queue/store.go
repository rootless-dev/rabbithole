package queue

import (
	"sort"
	"sync"
	"time"
)

// InterruptedMessage is the error message of an upload, and of each of its
// files that had not finished, when the daemon stopped while it was running.
const InterruptedMessage = "Upload interrupted"

// UploadRecord is an upload as stored: what a Snapshot shows plus where the
// upload was sent. It never holds credentials.
type UploadRecord struct {
	Snapshot Snapshot
	Bucket   string
	Region   string
	Prefix   string
	Parallel int
}

// ItemRecord is one path an upload was enqueued with. Resolved is the name the
// folder landed under at the destination, empty until it is resolved.
type ItemRecord struct {
	Index    int
	Path     string
	IsDir    bool
	DestName string
	Resolved string
}

// FileRecord is one file of an upload as stored: its snapshot plus what is
// needed to send it again.
type FileRecord struct {
	Snapshot   FileSnapshot
	Item       int    // index of the ItemRecord the file belongs to
	Inner      string // slash path inside the folder; empty for a file listed directly
	Unreadable bool
}

// ItemUpdate records where a folder of an upload landed.
type ItemUpdate struct {
	UploadID string
	Index    int
	Resolved string
}

// Changes is a batch of updates to rows that already exist. An update to a row
// that does not exist, for example one removed in the meantime, is ignored.
type Changes struct {
	Uploads []UploadRecord
	Items   []ItemUpdate
	Files   []FileRecord
}

// Store keeps uploads and their files across runs. The queue is its only
// consumer; internal/history provides the persistent implementation.
type Store interface {
	// CreateUpload stores a new upload with its items and files in one step.
	CreateUpload(rec UploadRecord, items []ItemRecord, files []FileRecord) error
	// Save applies changes to stored rows in one step.
	Save(c Changes) error
	// Uploads returns every stored upload, oldest first.
	Uploads() ([]UploadRecord, error)
	// Items returns the items of an upload in index order.
	Items(uploadID string) ([]ItemRecord, error)
	// Files returns the files of an upload in index order.
	Files(uploadID string) ([]FileRecord, error)
	// FailInterrupted turns every stored upload that is queued or uploading, and
	// each of its files that had not finished, into a failed one with message.
	FailInterrupted(message string, at time.Time) error
	// DeleteUpload removes an upload with its items and files.
	DeleteUpload(uploadID string) error
}

// Logger is what the queue needs to report a storage failure.
type Logger interface {
	Warn(msg string, kv ...any)
}

type nopLogger struct{}

func (nopLogger) Warn(string, ...any) {}

// memStore is the Store used when none is given: everything stays in memory.
type memStore struct {
	mu      sync.Mutex
	order   []string
	uploads map[string]UploadRecord
	items   map[string][]ItemRecord
	files   map[string][]FileRecord
}

func newMemStore() *memStore {
	return &memStore{
		uploads: map[string]UploadRecord{},
		items:   map[string][]ItemRecord{},
		files:   map[string][]FileRecord{},
	}
}

func (m *memStore) CreateUpload(rec UploadRecord, items []ItemRecord, files []FileRecord) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	id := rec.Snapshot.ID
	m.order = append(m.order, id)
	m.uploads[id] = rec
	m.items[id] = append([]ItemRecord(nil), items...)
	m.files[id] = append([]FileRecord(nil), files...)
	return nil
}

func (m *memStore) Save(c Changes) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	for _, rec := range c.Uploads {
		if _, ok := m.uploads[rec.Snapshot.ID]; ok {
			m.uploads[rec.Snapshot.ID] = rec
		}
	}
	for _, up := range c.Items {
		if items := m.items[up.UploadID]; up.Index >= 0 && up.Index < len(items) {
			items[up.Index].Resolved = up.Resolved
		}
	}
	for _, rec := range c.Files {
		if files := m.files[rec.Snapshot.UploadID]; rec.Snapshot.Index >= 0 && rec.Snapshot.Index < len(files) {
			files[rec.Snapshot.Index] = rec
		}
	}
	return nil
}

func (m *memStore) Uploads() ([]UploadRecord, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	out := make([]UploadRecord, 0, len(m.order))
	for _, id := range m.order {
		out = append(out, m.uploads[id])
	}
	return out, nil
}

func (m *memStore) Items(id string) ([]ItemRecord, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	return append([]ItemRecord(nil), m.items[id]...), nil
}

func (m *memStore) Files(id string) ([]FileRecord, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	return append([]FileRecord(nil), m.files[id]...), nil
}

func (m *memStore) FailInterrupted(message string, at time.Time) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	for id, rec := range m.uploads {
		if rec.Snapshot.State != Queued && rec.Snapshot.State != Uploading {
			continue
		}
		rec.Snapshot.State, rec.Snapshot.ErrorMessage, rec.Snapshot.EndedAt = Failed, message, at
		m.uploads[id] = rec
		for i, f := range m.files[id] {
			if f.Snapshot.State != Finished && f.Snapshot.State != Failed {
				m.files[id][i].Snapshot.State, m.files[id][i].Snapshot.ErrorMessage = Failed, message
			}
		}
	}
	return nil
}

func (m *memStore) DeleteUpload(id string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	delete(m.uploads, id)
	delete(m.items, id)
	delete(m.files, id)
	m.order = sortedWithout(m.order, id)
	return nil
}

func sortedWithout(ids []string, id string) []string {
	out := ids[:0:0]
	for _, v := range ids {
		if v != id {
			out = append(out, v)
		}
	}
	return out
}

type fileKey struct {
	upload string
	index  int
}

// journal collects changes made under the queue's lock and writes them to the
// store from another goroutine, so publishing never waits for the disk. The
// latest change per row wins, which also batches bursts of small changes.
type journal struct {
	store Store
	log   Logger
	wake  chan struct{} // capacity 1

	writeMu sync.Mutex // one write at a time, so rows never go back in time

	mu      sync.Mutex
	uploads map[string]UploadRecord
	items   map[fileKey]ItemUpdate
	files   map[fileKey]FileRecord
}

func newJournal(s Store, log Logger) *journal {
	return &journal{
		store:   s,
		log:     log,
		wake:    make(chan struct{}, 1),
		uploads: map[string]UploadRecord{},
		items:   map[fileKey]ItemUpdate{},
		files:   map[fileKey]FileRecord{},
	}
}

func (j *journal) uploadChanged(rec UploadRecord) {
	j.mu.Lock()
	j.uploads[rec.Snapshot.ID] = rec
	j.mu.Unlock()
	j.signal()
}

func (j *journal) fileChanged(rec FileRecord) {
	j.mu.Lock()
	j.files[fileKey{rec.Snapshot.UploadID, rec.Snapshot.Index}] = rec
	j.mu.Unlock()
	j.signal()
}

func (j *journal) itemResolved(up ItemUpdate) {
	j.mu.Lock()
	j.items[fileKey{up.UploadID, up.Index}] = up
	j.mu.Unlock()
	j.signal()
}

func (j *journal) signal() {
	select {
	case j.wake <- struct{}{}:
	default:
	}
}

// flush writes every change collected so far and returns once it is stored.
// A failure is logged and the changes are dropped: the upload goes on.
func (j *journal) flush() {
	j.writeMu.Lock()
	defer j.writeMu.Unlock()

	j.mu.Lock()
	c := Changes{}
	for _, rec := range j.uploads {
		c.Uploads = append(c.Uploads, rec)
	}
	for _, up := range j.items {
		c.Items = append(c.Items, up)
	}
	for _, rec := range j.files {
		c.Files = append(c.Files, rec)
	}
	clear(j.uploads)
	clear(j.items)
	clear(j.files)
	j.mu.Unlock()

	if len(c.Uploads)+len(c.Items)+len(c.Files) == 0 {
		return
	}
	sort.Slice(c.Files, func(a, b int) bool {
		fa, fb := c.Files[a].Snapshot, c.Files[b].Snapshot
		return fa.UploadID < fb.UploadID || fa.UploadID == fb.UploadID && fa.Index < fb.Index
	})
	if err := j.store.Save(c); err != nil {
		j.log.Warn("could not save upload history", "error", err.Error())
	}
}

// loop writes changes as they arrive until stop is closed, then writes what is
// left.
func (j *journal) loop(stop <-chan struct{}) {
	for {
		select {
		case <-j.wake:
			j.flush()
		case <-stop:
			j.flush()
			return
		}
	}
}
