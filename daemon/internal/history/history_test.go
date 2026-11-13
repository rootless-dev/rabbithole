package history

import (
	"database/sql"
	"errors"
	"path/filepath"
	"reflect"
	"testing"
	"time"

	"rabbithole/daemon/internal/queue"
)

func openTemp(t *testing.T) (*Store, string) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "nested", "history.db")
	s, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = s.Close() })
	return s, path
}

func countRows(t *testing.T, s *Store, table, where string, args ...any) int {
	t.Helper()
	var n int
	if err := s.db.QueryRow("SELECT COUNT(*) FROM "+table+" WHERE "+where, args...).Scan(&n); err != nil {
		t.Fatal(err)
	}
	return n
}

// folderUpload is an upload of one folder with two files, one of them inside a
// sub-folder, and a second item that is a plain file.
func folderUpload(id string, created int64) (queue.UploadRecord, []queue.ItemRecord, []queue.FileRecord) {
	rec := queue.UploadRecord{
		Snapshot: queue.Snapshot{
			ID: id, FileName: "photos", LocalPath: "/home/u/photos", ObjectKey: "", BytesTotal: 30,
			State: queue.Queued, Kind: queue.Multiple, RootPaths: []string{"/home/u/photos", "/home/u/a.txt"},
			FilesTotal: 3, CreatedAt: time.UnixMilli(created),
		},
		Bucket: "bucket-1", Region: "us-east-1", Prefix: "quick/", Parallel: 4,
	}
	items := []queue.ItemRecord{
		{Index: 0, Path: "/home/u/photos", IsDir: true, DestName: "photos"},
		{Index: 1, Path: "/home/u/a.txt", DestName: "a.txt"},
	}
	files := []queue.FileRecord{
		{Snapshot: queue.FileSnapshot{UploadID: id, Index: 0, RelativePath: "photos/x.jpg", LocalPath: "/home/u/photos/x.jpg", BytesTotal: 10, State: queue.Queued}, Item: 0, Inner: "x.jpg"},
		{Snapshot: queue.FileSnapshot{UploadID: id, Index: 1, RelativePath: "photos/sub/y.jpg", LocalPath: "/home/u/photos/sub/y.jpg", BytesTotal: 15, State: queue.Queued}, Item: 0, Inner: "sub/y.jpg"},
		{Snapshot: queue.FileSnapshot{UploadID: id, Index: 2, RelativePath: "a.txt", LocalPath: "/home/u/a.txt", BytesTotal: 5, State: queue.Queued}, Item: 1, Unreadable: true},
	}
	return rec, items, files
}

func TestOpenCreatesTheSchemaAtTheCurrentVersion(t *testing.T) {
	s, path := openTemp(t)

	v, err := s.SchemaVersion()
	if err != nil || v != len(migrations) || v < 1 {
		t.Fatalf("schema version = %d (err %v), want %d", v, err, len(migrations))
	}
	for _, table := range []string{"uploads", "items", "files"} {
		if n := countRows(t, s, "sqlite_master", "type = 'table' AND name = ?", table); n != 1 {
			t.Errorf("table %s: %d found, want 1", table, n)
		}
	}
	if filepath.Base(path) != "history.db" {
		t.Fatal("test setup")
	}
	if got, err := s.Uploads(); err != nil || len(got) != 0 {
		t.Errorf("new database holds %v (err %v), want nothing", got, err)
	}
}

func TestStoredUploadComesBackAsItWasWritten(t *testing.T) {
	s, _ := openTemp(t)
	rec, items, files := folderUpload("u1", 1_700_000_000_123)

	if err := s.CreateUpload(rec, items, files); err != nil {
		t.Fatal(err)
	}

	gotRecs, err := s.Uploads()
	if err != nil {
		t.Fatal(err)
	}
	if len(gotRecs) != 1 || !reflect.DeepEqual(gotRecs[0], rec) {
		t.Errorf("upload = %+v\nwant %+v", gotRecs, rec)
	}
	if got, _ := s.Items("u1"); !reflect.DeepEqual(got, items) {
		t.Errorf("items = %+v, want %+v", got, items)
	}
	if got, _ := s.Files("u1"); !reflect.DeepEqual(got, files) {
		t.Errorf("files = %+v, want %+v", got, files)
	}
}

func TestUploadsComeBackOldestFirst(t *testing.T) {
	s, _ := openTemp(t)
	for _, id := range []string{"b", "a", "c"} {
		rec, items, files := folderUpload(id, 1000)
		if err := s.CreateUpload(rec, items, files); err != nil {
			t.Fatal(err)
		}
	}
	got, _ := s.Uploads()
	var ids []string
	for _, r := range got {
		ids = append(ids, r.Snapshot.ID)
	}
	if want := []string{"b", "a", "c"}; !reflect.DeepEqual(ids, want) {
		t.Errorf("order = %v, want insertion order %v", ids, want)
	}
}

func TestCreatingTheSameUploadTwiceFailsAndLeavesNoPartialRows(t *testing.T) {
	s, _ := openTemp(t)
	rec, items, files := folderUpload("u1", 1)
	if err := s.CreateUpload(rec, items, files); err != nil {
		t.Fatal(err)
	}
	if err := s.CreateUpload(rec, items, files); err == nil {
		t.Fatal("second CreateUpload succeeded, want an error")
	}
	if n := countRows(t, s, "files", "upload_id = ?", "u1"); n != 3 {
		t.Errorf("%d file rows, want 3", n)
	}
}

func TestSaveUpdatesTheRowsThatChange(t *testing.T) {
	s, _ := openTemp(t)
	rec, items, files := folderUpload("u1", 1000)
	if err := s.CreateUpload(rec, items, files); err != nil {
		t.Fatal(err)
	}

	rec.Snapshot.State, rec.Snapshot.ErrorMessage = queue.Failed, "1 of 3 files could not be sent"
	rec.Snapshot.FilesFinished, rec.Snapshot.FilesFailed, rec.Snapshot.BytesSent = 2, 1, 25
	rec.Snapshot.ObjectKey = "quick/photos/"
	rec.Snapshot.EndedAt = time.UnixMilli(2000)
	files[1].Snapshot.State, files[1].Snapshot.ErrorMessage = queue.Failed, "Upload failed"
	files[1].Snapshot.BytesSent, files[1].Snapshot.ObjectKey = 4, "quick/photos/sub/y.jpg"
	err := s.Save(queue.Changes{
		Uploads: []queue.UploadRecord{rec},
		Items:   []queue.ItemUpdate{{UploadID: "u1", Index: 0, Resolved: "photos-2"}},
		Files:   files[1:2],
	})
	if err != nil {
		t.Fatal(err)
	}

	gotRecs, _ := s.Uploads()
	if !reflect.DeepEqual(gotRecs[0], rec) {
		t.Errorf("upload = %+v\nwant %+v", gotRecs[0], rec)
	}
	gotItems, _ := s.Items("u1")
	if gotItems[0].Resolved != "photos-2" || gotItems[1].Resolved != "" {
		t.Errorf("items = %+v, want only the folder resolved", gotItems)
	}
	gotFiles, _ := s.Files("u1")
	if !reflect.DeepEqual(gotFiles[1], files[1]) || gotFiles[0].Snapshot.State != queue.Queued {
		t.Errorf("files = %+v, want file 1 updated and file 0 untouched", gotFiles)
	}
}

func TestSaveIgnoresRowsThatDoNotExist(t *testing.T) {
	s, _ := openTemp(t)
	rec, _, files := folderUpload("gone", 1)

	err := s.Save(queue.Changes{Uploads: []queue.UploadRecord{rec}, Files: files, Items: []queue.ItemUpdate{{UploadID: "gone"}}})

	if err != nil {
		t.Fatalf("Save of unknown rows = %v, want nil", err)
	}
	if got, _ := s.Uploads(); len(got) != 0 {
		t.Errorf("Save created %d uploads, want none", len(got))
	}
}

func TestReopeningKeepsTheHistory(t *testing.T) {
	s, path := openTemp(t)
	rec, items, files := folderUpload("u1", 1000)
	if err := s.CreateUpload(rec, items, files); err != nil {
		t.Fatal(err)
	}
	if err := s.Close(); err != nil {
		t.Fatal(err)
	}

	again, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = again.Close() }()

	if v, _ := again.SchemaVersion(); v != len(migrations) {
		t.Errorf("version after reopen = %d, want %d", v, len(migrations))
	}
	got, _ := again.Uploads()
	if len(got) != 1 || !reflect.DeepEqual(got[0], rec) {
		t.Errorf("after reopen = %+v, want %+v", got, rec)
	}
	if f, _ := again.Files("u1"); !reflect.DeepEqual(f, files) {
		t.Errorf("files after reopen = %+v, want %+v", f, files)
	}
}

func TestFailInterruptedFailsActiveUploadsAndTheirUnfinishedFiles(t *testing.T) {
	s, _ := openTemp(t)
	states := map[string]queue.State{"queued": queue.Queued, "uploading": queue.Uploading, "finished": queue.Finished, "failed": queue.Failed}
	for id, st := range states {
		rec, items, files := folderUpload(id, 1000)
		rec.Snapshot.State = st
		files[0].Snapshot.State = queue.Finished
		files[1].Snapshot.State = queue.Uploading
		if err := s.CreateUpload(rec, items, files); err != nil {
			t.Fatal(err)
		}
	}
	at := time.UnixMilli(5000)

	if err := s.FailInterrupted("Upload interrupted", at); err != nil {
		t.Fatal(err)
	}

	recs, _ := s.Uploads()
	for _, r := range recs {
		active := r.Snapshot.ID == "queued" || r.Snapshot.ID == "uploading"
		if active && (r.Snapshot.State != queue.Failed || r.Snapshot.ErrorMessage != "Upload interrupted" || !r.Snapshot.EndedAt.Equal(at)) {
			t.Errorf("%s = %+v, want failed, interrupted, ended at %v", r.Snapshot.ID, r.Snapshot, at)
		}
		if !active && (r.Snapshot.State != states[r.Snapshot.ID] || r.Snapshot.ErrorMessage != "") {
			t.Errorf("%s was touched: %+v", r.Snapshot.ID, r.Snapshot)
		}
		fs, _ := s.Files(r.Snapshot.ID)
		wantSecond := queue.Uploading
		if active {
			wantSecond = queue.Failed
		}
		if fs[0].Snapshot.State != queue.Finished || fs[1].Snapshot.State != wantSecond {
			t.Errorf("%s files = %v, %v, want finished and %v", r.Snapshot.ID, fs[0].Snapshot.State, fs[1].Snapshot.State, wantSecond)
		}
		if active && fs[1].Snapshot.ErrorMessage != "Upload interrupted" {
			t.Errorf("%s file message = %q", r.Snapshot.ID, fs[1].Snapshot.ErrorMessage)
		}
	}
}

func TestDeleteUploadRemovesItsItemsAndFilesToo(t *testing.T) {
	s, _ := openTemp(t)
	for _, id := range []string{"keep", "drop"} {
		rec, items, files := folderUpload(id, 1)
		if err := s.CreateUpload(rec, items, files); err != nil {
			t.Fatal(err)
		}
	}

	if err := s.DeleteUpload("drop"); err != nil {
		t.Fatal(err)
	}

	if n := countRows(t, s, "uploads", "id = 'drop'"); n != 0 {
		t.Errorf("upload rows left = %d", n)
	}
	if n := countRows(t, s, "files", "upload_id = 'drop'") + countRows(t, s, "items", "upload_id = 'drop'"); n != 0 {
		t.Errorf("%d item and file rows left, want none", n)
	}
	if n := countRows(t, s, "files", "upload_id = 'keep'"); n != 3 {
		t.Errorf("other upload has %d files, want 3", n)
	}
}

func TestDeleteFilesRemovesOnlyTheListedOnes(t *testing.T) {
	s, _ := openTemp(t)
	rec, items, files := folderUpload("u1", 1)
	if err := s.CreateUpload(rec, items, files); err != nil {
		t.Fatal(err)
	}

	if err := s.DeleteFiles("u1", []int{0, 2}); err != nil {
		t.Fatal(err)
	}

	got, _ := s.Files("u1")
	if len(got) != 1 || got[0].Snapshot.Index != 1 {
		t.Errorf("files = %+v, want only index 1", got)
	}
}

func TestOpenRefusesADatabaseOfANewerSchema(t *testing.T) {
	_, path := openTemp(t)
	raw, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := raw.Exec("PRAGMA user_version = 99"); err != nil {
		t.Fatal(err)
	}
	_ = raw.Close()

	if _, err := Open(path); !errors.Is(err, ErrNewerSchema) {
		t.Fatalf("Open = %v, want ErrNewerSchema", err)
	}
}

func TestSaveStoresTheFileCountAndByteTotalOfAnUpload(t *testing.T) {
	s, _ := openTemp(t)
	rec, items, files := folderUpload("u1", 1)
	if err := s.CreateUpload(rec, items, files); err != nil {
		t.Fatal(err)
	}

	rec.Snapshot.FilesTotal, rec.Snapshot.BytesTotal = 1, 5
	if err := s.Save(queue.Changes{Uploads: []queue.UploadRecord{rec}}); err != nil {
		t.Fatal(err)
	}

	got, err := s.Uploads()
	if err != nil || len(got) != 1 || got[0].Snapshot.FilesTotal != 1 || got[0].Snapshot.BytesTotal != 5 {
		t.Fatalf("stored upload = %+v (err %v), want 1 file and 5 bytes", got, err)
	}
}

func TestOpenFailsWhenThePathIsAFolder(t *testing.T) {
	dir := t.TempDir()

	if s, err := Open(dir); err == nil {
		_ = s.Close()
		t.Fatal("Open of a folder succeeded, want an error")
	}
}
