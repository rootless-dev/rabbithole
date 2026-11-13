package app

import (
	"context"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"rabbithole/daemon/internal/buckets"
	pb "rabbithole/daemon/internal/gen/rabbithole/v1"
	"rabbithole/daemon/internal/uploader"
)

// readS3 is a bucketS3 whose objects can be read back: every object holds
// "data". With hang set, a read delivers two bytes and then waits for its
// context.
type readS3 struct {
	*bucketS3
	hang    bool
	started chan struct{}
}

func (r *readS3) GetObject(ctx context.Context, key string) (io.ReadCloser, int64, error) {
	if !r.has(key) {
		return nil, 0, uploader.ErrObjectNotFound
	}
	if r.hang {
		return &hangBody{ctx: ctx, started: r.started}, 4, nil
	}
	return io.NopCloser(strings.NewReader("data")), 4, nil
}

type hangBody struct {
	ctx     context.Context
	started chan struct{}
	sent    bool
}

func (h *hangBody) Read(p []byte) (int, error) {
	if !h.sent {
		h.sent = true
		close(h.started)
		return copy(p, "da"), nil
	}
	<-h.ctx.Done()
	return 0, h.ctx.Err()
}

func (h *hangBody) Close() error { return nil }

func startWithReads(t *testing.T, r *readS3) (*harness, pb.DaemonClient) {
	t.Helper()
	sock := filepath.Join(shortTempDir(t), "d.sock")
	h := start(t, sock, options{newS3: func(context.Context, uploader.Settings) (uploader.S3, error) { return r, nil }})
	h.waitListening()
	return h, dial(t, sock)
}

func waitDownload(t *testing.T, client pb.DaemonClient, want pb.DownloadState) *pb.DownloadSnapshot {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), waitTimeout)
	defer cancel()
	stream, err := client.WatchDownloads(ctx, &pb.WatchDownloadsRequest{})
	if err != nil {
		t.Fatal(err)
	}
	for {
		s, err := stream.Recv()
		if err != nil {
			t.Fatalf("stream ended before a download reached %v: %v", want, err)
		}
		if s.GetState() == want {
			return s
		}
	}
}

func TestDaemonDownloadsAnUploadedFileToTheDestination(t *testing.T) {
	r := &readS3{bucketS3: newBucketS3()}
	h, client := startWithReads(t, r)
	configureAs(t, client, "bucket-1")
	id := sendFile(t, client, "a.txt")
	dest := t.TempDir()

	ctx, cancel := context.WithTimeout(context.Background(), waitTimeout)
	defer cancel()
	resp, err := client.StartDownload(ctx, &pb.StartDownloadRequest{UploadId: id, DestinationDir: dest})
	if err != nil {
		t.Fatal(err)
	}
	got := waitDownload(t, client, pb.DownloadState_DOWNLOAD_FINISHED)

	if got.GetDownloadId() != resp.GetDownloadId() || got.GetDestinationPath() != filepath.Join(dest, "a.txt") || got.GetFilesDone() != 1 {
		t.Fatalf("snapshot = %v", got)
	}
	if b, err := os.ReadFile(filepath.Join(dest, "a.txt")); err != nil || string(b) != "data" {
		t.Fatalf("file = %q, %v", b, err)
	}
	h.stop()
	if out := h.stderr.String(); strings.Contains(out, markerSecret) || strings.Contains(out, markerKeyID) {
		t.Fatalf("log leaks a credential: %s", out)
	}
}

func TestDaemonRefusesToDownloadAnUnknownUpload(t *testing.T) {
	r := &readS3{bucketS3: newBucketS3()}
	_, client := startWithReads(t, r)
	configureAs(t, client, "bucket-1")
	ctx, cancel := context.WithTimeout(context.Background(), waitTimeout)
	defer cancel()

	_, err := client.StartDownload(ctx, &pb.StartDownloadRequest{UploadId: "nope", DestinationDir: t.TempDir()})

	if status.Code(err) != codes.NotFound {
		t.Fatalf("err = %v, want NotFound", err)
	}
}

func TestShutdownCancelsARunningDownloadWithinTheBudgetAndLeavesNoTemporaryFile(t *testing.T) {
	r := &readS3{bucketS3: newBucketS3(), started: make(chan struct{})}
	h, client := startWithReads(t, r)
	configureAs(t, client, "bucket-1")
	id := sendFile(t, client, "a.txt")
	r.hang = true
	dest := t.TempDir()
	ctx, cancel := context.WithTimeout(context.Background(), waitTimeout)
	defer cancel()
	if _, err := client.StartDownload(ctx, &pb.StartDownloadRequest{UploadId: id, DestinationDir: dest}); err != nil {
		t.Fatal(err)
	}
	select {
	case <-r.started:
	case <-time.After(waitTimeout):
		t.Fatal("the download never started reading")
	}

	since := time.Now()
	h.stdinW.Close()
	h.expectExit(since, 0)

	if entries, _ := os.ReadDir(dest); len(entries) != 0 {
		t.Fatalf("destination holds %d entries after shutdown, want none", len(entries))
	}
}

// listBuckets is a buckets.Service that answers without AWS.
type listBuckets struct{ created []string }

func (l *listBuckets) List(context.Context, buckets.Credentials) ([]buckets.Bucket, error) {
	return []buckets.Bucket{{Name: "b", Region: "eu-west-1"}}, nil
}

func (l *listBuckets) Create(_ context.Context, _ buckets.Credentials, name string) error {
	l.created = append(l.created, name)
	return nil
}

func TestDaemonListsAndCreatesBucketsBeforeItIsConfigured(t *testing.T) {
	lb := &listBuckets{}
	sock := filepath.Join(shortTempDir(t), "d.sock")
	h := start(t, sock, options{buckets: lb})
	h.waitListening()
	client := dial(t, sock)
	ctx, cancel := context.WithTimeout(context.Background(), waitTimeout)
	defer cancel()

	list, err := client.ListBuckets(ctx, &pb.ListBucketsRequest{AccessKeyId: markerKeyID, SecretAccessKey: markerSecret, Region: "us-east-1"})
	if err != nil || len(list.GetBuckets()) != 1 || list.GetBuckets()[0].GetRegion() != "eu-west-1" {
		t.Fatalf("list = %v, %v", list, err)
	}
	if _, err := client.CreateBucket(ctx, &pb.CreateBucketRequest{AccessKeyId: markerKeyID, SecretAccessKey: markerSecret, Region: "us-east-1", Name: "new-bucket"}); err != nil {
		t.Fatal(err)
	}
	if len(lb.created) != 1 || lb.created[0] != "new-bucket" {
		t.Fatalf("created = %v", lb.created)
	}
	h.stop()
	if out := h.stderr.String(); strings.Contains(out, markerSecret) || strings.Contains(out, markerKeyID) {
		t.Fatalf("log leaks a credential: %s", out)
	}
}

func TestSetOptionsReachesTheSharedLimiterAndTheVerification(t *testing.T) {
	tr := newTransfers()
	sock := filepath.Join(shortTempDir(t), "d.sock")
	h := start(t, sock, options{transfers: tr})
	h.waitListening()
	client := dial(t, sock)
	ctx, cancel := context.WithTimeout(context.Background(), waitTimeout)
	defer cancel()

	if tr.limiter.Rate() != 0 || tr.verify.Load() {
		t.Fatal("a fresh daemon must start unlimited and unverified")
	}
	if _, err := client.SetOptions(ctx, &pb.SetOptionsRequest{SpeedLimitBytesPerSecond: 123456, VerifyUploads: true}); err != nil {
		t.Fatal(err)
	}
	if tr.limiter.Rate() != 123456 || !tr.verify.Load() {
		t.Fatalf("limit %d verify %v after SetOptions", tr.limiter.Rate(), tr.verify.Load())
	}
}
