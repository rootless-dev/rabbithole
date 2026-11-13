package queue

import (
	"errors"
	"testing"
)

func downloadNames(files []DownloadFile) []string {
	var out []string
	for _, f := range files {
		out = append(out, f.RelativePath+"="+f.ObjectKey)
	}
	return out
}

func TestDownloadFilesReturnsOnlyFinishedFilesWithTheirKeys(t *testing.T) {
	e := endFolder(t, "b")

	got, err := e.q.DownloadFiles("bucket-1", e.id, nil)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 {
		t.Fatalf("files = %v, want a and c only (b failed)", downloadNames(got))
	}
	for _, f := range got {
		if f.ObjectKey == "" || f.RelativePath == "" || f.RelativePath[:2] != "d/" {
			t.Fatalf("file %+v lacks its key or relative path", f)
		}
	}
}

func TestDownloadFilesHonoursIndexesAndSkipsUnfinishedOnes(t *testing.T) {
	e := endFolder(t, "b")

	got, err := e.q.DownloadFiles("bucket-1", e.id, e.indexes("a", "b"))
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 1 || got[0].Index != e.index["a"] {
		t.Fatalf("files = %v, want only a: b did not finish", downloadNames(got))
	}
}

func TestDownloadFilesRefusals(t *testing.T) {
	failed := endFolder(t, "a", "b", "c")
	ok := endFolder(t)
	tests := []struct {
		name    string
		call    func() error
		wantErr error
	}{
		{"unknown upload", func() error { _, err := ok.q.DownloadFiles("bucket-1", "nope", nil); return err }, ErrUnknownUpload},
		{"unknown index", func() error { _, err := ok.q.DownloadFiles("bucket-1", ok.id, []int{99}); return err }, ErrUnknownFile},
		{"other bucket", func() error { _, err := ok.q.DownloadFiles("bucket-2", ok.id, nil); return err }, ErrOtherBucket},
		{"nothing finished", func() error { _, err := failed.q.DownloadFiles("bucket-1", failed.id, nil); return err }, ErrNoFinishedFiles},
	}
	for _, tt := range tests {
		if err := tt.call(); !errors.Is(err, tt.wantErr) {
			t.Errorf("%s: err = %v, want %v", tt.name, err, tt.wantErr)
		}
	}
}
