package server_test

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"strings"
	"sync"
	"testing"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"rabbithole/daemon/internal/buckets"
	"rabbithole/daemon/internal/download"
	pb "rabbithole/daemon/internal/gen/rabbithole/v1"
	"rabbithole/daemon/internal/queue"
	"rabbithole/daemon/internal/server"
	"rabbithole/daemon/internal/uploader"
)

type fakeTransfers struct {
	mu     sync.Mutex
	limits []int64
	verify []bool
}

func (f *fakeTransfers) SetSpeedLimit(n int64) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.limits = append(f.limits, n)
}

func (f *fakeTransfers) SetVerifyUploads(on bool) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.verify = append(f.verify, on)
}

func TestSetOptionsPassesTheSpeedLimitAndTheVerification(t *testing.T) {
	tr := &fakeTransfers{}
	e := newEnvWith(t, noopRunner(), server.WithTransfers(tr))

	if _, err := e.client.SetOptions(ctxT(t), &pb.SetOptionsRequest{SpeedLimitBytesPerSecond: 2_000_000, VerifyUploads: true}); err != nil {
		t.Fatal(err)
	}
	if _, err := e.client.SetOptions(ctxT(t), &pb.SetOptionsRequest{}); err != nil {
		t.Fatal(err)
	}
	if !slices.Equal(tr.limits, []int64{2_000_000, 0}) || !slices.Equal(tr.verify, []bool{true, false}) {
		t.Fatalf("limits %v, verify %v; want each call to replace the last", tr.limits, tr.verify)
	}
}

func TestSetOptionsRefusesANegativeSpeedLimitAndChangesNothing(t *testing.T) {
	tr := &fakeTransfers{}
	e := newEnvWith(t, noopRunner(), server.WithTransfers(tr))

	_, err := e.client.SetOptions(ctxT(t), &pb.SetOptionsRequest{SpeedLimitBytesPerSecond: -1, VerifyUploads: true})

	wantCode(t, err, codes.InvalidArgument)
	if len(tr.limits) != 0 || len(tr.verify) != 0 {
		t.Fatalf("options changed by a refused call: %v %v", tr.limits, tr.verify)
	}
}

func TestSetOptionsWithoutTransfersStillAccepts(t *testing.T) {
	e := newEnv(t, noopRunner())
	if _, err := e.client.SetOptions(ctxT(t), &pb.SetOptionsRequest{SpeedLimitBytesPerSecond: 5}); err != nil {
		t.Fatal(err)
	}
}

// fakeDownloads records Start and serves a stream the test drives.
type fakeDownloads struct {
	mu        sync.Mutex
	startErr  error
	cancelErr error
	started   []startCall
	canceled  []string
	initial   []download.Snapshot
	updates   chan download.Snapshot
}

type startCall struct {
	settings uploader.Settings
	uploadID string
	indexes  []int
	dest     string
}

func (f *fakeDownloads) Start(s uploader.Settings, id string, indexes []int, dest string) (string, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.started = append(f.started, startCall{s, id, indexes, dest})
	if f.startErr != nil {
		return "", f.startErr
	}
	return "dl-1", nil
}

func (f *fakeDownloads) Cancel(id string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.canceled = append(f.canceled, id)
	return f.cancelErr
}

func (f *fakeDownloads) Subscribe() ([]download.Snapshot, <-chan download.Snapshot, func()) {
	return f.initial, f.updates, func() {}
}

func TestStartDownloadBeforeConfigureFailsPrecondition(t *testing.T) {
	e := newEnvWith(t, noopRunner(), server.WithDownloads(&fakeDownloads{}))
	_, err := e.client.StartDownload(ctxT(t), &pb.StartDownloadRequest{UploadId: "u", DestinationDir: "/tmp"})
	wantCode(t, err, codes.FailedPrecondition)
}

func TestStartDownloadHandsTheRequestAndTheSettingsToTheManager(t *testing.T) {
	fd := &fakeDownloads{}
	e := newEnvWith(t, noopRunner(), server.WithDownloads(fd))
	if _, err := e.client.Configure(ctxT(t), validConfig()); err != nil {
		t.Fatal(err)
	}

	resp, err := e.client.StartDownload(ctxT(t), &pb.StartDownloadRequest{UploadId: "u-1", FileIndexes: []int32{2, 5}, DestinationDir: "/dest"})
	if err != nil || resp.GetDownloadId() != "dl-1" {
		t.Fatalf("resp %v err %v", resp, err)
	}
	got := fd.started[0]
	if got.uploadID != "u-1" || !slices.Equal(got.indexes, []int{2, 5}) || got.dest != "/dest" || got.settings.Bucket != validConfig().GetBucket() {
		t.Fatalf("Start called with %+v", got)
	}
}

func TestStartDownloadStatuses(t *testing.T) {
	tests := []struct {
		name string
		err  error
		code codes.Code
		msg  string
	}{
		{"unknown upload", fmt.Errorf("x: %w", queue.ErrUnknownUpload), codes.NotFound, "unknown upload"},
		{"unknown file", queue.ErrUnknownFile, codes.NotFound, "unknown file"},
		{"other bucket", queue.ErrOtherBucket, codes.FailedPrecondition, "This upload belongs to another bucket"},
		{"nothing finished", queue.ErrNoFinishedFiles, codes.FailedPrecondition, "None of the chosen files has finished uploading"},
		{"bad destination", download.ErrBadDestination, codes.FailedPrecondition, "The destination must be an existing folder that can be written to"},
		{"no free name", uploader.ErrNoFreeName, codes.FailedPrecondition, "Could not find a free name for this file"},
		{"anything else", errors.New("secret-detail"), codes.Internal, "could not start the download"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e := newEnvWith(t, noopRunner(), server.WithDownloads(&fakeDownloads{startErr: tt.err}))
			if _, err := e.client.Configure(ctxT(t), validConfig()); err != nil {
				t.Fatal(err)
			}
			_, err := e.client.StartDownload(ctxT(t), &pb.StartDownloadRequest{UploadId: "u", DestinationDir: "/d"})
			wantCode(t, err, tt.code)
			if got := status.Convert(err).Message(); got != tt.msg {
				t.Fatalf("message = %q, want %q", got, tt.msg)
			}
		})
	}
}

func TestCancelDownloadStatuses(t *testing.T) {
	tests := []struct {
		err  error
		code codes.Code
		msg  string
	}{
		{nil, codes.OK, ""},
		{download.ErrUnknownDownload, codes.NotFound, "unknown download"},
		{download.ErrDownloadEnded, codes.FailedPrecondition, "The download already ended"},
		{errors.New("boom"), codes.Internal, "could not cancel the download"},
	}
	for _, tt := range tests {
		fd := &fakeDownloads{cancelErr: tt.err}
		e := newEnvWith(t, noopRunner(), server.WithDownloads(fd))
		_, err := e.client.CancelDownload(ctxT(t), &pb.CancelDownloadRequest{DownloadId: "dl-9"})
		wantCode(t, err, tt.code)
		if tt.code != codes.OK && status.Convert(err).Message() != tt.msg {
			t.Fatalf("message = %q, want %q", status.Convert(err).Message(), tt.msg)
		}
		if !slices.Equal(fd.canceled, []string{"dl-9"}) {
			t.Fatalf("canceled = %v", fd.canceled)
		}
	}
}

func TestDownloadCallsWithoutAManagerAreUnimplemented(t *testing.T) {
	e := newEnv(t, noopRunner())
	_, err := e.client.CancelDownload(ctxT(t), &pb.CancelDownloadRequest{DownloadId: "x"})
	wantCode(t, err, codes.Unimplemented)
}

func TestWatchDownloadsReplaysThenStreamsAndMapsEveryField(t *testing.T) {
	fd := &fakeDownloads{
		updates: make(chan download.Snapshot, 4),
		initial: []download.Snapshot{{
			ID: "dl-1", UploadID: "u-1", FileIndexes: []int{1, 4}, Name: "photos", Destination: "/dest/photos",
			BytesTotal: 100, BytesDone: 40, FilesTotal: 2, FilesDone: 1, FilesFailed: 1,
			State: download.Failed, ErrorMessage: "1 of 2 files could not be downloaded",
		}},
	}
	e := newEnvWith(t, noopRunner(), server.WithDownloads(fd))
	stream, err := e.client.WatchDownloads(ctxT(t), &pb.WatchDownloadsRequest{})
	if err != nil {
		t.Fatal(err)
	}

	first, err := stream.Recv()
	if err != nil {
		t.Fatal(err)
	}
	if first.GetDownloadId() != "dl-1" || first.GetUploadId() != "u-1" || !slices.Equal(first.GetFileIndexes(), []int32{1, 4}) ||
		first.GetName() != "photos" || first.GetDestinationPath() != "/dest/photos" || first.GetBytesTotal() != 100 ||
		first.GetBytesDone() != 40 || first.GetFilesTotal() != 2 || first.GetFilesDone() != 1 || first.GetFilesFailed() != 1 ||
		first.GetState() != pb.DownloadState_DOWNLOAD_FAILED || first.GetErrorMessage() != "1 of 2 files could not be downloaded" {
		t.Fatalf("first = %v", first)
	}
	fd.updates <- download.Snapshot{ID: "dl-2", State: download.Downloading}
	next, err := stream.Recv()
	if err != nil || next.GetDownloadId() != "dl-2" || next.GetState() != pb.DownloadState_DOWNLOADING {
		t.Fatalf("next = %v, %v", next, err)
	}
}

func TestDownloadStatesMapToTheProtocol(t *testing.T) {
	want := map[download.State]pb.DownloadState{
		download.Queued: pb.DownloadState_DOWNLOAD_QUEUED, download.Downloading: pb.DownloadState_DOWNLOADING,
		download.Finished: pb.DownloadState_DOWNLOAD_FINISHED, download.Failed: pb.DownloadState_DOWNLOAD_FAILED,
		download.Canceled: pb.DownloadState_DOWNLOAD_CANCELED,
	}
	for state, proto := range want {
		fd := &fakeDownloads{updates: make(chan download.Snapshot), initial: []download.Snapshot{{ID: "d", State: state}}}
		e := newEnvWith(t, noopRunner(), server.WithDownloads(fd))
		stream, err := e.client.WatchDownloads(ctxT(t), &pb.WatchDownloadsRequest{})
		if err != nil {
			t.Fatal(err)
		}
		got, err := stream.Recv()
		if err != nil || got.GetState() != proto {
			t.Fatalf("state %v: got %v, %v; want %v", state, got.GetState(), err, proto)
		}
	}
}

// fakeBuckets answers List and Create and records the credentials it was given.
type fakeBuckets struct {
	list    []buckets.Bucket
	err     error
	creds   []buckets.Credentials
	created []string
}

func (f *fakeBuckets) List(_ context.Context, c buckets.Credentials) ([]buckets.Bucket, error) {
	f.creds = append(f.creds, c)
	return f.list, f.err
}

func (f *fakeBuckets) Create(_ context.Context, c buckets.Credentials, name string) error {
	f.creds = append(f.creds, c)
	f.created = append(f.created, name)
	return f.err
}

func TestListBucketsWorksBeforeConfigureAndReturnsWhatTheServiceFound(t *testing.T) {
	fb := &fakeBuckets{list: []buckets.Bucket{{Name: "alpha", Region: "eu-west-1"}, {Name: "beta"}}}
	e := newEnvWith(t, noopRunner(), server.WithBuckets(fb))

	resp, err := e.client.ListBuckets(ctxT(t), &pb.ListBucketsRequest{AccessKeyId: "AK", SecretAccessKey: "SK", Region: "us-east-1"})
	if err != nil {
		t.Fatal(err)
	}
	got := resp.GetBuckets()
	if len(got) != 2 || got[0].GetName() != "alpha" || got[0].GetRegion() != "eu-west-1" || got[1].GetName() != "beta" || got[1].GetRegion() != "" {
		t.Fatalf("buckets = %v", got)
	}
	if fb.creds[0] != (buckets.Credentials{AccessKeyID: "AK", SecretAccessKey: "SK", Region: "us-east-1"}) {
		t.Fatalf("service got %+v", fb.creds[0])
	}
}

func TestListBucketsDoesNotChangeTheConfiguredSettings(t *testing.T) {
	fb := &fakeBuckets{}
	fd := &fakeDownloads{}
	e := newEnvWith(t, noopRunner(), server.WithBuckets(fb), server.WithDownloads(fd))
	if _, err := e.client.Configure(ctxT(t), validConfig()); err != nil {
		t.Fatal(err)
	}
	if _, err := e.client.ListBuckets(ctxT(t), &pb.ListBucketsRequest{AccessKeyId: "OTHER", SecretAccessKey: "OTHER", Region: "ap-south-1"}); err != nil {
		t.Fatal(err)
	}
	if _, err := e.client.StartDownload(ctxT(t), &pb.StartDownloadRequest{UploadId: "u", DestinationDir: "/d"}); err != nil {
		t.Fatal(err)
	}
	if s := fd.started[0].settings; s.AccessKeyID != validConfig().GetAccessKeyId() || s.Region != validConfig().GetRegion() {
		t.Fatalf("settings changed by ListBuckets: %+v", s)
	}
}

func TestBucketCallsRefuseEmptyCredentialsOrRegion(t *testing.T) {
	e := newEnvWith(t, noopRunner(), server.WithBuckets(&fakeBuckets{}))
	cases := []struct{ ak, sk, region string }{{"", "s", "r"}, {"a", "", "r"}, {"a", "s", ""}}
	for _, c := range cases {
		_, err := e.client.ListBuckets(ctxT(t), &pb.ListBucketsRequest{AccessKeyId: c.ak, SecretAccessKey: c.sk, Region: c.region})
		wantCode(t, err, codes.InvalidArgument)
		_, err = e.client.CreateBucket(ctxT(t), &pb.CreateBucketRequest{AccessKeyId: c.ak, SecretAccessKey: c.sk, Region: c.region, Name: "my-bucket"})
		wantCode(t, err, codes.InvalidArgument)
	}
}

func TestListBucketsStatuses(t *testing.T) {
	tests := []struct {
		err  error
		code codes.Code
		msg  string
	}{
		{fmt.Errorf("x: %w", uploader.ErrListBucketsDenied), codes.PermissionDenied, "AWS denied permission to list buckets: the access key needs the s3:ListAllMyBuckets permission"},
		{uploader.ErrBadCredentials, codes.PermissionDenied, "AWS rejected the access key"},
		{uploader.ErrNoNetwork, codes.Unavailable, "No internet connection"},
		{errors.New("boom"), codes.Internal, "could not list buckets"},
	}
	for _, tt := range tests {
		e := newEnvWith(t, noopRunner(), server.WithBuckets(&fakeBuckets{err: tt.err}))
		_, err := e.client.ListBuckets(ctxT(t), &pb.ListBucketsRequest{AccessKeyId: "a", SecretAccessKey: "s", Region: "r"})
		wantCode(t, err, tt.code)
		if got := status.Convert(err).Message(); got != tt.msg {
			t.Fatalf("message = %q, want %q", got, tt.msg)
		}
	}
}

func TestCreateBucketValidatesTheNameBeforeCallingAWS(t *testing.T) {
	fb := &fakeBuckets{}
	e := newEnvWith(t, noopRunner(), server.WithBuckets(fb))
	for _, name := range []string{"", "ab", "Upper", "-lead", "trail-", "under_score", strings.Repeat("a", 64)} {
		_, err := e.client.CreateBucket(ctxT(t), &pb.CreateBucketRequest{AccessKeyId: "a", SecretAccessKey: "s", Region: "r", Name: name})
		wantCode(t, err, codes.InvalidArgument)
		if got := status.Convert(err).Message(); got != buckets.ErrInvalidName.Error() {
			t.Fatalf("name %q: message = %q", name, got)
		}
	}
	if len(fb.created) != 0 {
		t.Fatalf("AWS was called for invalid names: %v", fb.created)
	}
}

func TestCreateBucketStatusesAndMessages(t *testing.T) {
	tests := []struct {
		err  error
		code codes.Code
		msg  string
	}{
		{buckets.ErrNameTaken, codes.AlreadyExists, "This name is already taken by another AWS account. Bucket names are unique in all of AWS: try another one."},
		{buckets.ErrOwnedByYou, codes.AlreadyExists, "You already have a bucket with this name. Choose it in the list instead."},
		{buckets.ErrInvalidName, codes.InvalidArgument, "This name is not valid. Use 3 to 63 lowercase letters, numbers and hyphens, starting and ending with a letter or a number."},
		{buckets.ErrCreateDenied, codes.PermissionDenied, "AWS denied permission to create buckets: the access key needs the s3:CreateBucket permission"},
		{fmt.Errorf("x: %w", uploader.ErrBadCredentials), codes.PermissionDenied, "AWS rejected the access key"},
		{uploader.ErrNoNetwork, codes.Unavailable, "No internet connection"},
		{buckets.ErrTooManyBucket, codes.ResourceExhausted, "This account has reached its limit of buckets"},
		{errors.New("secret-text-from-aws"), codes.Internal, "The bucket could not be created"},
	}
	for _, tt := range tests {
		t.Run(tt.msg, func(t *testing.T) {
			fb := &fakeBuckets{err: tt.err}
			e := newEnvWith(t, noopRunner(), server.WithBuckets(fb))
			_, err := e.client.CreateBucket(ctxT(t), &pb.CreateBucketRequest{AccessKeyId: "AKSECRET", SecretAccessKey: "SKSECRET", Region: "eu-west-1", Name: "my-bucket"})
			wantCode(t, err, tt.code)
			if got := status.Convert(err).Message(); got != tt.msg {
				t.Fatalf("message = %q, want %q", got, tt.msg)
			}
			for _, leak := range []string{"AKSECRET", "SKSECRET", "secret-text-from-aws"} {
				if strings.Contains(e.logs.String(), leak) || strings.Contains(err.Error(), leak) {
					t.Fatalf("%q leaked into the logs or the status", leak)
				}
			}
			if !slices.Equal(fb.created, []string{"my-bucket"}) || fb.creds[0].Region != "eu-west-1" {
				t.Fatalf("service got %v %+v", fb.created, fb.creds)
			}
		})
	}
}

func TestCreateBucketSuccess(t *testing.T) {
	fb := &fakeBuckets{}
	e := newEnvWith(t, noopRunner(), server.WithBuckets(fb))
	if _, err := e.client.CreateBucket(ctxT(t), &pb.CreateBucketRequest{AccessKeyId: "a", SecretAccessKey: "s", Region: "us-east-1", Name: "abc"}); err != nil {
		t.Fatal(err)
	}
	if !slices.Equal(fb.created, []string{"abc"}) {
		t.Fatalf("created = %v", fb.created)
	}
}

func TestBucketCallsWithoutAServiceAreUnimplemented(t *testing.T) {
	e := newEnv(t, noopRunner())
	_, err := e.client.ListBuckets(ctxT(t), &pb.ListBucketsRequest{AccessKeyId: "a", SecretAccessKey: "s", Region: "r"})
	wantCode(t, err, codes.Unimplemented)
}
