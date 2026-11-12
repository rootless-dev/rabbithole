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

	id, err := s.queue.Enqueue(st, req.GetLocalPath())
	if err != nil {
		if errors.Is(err, queue.ErrInvalidPath) {
			s.log.Warn("enqueue rejected", "path", req.GetLocalPath(), "reason", err.Error())
			return nil, status.Error(codes.InvalidArgument, err.Error())
		}
		s.log.Error("enqueue failed", "path", req.GetLocalPath(), "error", err.Error())
		return nil, status.Error(codes.Internal, "could not enqueue upload")
	}
	s.log.Info("upload enqueued", "upload_id", id, "path", req.GetLocalPath())
	return &pb.EnqueueUploadResponse{UploadId: id}, nil
}

// WatchUploads sends one snapshot per known upload, then a snapshot whenever
// one changes, until the client goes away.
func (s *Server) WatchUploads(_ *pb.WatchUploadsRequest, stream pb.Daemon_WatchUploadsServer) error {
	initial, updates, cancel := s.queue.Subscribe()
	defer cancel()

	for _, snap := range initial {
		if err := stream.Send(toProto(snap)); err != nil {
			return err
		}
	}
	for {
		select {
		case snap, ok := <-updates:
			if !ok {
				return nil
			}
			if err := stream.Send(toProto(snap)); err != nil {
				return err
			}
		case <-stream.Context().Done():
			return stream.Context().Err()
		}
	}
}

func toProto(s queue.Snapshot) *pb.UploadSnapshot {
	return &pb.UploadSnapshot{
		UploadId:     s.ID,
		FileName:     s.FileName,
		LocalPath:    s.LocalPath,
		ObjectKey:    s.ObjectKey,
		BytesTotal:   s.BytesTotal,
		BytesSent:    s.BytesSent,
		State:        toProtoState(s.State),
		ErrorMessage: s.ErrorMessage,
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
