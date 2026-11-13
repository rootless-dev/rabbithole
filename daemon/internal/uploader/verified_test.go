package uploader

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"slices"
	"testing"
	"time"

	"rabbithole/daemon/internal/ratelimit"
)

// checkedFake is a fakeS3 that also implements CheckedS3. Like S3 it computes
// the SHA-256 of every body it receives and rejects a body that does not match
// the checksum declared with it.
type checkedFake struct {
	*fakeS3
	checksummed bool  // what ListPartsChecked answers
	storeWrong  int32 // part number whose bytes "arrive corrupted"; -1 is the single object
	corruptAll  bool

	checkedCalls []string
	putSum       string
	putBytes     int64
	partSums     map[int32]string
	completedSum []CheckedPart
}

func newChecked() *checkedFake {
	return &checkedFake{fakeS3: newFake(), partSums: map[int32]string{}}
}

func (c *checkedFake) receive(body io.Reader, declared string, corrupt bool) (int64, error) {
	h := sha256.New()
	n, err := io.Copy(h, body)
	if err != nil {
		return n, err
	}
	got := base64.StdEncoding.EncodeToString(h.Sum(nil))
	if corrupt || got != declared {
		return n, fmt.Errorf("%w: declared %s, received %s", ErrChecksumMismatch, declared, got)
	}
	return n, nil
}

func (c *checkedFake) PutObjectChecked(_ context.Context, key string, body io.Reader, _ int64, sum string) error {
	c.checkedCalls = append(c.checkedCalls, "put")
	n, err := c.receive(body, sum, c.corruptAll)
	c.putSum, c.putBytes = sum, n
	if err == nil {
		c.existing[key] = true
	}
	return err
}

func (c *checkedFake) CreateMultipartChecked(context.Context, string) (string, error) {
	c.checkedCalls = append(c.checkedCalls, "create")
	return "upload-1", nil
}

func (c *checkedFake) UploadPartChecked(_ context.Context, _, _ string, number int32, body io.Reader, size int64, sum string) (string, error) {
	c.checkedCalls = append(c.checkedCalls, "part")
	c.partNumbers = append(c.partNumbers, number)
	if _, err := c.receive(body, sum, c.corruptAll || c.storeWrong == number); err != nil {
		return "", err
	}
	c.partSums[number] = sum
	return fmt.Sprintf("etag-%d", number), nil
}

func (c *checkedFake) CompleteMultipartChecked(_ context.Context, key, id string, parts []CheckedPart) error {
	c.checkedCalls = append(c.checkedCalls, "complete")
	c.completedSum = parts
	c.completeKey, c.completeID = key, id
	return nil
}

func (c *checkedFake) ListPartsChecked(context.Context, string, string) ([]HeldPart, bool, error) {
	c.calls = append(c.calls, "list-parts")
	return c.held, c.checksummed, c.listErr
}

func sumOf(b []byte) string {
	s := sha256.Sum256(b)
	return base64.StdEncoding.EncodeToString(s[:])
}

func verifyingUploader() *Uploader {
	return New(func() time.Time { return fixedNow }, WithVerify(func() bool { return true }))
}

func contentFile(t *testing.T, name string, content []byte) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), name)
	if err := os.WriteFile(path, content, 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestVerifiedSingleUploadDeclaresTheSHA256OfTheLocalBytes(t *testing.T) {
	content := []byte("the bytes S3 has to check")
	path := contentFile(t, "a.txt", content)
	fake := newChecked()

	if err := verifyingUploader().Upload(context.Background(), fake, Request{Prefix: "p/", LocalPath: path}, Callbacks{}); err != nil {
		t.Fatal(err)
	}
	if fake.putSum != sumOf(content) || fake.putBytes != int64(len(content)) {
		t.Fatalf("declared %q for %d bytes, want %q for %d", fake.putSum, fake.putBytes, sumOf(content), len(content))
	}
	if slices.Contains(fake.calls, "put") {
		t.Fatalf("calls = %v, the unchecked PutObject must not be used while verifying", fake.calls)
	}
}

func TestVerifiedSingleUploadFailsWhenS3ReportsAMismatch(t *testing.T) {
	path := contentFile(t, "a.txt", []byte("abc"))
	fake := newChecked()
	fake.corruptAll = true

	err := verifyingUploader().Upload(context.Background(), fake, Request{Prefix: "p/", LocalPath: path}, Callbacks{})
	if !errors.Is(err, ErrChecksumMismatch) {
		t.Fatalf("err = %v, want ErrChecksumMismatch", err)
	}
	if IsFatal(err) {
		t.Fatal("a mismatch must fail that file only, not the whole upload")
	}
	if got := Message(err); got != "The file in the bucket does not match the local file" {
		t.Fatalf("message = %q", got)
	}
}

func TestVerifiedMultipartDeclaresEveryPartAndCompletesWithThem(t *testing.T) {
	path := sparseFile(t, "big.bin", 20*MiB) // parts of 8, 8 and 4 MiB of zeros
	fake := newChecked()

	if err := verifyingUploader().Upload(context.Background(), fake, Request{Prefix: "p/", LocalPath: path}, Callbacks{}); err != nil {
		t.Fatal(err)
	}
	full, tail := sumOf(make([]byte, 8*MiB)), sumOf(make([]byte, 4*MiB))
	want := []CheckedPart{
		{CompletedPart{1, "etag-1"}, full}, {CompletedPart{2, "etag-2"}, full}, {CompletedPart{3, "etag-3"}, tail},
	}
	if !slices.Equal(fake.completedSum, want) {
		t.Fatalf("completed with %+v, want %+v", fake.completedSum, want)
	}
	if !slices.Equal(fake.checkedCalls, []string{"create", "part", "part", "part", "complete"}) {
		t.Fatalf("calls = %v", fake.checkedCalls)
	}
}

func TestCompositeSHA256IsTheHashOfTheRawPartDigests(t *testing.T) {
	a, b := sha256.Sum256([]byte("one")), sha256.Sum256([]byte("two"))
	want := sha256.Sum256(append(a[:], b[:]...))
	got, err := CompositeSHA256([]string{base64.StdEncoding.EncodeToString(a[:]), base64.StdEncoding.EncodeToString(b[:])})
	if err != nil {
		t.Fatal(err)
	}
	if exp := base64.StdEncoding.EncodeToString(want[:]) + "-2"; got != exp {
		t.Fatalf("composite = %q, want %q", got, exp)
	}
	if _, err := CompositeSHA256([]string{"%%%"}); err == nil {
		t.Fatal("a part checksum that is not base64 must be an error")
	}
}

func TestVerifiedMultipartMismatchedPartFailsTheFileAndStopsThere(t *testing.T) {
	path := sparseFile(t, "big.bin", 20*MiB)
	fake := newChecked()
	fake.storeWrong = 2

	err := verifyingUploader().Upload(context.Background(), fake, Request{Prefix: "p/", LocalPath: path}, Callbacks{})
	if !errors.Is(err, ErrChecksumMismatch) || IsFatal(err) {
		t.Fatalf("err = %v, want a non-fatal ErrChecksumMismatch", err)
	}
	if !slices.Equal(fake.partNumbers, []int32{1, 2}) {
		t.Fatalf("parts sent = %v, want 1 and 2 only", fake.partNumbers)
	}
	if slices.Contains(fake.checkedCalls, "complete") {
		t.Fatal("an upload with a bad part must not be completed")
	}
}

func TestVerifyingOnAnUploadStartedWithoutChecksumsStartsOver(t *testing.T) {
	path := sparseFile(t, "big.bin", 20*MiB)
	fake := newChecked()
	fake.checksummed = false
	fake.held = []HeldPart{heldPart(1, 8*MiB), heldPart(2, 8*MiB)} // sent while verification was off

	err := verifyingUploader().Upload(context.Background(), fake,
		Request{Prefix: "p/", LocalPath: path, Resume: recordOf(t, path, "old-id", CompletedPart{1, "held-1"}, CompletedPart{2, "held-2"})}, Callbacks{})
	if err != nil {
		t.Fatal(err)
	}
	if !slices.Equal(fake.abortedIDs, []string{"old-id"}) {
		t.Fatalf("aborted = %v, want the old upload dropped", fake.abortedIDs)
	}
	if !slices.Equal(fake.partNumbers, []int32{1, 2, 3}) || len(fake.completedSum) != 3 {
		t.Fatalf("parts sent = %v, completed = %v; want every part sent again with a checksum", fake.partNumbers, fake.completedSum)
	}
}

func TestVerifiedResumeKeepsHeldPartsWhoseChecksumMatchesTheLocalFile(t *testing.T) {
	path := sparseFile(t, "big.bin", 24*MiB)
	fake := newChecked()
	fake.checksummed = true
	good := sumOf(make([]byte, 8*MiB))
	fake.held = []HeldPart{
		{Number: 1, ETag: "held-1", Size: 8 * MiB, SHA256: good},
		{Number: 2, ETag: "held-2", Size: 8 * MiB, SHA256: sumOf([]byte("not the local bytes"))},
	}

	err := verifyingUploader().Upload(context.Background(), fake,
		Request{Prefix: "p/", LocalPath: path, Resume: recordOf(t, path, "old-id")}, Callbacks{})
	if err != nil {
		t.Fatal(err)
	}
	if !slices.Equal(fake.partNumbers, []int32{2, 3}) {
		t.Fatalf("parts sent = %v, want the part whose checksum differs (2) and the missing one (3)", fake.partNumbers)
	}
	if len(fake.completedSum) != 3 || fake.completedSum[0] != (CheckedPart{CompletedPart{1, "held-1"}, good}) {
		t.Fatalf("completed = %+v", fake.completedSum)
	}
	if fake.completeID != "old-id" {
		t.Fatalf("completed %q, want the resumed upload", fake.completeID)
	}
}

func TestChecksummedUploadKeepsItsChecksumsWhenVerificationIsOffNow(t *testing.T) {
	path := sparseFile(t, "big.bin", 16*MiB)
	fake := newChecked()
	fake.checksummed = true // started while verification was on

	err := newUploader().Upload(context.Background(), fake,
		Request{Prefix: "p/", LocalPath: path, Resume: recordOf(t, path, "old-id")}, Callbacks{})
	if err != nil {
		t.Fatal(err)
	}
	if len(fake.partSums) != 2 || slices.Contains(fake.calls, "part") {
		t.Fatalf("checked parts = %v, calls = %v; want both parts sent with checksums", fake.partSums, fake.calls)
	}
}

func TestWithoutVerificationUploadsBehaveAsBefore(t *testing.T) {
	small := contentFile(t, "a.txt", []byte("abc"))
	big := sparseFile(t, "big.bin", 16*MiB)
	fake := newChecked()

	for _, p := range []string{small, big} {
		if err := newUploader().Upload(context.Background(), fake, Request{Prefix: "p/", LocalPath: p}, Callbacks{}); err != nil {
			t.Fatal(err)
		}
	}
	if len(fake.checkedCalls) != 0 {
		t.Fatalf("checked calls = %v, want none while verification is off", fake.checkedCalls)
	}
	if !slices.Contains(fake.calls, "put") || !slices.Contains(fake.calls, "create") || !slices.Contains(fake.calls, "complete") {
		t.Fatalf("calls = %v, want the plain put and multipart calls", fake.calls)
	}
}

func TestVerificationIsReadAtTheStartOfEachFile(t *testing.T) {
	path := contentFile(t, "a.txt", []byte("abc"))
	on := false
	u := New(func() time.Time { return fixedNow }, WithVerify(func() bool { return on }))
	fake := newChecked()

	if err := u.Upload(context.Background(), fake, Request{Prefix: "p/", LocalPath: path}, Callbacks{}); err != nil {
		t.Fatal(err)
	}
	on = true
	if err := u.Upload(context.Background(), fake, Request{Prefix: "p/", LocalPath: path}, Callbacks{}); err != nil {
		t.Fatal(err)
	}
	if !slices.Equal(fake.checkedCalls, []string{"put"}) || len(fake.putKeys) != 1 {
		t.Fatalf("checked = %v, plain keys = %v; want one plain and one checked put", fake.checkedCalls, fake.putKeys)
	}
}

func TestVerifyingWithAnS3ThatCannotCheckFails(t *testing.T) {
	path := contentFile(t, "a.txt", []byte("abc"))
	err := verifyingUploader().Upload(context.Background(), newFake(), Request{Prefix: "p/", LocalPath: path}, Callbacks{})
	if !errors.Is(err, ErrVerifyUnsupported) {
		t.Fatalf("err = %v, want ErrVerifyUnsupported", err)
	}
}

func TestLimiterSlowsDownTheBodiesOfSinglesAndParts(t *testing.T) {
	var now time.Time = time.Unix(0, 0)
	limiter := ratelimit.New(func() time.Time { return now }, func(_ context.Context, d time.Duration, _ <-chan struct{}) error {
		now = now.Add(d)
		return nil
	})
	limiter.SetRate(1 * MiB)
	u := New(func() time.Time { return fixedNow }, WithLimiter(limiter))
	small := sparseFile(t, "a.bin", 4*MiB)

	if err := u.Upload(context.Background(), newFake(), Request{Prefix: "p/", LocalPath: small}, Callbacks{}); err != nil {
		t.Fatal(err)
	}
	if got := now.Unix(); got < 3 || got > 4 {
		t.Fatalf("4 MiB at 1 MiB/s took %d s of limiter time, want 3 to 4", got)
	}

	now = time.Unix(0, 0)
	limiter.SetRate(1 * MiB) // restarts the bucket at the new clock
	big := sparseFile(t, "b.bin", 16*MiB)
	if err := u.Upload(context.Background(), newFake(), Request{Prefix: "p/", LocalPath: big}, Callbacks{}); err != nil {
		t.Fatal(err)
	}
	if got := now.Unix(); got < 14 || got > 16 {
		t.Fatalf("16 MiB of parts at 1 MiB/s took %d s, want 14 to 16", got)
	}
}
