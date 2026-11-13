// Package server implements the daemon's gRPC API on top of the upload queue.
package server

import (
	"context"
	"errors"
	"sync"

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

	queue *queue.Queue
	log   *logging.Logger

	mu       sync.Mutex
	settings uploader.Settings
	hasConf  bool
}

// New returns a Server that enqueues uploads on q.
func New(q *queue.Queue, log *logging.Logger) *Server {
	return &Server{queue: q, log: log}
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
	s.mu.Unlock()

	s.log.Info("configured", "region", st.Region, "bucket", st.Bucket, "prefix", st.Prefix)
	return &pb.ConfigureResponse{}, nil
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
		// ErrUnknownUpload is the only error SubscribeFiles returns.
		return status.Error(codes.NotFound, "unknown upload")
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
		ErrorMessage:  s.ErrorMessage,
		Kind:          toProtoKind(s.Kind),
		RootPaths:     s.RootPaths,
		FilesTotal:    int32(s.FilesTotal),
		FilesFinished: int32(s.FilesFinished),
		FilesFailed:   int32(s.FilesFailed),
	}
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
	default:
		return pb.UploadState_UPLOAD_STATE_UNSPECIFIED
	}
}
