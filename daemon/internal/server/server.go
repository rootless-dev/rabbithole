// Package server implements the daemon's gRPC API on top of the upload queue.
package server

import (
	"context"
	"errors"
	"sync"
	"time"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	pb "rabbithole/daemon/internal/gen/rabbithole/v1"
	"rabbithole/daemon/internal/logging"
	"rabbithole/daemon/internal/queue"
	"rabbithole/daemon/internal/uploader"
)

// Server implements pb.DaemonServer. Credentials are never logged and never
// placed in a returned status.
type Server struct {
	pb.UnimplementedDaemonServer

	queue        *queue.Queue
	log          *logging.Logger
	objects      Objects
	onConfigured func(uploader.Settings)

	mu       sync.Mutex
	settings uploader.Settings
	hasConf  bool
	// configuredOnce is set by the first successful Configure of the run.
	configuredOnce bool
}

// Option changes how New builds a Server.
type Option func(*Server)

// WithObjects lets RemoveUpload delete objects from the bucket through o.
// Without it a removal that asks for the objects to go is refused.
func WithObjects(o Objects) Option { return func(s *Server) { s.objects = o } }

// WithOnConfigured makes the server call fn each time Configure succeeds, with
// the new settings. fn must not block.
func WithOnConfigured(fn func(uploader.Settings)) Option {
	return func(s *Server) { s.onConfigured = fn }
}

// New returns a Server that enqueues uploads on q.
func New(q *queue.Queue, log *logging.Logger, opts ...Option) *Server {
	// Until Configure names a bucket no upload is shown.
	q.SetBucket("")
	s := &Server{queue: q, log: log}
	for _, opt := range opts {
		opt(s)
	}
	return s
}

// Configure replaces the AWS settings used by uploads enqueued from now on.
// It does not call AWS.
func (s *Server) Configure(_ context.Context, req *pb.ConfigureRequest) (*pb.ConfigureResponse, error) {
	switch {
	case req.GetAccessKeyId() == "":
		return nil, status.Error(codes.InvalidArgument, "access_key_id is required")
	case req.GetSecretAccessKey() == "":
		return nil, status.Error(codes.InvalidArgument, "secret_access_key is required")
	case req.GetRegion() == "":
		return nil, status.Error(codes.InvalidArgument, "region is required")
	case req.GetBucket() == "":
		return nil, status.Error(codes.InvalidArgument, "bucket is required")
	case req.GetQuickUploadsPrefix() == "":
		return nil, status.Error(codes.InvalidArgument, "quick_uploads_prefix is required")
	}

	st := uploader.Settings{
		AccessKeyID:     req.GetAccessKeyId(),
		SecretAccessKey: req.GetSecretAccessKey(),
		Region:          req.GetRegion(),
		Bucket:          req.GetBucket(),
		Prefix:          req.GetQuickUploadsPrefix(),
	}
	s.mu.Lock()
	s.settings, s.hasConf = st, true
	first := !s.configuredOnce
	s.configuredOnce = true
	s.mu.Unlock()
	s.queue.SetBucket(st.Bucket)
	s.queue.SetSettings(st)
	if s.onConfigured != nil {
		s.onConfigured(st)
	}
	s.log.Info("configured", "region", st.Region, "bucket", st.Bucket, "prefix", st.Prefix)

	// Once per daemon run: the first Configure decides, whatever later ones say.
	if first && req.GetResumeInterrupted() {
		n := s.queue.ResumeInterrupted(st)
		s.log.Info("interrupted uploads resumed", "uploads", n)
	}
	return &pb.ConfigureResponse{}, nil
}

// RetryUpload sends failed files of a failed upload again, with the settings
// in force now.
func (s *Server) RetryUpload(_ context.Context, req *pb.RetryUploadRequest) (*pb.RetryUploadResponse, error) {
	s.mu.Lock()
	st, ok := s.settings, s.hasConf
	s.mu.Unlock()
	if !ok {
		return nil, status.Error(codes.FailedPrecondition, "daemon is not configured: call Configure first")
	}
	indexes := make([]int, len(req.GetFileIndexes()))
	for i, idx := range req.GetFileIndexes() {
		indexes[i] = int(idx)
	}

	if err := s.queue.Retry(st, req.GetUploadId(), indexes); err != nil {
		return nil, s.retryStatus(req.GetUploadId(), err)
	}
	s.log.Info("upload retried", "upload_id", req.GetUploadId(), "files", len(indexes))
	return &pb.RetryUploadResponse{}, nil
}

// retryStatus maps what Queue.Retry returns to a gRPC status.
func (s *Server) retryStatus(id string, err error) error {
	switch {
	case errors.Is(err, queue.ErrUnknownUpload):
		return status.Error(codes.NotFound, "unknown upload")
	case errors.Is(err, queue.ErrUnknownFile):
		return status.Error(codes.NotFound, "unknown file")
	case errors.Is(err, queue.ErrUploadNotFailed):
		return status.Error(codes.FailedPrecondition, "Only a failed or canceled upload can be retried")
	case errors.Is(err, queue.ErrFileNotFailed):
		return status.Error(codes.FailedPrecondition, "Only a failed or canceled file can be retried")
	case errors.Is(err, queue.ErrOtherBucket):
		return status.Error(codes.FailedPrecondition, "This upload belongs to another bucket")
	case errors.Is(err, queue.ErrUploadActive):
		return status.Error(codes.FailedPrecondition, "This upload is being removed")
	}
	s.log.Error("retry failed", "upload_id", id, "error", err.Error())
	return status.Error(codes.Internal, "could not retry upload")
}

// EnqueueUpload queues the file at local_path with the settings in force now.
func (s *Server) EnqueueUpload(_ context.Context, req *pb.EnqueueUploadRequest) (*pb.EnqueueUploadResponse, error) {
	s.mu.Lock()
	st, ok := s.settings, s.hasConf
	s.mu.Unlock()
	if !ok {
		return nil, status.Error(codes.FailedPrecondition, "daemon is not configured: call Configure first")
	}

	paths := req.GetLocalPaths()
	if len(paths) == 0 {
		paths = []string{req.GetLocalPath()}
	}
	first := paths[0]

	id, err := s.queue.Enqueue(st, queue.EnqueueRequest{
		Paths:         paths,
		SkipPatterns:  req.GetSkipPatterns(),
		ParallelFiles: int(req.GetParallelFiles()),
	})
	if err != nil {
		switch {
		case errors.Is(err, queue.ErrInvalidPath):
			s.log.Warn("enqueue rejected", "path", first, "reason", err.Error())
			return nil, status.Error(codes.InvalidArgument, err.Error())
		case errors.Is(err, queue.ErrNoFiles):
			s.log.Warn("enqueue rejected", "path", first, "reason", err.Error())
			return nil, status.Error(codes.InvalidArgument, "There are no files to send")
		}
		s.log.Error("enqueue failed", "path", first, "error", err.Error())
		return nil, status.Error(codes.Internal, "could not enqueue upload")
	}
	s.log.Info("upload enqueued", "upload_id", id, "path", first, "items", len(paths))
	return &pb.EnqueueUploadResponse{UploadId: id}, nil
}

// WatchUploadFiles sends one snapshot per file of an upload, then a snapshot
// whenever one of them changes, until the client goes away.
func (s *Server) WatchUploadFiles(req *pb.WatchUploadFilesRequest, stream pb.Daemon_WatchUploadFilesServer) error {
	initial, updates, cancel, err := s.queue.SubscribeFiles(req.GetUploadId())
	if err != nil {
		if errors.Is(err, queue.ErrUnknownUpload) {
			return status.Error(codes.NotFound, "unknown upload")
		}
		s.log.Error("could not read files", "upload_id", req.GetUploadId(), "error", err.Error())
		return status.Error(codes.Internal, "could not read the files of the upload")
	}
	defer cancel()
	return relay(stream.Context(), initial, updates, func(f queue.FileSnapshot) error {
		return stream.Send(toProtoFile(f))
	})
}

// WatchUploads sends one snapshot per known upload, then a snapshot whenever
// one changes, until the client goes away.
func (s *Server) WatchUploads(_ *pb.WatchUploadsRequest, stream pb.Daemon_WatchUploadsServer) error {
	initial, updates, cancel := s.queue.Subscribe()
	defer cancel()
	return relay(stream.Context(), initial, updates, func(u queue.Snapshot) error {
		return stream.Send(toProto(u))
	})
}

// relay sends every value of initial, then every value of updates, until send
// fails or ctx ends. updates is closed only by the subscription's cancel, which
// the caller runs after relay returns, so it never closes while relay reads it.
func relay[T any](ctx context.Context, initial []T, updates <-chan T, send func(T) error) error {
	for _, v := range initial {
		if err := send(v); err != nil {
			return err
		}
	}
	for {
		select {
		case v := <-updates:
			if err := send(v); err != nil {
				return err
			}
		case <-ctx.Done():
			return ctx.Err()
		}
	}
}

func toProto(s queue.Snapshot) *pb.UploadSnapshot {
	return &pb.UploadSnapshot{
		UploadId:      s.ID,
		FileName:      s.FileName,
		LocalPath:     s.LocalPath,
		ObjectKey:     s.ObjectKey,
		BytesTotal:    s.BytesTotal,
		BytesSent:     s.BytesSent,
		State:         toProtoState(s.State),
		PauseReason:   toProtoPauseReason(s.PauseReason),
		ErrorMessage:  s.ErrorMessage,
		Kind:          toProtoKind(s.Kind),
		RootPaths:     s.RootPaths,
		FilesTotal:    int32(s.FilesTotal),
		FilesFinished: int32(s.FilesFinished),
		FilesFailed:   int32(s.FilesFailed),
		Removed:       s.Removed,
		CreatedAtMs:   millis(s.CreatedAt),
		EndedAtMs:     millis(s.EndedAt),
	}
}

// millis is t in milliseconds since the Unix epoch; zero for the zero time.
func millis(t time.Time) int64 {
	if t.IsZero() {
		return 0
	}
	return t.UnixMilli()
}

func toProtoFile(f queue.FileSnapshot) *pb.FileSnapshot {
	return &pb.FileSnapshot{
		UploadId:     f.UploadID,
		Index:        int32(f.Index),
		RelativePath: f.RelativePath,
		LocalPath:    f.LocalPath,
		ObjectKey:    f.ObjectKey,
		BytesTotal:   f.BytesTotal,
		BytesSent:    f.BytesSent,
		State:        toProtoState(f.State),
		ErrorMessage: f.ErrorMessage,
		Removed:      f.Removed,
	}
}

func toProtoKind(k queue.Kind) pb.UploadKind {
	switch k {
	case queue.SingleFile:
		return pb.UploadKind_SINGLE_FILE
	case queue.Folder:
		return pb.UploadKind_FOLDER
	case queue.Multiple:
		return pb.UploadKind_MULTIPLE
	default:
		return pb.UploadKind_UPLOAD_KIND_UNSPECIFIED
	}
}

func toProtoPauseReason(r queue.PauseReason) pb.PauseReason {
	switch r {
	case queue.PausedByUser:
		return pb.PauseReason_PAUSED_BY_USER
	case queue.PausedOnHold:
		return pb.PauseReason_PAUSED_ON_HOLD
	default:
		return pb.PauseReason_PAUSE_REASON_UNSPECIFIED
	}
}

func toProtoState(s queue.State) pb.UploadState {
	switch s {
	case queue.Queued:
		return pb.UploadState_QUEUED
	case queue.Uploading:
		return pb.UploadState_UPLOADING
	case queue.Finished:
		return pb.UploadState_FINISHED
	case queue.Failed:
		return pb.UploadState_FAILED
	case queue.Paused:
		return pb.UploadState_PAUSED
	case queue.Canceled:
		return pb.UploadState_CANCELED
	default:
		return pb.UploadState_UPLOAD_STATE_UNSPECIFIED
	}
}
