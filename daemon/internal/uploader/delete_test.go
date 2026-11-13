package uploader

import (
	"context"
	"errors"
	"fmt"
	"testing"
)

// deleteRecorder records every DeleteObjects batch; failOn makes the batch with
// that (1-based) number delete only half of its keys and then fail.
type deleteRecorder struct {
	*fakeS3
	batches [][]string
	failOn  int
}

func (d *deleteRecorder) DeleteObjects(_ context.Context, keys []string) ([]string, error) {
	d.batches = append(d.batches, append([]string(nil), keys...))
	if d.failOn == len(d.batches) {
		return keys[:len(keys)/2], ErrDeleteDenied
	}
	return keys, nil
}

func numberedKeys(n int) []string {
	keys := make([]string, n)
	for i := range keys {
		keys[i] = fmt.Sprintf("p/file-%04d", i)
	}
	return keys
}

func TestDeleteKeysSendsBatchesOfAtMostAThousand(t *testing.T) {
	rec := &deleteRecorder{fakeS3: newFake()}
	keys := numberedKeys(2500)

	deleted, err := DeleteKeys(context.Background(), rec, keys)

	if err != nil || len(deleted) != 2500 {
		t.Fatalf("deleted %d keys, err %v; want all 2500", len(deleted), err)
	}
	sizes := []int{}
	for _, b := range rec.batches {
		sizes = append(sizes, len(b))
	}
	if fmt.Sprint(sizes) != "[1000 1000 500]" {
		t.Fatalf("batch sizes = %v, want [1000 1000 500]", sizes)
	}
	if rec.batches[1][0] != keys[1000] || rec.batches[2][499] != keys[2499] {
		t.Fatal("batches do not carry the keys in order")
	}
}

func TestDeleteKeysWithoutKeysMakesNoCall(t *testing.T) {
	rec := &deleteRecorder{fakeS3: newFake()}
	if deleted, err := DeleteKeys(context.Background(), rec, nil); err != nil || len(deleted) != 0 || len(rec.batches) != 0 {
		t.Fatalf("deleted %v, err %v, %d batches; want nothing", deleted, err, len(rec.batches))
	}
}

func TestDeleteKeysStopsAtTheFirstFailedBatchAndKeepsWhatWasDeleted(t *testing.T) {
	rec := &deleteRecorder{fakeS3: newFake(), failOn: 2}

	deleted, err := DeleteKeys(context.Background(), rec, numberedKeys(2500))

	if !errors.Is(err, ErrDeleteDenied) {
		t.Fatalf("err = %v, want ErrDeleteDenied", err)
	}
	if len(rec.batches) != 2 {
		t.Fatalf("batches sent = %d, want it to stop after the second", len(rec.batches))
	}
	if len(deleted) != 1500 {
		t.Fatalf("deleted = %d keys, want 1000 from the first batch and 500 from the failed one", len(deleted))
	}
}

func TestDeleteDeniedMessageNamesThePermission(t *testing.T) {
	const want = "AWS denied permission to delete from the bucket: the access key needs the s3:DeleteObject permission"
	if got := Message(fmt.Errorf("wrapped: %w", ErrDeleteDenied)); got != want {
		t.Fatalf("Message = %q, want %q", got, want)
	}
	if IsFatal(ErrDeleteDenied) {
		t.Fatal("a denied delete must not stop uploads")
	}
}
