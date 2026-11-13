package server

import (
	"context"
	"errors"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	pb "rabbithole/daemon/internal/gen/rabbithole/v1"
	"rabbithole/daemon/internal/queue"
	"rabbithole/daemon/internal/uploader"
)

// configured returns the settings in force, or the status to answer with when
// Configure has not been called.
func (s *Server) configured() (uploader.Settings, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if !s.hasConf {
		return uploader.Settings{}, status.Error(codes.FailedPrecondition, "daemon is not configured: call Configure first")
	}
	return s.settings, nil
}

// SetOptions applies the options that apply to every upload: the speed limit
// and the verification, which take effect on files already being sent, and the
// hold. None of them is stored.
func (s *Server) SetOptions(_ context.Context, req *pb.SetOptionsRequest) (*pb.SetOptionsResponse, error) {
	if req.GetSpeedLimitBytesPerSecond() < 0 {
		return nil, status.Error(codes.InvalidArgument, "speed_limit_bytes_per_second must not be negative")
	}
	if s.transfers != nil {
		s.transfers.SetSpeedLimit(req.GetSpeedLimitBytesPerSecond())
		s.transfers.SetVerifyUploads(req.GetVerifyUploads())
	}
	s.queue.SetHold(req.GetHoldUploads())
	s.log.Info("options set", "speed_limit_bytes_per_second", req.GetSpeedLimitBytesPerSecond(),
		"verify_uploads", req.GetVerifyUploads(), "hold_uploads", req.GetHoldUploads())
	return &pb.SetOptionsResponse{}, nil
}

// PauseUpload stops a queued or running upload, keeping what was sent.
func (s *Server) PauseUpload(_ context.Context, req *pb.PauseUploadRequest) (*pb.PauseUploadResponse, error) {
	st, err := s.configured()
	if err != nil {
		return nil, err
	}
	if err := s.queue.Pause(st.Bucket, req.GetUploadId()); err != nil {
		return nil, s.controlStatus("pause", req.GetUploadId(), err)
	}
	s.log.Info("upload paused", "upload_id", req.GetUploadId())
	return &pb.PauseUploadResponse{}, nil
}

// ResumeUpload puts an upload the user paused back in the queue.
func (s *Server) ResumeUpload(_ context.Context, req *pb.ResumeUploadRequest) (*pb.ResumeUploadResponse, error) {
	st, err := s.configured()
	if err != nil {
		return nil, err
	}
	if err := s.queue.Resume(st, req.GetUploadId()); err != nil {
		return nil, s.controlStatus("resume", req.GetUploadId(), err)
	}
	s.log.Info("upload resumed", "upload_id", req.GetUploadId())
	return &pb.ResumeUploadResponse{}, nil
}

// CancelUpload stops an upload for good.
func (s *Server) CancelUpload(_ context.Context, req *pb.CancelUploadRequest) (*pb.CancelUploadResponse, error) {
	st, err := s.configured()
	if err != nil {
		return nil, err
	}
	if err := s.queue.Cancel(st.Bucket, req.GetUploadId()); err != nil {
		return nil, s.controlStatus("cancel", req.GetUploadId(), err)
	}
	s.log.Info("upload canceled", "upload_id", req.GetUploadId())
	return &pb.CancelUploadResponse{}, nil
}

// controlStatus maps what Queue.Pause, Resume and Cancel return to a gRPC
// status.
func (s *Server) controlStatus(action, id string, err error) error {
	switch {
	case errors.Is(err, queue.ErrUnknownUpload):
		return status.Error(codes.NotFound, "unknown upload")
	case errors.Is(err, queue.ErrNotPausable):
		return status.Error(codes.FailedPrecondition, "Only a queued or running upload can be paused")
	case errors.Is(err, queue.ErrNotResumable):
		return status.Error(codes.FailedPrecondition, "Only an upload paused by you can be resumed")
	case errors.Is(err, queue.ErrNotCancelable):
		return status.Error(codes.FailedPrecondition, "Only a queued, running or paused upload can be canceled")
	case errors.Is(err, queue.ErrOtherBucket):
		return status.Error(codes.FailedPrecondition, "This upload belongs to another bucket")
	case errors.Is(err, queue.ErrUploadActive):
		return status.Error(codes.FailedPrecondition, "This upload is being removed")
	}
	s.log.Error(action+" failed", "upload_id", id, "error", err.Error())
	return status.Error(codes.Internal, "could not "+action+" upload")
}
