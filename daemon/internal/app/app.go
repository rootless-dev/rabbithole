// Package app composes the daemon: it parses the command line, wires the
// uploader, queue and gRPC server together, listens on a Unix socket and
// shuts everything down when the parent goes away.
package app

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/grpclog"

	"rabbithole/daemon/internal/awss3"
	pb "rabbithole/daemon/internal/gen/rabbithole/v1"
	"rabbithole/daemon/internal/logging"
	"rabbithole/daemon/internal/queue"
	"rabbithole/daemon/internal/server"
	"rabbithole/daemon/internal/uploader"
)

const (
	serviceName = "rabbitholed"
	logLevelEnv = "RABBITHOLE_LOG_LEVEL"

	// shutdownTimeout is measured from the shutdown signal. It is shorter than
	// the 1.5 s the parent allows, so the process is gone in time even when an
	// upload's abort call hangs.
	shutdownTimeout = 1200 * time.Millisecond

	exitOK    = 0
	exitError = 1
	exitUsage = 2
)

// s3Factory builds an S3 client for one upload from its settings.
type s3Factory func(ctx context.Context, s uploader.Settings) (uploader.S3, error)

// runner is the queue.Runner used in production: it builds an S3 client from
// the job's settings and hands it to the uploader.
type runner struct {
	uploader *uploader.Uploader
	newS3    s3Factory
	log      *logging.Logger
}

// Run performs one upload and logs one line if it fails. The line carries the
// readable reason, the AWS error code and HTTP status when the error has them,
// and the file name; never the error's own text, which may echo request content.
func (r *runner) Run(ctx context.Context, s uploader.Settings, req uploader.Request, cb uploader.Callbacks) error {
	name := filepath.Base(req.LocalPath)
	cb.AbortFailed = func(err error) {
		r.logFailure(ctx, "multipart abort failed", name, err)
	}
	client, err := r.newS3(ctx, s)
	if err == nil {
		err = r.uploader.Upload(ctx, client, req, cb)
	}
	if err != nil {
		r.logFailure(ctx, "upload failed", name, err)
	}
	return err
}

func (r *runner) logFailure(ctx context.Context, msg, file string, err error) {
	kv := []any{"file", file, "reason", uploader.Message(err)}
	code, status := awss3.ErrorDetails(err)
	if code != "" {
		kv = append(kv, "aws_code", code)
	}
	if status != 0 {
		kv = append(kv, "http_status", status)
	}
	if ctx.Err() != nil {
		r.log.Warn(msg, kv...) // shutdown cancelled the work; not a defect
		return
	}
	r.log.Error(msg, kv...)
}

// options holds the seams tests replace; the zero value selects production
// behavior.
type options struct {
	signals <-chan os.Signal                                    // default: SIGTERM and SIGINT from the OS
	listen  func(network, address string) (net.Listener, error) // default: net.Listen
	newS3   s3Factory                                           // default: awss3.New
	runner  queue.Runner                                        // default: *runner over newS3
}

// Run runs the daemon until stdin reaches end of file, SIGTERM or SIGINT
// arrives, or ctx is cancelled. It returns the process exit code.
func Run(ctx context.Context, args []string, stdin io.Reader, stderr io.Writer) int {
	return run(ctx, args, stdin, stderr, options{})
}

func run(ctx context.Context, args []string, stdin io.Reader, stderr io.Writer, opts options) int {
	socketPath, err := parseArgs(args)
	if err != nil {
		logging.BootError(stderr, serviceName, err)
		return exitUsage
	}
	log := logging.New(stderr, os.Getenv(logLevelEnv), serviceName)

	if opts.listen == nil {
		opts.listen = net.Listen
	}
	if opts.newS3 == nil {
		opts.newS3 = awss3.New
	}
	if opts.runner == nil {
		opts.runner = &runner{uploader: uploader.New(time.Now), newS3: opts.newS3, log: log}
	}
	if opts.signals == nil {
		sigs := make(chan os.Signal, 1)
		signal.Notify(sigs, syscall.SIGTERM, syscall.SIGINT)
		defer signal.Stop(sigs)
		opts.signals = sigs
	}

	// grpc-go's default logger writes plain-text lines to stderr, which would
	// break the JSON log contract. Discard its output before any server exists.
	grpclog.SetLoggerV2(grpclog.NewLoggerV2(io.Discard, io.Discard, io.Discard))

	ln, socketInfo, err := listenUnix(socketPath, opts.listen)
	if err != nil {
		logging.BootError(stderr, serviceName, err)
		return exitError
	}

	q := queue.New(opts.runner, time.Now)
	grpcServer := grpc.NewServer()
	pb.RegisterDaemonServer(grpcServer, server.New(q, log))

	uploadCtx, cancelUploads := context.WithCancel(ctx)
	defer cancelUploads()
	queueDone := make(chan struct{})
	go func() {
		defer close(queueDone)
		q.Run(uploadCtx)
	}()
	serveErr := make(chan error, 1)
	go func() { serveErr <- grpcServer.Serve(ln) }()
	stdinDone := make(chan struct{})
	go func() {
		defer close(stdinDone)
		_, _ = io.Copy(io.Discard, stdin)
	}()

	log.Info("listening", "socket", socketPath)
	code := exitOK
	select {
	case <-stdinDone:
		log.Info("shutting down", "reason", "stdin closed")
	case sig := <-opts.signals:
		log.Info("shutting down", "reason", "signal", "signal", sig.String())
	case <-ctx.Done():
		log.Info("shutting down", "reason", "context cancelled")
	case err := <-serveErr:
		log.Error("server stopped unexpectedly", "error", fmt.Sprint(err))
		code = exitError
	}

	// The deadline runs from the moment shutdown started.
	deadline, cancelDeadline := context.WithTimeout(context.Background(), shutdownTimeout)
	defer cancelDeadline()

	cancelUploads()
	graceful := make(chan struct{})
	go func() {
		grpcServer.GracefulStop()
		close(graceful)
	}()
	select {
	case <-graceful:
	case <-deadline.Done():
		log.Warn("graceful stop timed out; stopping server")
	}
	grpcServer.Stop()
	select {
	case <-queueDone:
	case <-deadline.Done():
		log.Warn("upload did not stop before the deadline")
	}

	removeOwnSocket(log, socketPath, socketInfo)
	log.Info("stopped")
	return code
}

// removeOwnSocket removes path only if it is still the socket file this
// process created.
func removeOwnSocket(log *logging.Logger, path string, created os.FileInfo) {
	current, err := os.Lstat(path)
	if err != nil {
		if !errors.Is(err, os.ErrNotExist) {
			log.Warn("could not inspect socket", "error", err.Error())
		}
		return
	}
	if !os.SameFile(created, current) {
		log.Info("socket was replaced; leaving it in place")
		return
	}
	if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
		log.Warn("could not remove socket", "error", err.Error())
	}
}

// parseArgs reads --socket from args. Flag errors are returned instead of
// printed so the caller can emit them as a single JSON line.
func parseArgs(args []string) (string, error) {
	fs := flag.NewFlagSet(serviceName, flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	socket := fs.String("socket", "", "path of the Unix socket to listen on")
	if err := fs.Parse(args); err != nil {
		return "", err
	}
	if *socket == "" {
		return "", errors.New("missing required flag --socket")
	}
	return *socket, nil
}

// listenUnix creates the socket directory (mode 0700 even when it already
// existed), removes a stale file at path, listens on a Unix socket created
// with mode 0600 from the start, and returns the identity of the socket file
// this process created. The listener does not unlink the path on close: the
// caller removes it only if it is still the same file, so an exiting daemon
// never deletes a socket a newer daemon created at the same path.
func listenUnix(path string, listen func(network, address string) (net.Listener, error)) (net.Listener, os.FileInfo, error) {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, nil, fmt.Errorf("create socket directory: %w", err)
	}
	if err := os.Chmod(dir, 0o700); err != nil {
		return nil, nil, fmt.Errorf("restrict socket directory permissions: %w", err)
	}
	if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
		return nil, nil, fmt.Errorf("remove stale socket: %w", err)
	}

	// bind creates the socket file with the umask applied: 0177 yields 0600.
	oldMask := syscall.Umask(0o177)
	ln, err := listen("unix", path)
	syscall.Umask(oldMask)
	if err != nil {
		return nil, nil, fmt.Errorf("listen on %s: %w", path, err)
	}
	if unixLn, ok := ln.(*net.UnixListener); ok {
		unixLn.SetUnlinkOnClose(false)
	}
	if err := os.Chmod(path, 0o600); err != nil { // backstop for listeners that ignore the umask
		_ = ln.Close()
		return nil, nil, fmt.Errorf("restrict socket permissions: %w", err)
	}
	info, err := os.Stat(path)
	if err != nil {
		_ = ln.Close()
		return nil, nil, fmt.Errorf("stat socket: %w", err)
	}
	return ln, info, nil
}
