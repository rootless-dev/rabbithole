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
	"sync"
	"syscall"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/grpclog"

	"rabbithole/daemon/internal/awss3"
	"rabbithole/daemon/internal/buckets"
	"rabbithole/daemon/internal/download"
	pb "rabbithole/daemon/internal/gen/rabbithole/v1"
	"rabbithole/daemon/internal/history"
	"rabbithole/daemon/internal/logging"
	"rabbithole/daemon/internal/queue"
	"rabbithole/daemon/internal/reconcile"
	"rabbithole/daemon/internal/server"
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

// options holds the seams tests replace; the zero value selects production
// behavior.
type options struct {
	signals <-chan os.Signal // default: SIGTERM and SIGINT from the OS
	listen  listenFunc       // default: net.Listen
	newS3   s3Factory        // default: awss3.New
	runner  queue.Runner     // default: *runner over newS3
	objects bucketObjects    // default: the same *runner; nil when runner is replaced
	buckets buckets.Service  // default: awss3.NewBuckets()
	sources download.Opener  // default: a client per download, built with newS3

	transfers *transfers // the speed limit and verification; built by withDefaults
}

// bucketObjects is what the daemon does with the bucket besides uploading:
// deleting objects for RemoveUpload and listing them to reconcile the history.
type bucketObjects interface {
	server.Objects
	reconcile.Lister
}

// withDefaults fills every unset seam with its production value. The returned
// function releases what the defaults acquired.
func (o options) withDefaults(log *logging.Logger) (options, func()) {
	release := func() {}
	if o.listen == nil {
		o.listen = net.Listen
	}
	if o.newS3 == nil {
		o.newS3 = awss3.New
	}
	if o.buckets == nil {
		o.buckets = awss3.NewBuckets()
	}
	if o.sources == nil {
		o.sources = sourceOpener(o.newS3)
	}
	if o.transfers == nil {
		o.transfers = newTransfers()
	}
	if o.runner == nil {
		r := &runner{uploader: o.transfers.uploaderFor(time.Now), newS3: o.newS3, log: log}
		o.runner = r
		if o.objects == nil {
			o.objects = r
		}
	}
	if o.signals == nil {
		sigs := make(chan os.Signal, 1)
		signal.Notify(sigs, syscall.SIGTERM, syscall.SIGINT)
		release = func() { signal.Stop(sigs) }
		o.signals = sigs
	}
	return o, release
}

// Run runs the daemon until stdin reaches end of file, SIGTERM or SIGINT
// arrives, or ctx is cancelled. It returns the process exit code.
func Run(ctx context.Context, args []string, stdin io.Reader, stderr io.Writer) int {
	return run(ctx, args, stdin, stderr, options{})
}

var grpcLogOnce sync.Once

// silenceGRPCLog discards grpc-go's own log output. Its default logger writes
// plain-text lines to stderr, which would break the JSON log contract. The
// logger is a process-wide global that is unsafe to replace while gRPC is in
// use, so it is set once per process, by the first run, before that run
// creates any gRPC server.
func silenceGRPCLog() {
	grpcLogOnce.Do(func() {
		grpclog.SetLoggerV2(grpclog.NewLoggerV2(io.Discard, io.Discard, io.Discard))
	})
}

func run(ctx context.Context, args []string, stdin io.Reader, stderr io.Writer, opts options) int {
	cfg, err := parseArgs(args)
	if err != nil {
		logging.BootError(stderr, serviceName, err)
		return exitUsage
	}
	log := logging.New(stderr, os.Getenv(logLevelEnv), serviceName)
	opts, release := opts.withDefaults(log)
	defer release()

	silenceGRPCLog()

	store, err := history.Open(cfg.database)
	if err != nil {
		logging.BootError(stderr, serviceName, err)
		return exitError
	}
	ln, socketInfo, err := listenUnix(cfg.socket, opts.listen)
	if err != nil {
		_ = store.Close()
		logging.BootError(stderr, serviceName, err)
		return exitError
	}

	svc, err := startServices(ctx, ln, opts.deps(), store, log)
	if err != nil {
		_ = ln.Close()
		_ = store.Close()
		removeOwnSocket(log, cfg.socket, socketInfo)
		logging.BootError(stderr, serviceName, err)
		return exitError
	}
	log.Info("listening", "socket", cfg.socket, "database", cfg.database)
	code := awaitShutdown(ctx, log, stdin, opts.signals, svc.serveErr)
	if svc.stop(log) {
		// Closed only once nothing can write to it any more.
		if err := store.Close(); err != nil {
			log.Warn("could not close database", "error", err.Error())
		}
	}

	removeOwnSocket(log, cfg.socket, socketInfo)
	log.Info("stopped")
	return code
}

// deps is what the services are built from.
type deps struct {
	runner    queue.Runner
	objects   bucketObjects
	buckets   buckets.Service
	sources   download.Opener
	transfers *transfers
}

func (o options) deps() deps {
	return deps{runner: o.runner, objects: o.objects, buckets: o.buckets, sources: o.sources, transfers: o.transfers}
}

// services is the running part of the daemon: the upload queue, the
// reconciliation of its history with the bucket, the downloads, and the gRPC
// server in front of them.
type services struct {
	grpcServer    *grpc.Server
	cancelUploads context.CancelFunc
	queueDone     <-chan struct{} // closed when the queue has stopped
	reconcileDone <-chan struct{} // closed when the reconciliation has stopped
	downloadsDone <-chan struct{} // closed when the downloads have stopped
	serveErr      <-chan error    // receives the error that ended Serve
}

// startServices loads the stored history, starts the queue, the
// reconciliation and the downloads and serves the gRPC API on ln. Without
// objects the daemon neither deletes from the bucket nor reconciles with it.
func startServices(ctx context.Context, ln net.Listener, d deps, store queue.Store, log *logging.Logger) (*services, error) {
	r, objects := d.runner, d.objects
	// Set below, before the queue runs; an upload ending is what triggers it.
	var reconciler *reconcile.Reconciler
	q := queue.New(r, time.Now, queue.WithStore(store, log), queue.WithOnEnded(func() {
		if reconciler != nil {
			reconciler.Trigger()
		}
	}))
	if err := q.Restore(); err != nil {
		return nil, fmt.Errorf("load upload history: %w", err)
	}
	var serverOpts []server.Option
	reconcileDone := make(chan struct{})
	uploadCtx, cancelUploads := context.WithCancel(ctx)
	if objects != nil {
		reconciler = reconcile.New(q, objects, log)
		serverOpts = append(serverOpts, server.WithObjects(objects), server.WithOnConfigured(reconciler.Configure))
		go func() {
			defer close(reconcileDone)
			reconciler.Run(uploadCtx)
		}()
	} else {
		close(reconcileDone)
	}
	downloads := download.New(d.sources, q, log)
	downloadsDone := make(chan struct{})
	go func() {
		defer close(downloadsDone)
		downloads.Run(uploadCtx) // on shutdown it cancels the downloads and waits for them
	}()
	serverOpts = append(serverOpts, server.WithTransfers(d.transfers), server.WithDownloads(downloads), server.WithBuckets(d.buckets))
	grpcServer := grpc.NewServer()
	pb.RegisterDaemonServer(grpcServer, server.New(q, log, serverOpts...))

	queueDone := make(chan struct{})
	go func() {
		defer close(queueDone)
		q.Run(uploadCtx)
	}()
	serveErr := make(chan error, 1)
	go func() { serveErr <- grpcServer.Serve(ln) }()

	return &services{
		grpcServer: grpcServer, cancelUploads: cancelUploads, queueDone: queueDone, reconcileDone: reconcileDone,
		downloadsDone: downloadsDone, serveErr: serveErr,
	}, nil
}

// awaitShutdown blocks until something ends the daemon, logs what it was and
// returns the exit code that reason deserves.
func awaitShutdown(ctx context.Context, log *logging.Logger, stdin io.Reader, signals <-chan os.Signal, serveErr <-chan error) int {
	stdinDone := make(chan struct{})
	go func() {
		defer close(stdinDone)
		_, _ = io.Copy(io.Discard, stdin)
	}()

	select {
	case <-stdinDone:
		log.Info("shutting down", "reason", "stdin closed")
	case sig := <-signals:
		log.Info("shutting down", "reason", "signal", "signal", sig.String())
	case <-ctx.Done():
		log.Info("shutting down", "reason", "context cancelled")
	case err := <-serveErr:
		log.Error("server stopped unexpectedly", "error", fmt.Sprint(err))
		return exitError
	}
	return exitOK
}

// stop cancels the uploads and stops the server, waiting for both at most
// shutdownTimeout, counted from this call. It reports whether the queue, the
// only writer of the history, has stopped.
func (s *services) stop(log *logging.Logger) bool {
	deadline, cancelDeadline := context.WithTimeout(context.Background(), shutdownTimeout)
	defer cancelDeadline()

	s.cancelUploads()
	graceful := make(chan struct{})
	go func() {
		s.grpcServer.GracefulStop()
		close(graceful)
	}()
	select {
	case <-graceful:
	case <-deadline.Done():
		log.Warn("graceful stop timed out; stopping server")
	}
	s.grpcServer.Stop()
	// The queue and the reconciliation are the only writers of the history; the
	// downloads must have removed their temporary files before the process ends.
	stopping := map[string]<-chan struct{}{"upload": s.queueDone, "reconciliation": s.reconcileDone, "download": s.downloadsDone}
	for name, done := range stopping {
		select {
		case <-done:
		case <-deadline.Done():
			log.Warn(name + " did not stop before the deadline")
			return false
		}
	}
	return true
}

// config is what the command line selects.
type config struct {
	socket   string
	database string
}

// databaseFile is the name of the history database next to the socket.
const databaseFile = "history.db"

// parseArgs reads --socket and --database from args. Flag errors are returned
// instead of printed so the caller can emit them as a single JSON line.
func parseArgs(args []string) (config, error) {
	fs := flag.NewFlagSet(serviceName, flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	socket := fs.String("socket", "", "path of the Unix socket to listen on")
	database := fs.String("database", "", "path of the history database (default: "+databaseFile+" next to the socket)")
	if err := fs.Parse(args); err != nil {
		return config{}, err
	}
	if *socket == "" {
		return config{}, errors.New("missing required flag --socket")
	}
	if *database == "" {
		*database = filepath.Join(filepath.Dir(*socket), databaseFile)
	}
	return config{socket: *socket, database: *database}, nil
}
