package server

import (
	"context"
	"errors"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"rabbithole/daemon/internal/buckets"
	"rabbithole/daemon/internal/download"
	pb "rabbithole/daemon/internal/gen/rabbithole/v1"
	"rabbithole/daemon/internal/queue"
	"rabbithole/daemon/internal/uploader"
)

// Transfers holds the options that shape every upload while it is sent.
type Transfers interface {
	// SetSpeedLimit sets the most bytes per second all uploads together may
	// send; zero means no limit.
	SetSpeedLimit(bytesPerSecond int64)
	// SetVerifyUploads makes S3 check every upload against a checksum of the
	// local bytes.
	SetVerifyUploads(on bool)
}

// Downloads copies files of stored uploads from the bucket to disk.
type Downloads interface {
	Start(s uploader.Settings, uploadID string, indexes []int, destDir string) (string, error)
	Cancel(id string) error
	Subscribe() (initial []download.Snapshot, updates <-chan download.Snapshot, cancel func())
}

// WithTransfers lets SetOptions change the speed limit and the verification
// through t. Without it both are accepted and ignored.
func WithTransfers(t Transfers) Option { return func(s *Server) { s.transfers = t } }

// WithDownloads lets StartDownload, CancelDownload and WatchDownloads work
// through d. Without it they answer Unimplemented.
func WithDownloads(d Downloads) Option { return func(s *Server) { s.downloads = d } }

// WithBuckets lets ListBuckets and CreateBucket work through b. Without it they
// answer Unimplemented.
func WithBuckets(b buckets.Service) Option { return func(s *Server) { s.buckets = b } }

var errNoDownloads = status.Error(codes.Unimplemented, "this daemon cannot download files")

// StartDownload copies finished files of an upload to a folder, in the
// background, with the settings in force now.
func (s *Server) StartDownload(_ context.Context, req *pb.StartDownloadRequest) (*pb.StartDownloadResponse, error) {
	if s.downloads == nil {
		return nil, errNoDownloads
	}
	st, err := s.configured()
	if err != nil {
		return nil, err
	}
	indexes := make([]int, len(req.GetFileIndexes()))
	for i, idx := range req.GetFileIndexes() {
		indexes[i] = int(idx)
	}
	id, err := s.downloads.Start(st, req.GetUploadId(), indexes, req.GetDestinationDir())
	if err != nil {
		return nil, s.startDownloadStatus(req.GetUploadId(), err)
	}
	return &pb.StartDownloadResponse{DownloadId: id}, nil
}

// startDownloadStatus maps what Downloads.Start returns to a gRPC status.
func (s *Server) startDownloadStatus(uploadID string, err error) error {
	switch {
	case errors.Is(err, queue.ErrUnknownUpload):
		return status.Error(codes.NotFound, "unknown upload")
	case errors.Is(err, queue.ErrUnknownFile):
		return status.Error(codes.NotFound, "unknown file")
	case errors.Is(err, queue.ErrOtherBucket):
		return status.Error(codes.FailedPrecondition, "This upload belongs to another bucket")
	case errors.Is(err, queue.ErrNoFinishedFiles):
		return status.Error(codes.FailedPrecondition, "None of the chosen files has finished uploading")
	case errors.Is(err, download.ErrBadDestination):
		return status.Error(codes.FailedPrecondition, download.ErrBadDestination.Error())
	case errors.Is(err, uploader.ErrNoFreeName):
		return status.Error(codes.FailedPrecondition, uploader.Message(err))
	}
	s.log.Error("download failed to start", "upload_id", uploadID, "error", err.Error())
	return status.Error(codes.Internal, "could not start the download")
}

// CancelDownload stops a download.
func (s *Server) CancelDownload(_ context.Context, req *pb.CancelDownloadRequest) (*pb.CancelDownloadResponse, error) {
	if s.downloads == nil {
		return nil, errNoDownloads
	}
	if err := s.downloads.Cancel(req.GetDownloadId()); err != nil {
		switch {
		case errors.Is(err, download.ErrUnknownDownload):
			return nil, status.Error(codes.NotFound, "unknown download")
		case errors.Is(err, download.ErrDownloadEnded):
			return nil, status.Error(codes.FailedPrecondition, "The download already ended")
		}
		s.log.Error("cancel download failed", "download_id", req.GetDownloadId(), "error", err.Error())
		return nil, status.Error(codes.Internal, "could not cancel the download")
	}
	s.log.Info("download canceled", "download_id", req.GetDownloadId())
	return &pb.CancelDownloadResponse{}, nil
}

// WatchDownloads sends one snapshot per download of this run, then a snapshot
// whenever one changes, until the client goes away.
func (s *Server) WatchDownloads(_ *pb.WatchDownloadsRequest, stream pb.Daemon_WatchDownloadsServer) error {
	if s.downloads == nil {
		return errNoDownloads
	}
	initial, updates, cancel := s.downloads.Subscribe()
	defer cancel()
	return relay(stream.Context(), initial, updates, func(d download.Snapshot) error {
		return stream.Send(toProtoDownload(d))
	})
}

func toProtoDownload(d download.Snapshot) *pb.DownloadSnapshot {
	indexes := make([]int32, len(d.FileIndexes))
	for i, idx := range d.FileIndexes {
		indexes[i] = int32(idx)
	}
	return &pb.DownloadSnapshot{
		DownloadId:      d.ID,
		UploadId:        d.UploadID,
		FileIndexes:     indexes,
		Name:            d.Name,
		DestinationPath: d.Destination,
		BytesTotal:      d.BytesTotal,
		BytesDone:       d.BytesDone,
		FilesTotal:      int32(d.FilesTotal),
		FilesDone:       int32(d.FilesDone),
		FilesFailed:     int32(d.FilesFailed),
		State:           toProtoDownloadState(d.State),
		ErrorMessage:    d.ErrorMessage,
	}
}

func toProtoDownloadState(s download.State) pb.DownloadState {
	switch s {
	case download.Queued:
		return pb.DownloadState_DOWNLOAD_QUEUED
	case download.Downloading:
		return pb.DownloadState_DOWNLOADING
	case download.Finished:
		return pb.DownloadState_DOWNLOAD_FINISHED
	case download.Failed:
		return pb.DownloadState_DOWNLOAD_FAILED
	case download.Canceled:
		return pb.DownloadState_DOWNLOAD_CANCELED
	default:
		return pb.DownloadState_DOWNLOAD_STATE_UNSPECIFIED
	}
}
