package history

import (
	"database/sql"
	"path/filepath"
	"reflect"
	"testing"
	"time"

	"rabbithole/daemon/internal/queue"
	"rabbithole/daemon/internal/uploader"
)

func sampleMultipart(id string) uploader.Multipart {
	return uploader.Multipart{
		Key: "quick/photos/x.jpg", UploadID: id, PartSize: 8 << 20, FileSize: 20 << 20, ModTimeNanos: 1_700_000_000_123_456_789,
		Parts: []uploader.CompletedPart{{Number: 1, ETag: `"a"`}, {Number: 2, ETag: `"b"`}},
	}
}

func TestVersionOneDatabaseOpensAndMigratesKeepingItsHistory(t *testing.T) {
	path := filepath.Join(t.TempDir(), "history.db")
	raw, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	// Exactly what the first release wrote: the version 1 schema and a row.
	for _, stmt := range []string{
		migrations[0],
		`INSERT INTO uploads (id, file_name, local_path, object_key, kind, root_paths, bytes_total, bytes_sent, state,
			error_message, files_total, files_finished, files_failed, bucket, region, prefix, parallel, created_at_ms, ended_at_ms)
			VALUES ('old', 'a.txt', '/a.txt', 'quick/a.txt', 0, '["/a.txt"]', 5, 5, 2, '', 1, 1, 0, 'b', 'r', 'quick/', 4, 10, 20)`,
		`INSERT INTO files (upload_id, idx, item_idx, inner, unreadable, local_path, relative_path, object_key, bytes_total,
			bytes_sent, state, error_message) VALUES ('old', 0, 0, '', 0, '/a.txt', 'a.txt', 'quick/a.txt', 5, 5, 2, '')`,
		`PRAGMA user_version = 1`,
	} {
		if _, err := raw.Exec(stmt); err != nil {
			t.Fatalf("seeding a version 1 database: %v", err)
		}
	}
	_ = raw.Close()

	s, err := Open(path)
	if err != nil {
		t.Fatalf("Open of a version 1 database: %v", err)
	}
	defer s.Close()

	if v, err := s.SchemaVersion(); err != nil || v != 2 || len(migrations) != 2 {
		t.Fatalf("schema version = %d (err %v), migrations = %d; want 2", v, err, len(migrations))
	}
	ups, err := s.Uploads()
	if err != nil || len(ups) != 1 || ups[0].Snapshot.ID != "old" || ups[0].Snapshot.State != queue.Finished {
		t.Fatalf("uploads after the migration = %+v (err %v), want the old one intact", ups, err)
	}
	files, err := s.Files("old")
	if err != nil || len(files) != 1 || files[0].Snapshot.ObjectKey != "quick/a.txt" {
		t.Fatalf("files after the migration = %+v (err %v)", files, err)
	}
	if got, err := s.Multiparts("old"); err != nil || len(got) != 0 {
		t.Fatalf("multipart records of an old upload = %v (err %v), want none", got, err)
	}
	// The new table works on the migrated database.
	m := sampleMultipart("up-1")
	if err := s.Save(queue.Changes{Multiparts: []queue.MultipartChange{{UploadID: "old", Index: 0, Record: &m}}}); err != nil {
		t.Fatal(err)
	}
	if got, _ := s.Multiparts("old"); !reflect.DeepEqual(got[0], m) {
		t.Fatalf("record = %+v, want %+v", got[0], m)
	}
}

func TestMultipartRecordComesBackAsItWasWrittenAndIsReplacedAndCleared(t *testing.T) {
	s, _ := openTemp(t)
	rec, items, files := folderUpload("u1", 1)
	if err := s.CreateUpload(rec, items, files); err != nil {
		t.Fatal(err)
	}
	first := sampleMultipart("up-1")
	if err := s.Save(queue.Changes{Multiparts: []queue.MultipartChange{{UploadID: "u1", Index: 1, Record: &first}}}); err != nil {
		t.Fatal(err)
	}
	got, err := s.Multiparts("u1")
	if err != nil || !reflect.DeepEqual(got, map[int]uploader.Multipart{1: first}) {
		t.Fatalf("records = %+v (err %v), want %+v", got, err, first)
	}

	second := first
	second.Parts = append(append([]uploader.CompletedPart(nil), first.Parts...), uploader.CompletedPart{Number: 3, ETag: `"c"`})
	if err := s.Save(queue.Changes{Multiparts: []queue.MultipartChange{{UploadID: "u1", Index: 1, Record: &second}}}); err != nil {
		t.Fatal(err)
	}
	if got, _ := s.Multiparts("u1"); !reflect.DeepEqual(got[1], second) || len(got) != 1 {
		t.Fatalf("records after an update = %+v, want the new one only", got)
	}

	if err := s.Save(queue.Changes{Multiparts: []queue.MultipartChange{{UploadID: "u1", Index: 1}}}); err != nil {
		t.Fatal(err)
	}
	if got, _ := s.Multiparts("u1"); len(got) != 0 {
		t.Fatalf("records after clearing = %+v, want none", got)
	}
}

func TestMultipartRecordOfAFileThatDoesNotExistIsIgnored(t *testing.T) {
	s, _ := openTemp(t)
	m := sampleMultipart("up-1")

	err := s.Save(queue.Changes{Multiparts: []queue.MultipartChange{{UploadID: "nope", Index: 0, Record: &m}, {UploadID: "nope", Index: 1}}})

	if err != nil {
		t.Fatalf("Save = %v, want nil: the file may have been removed meanwhile", err)
	}
	if n := countRows(t, s, "multiparts", "1 = 1"); n != 0 {
		t.Fatalf("%d records stored for a file that does not exist", n)
	}
}

func TestMultipartRecordsGoWithTheirFilesAndUploads(t *testing.T) {
	s, _ := openTemp(t)
	rec, items, files := folderUpload("u1", 1)
	if err := s.CreateUpload(rec, items, files); err != nil {
		t.Fatal(err)
	}
	m := sampleMultipart("up-1")
	if err := s.Save(queue.Changes{Multiparts: []queue.MultipartChange{
		{UploadID: "u1", Index: 0, Record: &m}, {UploadID: "u1", Index: 1, Record: &m},
	}}); err != nil {
		t.Fatal(err)
	}

	if err := s.DeleteFiles("u1", []int{0}); err != nil {
		t.Fatal(err)
	}
	got, _ := s.Multiparts("u1")
	if _, has1 := got[1]; len(got) != 1 || !has1 {
		t.Fatalf("records after deleting file 0 = %+v, want only file 1's", got)
	}
	if err := s.DeleteUpload("u1"); err != nil {
		t.Fatal(err)
	}
	if n := countRows(t, s, "multiparts", "1 = 1"); n != 0 {
		t.Fatalf("%d records left after the upload was deleted", n)
	}
}

func TestPausedAndCanceledStatesAreStoredAndFailInterruptedLeavesPausedAlone(t *testing.T) {
	s, _ := openTemp(t)
	rec, items, files := folderUpload("u1", 1)
	rec.Snapshot.State = queue.Paused
	files[0].Snapshot.State = queue.Paused
	if err := s.CreateUpload(rec, items, files); err != nil {
		t.Fatal(err)
	}
	rec2, items2, files2 := folderUpload("u2", 2)
	rec2.Snapshot.State = queue.Canceled
	rec2.Snapshot.EndedAt = time.UnixMilli(99)
	files2[0].Snapshot.State = queue.Canceled
	if err := s.CreateUpload(rec2, items2, files2); err != nil {
		t.Fatal(err)
	}

	if err := s.FailInterrupted("Upload interrupted", time.UnixMilli(500)); err != nil {
		t.Fatal(err)
	}

	got, err := s.Uploads()
	if err != nil || got[0].Snapshot.State != queue.Paused || got[1].Snapshot.State != queue.Canceled {
		t.Fatalf("uploads = %+v (err %v), want paused and canceled untouched", got, err)
	}
	f1, _ := s.Files("u1")
	if f1[0].Snapshot.State != queue.Paused || f1[1].Snapshot.State != queue.Queued {
		t.Fatalf("files of the paused upload = %+v", f1)
	}
}
