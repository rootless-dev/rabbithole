package uploader

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"slices"
	"strings"
	"testing"
	"time"
)

// fakeS3 records calls and can be scripted per call.
type fakeS3 struct {
	existing map[string]bool

	existsErr   error
	putErr      func(key string) error
	partErr     func(number int32) error
	createErr   error
	completeErr error
	abortErr    error

	// What ListParts answers.
	held    []HeldPart
	listErr error

	// Hooks run at the start of the named call.
	onExists func()
	onPart   func(number int32)

	// readBodyTwice makes the fake read each body again after the first pass,
	// the way an SDK retry might.
	readBodyTwice bool

	calls         []string
	prefixes      []string
	putKeys       []string
	putSizes      []int64
	partSizes     []int64
	partNumbers   []int32
	completeKey   string
	completeID    string
	abortedIDs    []string
	createdKeys   []string
	completed     []CompletedPart
	aborted       bool
	abortCtxErr   error
	abortHadDline bool
	abortDeadline time.Duration
}

func newFake(existing ...string) *fakeS3 {
	f := &fakeS3{existing: map[string]bool{}}
	for _, k := range existing {
		f.existing[k] = true
	}
	return f
}

func (f *fakeS3) writeCalls() int {
	n := 0
	for _, c := range f.calls {
		if c != "exists" && c != "prefix" {
			n++
		}
	}
	return n
}

func (f *fakeS3) drain(body io.Reader) error {
	if _, err := io.Copy(io.Discard, body); err != nil {
		return err
	}
	if f.readBodyTwice {
		// A second pass over an exhausted reader yields nothing and must not
		// disturb progress.
		if _, err := io.Copy(io.Discard, body); err != nil {
			return err
		}
	}
	return nil
}

func (f *fakeS3) ObjectExists(ctx context.Context, key string) (bool, error) {
	f.calls = append(f.calls, "exists")
	if f.onExists != nil {
		f.onExists()
	}
	if f.existsErr != nil {
		return false, f.existsErr
	}
	return f.existing[key], nil
}

func (f *fakeS3) PrefixExists(ctx context.Context, prefix string) (bool, error) {
	f.calls = append(f.calls, "prefix")
	f.prefixes = append(f.prefixes, prefix)
	if f.existsErr != nil {
		return false, f.existsErr
	}
	for k := range f.existing {
		if strings.HasPrefix(k, prefix) {
			return true, nil
		}
	}
	return false, nil
}

func (f *fakeS3) DeleteObjects(_ context.Context, keys []string) ([]string, error) {
	f.calls = append(f.calls, "delete")
	return keys, nil
}

func (f *fakeS3) ListKeys(context.Context, string, func(string)) error {
	f.calls = append(f.calls, "list")
	return nil
}

func (f *fakeS3) PutObject(ctx context.Context, key string, body io.Reader, size int64) error {
	f.calls = append(f.calls, "put")
	f.putKeys = append(f.putKeys, key)
	f.putSizes = append(f.putSizes, size)
	if f.putErr != nil {
		if err := f.putErr(key); err != nil {
			return err
		}
	}
	if err := f.drain(body); err != nil {
		return err
	}
	f.existing[key] = true
	return nil
}

func (f *fakeS3) CreateMultipart(ctx context.Context, key string) (string, error) {
	f.calls = append(f.calls, "create")
	f.createdKeys = append(f.createdKeys, key)
	if f.createErr != nil {
		return "", f.createErr
	}
	return "upload-1", nil
}

func (f *fakeS3) UploadPart(ctx context.Context, key, uploadID string, number int32, body io.Reader, size int64) (string, error) {
	f.calls = append(f.calls, "part")
	f.partSizes = append(f.partSizes, size)
	f.partNumbers = append(f.partNumbers, number)
	if f.onPart != nil {
		f.onPart(number)
	}
	if f.partErr != nil {
		if err := f.partErr(number); err != nil {
			return "", err
		}
	}
	if err := ctx.Err(); err != nil {
		return "", err
	}
	if err := f.drain(body); err != nil {
		return "", err
	}
	return fmt.Sprintf("etag-%d", number), nil
}

func (f *fakeS3) CompleteMultipart(ctx context.Context, key, uploadID string, parts []CompletedPart) error {
	f.calls = append(f.calls, "complete")
	f.completed = parts
	f.completeKey, f.completeID = key, uploadID
	return f.completeErr
}

func (f *fakeS3) ListParts(context.Context, string, string) ([]HeldPart, error) {
	f.calls = append(f.calls, "list-parts")
	return f.held, f.listErr
}

func (f *fakeS3) AbortMultipart(ctx context.Context, key, uploadID string) error {
	f.calls = append(f.calls, "abort")
	f.aborted = true
	f.abortedIDs = append(f.abortedIDs, uploadID)
	f.abortCtxErr = ctx.Err()
	if d, ok := ctx.Deadline(); ok {
		f.abortHadDline = true
		f.abortDeadline = time.Until(d)
	}
	return f.abortErr
}

var fixedNow = time.Date(2026, 3, 5, 14, 30, 9, 0, time.Local)

func newUploader() *Uploader { return New(func() time.Time { return fixedNow }) }

// sparseFile creates a file of the given size without writing its content.
func sparseFile(t *testing.T, name string, size int64) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), name)
	if err := os.WriteFile(path, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Truncate(path, size); err != nil {
		t.Fatal(err)
	}
	return path
}

type recorder struct {
	keys     []string
	progress []int64
}

func (r *recorder) callbacks() Callbacks {
	return Callbacks{
		KeyResolved: func(key string) { r.keys = append(r.keys, key) },
		Progress:    func(sent int64) { r.progress = append(r.progress, sent) },
	}
}

func (r *recorder) lastProgress() int64 {
	if len(r.progress) == 0 {
		return -1
	}
	return r.progress[len(r.progress)-1]
}

func TestSmallFileUsesSinglePut(t *testing.T) {
	size := int64(16*MiB - 1)
	path := sparseFile(t, "small.bin", size)
	fake := newFake()
	rec := &recorder{}

	err := newUploader().Upload(context.Background(), fake, Request{Prefix: "quick-uploads/", LocalPath: path}, rec.callbacks())
	if err != nil {
		t.Fatal(err)
	}
	if !slices.Equal(fake.putKeys, []string{"quick-uploads/small.bin"}) {
		t.Fatalf("put keys = %v", fake.putKeys)
	}
	if fake.putSizes[0] != size {
		t.Fatalf("put size = %d, want %d", fake.putSizes[0], size)
	}
	for _, c := range fake.calls {
		if c == "create" || c == "part" || c == "complete" || c == "abort" {
			t.Fatalf("unexpected multipart call %q in %v", c, fake.calls)
		}
	}
	if rec.lastProgress() != size {
		t.Fatalf("last progress = %d, want %d", rec.lastProgress(), size)
	}
	if !slices.Equal(rec.keys, []string{"quick-uploads/small.bin"}) {
		t.Fatalf("resolved keys = %v", rec.keys)
	}
}

func TestSixteenMiBUsesMultipart(t *testing.T) {
	size := int64(16 * MiB)
	path := sparseFile(t, "big.bin", size)
	fake := newFake()
	rec := &recorder{}

	err := newUploader().Upload(context.Background(), fake, Request{Prefix: "p/", LocalPath: path}, rec.callbacks())
	if err != nil {
		t.Fatal(err)
	}
	if !slices.Equal(fake.partSizes, []int64{8 * MiB, 8 * MiB}) {
		t.Fatalf("part sizes = %v", fake.partSizes)
	}
	want := []CompletedPart{{1, "etag-1"}, {2, "etag-2"}}
	if !slices.Equal(fake.completed, want) {
		t.Fatalf("completed = %v, want %v", fake.completed, want)
	}
	if fake.aborted {
		t.Fatal("multipart upload was aborted on success")
	}
	if slices.Contains(fake.calls, "put") {
		t.Fatalf("unexpected PutObject in %v", fake.calls)
	}
	if rec.lastProgress() != size {
		t.Fatalf("last progress = %d, want %d", rec.lastProgress(), size)
	}
}

func TestZeroByteFile(t *testing.T) {
	path := sparseFile(t, "empty.txt", 0)
	fake := newFake()
	rec := &recorder{}

	err := newUploader().Upload(context.Background(), fake, Request{Prefix: "p/", LocalPath: path}, rec.callbacks())
	if err != nil {
		t.Fatal(err)
	}
	if !slices.Equal(fake.putKeys, []string{"p/empty.txt"}) || fake.putSizes[0] != 0 {
		t.Fatalf("puts = %v sizes = %v", fake.putKeys, fake.putSizes)
	}
	for _, p := range rec.progress {
		if p != 0 {
			t.Fatalf("progress %d for an empty file", p)
		}
	}
}

func TestExistingKeyGetsTimestamp(t *testing.T) {
	path := sparseFile(t, "report.pdf", 10)
	fake := newFake("p/report.pdf")
	rec := &recorder{}

	if err := newUploader().Upload(context.Background(), fake, Request{Prefix: "p/", LocalPath: path}, rec.callbacks()); err != nil {
		t.Fatal(err)
	}
	want := CandidateKey("p/", "report.pdf", fixedNow, 1)
	if !slices.Equal(fake.putKeys, []string{want}) {
		t.Fatalf("put keys = %v, want [%s]", fake.putKeys, want)
	}
	if !slices.Equal(rec.keys, []string{want}) {
		t.Fatalf("resolved keys = %v", rec.keys)
	}
}

func TestExistingTimestampedKeyGetsSuffix(t *testing.T) {
	path := sparseFile(t, "report.pdf", 10)
	fake := newFake("p/report.pdf", CandidateKey("p/", "report.pdf", fixedNow, 1))
	rec := &recorder{}

	if err := newUploader().Upload(context.Background(), fake, Request{Prefix: "p/", LocalPath: path}, rec.callbacks()); err != nil {
		t.Fatal(err)
	}
	want := CandidateKey("p/", "report.pdf", fixedNow, 2)
	if !strings.HasSuffix(want, "-2.pdf") {
		t.Fatalf("candidate %q does not end in -2.pdf", want)
	}
	if !slices.Equal(fake.putKeys, []string{want}) {
		t.Fatalf("put keys = %v, want [%s]", fake.putKeys, want)
	}
}

func TestCandidatesShareOneTimestampWhenTheClockAdvances(t *testing.T) {
	path := sparseFile(t, "report.pdf", 10)
	tick := fixedNow
	u := New(func() time.Time {
		tick = tick.Add(time.Second) // every read of the clock differs
		return tick
	})
	// The timestamp is read once, before the loop; the first read is fixedNow+1s.
	stamp := fixedNow.Add(time.Second)
	fake := newFake("p/report.pdf", CandidateKey("p/", "report.pdf", stamp, 1))

	if err := u.Upload(context.Background(), fake, Request{Prefix: "p/", LocalPath: path}, Callbacks{}); err != nil {
		t.Fatal(err)
	}
	want := CandidateKey("p/", "report.pdf", stamp, 2)
	if !strings.HasSuffix(want, "-2.pdf") {
		t.Fatalf("candidate %q does not end in -2.pdf", want)
	}
	if !slices.Equal(fake.putKeys, []string{want}) {
		t.Fatalf("put keys = %v, want [%s]", fake.putKeys, want)
	}
}

// everythingExists reports every key as taken.
type everythingExists struct {
	*fakeS3
	checks int
}

func (e *everythingExists) ObjectExists(ctx context.Context, key string) (bool, error) {
	e.checks++
	return true, nil
}

func TestUploadGivesUpAfterAThousandTakenNames(t *testing.T) {
	path := sparseFile(t, "report.pdf", 10)
	fake := &everythingExists{fakeS3: newFake()}

	err := newUploader().Upload(context.Background(), fake, Request{Prefix: "p/", LocalPath: path}, Callbacks{})
	if !errors.Is(err, ErrNoFreeName) {
		t.Fatalf("error = %v, want ErrNoFreeName", err)
	}
	if fake.checks != 1000 {
		t.Fatalf("existence checks = %d, want 1000", fake.checks)
	}
	if fake.writeCalls() != 0 {
		t.Fatalf("write calls = %v, want none", fake.calls)
	}
	if got := Message(err); got != "Could not find a free name for this file" {
		t.Fatalf("Message = %q", got)
	}
}

func TestSinglePutRejectedWriteMovesToNextCandidate(t *testing.T) {
	path := sparseFile(t, "a.txt", 10)
	fake := newFake()
	first := "p/a.txt"
	fake.putErr = func(key string) error {
		if key == first {
			return fmt.Errorf("put: %w", ErrPreconditionFailed)
		}
		return nil
	}
	rec := &recorder{}

	if err := newUploader().Upload(context.Background(), fake, Request{Prefix: "p/", LocalPath: path}, rec.callbacks()); err != nil {
		t.Fatal(err)
	}
	final := CandidateKey("p/", "a.txt", fixedNow, 1)
	if !slices.Equal(fake.putKeys, []string{first, final}) {
		t.Fatalf("put keys = %v", fake.putKeys)
	}
	if rec.keys[len(rec.keys)-1] != final {
		t.Fatalf("last resolved key = %q, want %q", rec.keys[len(rec.keys)-1], final)
	}
	if rec.lastProgress() != 10 {
		t.Fatalf("last progress = %d, want 10", rec.lastProgress())
	}
}

func TestMultipartRejectedCompleteFailsAndAborts(t *testing.T) {
	path := sparseFile(t, "big.bin", 16*MiB)
	fake := newFake()
	fake.completeErr = fmt.Errorf("complete: %w", ErrPreconditionFailed)

	err := newUploader().Upload(context.Background(), fake, Request{Prefix: "p/", LocalPath: path}, Callbacks{})
	if err == nil {
		t.Fatal("expected an error")
	}
	if got := Message(err); got != "An object with this name appeared during the upload" {
		t.Fatalf("message = %q", got)
	}
	if !fake.aborted {
		t.Fatal("multipart upload was not aborted")
	}
}

func TestForbiddenExistenceCheckNamesPermission(t *testing.T) {
	path := sparseFile(t, "a.txt", 10)
	fake := newFake()
	fake.existsErr = fmt.Errorf("head: %w", ErrForbidden)

	err := newUploader().Upload(context.Background(), fake, Request{Prefix: "p/", LocalPath: path}, Callbacks{})
	if err == nil {
		t.Fatal("expected an error")
	}
	if got := Message(err); !strings.Contains(got, "s3:ListBucket") {
		t.Fatalf("message = %q", got)
	}
	if n := fake.writeCalls(); n != 0 {
		t.Fatalf("%d write calls after a forbidden check: %v", n, fake.calls)
	}
}

func TestFailedAbortIsReportedAndTheOriginalErrorWins(t *testing.T) {
	path := sparseFile(t, "big.bin", 16*MiB)
	fake := newFake()
	fake.completeErr = ErrPreconditionFailed
	abortErr := errors.New("abort boom")
	fake.abortErr = abortErr

	var reported []error
	err := newUploader().Upload(context.Background(), fake, Request{Prefix: "p/", LocalPath: path},
		Callbacks{AbortFailed: func(err error) { reported = append(reported, err) }})
	if !errors.Is(err, ErrPreconditionFailed) {
		t.Fatalf("err = %v, want ErrPreconditionFailed", err)
	}
	if len(reported) != 1 || !errors.Is(reported[0], abortErr) {
		t.Fatalf("AbortFailed calls = %v, want one with the abort error", reported)
	}
}

func TestPartFailureKeepsTheMultipartUploadAndItsRecord(t *testing.T) {
	path := sparseFile(t, "big.bin", 16*MiB)
	fake := newFake()
	fake.partErr = func(number int32) error {
		if number == 2 {
			return ErrNoNetwork
		}
		return nil
	}
	var recorded []Multipart
	var done []CompletedPart
	ended := 0
	cb := Callbacks{
		MultipartRecorded: func(m Multipart) { recorded = append(recorded, m) },
		PartDone:          func(p CompletedPart) { done = append(done, p) },
		MultipartEnded:    func() { ended++ },
	}

	err := newUploader().Upload(context.Background(), fake, Request{Prefix: "p/", LocalPath: path}, cb)
	if !errors.Is(err, ErrNoNetwork) {
		t.Fatalf("err = %v, want ErrNoNetwork", err)
	}
	if fake.aborted {
		t.Fatal("multipart upload was aborted; it must stay so the file can continue")
	}
	if slices.Contains(fake.calls, "complete") {
		t.Fatalf("complete called after a part failure: %v", fake.calls)
	}
	info, statErr := os.Stat(path)
	if statErr != nil {
		t.Fatal(statErr)
	}
	want := Multipart{Key: "p/big.bin", UploadID: "upload-1", PartSize: 8 * MiB, FileSize: 16 * MiB, ModTimeNanos: info.ModTime().UnixNano()}
	if len(recorded) != 1 || !reflect.DeepEqual(recorded[0], want) {
		t.Fatalf("recorded = %+v, want one record %+v", recorded, want)
	}
	if !slices.Equal(done, []CompletedPart{{1, "etag-1"}}) || ended != 0 {
		t.Fatalf("parts done = %v, ended = %d; want part 1 only and no end", done, ended)
	}
}

func TestSuccessEndsTheMultipartRecord(t *testing.T) {
	path := sparseFile(t, "big.bin", 16*MiB)
	ended := 0

	err := newUploader().Upload(context.Background(), newFake(), Request{Prefix: "p/", LocalPath: path}, Callbacks{MultipartEnded: func() { ended++ }})
	if err != nil || ended != 1 {
		t.Fatalf("err = %v, ended = %d; want nil and one end", err, ended)
	}
}

func TestCancelKeepsMultipartForResume(t *testing.T) {
	path := sparseFile(t, "big.bin", 16*MiB)
	fake := newFake()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	fake.onPart = func(number int32) {
		if number == 1 {
			cancel()
		}
	}

	err := newUploader().Upload(ctx, fake, Request{Prefix: "p/", LocalPath: path}, Callbacks{})
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("err = %v, want context.Canceled", err)
	}
	if fake.aborted {
		t.Fatal("multipart upload was aborted; the user's pause must keep it")
	}
}

func TestRejectedCompleteAbortsWithADeadline(t *testing.T) {
	path := sparseFile(t, "big.bin", 16*MiB)
	fake := newFake()
	fake.completeErr = ErrPreconditionFailed

	_ = newUploader().Upload(context.Background(), fake, Request{Prefix: "p/", LocalPath: path}, Callbacks{})
	if !fake.aborted || fake.abortCtxErr != nil {
		t.Fatalf("aborted = %v, abort ctx err = %v", fake.aborted, fake.abortCtxErr)
	}
	if !fake.abortHadDline || fake.abortDeadline > time.Second {
		t.Fatalf("abort deadline = %v (set: %v), want at most 1s", fake.abortDeadline, fake.abortHadDline)
	}
}

func TestFailedCreateMultipartIsReturnedWithoutAnAbort(t *testing.T) {
	path := sparseFile(t, "big.bin", 16*MiB)
	fake := newFake()
	fake.createErr = ErrBucketNotFound

	err := newUploader().Upload(context.Background(), fake, Request{Prefix: "p/", LocalPath: path}, Callbacks{})
	if !errors.Is(err, ErrBucketNotFound) {
		t.Fatalf("err = %v, want ErrBucketNotFound", err)
	}
	if fake.aborted || slices.Contains(fake.calls, "part") || slices.Contains(fake.calls, "complete") {
		t.Fatalf("calls = %v, want nothing after create", fake.calls)
	}
}

func TestMultipartOfAFileThatCannotBeOpenedTouchesNothing(t *testing.T) {
	fake := newFake()
	gone := filepath.Join(t.TempDir(), "gone.bin")

	err := uploadMultipart(context.Background(), fake, "p/gone.bin", gone, 16*MiB, 0, &progressTracker{total: 16 * MiB}, Callbacks{})
	if !errors.Is(err, ErrFileUnreadable) {
		t.Fatalf("err = %v, want ErrFileUnreadable", err)
	}
	if len(fake.calls) != 0 {
		t.Fatalf("S3 was called: %v", fake.calls)
	}
}

func TestCancelBetweenPartsKeepsMultipart(t *testing.T) {
	path := sparseFile(t, "big.bin", 16*MiB)
	fake := newFake()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	// The first part is fully sent by the time progress reaches 8 MiB, so the
	// cancellation lands between part 1 and part 2.
	cb := Callbacks{Progress: func(sent int64) {
		if sent >= 8*MiB {
			cancel()
		}
	}}

	err := newUploader().Upload(ctx, fake, Request{Prefix: "p/", LocalPath: path}, cb)
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("err = %v, want context.Canceled", err)
	}
	if !slices.Equal(fake.partSizes, []int64{8 * MiB}) {
		t.Fatalf("part sizes = %v, want only the first part", fake.partSizes)
	}
	if fake.aborted || slices.Contains(fake.calls, "complete") {
		t.Fatalf("calls = %v, want no abort and no complete", fake.calls)
	}
}

func TestProgressNeverExceedsTotal(t *testing.T) {
	for _, size := range []int64{10, 16 * MiB, 20*MiB + 123} {
		t.Run(fmt.Sprint(size), func(t *testing.T) {
			path := sparseFile(t, "f.bin", size)
			fake := newFake()
			fake.readBodyTwice = true
			rec := &recorder{}

			if err := newUploader().Upload(context.Background(), fake, Request{Prefix: "p/", LocalPath: path}, rec.callbacks()); err != nil {
				t.Fatal(err)
			}
			var prev int64
			for _, p := range rec.progress {
				if p < prev || p > size {
					t.Fatalf("progress %d after %d, total %d", p, prev, size)
				}
				prev = p
			}
			if rec.lastProgress() != size {
				t.Fatalf("last progress = %d, want %d", rec.lastProgress(), size)
			}
		})
	}
}

func TestProgressTrackerClampsAndNeverGoesBack(t *testing.T) {
	var got []int64
	p := &progressTracker{total: 100, report: func(n int64) { got = append(got, n) }}
	for _, n := range []int64{40, 30, 100, 250} {
		p.advance(n)
	}
	if !slices.Equal(got, []int64{40, 100}) {
		t.Fatalf("reported %v", got)
	}
}

func TestGrowingFileIsCutAtRecordedSize(t *testing.T) {
	path := sparseFile(t, "grow.bin", 16*MiB)
	fake := newFake()
	fake.onPart = func(number int32) {
		if number == 1 {
			if err := os.Truncate(path, 24*MiB); err != nil {
				t.Error(err)
			}
		}
	}
	rec := &recorder{}

	if err := newUploader().Upload(context.Background(), fake, Request{Prefix: "p/", LocalPath: path}, rec.callbacks()); err != nil {
		t.Fatal(err)
	}
	if !slices.Equal(fake.partSizes, []int64{8 * MiB, 8 * MiB}) {
		t.Fatalf("part sizes = %v", fake.partSizes)
	}
	if rec.lastProgress() != 16*MiB {
		t.Fatalf("last progress = %d", rec.lastProgress())
	}
}

func TestVanishedFileIsUnreadable(t *testing.T) {
	path := sparseFile(t, "gone.txt", 10)
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	fake := newFake()

	err := newUploader().Upload(context.Background(), fake, Request{Prefix: "p/", LocalPath: path}, Callbacks{})
	if got := Message(err); got != "File could not be read" {
		t.Fatalf("message = %q (err %v)", got, err)
	}
	if len(fake.calls) != 0 {
		t.Fatalf("S3 was called: %v", fake.calls)
	}
}

func TestShrunkFileIsUnreadable(t *testing.T) {
	for _, tc := range []struct {
		name string
		size int64
	}{{"single", 1024}, {"multipart", 16 * MiB}} {
		t.Run(tc.name, func(t *testing.T) {
			path := sparseFile(t, "shrink.bin", tc.size)
			fake := newFake()
			fake.onExists = func() {
				if err := os.Truncate(path, tc.size/2); err != nil {
					t.Error(err)
				}
			}

			err := newUploader().Upload(context.Background(), fake, Request{Prefix: "p/", LocalPath: path}, Callbacks{})
			if !errors.Is(err, ErrFileUnreadable) {
				t.Fatalf("err = %v, want ErrFileUnreadable", err)
			}
			if fake.aborted {
				t.Fatal("multipart upload was aborted; a later attempt sees the changed file and decides")
			}
		})
	}
}

func TestMessageMapping(t *testing.T) {
	cases := []struct {
		err  error
		want string
	}{
		{ErrBadCredentials, "AWS rejected the access key"},
		{ErrBucketNotFound, "Bucket not found"},
		{ErrNoNetwork, "No internet connection"},
		{ErrWriteDenied, "AWS denied permission to write to the bucket"},
		{ErrWrongRegion, "The bucket is in a different region"},
		{ErrBucketInaccessible, "AWS blocked access to this bucket: check that the bucket name is yours"},
		{fmt.Errorf("wrapped: %w", ErrNoNetwork), "No internet connection"},
		{errors.New("boom"), "Upload failed"},
	}
	for _, tc := range cases {
		if got := Message(tc.err); got != tc.want {
			t.Errorf("Message(%v) = %q, want %q", tc.err, got, tc.want)
		}
	}
}

func TestSettingsStringRedactsSecrets(t *testing.T) {
	s := Settings{AccessKeyID: "AKIAEXAMPLEKEY", SecretAccessKey: "super-secret-value", Region: "us-east-1", Bucket: "b", Prefix: "p/"}
	for _, out := range []string{fmt.Sprintf("%v", s), fmt.Sprintf("%+v", s), fmt.Sprintf("%#v", s), fmt.Sprint(&s)} {
		if strings.Contains(out, s.AccessKeyID) || strings.Contains(out, s.SecretAccessKey) {
			t.Fatalf("output leaks credentials: %s", out)
		}
	}
}
