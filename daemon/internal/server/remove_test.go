package server_test

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	pb "rabbithole/daemon/internal/gen/rabbithole/v1"
	"rabbithole/daemon/internal/server"
	"rabbithole/daemon/internal/uploader"
)

// fakeObjects records the delete calls the server makes. When err is set, a
// call deletes only the first failAfter keys and then fails with it.
type fakeObjects struct {
	mu        sync.Mutex
	calls     [][]string
	settings  []uploader.Settings
	err       error
	failAfter int
}

func (f *fakeObjects) DeleteObjects(_ context.Context, s uploader.Settings, keys []string) ([]string, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls = append(f.calls, slices.Clone(keys))
	f.settings = append(f.settings, s)
	if f.err != nil {
		return keys[:min(f.failAfter, len(keys))], f.err
	}
	return keys, nil
}

func (f *fakeObjects) callCount() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.calls)
}

// keyedRunner reports the key of each file it sends: the request prefix and the
// file name.
func keyedRunner() runnerFunc {
	return func(_ context.Context, _ uploader.Settings, req uploader.Request, cb uploader.Callbacks) error {
		cb.KeyResolved(req.Prefix + filepath.Base(req.LocalPath))
		return nil
	}
}

func removeEnv(t *testing.T, objects server.Objects) *env {
	t.Helper()
	var opts []server.Option
	if objects != nil {
		opts = append(opts, server.WithObjects(objects))
	}
	e := newEnvWith(t, keyedRunner(), opts...)
	e.startQueue(t)
	return e
}

// sendFolder configures the daemon for bucket, uploads a folder holding the
// named files and waits for the upload to end.
func sendFolder(t *testing.T, e *env, bucket string, names ...string) string {
	t.Helper()
	cfg := configFor(bucket)
	cfg.QuickUploadsPrefix = "quick/"
	if _, err := e.client.Configure(ctxT(t), cfg); err != nil {
		t.Fatal(err)
	}
	dir := filepath.Join(t.TempDir(), "folder")
	if err := os.Mkdir(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	for _, n := range names {
		if err := os.WriteFile(filepath.Join(dir, n), []byte("x"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	resp, err := e.client.EnqueueUpload(ctxT(t), &pb.EnqueueUploadRequest{LocalPath: dir})
	if err != nil {
		t.Fatal(err)
	}
	stream, err := e.client.WatchUploads(ctxT(t), &pb.WatchUploadsRequest{})
	if err != nil {
		t.Fatal(err)
	}
	recvUntil(t, stream, resp.GetUploadId(), func(s *pb.UploadSnapshot) bool {
		return s.GetState() == pb.UploadState_FINISHED || s.GetState() == pb.UploadState_FAILED
	})
	return resp.GetUploadId()
}

// fileIndexes returns the index of each file of an upload by its name.
func fileIndexes(t *testing.T, e *env, id string, count int) map[string]int32 {
	t.Helper()
	ctx, cancel := context.WithCancel(ctxT(t))
	defer cancel()
	stream, err := e.client.WatchUploadFiles(ctx, &pb.WatchUploadFilesRequest{UploadId: id})
	if err != nil {
		t.Fatal(err)
	}
	out := map[string]int32{}
	for range count {
		f, err := stream.Recv()
		if err != nil {
			t.Fatal(err)
		}
		out[filepath.Base(f.GetLocalPath())] = f.GetIndex()
	}
	return out
}

func hasUpload(t *testing.T, e *env, id string) bool {
	t.Helper()
	initial, _, cancel := e.queue.Subscribe()
	cancel()
	for _, s := range initial {
		if s.ID == id {
			return true
		}
	}
	return false
}

func TestRemoveUploadBeforeConfigureFailsPrecondition(t *testing.T) {
	e := removeEnv(t, &fakeObjects{})
	_, err := e.client.RemoveUpload(ctxT(t), &pb.RemoveUploadRequest{UploadId: "x"})
	wantCode(t, err, codes.FailedPrecondition)
}

func TestRemoveUploadWithoutDeletingFromTheBucketCallsNoS3(t *testing.T) {
	objects := &fakeObjects{}
	e := removeEnv(t, objects)
	id := sendFolder(t, e, "my-bucket", "a", "b")

	if _, err := e.client.RemoveUpload(ctxT(t), &pb.RemoveUploadRequest{UploadId: id}); err != nil {
		t.Fatal(err)
	}

	if objects.callCount() != 0 {
		t.Fatalf("S3 was called %d times, want none", objects.callCount())
	}
	if hasUpload(t, e, id) {
		t.Fatal("upload is still in the history")
	}
}

func TestRemoveUploadDeletesTheExactKeysOfTheFinishedFiles(t *testing.T) {
	objects := &fakeObjects{}
	e := removeEnv(t, objects)
	id := sendFolder(t, e, "my-bucket", "a", "b")

	_, err := e.client.RemoveUpload(ctxT(t), &pb.RemoveUploadRequest{UploadId: id, DeleteFromBucket: true})
	if err != nil {
		t.Fatal(err)
	}

	if objects.callCount() != 1 {
		t.Fatalf("delete calls = %d, want 1", objects.callCount())
	}
	got := slices.Clone(objects.calls[0])
	slices.Sort(got)
	if want := []string{"quick/folder/a", "quick/folder/b"}; !slices.Equal(got, want) {
		t.Fatalf("keys = %v, want %v (never a prefix)", got, want)
	}
	s := objects.settings[0]
	if s.Bucket != "my-bucket" || s.AccessKeyID != validConfig().AccessKeyId {
		t.Fatalf("delete used settings %v, want the configured ones", s)
	}
	if hasUpload(t, e, id) {
		t.Fatal("upload is still in the history")
	}
}

func TestRemoveSelectedFilesKeepsTheUploadWithTheOthers(t *testing.T) {
	objects := &fakeObjects{}
	e := removeEnv(t, objects)
	id := sendFolder(t, e, "my-bucket", "a", "b", "c")
	idx := fileIndexes(t, e, id, 3)

	_, err := e.client.RemoveUpload(ctxT(t), &pb.RemoveUploadRequest{
		UploadId: id, FileIndexes: []int32{idx["a"], idx["c"]}, DeleteFromBucket: true,
	})
	if err != nil {
		t.Fatal(err)
	}

	got := slices.Clone(objects.calls[0])
	slices.Sort(got)
	if want := []string{"quick/folder/a", "quick/folder/c"}; !slices.Equal(got, want) {
		t.Fatalf("keys = %v, want %v", got, want)
	}
	initial, _, cancel := e.queue.Subscribe()
	cancel()
	if len(initial) != 1 || initial[0].FilesTotal != 1 || initial[0].FilesFinished != 1 || initial[0].BytesTotal != 1 {
		t.Fatalf("upload after = %+v, want one file left", initial)
	}
}

func TestRemoveUploadRefusals(t *testing.T) {
	e := removeEnv(t, &fakeObjects{})
	id := sendFolder(t, e, "my-bucket", "a")
	other := sendFolder(t, e, "other-bucket", "a")
	if _, err := e.client.Configure(ctxT(t), configFor("my-bucket")); err != nil {
		t.Fatal(err)
	}

	tests := []struct {
		name string
		req  *pb.RemoveUploadRequest
		code codes.Code
		msg  string
	}{
		{"unknown upload", &pb.RemoveUploadRequest{UploadId: "nope"}, codes.NotFound, "unknown upload"},
		{"unknown file", &pb.RemoveUploadRequest{UploadId: id, FileIndexes: []int32{42}}, codes.NotFound, "unknown file"},
		{"other bucket", &pb.RemoveUploadRequest{UploadId: other}, codes.FailedPrecondition, "This upload belongs to another bucket"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			_, err := e.client.RemoveUpload(ctxT(t), tt.req)
			wantCode(t, err, tt.code)
			if got := status.Convert(err).Message(); got != tt.msg {
				t.Fatalf("message = %q, want %q", got, tt.msg)
			}
		})
	}
}

func TestRemoveUploadRefusesAQueuedUpload(t *testing.T) {
	e := newEnvWith(t, keyedRunner(), server.WithObjects(&fakeObjects{})) // queue not started
	if _, err := e.client.Configure(ctxT(t), configFor("my-bucket")); err != nil {
		t.Fatal(err)
	}
	id := enqueueDirect(t, e, "my-bucket", "a.txt")

	_, err := e.client.RemoveUpload(ctxT(t), &pb.RemoveUploadRequest{UploadId: id})

	wantCode(t, err, codes.FailedPrecondition)
	if got := status.Convert(err).Message(); !strings.Contains(got, "queued or running") {
		t.Fatalf("message = %q, want it to say the upload is queued or running", got)
	}
}

func TestRemoveUploadRefusesDeletingWhenTheDaemonHasNoObjectAccess(t *testing.T) {
	e := removeEnv(t, nil)
	id := sendFolder(t, e, "my-bucket", "a")

	_, err := e.client.RemoveUpload(ctxT(t), &pb.RemoveUploadRequest{UploadId: id, DeleteFromBucket: true})

	wantCode(t, err, codes.Unimplemented)
	if !hasUpload(t, e, id) {
		t.Fatal("the upload must stay when the removal was refused")
	}
}

func TestRemoveUploadDeleteFailuresCarryTheReadableSentence(t *testing.T) {
	tests := []struct {
		name string
		err  error
		code codes.Code
		msg  string
	}{
		{"denied", uploader.ErrDeleteDenied, codes.PermissionDenied,
			"AWS denied permission to delete from the bucket: the access key needs the s3:DeleteObject permission"},
		{"no network", uploader.ErrNoNetwork, codes.Unavailable, "No internet connection"},
		{"bad credentials", uploader.ErrBadCredentials, codes.PermissionDenied, "AWS rejected the access key"},
		{"no bucket", uploader.ErrBucketNotFound, codes.FailedPrecondition, "Bucket not found"},
		{"unknown failure", errors.New("request signed with SECRET-MARKER"), codes.Internal, "Could not delete the objects from the bucket"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e := removeEnv(t, &fakeObjects{err: tt.err})
			id := sendFolder(t, e, "my-bucket", "a")

			_, err := e.client.RemoveUpload(ctxT(t), &pb.RemoveUploadRequest{UploadId: id, DeleteFromBucket: true})

			wantCode(t, err, tt.code)
			if got := status.Convert(err).Message(); got != tt.msg {
				t.Fatalf("message = %q, want %q", got, tt.msg)
			}
			if !hasUpload(t, e, id) {
				t.Fatal("nothing was deleted, so the upload must stay")
			}
			if strings.Contains(e.logs.String(), "SECRET-MARKER") {
				t.Fatalf("the log carries the error text: %s", e.logs.String())
			}
		})
	}
}

func TestRemoveUploadPartialDeleteForgetsOnlyWhatWasDeleted(t *testing.T) {
	objects := &fakeObjects{err: uploader.ErrDeleteDenied, failAfter: 1}
	e := removeEnv(t, objects)
	id := sendFolder(t, e, "my-bucket", "a", "b")

	_, err := e.client.RemoveUpload(ctxT(t), &pb.RemoveUploadRequest{UploadId: id, DeleteFromBucket: true})

	wantCode(t, err, codes.PermissionDenied)
	initial, _, cancel := e.queue.Subscribe()
	cancel()
	if len(initial) != 1 || initial[0].FilesTotal != 1 {
		t.Fatalf("upload after = %+v, want the one file whose object stayed", initial)
	}
}

func TestConfigureCallsTheHookWithTheNewSettings(t *testing.T) {
	var got []uploader.Settings
	e := newEnvWith(t, noopRunner(), server.WithOnConfigured(func(s uploader.Settings) { got = append(got, s) }))

	if _, err := e.client.Configure(ctxT(t), &pb.ConfigureRequest{}); err == nil {
		t.Fatal("an invalid Configure must fail")
	}
	if _, err := e.client.Configure(ctxT(t), configFor("my-bucket")); err != nil {
		t.Fatal(err)
	}

	if len(got) != 1 || got[0].Bucket != "my-bucket" {
		t.Fatalf("hook calls = %v, want one for the valid Configure", got)
	}
}
