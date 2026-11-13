// Package history keeps the upload history in a local SQLite database, through
// the pure-Go driver modernc.org/sqlite. It implements queue.Store.
//
// The database holds where each upload was sent (bucket, region, prefix) and
// the state of each of its files. It never holds the access key id or the
// secret.
package history

import (
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"time"

	_ "modernc.org/sqlite" // registers the "sqlite" driver

	"rabbithole/daemon/internal/queue"
)

// ErrNewerSchema means the database was written by a newer daemon.
var ErrNewerSchema = errors.New("database schema is newer than this daemon understands")

// migrations[n] upgrades a database from schema version n to n+1. The schema
// version is kept in the database's user_version. Append to the list to change
// the schema; never edit an entry that has shipped.
var migrations = []string{
	`CREATE TABLE uploads (
		seq            INTEGER PRIMARY KEY AUTOINCREMENT,
		id             TEXT    NOT NULL UNIQUE,
		file_name      TEXT    NOT NULL,
		local_path     TEXT    NOT NULL,
		object_key     TEXT    NOT NULL,
		kind           INTEGER NOT NULL,
		root_paths     TEXT    NOT NULL,
		bytes_total    INTEGER NOT NULL,
		bytes_sent     INTEGER NOT NULL,
		state          INTEGER NOT NULL,
		error_message  TEXT    NOT NULL,
		files_total    INTEGER NOT NULL,
		files_finished INTEGER NOT NULL,
		files_failed   INTEGER NOT NULL,
		bucket         TEXT    NOT NULL,
		region         TEXT    NOT NULL,
		prefix         TEXT    NOT NULL,
		parallel       INTEGER NOT NULL,
		created_at_ms  INTEGER NOT NULL,
		ended_at_ms    INTEGER NOT NULL
	);
	CREATE INDEX uploads_state ON uploads (state);
	CREATE TABLE items (
		upload_id     TEXT    NOT NULL REFERENCES uploads (id) ON DELETE CASCADE,
		idx           INTEGER NOT NULL,
		path          TEXT    NOT NULL,
		is_dir        INTEGER NOT NULL,
		dest_name     TEXT    NOT NULL,
		resolved_name TEXT    NOT NULL,
		PRIMARY KEY (upload_id, idx)
	) WITHOUT ROWID;
	CREATE TABLE files (
		upload_id     TEXT    NOT NULL REFERENCES uploads (id) ON DELETE CASCADE,
		idx           INTEGER NOT NULL,
		item_idx      INTEGER NOT NULL,
		inner         TEXT    NOT NULL,
		unreadable    INTEGER NOT NULL,
		local_path    TEXT    NOT NULL,
		relative_path TEXT    NOT NULL,
		object_key    TEXT    NOT NULL,
		bytes_total   INTEGER NOT NULL,
		bytes_sent    INTEGER NOT NULL,
		state         INTEGER NOT NULL,
		error_message TEXT    NOT NULL,
		PRIMARY KEY (upload_id, idx)
	) WITHOUT ROWID;`,
}

// Store is the SQLite-backed history.
type Store struct {
	db *sql.DB
}

var _ queue.Store = (*Store)(nil)

// Open opens the database at path, creating the file, its folder and the schema
// when they do not exist, and migrating an older schema.
func Open(path string) (*Store, error) {
	abs, err := filepath.Abs(path)
	if err != nil {
		return nil, fmt.Errorf("resolve database path: %w", err)
	}
	if err := os.MkdirAll(filepath.Dir(abs), 0o700); err != nil {
		return nil, fmt.Errorf("create database directory: %w", err)
	}
	db, err := sql.Open("sqlite", dsn(abs))
	if err != nil {
		return nil, fmt.Errorf("open database: %w", err)
	}
	if err := migrate(db); err != nil {
		_ = db.Close()
		return nil, fmt.Errorf("open database %s: %w", abs, err)
	}
	return &Store{db: db}, nil
}

func dsn(path string) string {
	q := url.Values{}
	for _, p := range []string{"foreign_keys(1)", "busy_timeout(5000)", "journal_mode(WAL)", "synchronous(NORMAL)"} {
		q.Add("_pragma", p)
	}
	return (&url.URL{Scheme: "file", Path: path, RawQuery: q.Encode()}).String()
}

// Close closes the database.
func (s *Store) Close() error { return s.db.Close() }

// SchemaVersion returns the schema version of the open database.
func (s *Store) SchemaVersion() (int, error) { return schemaVersion(s.db) }

func schemaVersion(db *sql.DB) (int, error) {
	var v int
	if err := db.QueryRow("PRAGMA user_version").Scan(&v); err != nil {
		return 0, fmt.Errorf("read schema version: %w", err)
	}
	return v, nil
}

func migrate(db *sql.DB) error {
	v, err := schemaVersion(db)
	if err != nil {
		return err
	}
	if v > len(migrations) {
		return fmt.Errorf("%w (version %d, known %d)", ErrNewerSchema, v, len(migrations))
	}
	for ; v < len(migrations); v++ {
		if err := applyMigration(db, v); err != nil {
			return err
		}
	}
	return nil
}

func applyMigration(db *sql.DB, from int) error {
	tx, err := db.Begin()
	if err != nil {
		return fmt.Errorf("begin migration: %w", err)
	}
	defer func() { _ = tx.Rollback() }()
	if _, err := tx.Exec(migrations[from]); err != nil {
		return fmt.Errorf("migrate schema from version %d: %w", from, err)
	}
	if _, err := tx.Exec(fmt.Sprintf("PRAGMA user_version = %d", from+1)); err != nil {
		return fmt.Errorf("set schema version: %w", err)
	}
	return tx.Commit()
}

// inTx runs fn in a transaction, committing when it succeeds.
func (s *Store) inTx(fn func(tx *sql.Tx) error) error {
	tx, err := s.db.Begin()
	if err != nil {
		return fmt.Errorf("begin: %w", err)
	}
	defer func() { _ = tx.Rollback() }()
	if err := fn(tx); err != nil {
		return err
	}
	return tx.Commit()
}

func ms(t time.Time) int64 {
	if t.IsZero() {
		return 0
	}
	return t.UnixMilli()
}

func fromMs(v int64) time.Time {
	if v == 0 {
		return time.Time{}
	}
	return time.UnixMilli(v)
}

func boolInt(b bool) int {
	if b {
		return 1
	}
	return 0
}

// CreateUpload stores an upload with its items and files in one transaction.
func (s *Store) CreateUpload(rec queue.UploadRecord, items []queue.ItemRecord, files []queue.FileRecord) error {
	roots, err := json.Marshal(rec.Snapshot.RootPaths)
	if err != nil {
		return fmt.Errorf("encode root paths: %w", err)
	}
	return s.inTx(func(tx *sql.Tx) error {
		sn := rec.Snapshot
		if _, err := tx.Exec(`INSERT INTO uploads (id, file_name, local_path, object_key, kind, root_paths,
			bytes_total, bytes_sent, state, error_message, files_total, files_finished, files_failed,
			bucket, region, prefix, parallel, created_at_ms, ended_at_ms)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
			sn.ID, sn.FileName, sn.LocalPath, sn.ObjectKey, int(sn.Kind), string(roots),
			sn.BytesTotal, sn.BytesSent, int(sn.State), sn.ErrorMessage, sn.FilesTotal, sn.FilesFinished, sn.FilesFailed,
			rec.Bucket, rec.Region, rec.Prefix, rec.Parallel, ms(sn.CreatedAt), ms(sn.EndedAt)); err != nil {
			return fmt.Errorf("insert upload: %w", err)
		}
		if err := insertItems(tx, sn.ID, items); err != nil {
			return err
		}
		return insertFiles(tx, files)
	})
}

func insertItems(tx *sql.Tx, uploadID string, items []queue.ItemRecord) error {
	stmt, err := tx.Prepare(`INSERT INTO items (upload_id, idx, path, is_dir, dest_name, resolved_name) VALUES (?, ?, ?, ?, ?, ?)`)
	if err != nil {
		return fmt.Errorf("prepare items: %w", err)
	}
	defer func() { _ = stmt.Close() }()
	for _, it := range items {
		if _, err := stmt.Exec(uploadID, it.Index, it.Path, boolInt(it.IsDir), it.DestName, it.Resolved); err != nil {
			return fmt.Errorf("insert item: %w", err)
		}
	}
	return nil
}

func insertFiles(tx *sql.Tx, files []queue.FileRecord) error {
	stmt, err := tx.Prepare(`INSERT INTO files (upload_id, idx, item_idx, inner, unreadable, local_path, relative_path,
		object_key, bytes_total, bytes_sent, state, error_message) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`)
	if err != nil {
		return fmt.Errorf("prepare files: %w", err)
	}
	defer func() { _ = stmt.Close() }()
	for _, f := range files {
		sn := f.Snapshot
		if _, err := stmt.Exec(sn.UploadID, sn.Index, f.Item, f.Inner, boolInt(f.Unreadable), sn.LocalPath, sn.RelativePath,
			sn.ObjectKey, sn.BytesTotal, sn.BytesSent, int(sn.State), sn.ErrorMessage); err != nil {
			return fmt.Errorf("insert file: %w", err)
		}
	}
	return nil
}

// Save applies changes to stored rows in one transaction. Rows that do not
// exist are left alone.
func (s *Store) Save(c queue.Changes) error {
	return s.inTx(func(tx *sql.Tx) error {
		if err := updateUploads(tx, c.Uploads); err != nil {
			return err
		}
		if err := updateItems(tx, c.Items); err != nil {
			return err
		}
		return updateFiles(tx, c.Files)
	})
}

func updateUploads(tx *sql.Tx, recs []queue.UploadRecord) error {
	stmt, err := tx.Prepare(`UPDATE uploads SET object_key = ?, bytes_sent = ?, state = ?, error_message = ?,
		files_finished = ?, files_failed = ?, region = ?, prefix = ?, ended_at_ms = ? WHERE id = ?`)
	if err != nil {
		return fmt.Errorf("prepare upload update: %w", err)
	}
	defer func() { _ = stmt.Close() }()
	for _, rec := range recs {
		sn := rec.Snapshot
		if _, err := stmt.Exec(sn.ObjectKey, sn.BytesSent, int(sn.State), sn.ErrorMessage,
			sn.FilesFinished, sn.FilesFailed, rec.Region, rec.Prefix, ms(sn.EndedAt), sn.ID); err != nil {
			return fmt.Errorf("update upload: %w", err)
		}
	}
	return nil
}

func updateItems(tx *sql.Tx, updates []queue.ItemUpdate) error {
	stmt, err := tx.Prepare(`UPDATE items SET resolved_name = ? WHERE upload_id = ? AND idx = ?`)
	if err != nil {
		return fmt.Errorf("prepare item update: %w", err)
	}
	defer func() { _ = stmt.Close() }()
	for _, up := range updates {
		if _, err := stmt.Exec(up.Resolved, up.UploadID, up.Index); err != nil {
			return fmt.Errorf("update item: %w", err)
		}
	}
	return nil
}

func updateFiles(tx *sql.Tx, recs []queue.FileRecord) error {
	stmt, err := tx.Prepare(`UPDATE files SET object_key = ?, bytes_sent = ?, state = ?, error_message = ?
		WHERE upload_id = ? AND idx = ?`)
	if err != nil {
		return fmt.Errorf("prepare file update: %w", err)
	}
	defer func() { _ = stmt.Close() }()
	for _, f := range recs {
		sn := f.Snapshot
		if _, err := stmt.Exec(sn.ObjectKey, sn.BytesSent, int(sn.State), sn.ErrorMessage, sn.UploadID, sn.Index); err != nil {
			return fmt.Errorf("update file: %w", err)
		}
	}
	return nil
}

// Uploads returns every stored upload, oldest first.
func (s *Store) Uploads() ([]queue.UploadRecord, error) {
	rows, err := s.db.Query(`SELECT id, file_name, local_path, object_key, kind, root_paths, bytes_total, bytes_sent,
		state, error_message, files_total, files_finished, files_failed, bucket, region, prefix, parallel,
		created_at_ms, ended_at_ms FROM uploads ORDER BY seq`)
	if err != nil {
		return nil, fmt.Errorf("query uploads: %w", err)
	}
	defer func() { _ = rows.Close() }()
	var out []queue.UploadRecord
	for rows.Next() {
		rec, err := scanUpload(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, rec)
	}
	return out, rows.Err()
}

func scanUpload(rows *sql.Rows) (queue.UploadRecord, error) {
	var (
		rec                queue.UploadRecord
		kind, state        int
		roots              string
		createdMs, endedMs int64
		sn                 = &rec.Snapshot
	)
	if err := rows.Scan(&sn.ID, &sn.FileName, &sn.LocalPath, &sn.ObjectKey, &kind, &roots, &sn.BytesTotal, &sn.BytesSent,
		&state, &sn.ErrorMessage, &sn.FilesTotal, &sn.FilesFinished, &sn.FilesFailed, &rec.Bucket, &rec.Region, &rec.Prefix,
		&rec.Parallel, &createdMs, &endedMs); err != nil {
		return rec, fmt.Errorf("read upload: %w", err)
	}
	if err := json.Unmarshal([]byte(roots), &sn.RootPaths); err != nil {
		return rec, fmt.Errorf("decode root paths: %w", err)
	}
	sn.Kind, sn.State = queue.Kind(kind), queue.State(state)
	sn.CreatedAt, sn.EndedAt = fromMs(createdMs), fromMs(endedMs)
	return rec, nil
}

// Items returns the items of an upload in index order.
func (s *Store) Items(uploadID string) ([]queue.ItemRecord, error) {
	rows, err := s.db.Query(`SELECT idx, path, is_dir, dest_name, resolved_name FROM items WHERE upload_id = ? ORDER BY idx`, uploadID)
	if err != nil {
		return nil, fmt.Errorf("query items: %w", err)
	}
	defer func() { _ = rows.Close() }()
	out := []queue.ItemRecord{}
	for rows.Next() {
		var it queue.ItemRecord
		var isDir int
		if err := rows.Scan(&it.Index, &it.Path, &isDir, &it.DestName, &it.Resolved); err != nil {
			return nil, fmt.Errorf("read item: %w", err)
		}
		it.IsDir = isDir != 0
		out = append(out, it)
	}
	return out, rows.Err()
}

// Files returns the files of an upload in index order. It returns an empty,
// non-nil slice when the upload has none.
func (s *Store) Files(uploadID string) ([]queue.FileRecord, error) {
	rows, err := s.db.Query(`SELECT idx, item_idx, inner, unreadable, local_path, relative_path, object_key,
		bytes_total, bytes_sent, state, error_message FROM files WHERE upload_id = ? ORDER BY idx`, uploadID)
	if err != nil {
		return nil, fmt.Errorf("query files: %w", err)
	}
	defer func() { _ = rows.Close() }()
	out := []queue.FileRecord{}
	for rows.Next() {
		var f queue.FileRecord
		var unreadable, state int
		sn := &f.Snapshot
		sn.UploadID = uploadID
		if err := rows.Scan(&sn.Index, &f.Item, &f.Inner, &unreadable, &sn.LocalPath, &sn.RelativePath, &sn.ObjectKey,
			&sn.BytesTotal, &sn.BytesSent, &state, &sn.ErrorMessage); err != nil {
			return nil, fmt.Errorf("read file: %w", err)
		}
		f.Unreadable, sn.State = unreadable != 0, queue.State(state)
		out = append(out, f)
	}
	return out, rows.Err()
}

// FailInterrupted turns every upload stored as queued or uploading into a
// failed one, and each of its files that had not ended.
func (s *Store) FailInterrupted(message string, at time.Time) error {
	active := fmt.Sprintf("state IN (%d, %d)", int(queue.Queued), int(queue.Uploading))
	return s.inTx(func(tx *sql.Tx) error {
		if _, err := tx.Exec(`UPDATE files SET state = ?, error_message = ? WHERE `+active+
			` AND upload_id IN (SELECT id FROM uploads WHERE `+active+`)`, int(queue.Failed), message); err != nil {
			return fmt.Errorf("fail interrupted files: %w", err)
		}
		if _, err := tx.Exec(`UPDATE uploads SET state = ?, error_message = ?, ended_at_ms = ? WHERE `+active,
			int(queue.Failed), message, ms(at)); err != nil {
			return fmt.Errorf("fail interrupted uploads: %w", err)
		}
		return nil
	})
}

// DeleteUpload removes an upload with its items and files.
func (s *Store) DeleteUpload(uploadID string) error {
	if _, err := s.db.Exec(`DELETE FROM uploads WHERE id = ?`, uploadID); err != nil {
		return fmt.Errorf("delete upload: %w", err)
	}
	return nil
}

// DeleteFiles removes the files with the given indexes from an upload. It does
// not touch the upload's own counters.
func (s *Store) DeleteFiles(uploadID string, indexes []int) error {
	return s.inTx(func(tx *sql.Tx) error {
		stmt, err := tx.Prepare(`DELETE FROM files WHERE upload_id = ? AND idx = ?`)
		if err != nil {
			return fmt.Errorf("prepare file delete: %w", err)
		}
		defer func() { _ = stmt.Close() }()
		for _, idx := range indexes {
			if _, err := stmt.Exec(uploadID, idx); err != nil {
				return fmt.Errorf("delete file: %w", err)
			}
		}
		return nil
	})
}
