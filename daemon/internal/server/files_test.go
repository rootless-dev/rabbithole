package server_test

import (
	"context"
	"os"
	"path/filepath"
	"slices"
	"sync"
	"testing"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	pb "rabbithole/daemon/internal/gen/rabbithole/v1"
	"rabbithole/daemon/internal/queue"
	"rabbithole/daemon/internal/uploader"
)

func configured(t *testing.T, r queue.Runner) *env {
	t.Helper()
	e := newEnv(t, r)
	if _, err := e.client.Configure(ctxT(t), validConfig()); err != nil {
		t.Fatal(err)
	}
	return e
}

func writeTree(t *testing.T, files ...string) string {
	t.Helper()
	root := t.TempDir()
	for _, f := range files {
		p := filepath.Join(root, filepath.FromSlash(f))
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte("xy"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	return root
}

func TestEnqueueEmptyFolderIsInvalidArgumentWithAReadableMessage(t *testing.T) {
	e := configured(t, noopRunner())
	_, err := e.client.EnqueueUpload(ctxT(t), &pb.EnqueueUploadRequest{LocalPaths: []string{t.TempDir()}})
	wantCode(t, err, codes.InvalidArgument)
	if got := status.Convert(err).Message(); got != "There are no files to send" {
		t.Errorf("message = %q", got)
	}
}

func TestEnqueueWithoutAnyPathIsInvalidArgument(t *testing.T) {
	e := configured(t, noopRunner())
	_, err := e.client.EnqueueUpload(ctxT(t), &pb.EnqueueUploadRequest{})
	wantCode(t, err, codes.InvalidArgument)
}

func TestEnqueueMapsNewFieldsToTheSnapshot(t *testing.T) {
	root := writeTree(t, "a.txt", "dir/b.txt", "dir/c.txt", "dir/skip.tmp")
	a, dir := filepath.Join(root, "a.txt"), filepath.Join(root, "dir")
	e := configured(t, noopRunner())
	// local_paths wins over local_path.
	resp, err := e.client.EnqueueUpload(ctxT(t), &pb.EnqueueUploadRequest{
		LocalPath:     filepath.Join(root, "ignored"),
		LocalPaths:    []string{a, dir},
		SkipPatterns:  []string{"*.tmp"},
		ParallelFiles: 2,
	})
	if err != nil {
		t.Fatal(err)
	}

	stream, err := e.client.WatchUploads(ctxT(t), &pb.WatchUploadsRequest{})
	if err != nil {
		t.Fatal(err)
	}
	snap, err := stream.Recv()
	if err != nil {
		t.Fatal(err)
	}
	if snap.GetUploadId() != resp.GetUploadId() || snap.GetKind() != pb.UploadKind_MULTIPLE ||
		!slices.Equal(snap.GetRootPaths(), []string{a, dir}) || snap.GetFilesTotal() != 3 ||
		snap.GetFilesFinished() != 0 || snap.GetFilesFailed() != 0 || snap.GetBytesTotal() != 6 ||
		snap.GetFileName() != "a.txt" || snap.GetLocalPath() != a {
		t.Errorf("snapshot = %v", snap)
	}
}

func TestSingleLocalPathStillWorksAndIsASingleFileOrFolder(t *testing.T) {
	root := writeTree(t, "a.txt", "dir/b.txt")
	e := configured(t, noopRunner())
	for path, want := range map[string]pb.UploadKind{
		filepath.Join(root, "a.txt"): pb.UploadKind_SINGLE_FILE,
		filepath.Join(root, "dir"):   pb.UploadKind_FOLDER,
	} {
		resp, err := e.client.EnqueueUpload(ctxT(t), &pb.EnqueueUploadRequest{LocalPath: path})
		if err != nil {
			t.Fatal(err)
		}
		stream, err := e.client.WatchUploads(ctxT(t), &pb.WatchUploadsRequest{})
		if err != nil {
			t.Fatal(err)
		}
		for {
			snap, err := stream.Recv()
			if err != nil {
				t.Fatal(err)
			}
			if snap.GetUploadId() == resp.GetUploadId() {
				if snap.GetKind() != want {
					t.Errorf("%s: kind = %v, want %v", path, snap.GetKind(), want)
				}
				break
			}
		}
	}
}

func TestEnqueuePassesSkipPatternsAndParallelismToTheQueue(t *testing.T) {
	root := writeTree(t, "dir/keep.txt", "dir/skip.tmp")
	var mu sync.Mutex
	var seen []string
	r := runnerFunc(func(_ context.Context, _ uploader.Settings, req uploader.Request, _ uploader.Callbacks) error {
		mu.Lock()
		seen = append(seen, filepath.Base(req.LocalPath))
		mu.Unlock()
		return nil
	})
	e := configured(t, r)
	resp, err := e.client.EnqueueUpload(ctxT(t), &pb.EnqueueUploadRequest{
		LocalPaths: []string{filepath.Join(root, "dir")}, SkipPatterns: []string{"*.tmp"}, ParallelFiles: 1,
	})
	if err != nil {
		t.Fatal(err)
	}
	e.startQueue(t)
	stream, err := e.client.WatchUploadFiles(ctxT(t), &pb.WatchUploadFilesRequest{UploadId: resp.GetUploadId()})
	if err != nil {
		t.Fatal(err)
	}
	for {
		f, err := stream.Recv()
		if err != nil {
			t.Fatal(err)
		}
		if f.GetState() == pb.UploadState_FINISHED {
			break
		}
	}
	mu.Lock()
	defer mu.Unlock()
	if !slices.Equal(seen, []string{"keep.txt"}) {
		t.Errorf("files run = %v", seen)
	}
}

func TestWatchUploadFilesReplaysThenStreamsChanges(t *testing.T) {
	root := writeTree(t, "dir/a.txt", "dir/b.txt")
	r := runnerFunc(func(_ context.Context, _ uploader.Settings, req uploader.Request, cb uploader.Callbacks) error {
		cb.KeyResolved("quick/dir/" + filepath.Base(req.LocalPath))
		if filepath.Base(req.LocalPath) == "b.txt" {
			return uploader.ErrFileUnreadable
		}
		return nil
	})
	e := configured(t, r)
	dir := filepath.Join(root, "dir")
	resp, err := e.client.EnqueueUpload(ctxT(t), &pb.EnqueueUploadRequest{LocalPaths: []string{dir}, ParallelFiles: 1})
	if err != nil {
		t.Fatal(err)
	}
	stream, err := e.client.WatchUploadFiles(ctxT(t), &pb.WatchUploadFilesRequest{UploadId: resp.GetUploadId()})
	if err != nil {
		t.Fatal(err)
	}
	for i, name := range []string{"a.txt", "b.txt"} {
		f, err := stream.Recv()
		if err != nil {
			t.Fatal(err)
		}
		if f.GetUploadId() != resp.GetUploadId() || f.GetIndex() != int32(i) || f.GetRelativePath() != "dir/"+name ||
			f.GetLocalPath() != filepath.Join(dir, name) || f.GetBytesTotal() != 2 || f.GetState() != pb.UploadState_QUEUED {
			t.Fatalf("replayed file %d = %v", i, f)
		}
	}

	e.startQueue(t)
	final := map[int32]*pb.FileSnapshot{}
	for len(final) < 2 || final[0].GetState() < pb.UploadState_FINISHED || final[1].GetState() < pb.UploadState_FINISHED {
		f, err := stream.Recv()
		if err != nil {
			t.Fatal(err)
		}
		final[f.GetIndex()] = f
	}
	if final[0].GetState() != pb.UploadState_FINISHED || final[0].GetObjectKey() != "quick/dir/a.txt" || final[0].GetBytesSent() != 2 {
		t.Errorf("file 0 = %v", final[0])
	}
	if final[1].GetState() != pb.UploadState_FAILED || final[1].GetErrorMessage() != "File could not be read" {
		t.Errorf("file 1 = %v", final[1])
	}
}

func TestWatchUploadFilesUnknownUploadIsNotFound(t *testing.T) {
	e := configured(t, noopRunner())
	stream, err := e.client.WatchUploadFiles(ctxT(t), &pb.WatchUploadFilesRequest{UploadId: "nope"})
	if err != nil {
		t.Fatal(err)
	}
	_, err = stream.Recv()
	wantCode(t, err, codes.NotFound)
}

func TestWatchUploadFilesEndsWhenClientContextEnds(t *testing.T) {
	root := writeTree(t, "a.txt")
	e := configured(t, noopRunner())
	resp, err := e.client.EnqueueUpload(ctxT(t), &pb.EnqueueUploadRequest{LocalPath: filepath.Join(root, "a.txt")})
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(ctxT(t))
	stream, err := e.client.WatchUploadFiles(ctx, &pb.WatchUploadFilesRequest{UploadId: resp.GetUploadId()})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := stream.Recv(); err != nil {
		t.Fatal(err)
	}
	cancel()
	_, err = stream.Recv()
	wantCode(t, err, codes.Canceled)
}
