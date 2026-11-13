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

// Objects deletes objects from the bucket named in the settings.
type Objects interface {
	// DeleteObjects deletes the objects with exactly these keys, in as many
	// requests as it takes, and returns the keys that are gone. When it fails
	// part-way it returns the keys deleted before the failure with the error.
	DeleteObjects(ctx context.Context, s uploader.Settings, keys []string) (deleted []string, err error)
}

// objectError marks an error that came from the bucket, as opposed to the
// history, so that the status can describe it to the user.
type objectError struct{ err error }

func (e *objectError) Error() string { return e.err.Error() }
func (e *objectError) Unwrap() error { return e.err }

// RemoveUpload takes an upload, or some of its files, out of the history, with
// the settings in force now, and deletes their objects from the bucket when
// asked to.
func (s *Server) RemoveUpload(ctx context.Context, req *pb.RemoveUploadRequest) (*pb.RemoveUploadResponse, error) {
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

	var del queue.DeleteFunc
	if req.GetDeleteFromBucket() {
		if s.objects == nil {
			return nil, status.Error(codes.Unimplemented, "this daemon cannot delete objects from the bucket")
		}
		del = func(ctx context.Context, keys []string) ([]string, error) {
			deleted, err := s.objects.DeleteObjects(ctx, st, keys)
			if err != nil {
				err = &objectError{err}
			}
			return deleted, err
		}
	}

	if err := s.queue.Remove(ctx, st.Bucket, req.GetUploadId(), indexes, del); err != nil {
		return nil, s.removeStatus(req.GetUploadId(), err)
	}
	s.log.Info("upload removed", "upload_id", req.GetUploadId(), "files", len(indexes), "from_bucket", req.GetDeleteFromBucket())
	return &pb.RemoveUploadResponse{}, nil
}

// objectStatuses gives the status code of each failure of the bucket that has
// a readable sentence in uploader.Message. A denied call is PermissionDenied,
// no network is Unavailable, and a bucket that cannot be used as configured is
// FailedPrecondition, like a daemon that is not configured.
var objectStatuses = []struct {
	err  error
	code codes.Code
}{
	{uploader.ErrNoNetwork, codes.Unavailable},
	{uploader.ErrDeleteDenied, codes.PermissionDenied},
	{uploader.ErrForbidden, codes.PermissionDenied},
	{uploader.ErrWriteDenied, codes.PermissionDenied},
	{uploader.ErrBadCredentials, codes.PermissionDenied},
	{uploader.ErrBucketNotFound, codes.FailedPrecondition},
	{uploader.ErrBucketInaccessible, codes.FailedPrecondition},
	{uploader.ErrWrongRegion, codes.FailedPrecondition},
}

// removeStatus maps what Queue.Remove returns to a gRPC status.
func (s *Server) removeStatus(id string, err error) error {
	switch {
	case errors.Is(err, queue.ErrUnknownUpload):
		return status.Error(codes.NotFound, "unknown upload")
	case errors.Is(err, queue.ErrUnknownFile):
		return status.Error(codes.NotFound, "unknown file")
	case errors.Is(err, queue.ErrUploadActive):
		return status.Error(codes.FailedPrecondition, "The upload is queued or running")
	case errors.Is(err, queue.ErrOtherBucket):
		return status.Error(codes.FailedPrecondition, "This upload belongs to another bucket")
	}
	var fromBucket *objectError
	if !errors.As(err, &fromBucket) {
		s.log.Error("remove failed", "upload_id", id, "error", err.Error())
		return status.Error(codes.Internal, "could not remove upload")
	}
	// The text of an error from the bucket may echo request content: only the
	// readable sentence is logged and returned.
	for _, st := range objectStatuses {
		if errors.Is(err, st.err) {
			s.log.Warn("delete from bucket failed", "upload_id", id, "reason", uploader.Message(err))
			return status.Error(st.code, uploader.Message(err))
		}
	}
	if ctxErr := contextStatus(err); ctxErr != nil {
		return ctxErr
	}
	s.log.Error("delete from bucket failed", "upload_id", id)
	return status.Error(codes.Internal, "Could not delete the objects from the bucket")
}

func contextStatus(err error) error {
	switch {
	case errors.Is(err, context.Canceled):
		return status.Error(codes.Canceled, "The removal was cancelled")
	case errors.Is(err, context.DeadlineExceeded):
		return status.Error(codes.DeadlineExceeded, "The removal took too long")
	}
	return nil
}
