package server

import (
	"context"
	"errors"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"rabbithole/daemon/internal/awss3"
	"rabbithole/daemon/internal/buckets"
	pb "rabbithole/daemon/internal/gen/rabbithole/v1"
	"rabbithole/daemon/internal/uploader"
)

var errNoBuckets = status.Error(codes.Unimplemented, "this daemon cannot reach the buckets of an account")

// credentialsOf reads the credentials of a request, or says which one is
// missing. They are never logged and never placed in a status.
func credentialsOf(accessKeyID, secretAccessKey, region string) (buckets.Credentials, error) {
	switch {
	case accessKeyID == "":
		return buckets.Credentials{}, status.Error(codes.InvalidArgument, "access_key_id is required")
	case secretAccessKey == "":
		return buckets.Credentials{}, status.Error(codes.InvalidArgument, "secret_access_key is required")
	case region == "":
		return buckets.Credentials{}, status.Error(codes.InvalidArgument, "region is required")
	}
	return buckets.Credentials{AccessKeyID: accessKeyID, SecretAccessKey: secretAccessKey, Region: region}, nil
}

// ListBuckets lists the buckets the key of the request can see. It works
// before Configure and leaves the configured settings alone.
func (s *Server) ListBuckets(ctx context.Context, req *pb.ListBucketsRequest) (*pb.ListBucketsResponse, error) {
	if s.buckets == nil {
		return nil, errNoBuckets
	}
	creds, err := credentialsOf(req.GetAccessKeyId(), req.GetSecretAccessKey(), req.GetRegion())
	if err != nil {
		return nil, err
	}
	found, err := s.buckets.List(ctx, creds)
	if err != nil {
		return nil, s.bucketStatus("list buckets failed", codes.Internal, "could not list buckets", listStatuses, uploader.Message, err)
	}
	resp := &pb.ListBucketsResponse{}
	for _, b := range found {
		resp.Buckets = append(resp.Buckets, &pb.Bucket{Name: b.Name, Region: b.Region})
	}
	return resp, nil
}

// CreateBucket creates a private bucket in the region of the request. It works
// before Configure and leaves the configured settings alone.
func (s *Server) CreateBucket(ctx context.Context, req *pb.CreateBucketRequest) (*pb.CreateBucketResponse, error) {
	if s.buckets == nil {
		return nil, errNoBuckets
	}
	creds, err := credentialsOf(req.GetAccessKeyId(), req.GetSecretAccessKey(), req.GetRegion())
	if err != nil {
		return nil, err
	}
	if err := buckets.ValidateName(req.GetName()); err != nil {
		return nil, status.Error(codes.InvalidArgument, buckets.CreateMessage(err))
	}
	if err := s.buckets.Create(ctx, creds, req.GetName()); err != nil {
		return nil, s.bucketStatus("create bucket failed", codes.Internal, buckets.CreateFailed, createStatuses, buckets.CreateMessage, err)
	}
	s.log.Info("bucket created", "bucket", req.GetName(), "region", req.GetRegion())
	return &pb.CreateBucketResponse{}, nil
}

// codeOf pairs a failure with the status code that describes it.
type codeOf struct {
	err  error
	code codes.Code
}

var listStatuses = []codeOf{
	{uploader.ErrListBucketsDenied, codes.PermissionDenied},
	{uploader.ErrBadCredentials, codes.PermissionDenied},
	{uploader.ErrNoNetwork, codes.Unavailable},
}

var createStatuses = []codeOf{
	{buckets.ErrNameTaken, codes.AlreadyExists},
	{buckets.ErrOwnedByYou, codes.AlreadyExists},
	{buckets.ErrInvalidName, codes.InvalidArgument},
	{buckets.ErrCreateDenied, codes.PermissionDenied},
	{uploader.ErrBadCredentials, codes.PermissionDenied},
	{uploader.ErrNoNetwork, codes.Unavailable},
	{buckets.ErrTooManyBucket, codes.ResourceExhausted},
}

// bucketStatus turns a failure of the bucket service into a status: the code
// of the first entry of table that err matches, with message(err) as its text.
// Anything else is logged, with the AWS code and never the error's own text,
// and answered with fallbackCode and fallbackText.
func (s *Server) bucketStatus(logMsg string, fallbackCode codes.Code, fallbackText string, table []codeOf, message func(error) string, err error) error {
	for _, c := range table {
		if errors.Is(err, c.err) {
			return status.Error(c.code, message(err))
		}
	}
	kv := []any{}
	if code, httpStatus := awss3.ErrorDetails(err); code != "" || httpStatus != 0 {
		kv = append(kv, "aws_code", code, "http_status", httpStatus)
	}
	s.log.Error(logMsg, kv...)
	return status.Error(fallbackCode, fallbackText)
}
