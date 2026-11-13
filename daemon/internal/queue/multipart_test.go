package queue

import (
	"context"
	"errors"
	"reflect"
	"slices"
	"testing"
	"time"

	"rabbithole/daemon/internal/uploader"
)

func partRecord(key, id string) uploader.Multipart {
	return uploader.Multipart{
		Key: key, UploadID: id, PartSize: 8, FileSize: 1, ModTimeNanos: 42,
		Parts: []uploader.CompletedPart{{Number: 1, ETag: "e1"}, {Number: 2, ETag: "e2"}},
	}
}

// failedWithRecord runs a single file whose multipart upload is cut off, and
// returns the queue, its runner and store and the upload id.
func failedWithRecord(t *testing.T) (*Queue, *ctlRunner, *memStore, string) {
	t.Helper()
	r := newCtl()
	r.record["m.bin"] = partRecord("pfx/m.bin", "up-m")
	r.failWith["m.bin"] = errors.New("boom")
	st := newMemStore()
	q := ctlQueue(t, st, r)
	id := enqueueOne(t, q, "m.bin")
	waitState(t, q, id, Failed)
	return q, r, st, id
}

func TestFailedUploadKeepsItsMultipartUploadAndRecordsItsParts(t *testing.T) {
	_, r, st, id := failedWithRecord(t)

	recs, err := st.Multiparts(id)
	if err != nil {
		t.Fatal(err)
	}
	if want := partRecord("pfx/m.bin", "up-m"); !reflect.DeepEqual(recs[0], want) {
		t.Fatalf("stored record = %+v, want %+v", recs[0], want)
	}
	if got := r.abortList(); len(got) != 0 {
		t.Fatalf("a failure aborted %v; the multipart upload must stay for the retry", got)
	}
}

func TestRetryHandsTheRecordToTheRunnerAndASuccessClearsIt(t *testing.T) {
	q, r, st, id := failedWithRecord(t)
	delete(r.failWith, "m.bin")

	if err := q.Retry(settingsFor("bucket-1"), id, nil); err != nil {
		t.Fatal(err)
	}
	waitState(t, q, id, Finished)

	reqs := r.requests("m.bin")
	if len(reqs) != 2 || reqs[0].Resume != nil {
		t.Fatalf("requests = %+v, want a first attempt without a record and a retry", reqs)
	}
	if want := partRecord("pfx/m.bin", "up-m"); reqs[1].Resume == nil || !reflect.DeepEqual(*reqs[1].Resume, want) {
		t.Fatalf("retry carried %+v, want the stored record %+v", reqs[1].Resume, want)
	}
	q.journal.flush()
	if recs, _ := st.Multiparts(id); len(recs) != 0 {
		t.Fatalf("records after the file finished = %v, want none", recs)
	}
}

func TestResumeAfterAPauseHandsTheRecordToTheRunner(t *testing.T) {
	r := newCtl()
	r.setHang("m.bin")
	r.record["m.bin"] = partRecord("pfx/m.bin", "up-m")
	q := ctlQueue(t, newMemStore(), r)
	id := enqueueOne(t, q, "m.bin")
	r.awaitStarted(t, "m.bin")
	if err := q.Pause("bucket-1", id); err != nil {
		t.Fatal(err)
	}
	waitState(t, q, id, Paused)
	r.setHang()

	if err := q.Resume(settingsFor("bucket-1"), id); err != nil {
		t.Fatal(err)
	}
	waitState(t, q, id, Finished)

	reqs := r.requests("m.bin")
	if len(reqs) != 2 || reqs[1].Resume == nil || reqs[1].Resume.UploadID != "up-m" {
		t.Fatalf("requests = %+v, want the resume to carry the upload id up-m", reqs)
	}
	if len(r.abortList()) != 0 {
		t.Fatalf("pausing aborted %v", r.abortList())
	}
}

func TestRemoveAbortsTheMultipartUploadWithAndWithoutDeletingFromTheBucket(t *testing.T) {
	for _, withDelete := range []bool{false, true} {
		name := "history only"
		if withDelete {
			name = "history and bucket"
		}
		t.Run(name, func(t *testing.T) {
			q, r, st, id := failedWithRecord(t)
			spy := &deleteSpy{}
			var del DeleteFunc
			if withDelete {
				del = spy.del
			}

			if err := q.Remove(context.Background(), "bucket-1", id, nil, del); err != nil {
				t.Fatal(err)
			}

			if got := r.abortList(); !slices.Equal(got, []abortCall{{"bucket-1", "pfx/m.bin", "up-m"}}) {
				t.Fatalf("aborts = %v, want the multipart upload of the removed file", got)
			}
			if _, ok := lookup(q, id); ok {
				t.Fatal("the upload is still in the history")
			}
			if recs, _ := st.Multiparts(id); len(recs) != 0 {
				t.Fatalf("records left behind: %v", recs)
			}
		})
	}
}

func TestRemoveOfOneFileAbortsOnlyItsOwnMultipartUpload(t *testing.T) {
	r := newCtl()
	r.record["a"] = partRecord("pfx/d/a", "up-a")
	r.record["b"] = partRecord("pfx/d/b", "up-b")
	r.failWith["a"] = errors.New("boom")
	r.failWith["b"] = errors.New("boom")
	q := ctlQueue(t, newMemStore(), r)
	id := enqueueTree(t, q, 1, "d/a", "d/b")
	waitState(t, q, id, Failed)

	if err := q.Remove(context.Background(), "bucket-1", id, []int{indexOfFile(t, filesOf(t, q, id), "d/a")}, nil); err != nil {
		t.Fatal(err)
	}

	if got := r.abortList(); !slices.Equal(got, []abortCall{{"bucket-1", "pfx/d/a", "up-a"}}) {
		t.Fatalf("aborts = %v, want only the removed file's upload", got)
	}
	if recs, _ := q.store.Multiparts(id); len(recs) != 1 {
		t.Fatalf("records = %v, want b's record kept", recs)
	}
}

func TestRemoveKeepsAFileWhoseMultipartUploadCouldNotBeAborted(t *testing.T) {
	q, r, st, id := failedWithRecord(t)
	r.abortErr = uploader.ErrNoNetwork

	err := q.Remove(context.Background(), "bucket-1", id, nil, nil)

	if !errors.Is(err, ErrMultipartAbort) || !errors.Is(err, uploader.ErrNoNetwork) {
		t.Fatalf("err = %v, want ErrMultipartAbort wrapping the cause", err)
	}
	if _, ok := lookup(q, id); !ok {
		t.Fatal("the file left the history although its multipart upload is still in the bucket")
	}
	if recs, _ := st.Multiparts(id); len(recs) != 1 {
		t.Fatalf("records = %v, want the record kept so it can be aborted later", recs)
	}

	r.abortErr = nil
	if err := q.Remove(context.Background(), "bucket-1", id, nil, nil); err != nil {
		t.Fatalf("second removal: %v", err)
	}
	if got := r.abortList(); len(got) != 2 {
		t.Fatalf("aborts = %v, want the failed attempt and the one that worked", got)
	}
}

func TestAnUploadThatS3NoLongerKnowsIsNotAnAbortFailure(t *testing.T) {
	q, r, _, id := failedWithRecord(t)
	r.abortErr = uploader.ErrNoSuchUpload

	if err := q.Remove(context.Background(), "bucket-1", id, nil, nil); err != nil {
		t.Fatalf("err = %v, want the removal to go through", err)
	}
}

func TestCancelKeepsTheRecordWhenTheAbortFails(t *testing.T) {
	r := newCtl()
	r.setHang("m.bin")
	r.record["m.bin"] = partRecord("pfx/m.bin", "up-m")
	r.abortErr = uploader.ErrNoNetwork
	st := newMemStore()
	q := ctlQueue(t, st, r)
	id := enqueueOne(t, q, "m.bin")
	r.awaitStarted(t, "m.bin")

	if err := q.Cancel("bucket-1", id); err != nil {
		t.Fatal(err)
	}
	waitState(t, q, id, Canceled)
	deadline := time.Now().Add(guard)
	for len(r.abortList()) == 0 {
		if time.Now().After(deadline) {
			t.Fatal("no abort attempt")
		}
		time.Sleep(2 * time.Millisecond)
	}

	q.journal.flush()
	if recs, _ := st.Multiparts(id); len(recs) != 1 {
		t.Fatalf("records = %v, want the record kept for a later abort", recs)
	}
}
