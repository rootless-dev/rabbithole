package uploader

import (
	"context"
	"errors"
	"os"
	"slices"
	"testing"
	"time"
)

// recordOf is the record of a multipart upload started from the file at path as
// it is now.
func recordOf(t *testing.T, path, uploadID string, parts ...CompletedPart) *Multipart {
	t.Helper()
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	return &Multipart{
		Key: "p/big.bin", UploadID: uploadID, PartSize: PartSize(info.Size()),
		FileSize: info.Size(), ModTimeNanos: info.ModTime().UnixNano(), Parts: parts,
	}
}

func heldPart(number int32, size int64) HeldPart {
	return HeldPart{Number: number, ETag: "held-" + string(rune('0'+number)), Size: size}
}

func TestResumeSendsOnlyThePartsS3DoesNotHold(t *testing.T) {
	path := sparseFile(t, "big.bin", 24*MiB)
	fake := newFake()
	fake.held = []HeldPart{heldPart(1, 8*MiB), heldPart(2, 8*MiB)}
	rec := &recorder{}

	err := newUploader().Upload(context.Background(), fake,
		Request{Prefix: "p/", LocalPath: path, Resume: recordOf(t, path, "old-id", CompletedPart{1, "held-1"}, CompletedPart{2, "held-2"})}, rec.callbacks())
	if err != nil {
		t.Fatal(err)
	}
	if !slices.Equal(fake.partNumbers, []int32{3}) {
		t.Fatalf("parts sent = %v, want only part 3", fake.partNumbers)
	}
	want := []CompletedPart{{1, "held-1"}, {2, "held-2"}, {3, "etag-3"}}
	if !slices.Equal(fake.completed, want) || fake.completeID != "old-id" || fake.completeKey != "p/big.bin" {
		t.Fatalf("completed %v under %q/%q, want %v under p/big.bin/old-id", fake.completed, fake.completeKey, fake.completeID, want)
	}
	if slices.Contains(fake.calls, "create") || slices.Contains(fake.calls, "abort") || slices.Contains(fake.calls, "exists") {
		t.Fatalf("calls = %v, want neither create, abort nor an existence check", fake.calls)
	}
	if len(rec.progress) == 0 || rec.progress[0] != 16*MiB || rec.lastProgress() != 24*MiB {
		t.Fatalf("progress = %v, want it to start at the 16 MiB S3 holds and end at 24 MiB", rec.progress)
	}
	if !slices.Equal(rec.keys, []string{"p/big.bin"}) {
		t.Fatalf("resolved keys = %v, want the recorded key", rec.keys)
	}
}

func TestResumeTrustsS3OverTheLocalRecord(t *testing.T) {
	path := sparseFile(t, "big.bin", 24*MiB)
	fake := newFake()
	fake.held = []HeldPart{heldPart(1, 8*MiB)} // the record claims parts 1 and 2
	var adopted []Multipart

	err := newUploader().Upload(context.Background(), fake,
		Request{Prefix: "p/", LocalPath: path, Resume: recordOf(t, path, "old-id", CompletedPart{1, "held-1"}, CompletedPart{2, "stale-2"})},
		Callbacks{MultipartRecorded: func(m Multipart) { adopted = append(adopted, m) }})
	if err != nil {
		t.Fatal(err)
	}
	if !slices.Equal(fake.partNumbers, []int32{2, 3}) {
		t.Fatalf("parts sent = %v, want 2 and 3", fake.partNumbers)
	}
	if len(adopted) != 1 || !slices.Equal(adopted[0].Parts, []CompletedPart{{1, "held-1"}}) {
		t.Fatalf("record after listing = %+v, want only part 1 from S3", adopted)
	}
}

func TestResumeTrustsS3OverTheLocalRecordWhenS3HoldsMore(t *testing.T) {
	path := sparseFile(t, "big.bin", 24*MiB)
	fake := newFake()
	fake.held = []HeldPart{heldPart(1, 8*MiB), heldPart(2, 8*MiB), heldPart(3, 8*MiB)}

	err := newUploader().Upload(context.Background(), fake,
		Request{Prefix: "p/", LocalPath: path, Resume: recordOf(t, path, "old-id")}, Callbacks{})
	if err != nil {
		t.Fatal(err)
	}
	if len(fake.partNumbers) != 0 || len(fake.completed) != 3 {
		t.Fatalf("parts sent = %v, completed = %v; want nothing sent and all three completed", fake.partNumbers, fake.completed)
	}
}

func TestResumeSendsAgainAHeldPartOfTheWrongSize(t *testing.T) {
	path := sparseFile(t, "big.bin", 16*MiB)
	fake := newFake()
	fake.held = []HeldPart{heldPart(1, 5*MiB), heldPart(2, 8*MiB)}

	err := newUploader().Upload(context.Background(), fake,
		Request{Prefix: "p/", LocalPath: path, Resume: recordOf(t, path, "old-id")}, Callbacks{})
	if err != nil {
		t.Fatal(err)
	}
	if !slices.Equal(fake.partNumbers, []int32{1}) {
		t.Fatalf("parts sent = %v, want part 1 again", fake.partNumbers)
	}
}

func TestChangedFileAbortsTheOldUploadAndStartsOver(t *testing.T) {
	cases := []struct {
		name   string
		change func(t *testing.T, path string)
	}{
		{"size", func(t *testing.T, path string) {
			if err := os.Truncate(path, 17*MiB); err != nil {
				t.Fatal(err)
			}
		}},
		{"modification time", func(t *testing.T, path string) {
			later := time.Now().Add(time.Hour)
			if err := os.Chtimes(path, later, later); err != nil {
				t.Fatal(err)
			}
		}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			path := sparseFile(t, "big.bin", 16*MiB)
			old := recordOf(t, path, "old-id", CompletedPart{1, "held-1"})
			tc.change(t, path)
			fake := newFake()
			fake.held = []HeldPart{heldPart(1, 8*MiB)}
			ended := 0

			err := newUploader().Upload(context.Background(), fake, Request{Prefix: "p/", LocalPath: path, Resume: old},
				Callbacks{MultipartEnded: func() { ended++ }})
			if err != nil {
				t.Fatal(err)
			}
			if !slices.Equal(fake.abortedIDs, []string{"old-id"}) {
				t.Fatalf("aborted = %v, want the old upload", fake.abortedIDs)
			}
			if slices.Contains(fake.calls, "list-parts") {
				t.Fatalf("calls = %v: a changed file must not ask S3 for parts", fake.calls)
			}
			if len(fake.createdKeys) != 1 || fake.completeID != "upload-1" {
				t.Fatalf("created %v, completed under %q; want a fresh multipart upload", fake.createdKeys, fake.completeID)
			}
			if ended < 1 {
				t.Fatal("the old record was not ended")
			}
		})
	}
}

func TestUploadIdUnknownToS3StartsOverWithoutAnAbort(t *testing.T) {
	path := sparseFile(t, "big.bin", 16*MiB)
	fake := newFake()
	fake.listErr = ErrNoSuchUpload
	ended := 0

	err := newUploader().Upload(context.Background(), fake,
		Request{Prefix: "p/", LocalPath: path, Resume: recordOf(t, path, "old-id", CompletedPart{1, "held-1"})},
		Callbacks{MultipartEnded: func() { ended++ }})
	if err != nil {
		t.Fatal(err)
	}
	if fake.aborted {
		t.Fatalf("aborted %v: S3 does not know that upload", fake.abortedIDs)
	}
	if !slices.Equal(fake.partNumbers, []int32{1, 2}) || fake.completeID != "upload-1" || ended < 1 {
		t.Fatalf("parts %v, completed under %q, ended %d; want a full fresh upload and the old record ended", fake.partNumbers, fake.completeID, ended)
	}
}

func TestDeniedListPartsStartsOverAndAbortsTheOldUpload(t *testing.T) {
	path := sparseFile(t, "big.bin", 16*MiB)
	fake := newFake()
	fake.listErr = ErrListPartsDenied

	err := newUploader().Upload(context.Background(), fake,
		Request{Prefix: "p/", LocalPath: path, Resume: recordOf(t, path, "old-id", CompletedPart{1, "held-1"})}, Callbacks{})
	if err != nil {
		t.Fatalf("a denied ListParts must not fail the file: %v", err)
	}
	if !slices.Equal(fake.abortedIDs, []string{"old-id"}) {
		t.Fatalf("aborted = %v, want the old upload", fake.abortedIDs)
	}
	if !slices.Equal(fake.partNumbers, []int32{1, 2}) || fake.completeID != "upload-1" {
		t.Fatalf("parts %v completed under %q; want everything sent again under a new upload", fake.partNumbers, fake.completeID)
	}
}

func TestListPartsFailureOtherThanDenialFailsTheFileAndKeepsTheUpload(t *testing.T) {
	path := sparseFile(t, "big.bin", 16*MiB)
	fake := newFake()
	fake.listErr = ErrNoNetwork

	err := newUploader().Upload(context.Background(), fake,
		Request{Prefix: "p/", LocalPath: path, Resume: recordOf(t, path, "old-id")}, Callbacks{MultipartEnded: func() { t.Error("record ended") }})
	if !errors.Is(err, ErrNoNetwork) {
		t.Fatalf("err = %v, want ErrNoNetwork", err)
	}
	if fake.aborted || slices.Contains(fake.calls, "create") {
		t.Fatalf("calls = %v, want neither abort nor create", fake.calls)
	}
}

func TestRecordForAFileNowBelowTheThresholdStartsOverWithAPut(t *testing.T) {
	path := sparseFile(t, "big.bin", 16*MiB)
	old := recordOf(t, path, "old-id")
	if err := os.Truncate(path, 1024); err != nil {
		t.Fatal(err)
	}
	fake := newFake()

	if err := newUploader().Upload(context.Background(), fake, Request{Prefix: "p/", LocalPath: path, Resume: old}, Callbacks{}); err != nil {
		t.Fatal(err)
	}
	if !slices.Equal(fake.abortedIDs, []string{"old-id"}) || !slices.Equal(fake.putKeys, []string{"p/big.bin"}) {
		t.Fatalf("aborted %v, put %v; want the old upload aborted and a plain put", fake.abortedIDs, fake.putKeys)
	}
}

func TestResumedUploadRejectedAtCompletionAbortsAndEndsTheRecord(t *testing.T) {
	path := sparseFile(t, "big.bin", 16*MiB)
	fake := newFake()
	fake.held = []HeldPart{heldPart(1, 8*MiB), heldPart(2, 8*MiB)}
	fake.completeErr = ErrPreconditionFailed
	ended := 0

	err := newUploader().Upload(context.Background(), fake, Request{Prefix: "p/", LocalPath: path, Resume: recordOf(t, path, "old-id")},
		Callbacks{MultipartEnded: func() { ended++ }})
	if !errors.Is(err, ErrPreconditionFailed) {
		t.Fatalf("err = %v, want ErrPreconditionFailed", err)
	}
	if !slices.Equal(fake.abortedIDs, []string{"old-id"}) || ended != 1 {
		t.Fatalf("aborted %v, ended %d; want the old upload aborted and its record ended once", fake.abortedIDs, ended)
	}
}
