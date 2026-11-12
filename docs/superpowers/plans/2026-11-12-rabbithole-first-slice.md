# Rabbithole First Slice Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Drop one file on the menu bar window and find it in the owner's S3 bucket, with progress, through a Swift app and a Go upload daemon talking gRPC over a Unix socket.

**Architecture:** A Swift menu bar app (SwiftUI plus AppKit) launches `rabbitholed`, a Go child process, with `--socket <path>` and a stdin pipe it keeps open. The app hands AWS settings to the daemon over `Configure`, enqueues files with `EnqueueUpload` and renders `WatchUploads` snapshots. The daemon owns the queue and the S3 uploader and exits when stdin closes or on SIGTERM.

**Tech Stack:** Go 1.27.1, AWS SDK for Go v2, `github.com/phuslu/log`, grpc-go, protobuf, buf; Swift 6.4, SwiftUI/AppKit, grpc-swift with its protobuf and NIO transport packages, xcodegen, XCTest (or Swift Testing, whichever the generated project template uses), Homebrew.

**Spec:** `docs/superpowers/specs/2026-11-12-rabbithole-first-slice-design.md`. Visual reference: `design/mockups/tray-popover.html`, `tray-setup.html`, `tray-drag.html`.

## Global Constraints

- macOS only; native Swift app; upload engine is a Go daemon. UI strings in English.
- Daemon is the app's child process, not a launchd service. gRPC over a Unix domain socket only, never TCP.
- Progress reaches the UI through the server-streaming `WatchUploads`.
- Credentials live in the keychain; the daemon never touches it. Credentials never go to a file, log line, environment variable or command line argument.
- Layout: `app/`, `daemon/` (module `rabbithole/daemon`), `proto/` (`rabbithole/v1/daemon.proto`), `design/`, `docs/`, root `Makefile` with `generate`, `build`, `test`, `run`. Generated gRPC code for both languages is committed. `.gitignore` already ignores `*.xcodeproj`, build output and `daemon/bin/`.
- Go rules: `cmd/rabbitholed/main.go` only calls `internal/app`; composition and lifecycle live in `internal/app`; dependencies through constructors; no abstraction that exists only to save lines.
- Logging: `github.com/phuslu/log` through its own API (not a slog handler), wrapped in an internal package that returns none of the library's types. JSON to stderr with `time`, `level`, `msg`, `service`. Unknown level falls back to info. A failure before the logger exists prints one parseable JSON line to stderr.
- Socket: `~/Library/Application Support/Rabbithole/daemon.sock`, directory mode 0700, socket mode 0600; a stale socket file is removed on start.
- Exit within 1.5 seconds of stdin EOF or SIGTERM (hard deadline; multipart abort is best effort).
- Queue: in memory, FIFO, one upload at a time, nothing persisted.
- Upload rule: below 16 MiB one `PutObject`; 16 MiB or more multipart with 8 MiB parts; part size stays 8 MiB up to and including 80,000 MiB and above that is the smallest whole MiB keeping the upload within 10,000 parts. Zero-byte files are valid.
- Object key `<quick_uploads_prefix><file name>`, resolved when the upload starts (`object_key` empty while `QUEUED`). On a collision try `<prefix><base>-<YYYYMMDD-HHMMSS><ext>` (local time), then the same with `-2`, `-3`... appended to the timestamp. Existence check plus `If-None-Match: *` on `PutObject` and on `CompleteMultipartUpload`. Rejected conditional write: next candidate for a single request, `FAILED` for multipart. Forbidden existence check: `FAILED` naming `s3:ListBucket`.
- Required bucket permissions: `s3:PutObject`, `s3:AbortMultipartUpload`, `s3:ListBucket`. Failed multipart uploads are aborted; orphans after a crash are accepted.
- AWS settings are captured at enqueue; `Configure` later affects only later uploads. `EnqueueUpload` fails `FAILED_PRECONDITION` before `Configure` and `INVALID_ARGUMENT` for an unreadable or non-regular path.
- `WatchUploads`: one snapshot per known upload on subscribe, then one per change, at most 10 per second per upload, final one always sent. `bytes_sent` never exceeds `bytes_total` and equals it when `FINISHED`.
- App: bundle id `com.rabbithole.app`, `LSUIElement`, not sandboxed, ad-hoc signed (`CODE_SIGN_IDENTITY: "-"`, one build setting; the owner's signing question is open). Tray window 232 pt wide, 3 pt under the menu bar, 64 pt tall solid drop area, stays open until the icon is clicked again. Prefix fixed to `quick-uploads/`. Socket path as above. All gRPC calls off the main thread. Daemon restarted up to 3 times, then "uploads are unavailable".
- Status line counting rule: batch = every upload enqueued since the queue was last empty; "N of M files left"; percentage is batch bytes sent over batch bytes total; earlier batches and replayed snapshots are ignored; after a daemon restart queued or in-progress uploads show failed with "Upload interrupted".
- Folders and drops of more than one item are refused with a one-line message in the drop area; nothing is enqueued.
- Commit messages in English, conventional style.

## Review Focus

Failure modes the spec implies, most likely first; each is pinned by a test in the task named in brackets.

1. File names with no extension, several dots or a leading dot (`.env`, `archive.tar.gz`, `a b.txt`): the timestamp goes before the last extension only and a leading-dot name has no extension. [Task 3]
2. The file vanishes, shrinks or grows between enqueue and upload: `FAILED` with "File could not be read", never a panic, never `bytes_sent` above `bytes_total`. [Task 4]
3. `Configure` with an empty key, secret, region or bucket: `INVALID_ARGUMENT`, not a daemon that fails later with an opaque AWS error. [Task 7]
4. Dropping a macOS package (a `.app` directory) or a symlink to a file: the package is a folder and is refused, the symlink to a regular file is accepted. [Task 12; the symlink case is checked by hand in Task 14]
5. Daemon binary missing, or the daemon dying during an upload: the app shows "unavailable" or "Upload interrupted" rather than hanging. [Task 10]

---

### Task 1: Scaffolding, proto contract, code generation, Makefile

**Files:**
- Create: `proto/buf.yaml`, `proto/buf.gen.yaml`, `proto/rabbithole/v1/daemon.proto`, `Makefile`, `daemon/go.mod`, `daemon/internal/gen/rabbithole/v1/*.go` (generated), `app/Sources/Generated/*.swift` (generated)
- Modify: none

**Interfaces:**
- Produces: Go package `rabbithole/daemon/internal/gen/rabbithole/v1` (alias `pb`) with `DaemonServer`, `UnimplementedDaemonServer`, `UploadSnapshot`, `UploadState_{QUEUED,UPLOADING,FINISHED,FAILED}`; Swift generated client and message types; `make generate`, `make test`.

- [ ] **Step 1: Install and verify tooling.** Run `brew info xcodegen` and `brew search grpc-swift`; read the current grpc-swift documentation to learn which `protoc` plugin names and which Swift packages the current generation uses (generator names have changed between generations; do not assume). Install what is missing with `brew install`. Run `buf --version`, `protoc-gen-go --version`, `xcodegen --version` and the Swift gRPC plugin's `--version`. Expected: all print a version.
- [ ] **Step 2: Write `proto/rabbithole/v1/daemon.proto`**, package `rabbithole.v1`, `go_package` under `rabbithole/daemon/internal/gen/rabbithole/v1`:
  - `service Daemon { rpc Configure(ConfigureRequest) returns (ConfigureResponse); rpc EnqueueUpload(EnqueueUploadRequest) returns (EnqueueUploadResponse); rpc WatchUploads(WatchUploadsRequest) returns (stream UploadSnapshot); }`
  - `ConfigureRequest`: `access_key_id=1, secret_access_key=2, region=3, bucket=4, quick_uploads_prefix=5` (strings). `EnqueueUploadRequest`: `local_path=1`. `EnqueueUploadResponse`: `upload_id=1`. `ConfigureResponse` and `WatchUploadsRequest` empty.
  - `UploadSnapshot`: `upload_id=1, file_name=2, local_path=3, object_key=4, bytes_total=5 (int64), bytes_sent=6 (int64), state=7 (UploadState), error_message=8`. Enum `UploadState`: `UPLOAD_STATE_UNSPECIFIED=0, QUEUED=1, UPLOADING=2, FINISHED=3, FAILED=4`.
- [ ] **Step 3: Write `buf.yaml`, `buf.gen.yaml`** with the Go (`protoc-gen-go`, `protoc-gen-go-grpc`) and Swift plugins verified in Step 1, outputs to `daemon/internal/gen` and `app/Sources/Generated`. Run `buf lint` and `buf generate` from `proto/`. Expected: no lint errors, generated files exist in both outputs.
- [ ] **Step 4: Create the Go module** `cd daemon && go mod init rabbithole/daemon` (go 1.27.1) and `go mod tidy`; run `go build ./...`. Expected: success.
- [ ] **Step 5: Write the `Makefile`** with `generate` (buf), `build` (daemon to `daemon/bin/rabbitholed`, then Task 9's xcodegen and xcodebuild once they exist), `test` (`cd daemon && go test ./...` then the `xcodebuild test` of Task 9), `run` (build, then open the built app). Targets that depend on later tasks may print "not yet" until those tasks land.
- [ ] **Step 6: Verify** `make generate && git status --short` shows only the expected new files. Expected: generation is deterministic (a second run changes nothing).
- [ ] **Step 7: Commit**

```bash
git add proto daemon Makefile app/Sources/Generated
git commit -m "chore: add gRPC contract, code generation and Makefile"
```

### Task 2: Daemon logging package

**Files:**
- Create: `daemon/internal/logging/logging.go`
- Test: `daemon/internal/logging/logging_test.go`

**Interfaces:**
- Produces: `type Logger struct{...}` (no phuslu types exported); `func New(w io.Writer, level string, service string) *Logger`; `func (l *Logger) Debug/Info/Warn/Error(msg string, kv ...any)` (alternating key, value); `func BootError(w io.Writer, service string, err error)` which writes one JSON line and returns.

- [ ] **Step 1: Write failing tests**, each parsing the output with `encoding/json`:
  - `TestInfoLineHasContractFields`: `New(buf,"info","rabbitholed").Info("hello","upload_id","u1")` yields an object with keys `time`, `level`="info", `msg`="hello", `service`="rabbitholed", `upload_id`="u1".
  - `TestUnknownLevelFallsBackToInfo`: level `"loud"` and `""`: `Debug("x")` writes nothing, `Info("x")` writes one line.
  - `TestDebugLevelEnablesDebug`.
  - `TestBootErrorPrintsOneParseableLine`: output is exactly one line, valid JSON, `level`="error", `msg` contains the error text, `service` set, has `time`.
- [ ] **Step 2: Run** `cd daemon && go test ./internal/logging/ -v`. Expected: FAIL (package does not compile).
- [ ] **Step 3: Implement** with `github.com/phuslu/log` using its `Logger` struct and entry API. phuslu's default message key is not `msg`: read its docs and use the supported way to emit `msg` (verify before coding; if no supported option exists, say so in the commit message and use the smallest wrapper writer that renames the key). Run `go get github.com/phuslu/log`.
- [ ] **Step 4: Run tests.** Expected: PASS.
- [ ] **Step 5: Commit**

```bash
git add daemon/go.mod daemon/go.sum daemon/internal/logging
git commit -m "feat(daemon): add structured logging behind an internal package"
```

### Task 3: Object key and part size rules

**Files:**
- Create: `daemon/internal/uploader/key.go`, `daemon/internal/uploader/parts.go`
- Test: `daemon/internal/uploader/key_test.go`, `daemon/internal/uploader/parts_test.go`

**Interfaces:**
- Produces: `func CandidateKey(prefix, fileName string, now time.Time, attempt int) string` (attempt 0 plain; 1 timestamped; n>=2 timestamp plus `-n`); `const MiB = 1 << 20`; `func UseMultipart(size int64) bool`; `func PartSize(size int64) int64`.

- [ ] **Step 1: Write failing tests** (table-driven, `now` = 2026-11-12 13:10:05 local):
  - `TestCandidateKey`: `("quick-uploads/","report.pdf",now,0)` = `quick-uploads/report.pdf`; attempt 1 = `quick-uploads/report-20261112-131005.pdf`; attempt 2 = `quick-uploads/report-20261112-131005-2.pdf`; attempt 3 ends `-3.pdf`; `archive.tar.gz` attempt 1 = `archive.tar-20261112-131005.gz`; `Makefile` attempt 1 = `Makefile-20261112-131005`; `.env` attempt 1 = `.env-20261112-131005`; `a b é.txt` attempt 0 keeps the name unchanged.
  - `TestUseMultipartBoundary`: `16*MiB-1` false, `16*MiB` true, `0` false.
  - `TestPartSize`: sizes `0`, `16*MiB`, `80000*MiB` all return `8*MiB`; `80000*MiB+1` returns `9*MiB`; `160000*MiB` returns `16*MiB`.
- [ ] **Step 2: Run** `go test ./internal/uploader/ -run 'Key|Multipart|PartSize' -v`. Expected: FAIL.
- [ ] **Step 3: Implement** both files. `PartSize`: ceil(size/10000) rounded up to whole MiB, never below 8 MiB. Extension is `filepath.Ext` except a name whose only dot is the leading one has none.
- [ ] **Step 4: Run tests.** Expected: PASS.
- [ ] **Step 5: Commit**

```bash
git add daemon/internal/uploader
git commit -m "feat(daemon): add object key and multipart part size rules"
```

### Task 4: Uploader with a fake S3

**Files:**
- Create: `daemon/internal/uploader/s3.go` (interface, sentinel errors, `Settings`), `daemon/internal/uploader/uploader.go`, `daemon/internal/uploader/messages.go`
- Test: `daemon/internal/uploader/uploader_test.go` (contains the fake S3)

**Interfaces:**
- Consumes: `CandidateKey`, `UseMultipart`, `PartSize`, `MiB` (Task 3).
- Produces:
  - `type Settings struct{ AccessKeyID, SecretAccessKey, Region, Bucket, Prefix string }` with `String()` that redacts the secret and key.
  - `type S3 interface { ObjectExists(ctx, key string) (bool, error); PutObject(ctx, key string, body io.Reader, size int64) error; CreateMultipart(ctx, key string) (uploadID string, err error); UploadPart(ctx, key, uploadID string, number int32, body io.Reader, size int64) (etag string, err error); CompleteMultipart(ctx, key, uploadID string, parts []CompletedPart) error; AbortMultipart(ctx, key, uploadID string) error }`; `type CompletedPart struct{ Number int32; ETag string }`.
  - Sentinels: `ErrPreconditionFailed` (conditional write rejected), `ErrForbidden` (existence check denied), `ErrWriteDenied` (a write call denied), `ErrBucketNotFound`, `ErrBadCredentials`, `ErrNoNetwork`, `ErrFileUnreadable`.
  - `type Request struct{ Prefix, LocalPath string }`; `type Callbacks struct{ KeyResolved func(key string); Progress func(sent int64) }`.
  - `func New(now func() time.Time) *Uploader`; `func (u *Uploader) Upload(ctx context.Context, s3 S3, req Request, cb Callbacks) error`; `func Message(err error) string`.

- [ ] **Step 1: Write failing tests** against a fake S3 that records calls and can be scripted (existing keys, per-call errors, a hook to cancel mid-upload). Names and assertions:
  - `TestSmallFileUsesSinglePut`: 16 MiB minus 1 byte file: one `PutObject`, zero multipart calls, key `quick-uploads/<name>`, last `Progress` equals size.
  - `TestSixteenMiBUsesMultipart`: 16 MiB file: create, 2 parts of 8 MiB, complete with parts in order, no abort.
  - `TestZeroByteFile`: one `PutObject` of size 0, finishes.
  - `TestExistingKeyGetsTimestamp`; `TestExistingTimestampedKeyGetsSuffix` (existing plain and timestamped keys yield the `-2` key).
  - `TestSinglePutRejectedWriteMovesToNextCandidate`: `PutObject` returns `ErrPreconditionFailed` for the first key, succeeds for the next; `KeyResolved` is called for the final key.
  - `TestMultipartRejectedCompleteFailsAndAborts`: `CompleteMultipart` returns `ErrPreconditionFailed`: `Upload` returns an error whose `Message` is "An object with this name appeared during the upload", and `AbortMultipart` was called.
  - `TestForbiddenExistenceCheckNamesPermission`: `ObjectExists` returns `ErrForbidden`: `Message(err)` contains `s3:ListBucket`, no write call was made.
  - `TestPartFailureAbortsMultipart`; `TestCancelAbortsMultipart` (ctx cancelled mid-part: abort called with a fresh bounded context, `Upload` returns `context.Canceled`).
  - `TestProgressNeverExceedsTotal`: progress values are non-decreasing and at most the file size, including when the fake reads the body twice.
  - `TestVanishedFileIsUnreadable`: path removed before start: `Message` is "File could not be read", no S3 call. `TestShrunkFileIsUnreadable`: file truncated after the size was recorded: fails with `ErrFileUnreadable`.
  - `TestMessageMapping`: `ErrBadCredentials` "AWS rejected the access key", `ErrBucketNotFound` "Bucket not found", `ErrNoNetwork` "No internet connection", `ErrWriteDenied` "AWS denied permission to write to the bucket", unknown error "Upload failed".
  - `TestSettingsStringRedactsSecrets`: `fmt.Sprintf("%v", s)` contains neither key nor secret.
- [ ] **Step 2: Run** `go test ./internal/uploader/ -v`. Expected: FAIL.
- [ ] **Step 3: Implement.** Measure progress by wrapping the body reader in a counting reader and clamping to the size read from `os.Stat` at upload start; read multipart parts with `io.NewSectionReader` so a growing file is cut at the recorded size and a shrinking one yields `ErrFileUnreadable`. Key resolution loops `attempt` from 0 using `ObjectExists`. Abort on failure or cancellation uses `context.WithTimeout(context.WithoutCancel(ctx), 1*time.Second)`.
- [ ] **Step 4: Run tests.** Expected: PASS.
- [ ] **Step 5: Commit**

```bash
git add daemon/internal/uploader
git commit -m "feat(daemon): add uploader with conditional writes and error messages"
```

### Task 5: AWS S3 adapter

**Files:**
- Create: `daemon/internal/awss3/client.go`
- Test: `daemon/internal/awss3/client_test.go`

**Interfaces:**
- Consumes: `uploader.S3`, `uploader.Settings`, sentinel errors (Task 4).
- Produces: `func New(ctx context.Context, s uploader.Settings) (uploader.S3, error)`; `func mapError(err error) error` (package-private, tested).

- [ ] **Step 1: Verify the SDK.** Read the aws-sdk-go-v2 docs for `s3.PutObjectInput` and `s3.CompleteMultipartUploadInput` to find the exact field that carries `If-None-Match`, and for the error types and codes for 404, 403, `PreconditionFailed` (412), `NoSuchBucket`, `InvalidAccessKeyId`, `SignatureDoesNotMatch`. Do not assume names.
- [ ] **Step 2: Write failing tests** for `mapError` using `smithy.GenericAPIError` values and a `net.OpError`: `NoSuchBucket` to `ErrBucketNotFound`; `InvalidAccessKeyId` and `SignatureDoesNotMatch` to `ErrBadCredentials`; `PreconditionFailed` (and `ConditionalRequestConflict`) to `ErrPreconditionFailed`; a network error to `ErrNoNetwork`; `AccessDenied` from `ObjectExists` to `ErrForbidden`, and `AccessDenied` from any write call to `ErrWriteDenied`. Add `TestObjectExistsTreatsNotFoundAsFalse` using a stubbed HTTP client in the SDK config that returns 404 on `HEAD`.
- [ ] **Step 3: Run** `go test ./internal/awss3/ -v`. Expected: FAIL.
- [ ] **Step 4: Implement** the adapter with static credentials from `Settings`, the field verified in Step 1 set to `*` on both `PutObject` and `CompleteMultipartUpload`, and `mapError` applied to every call.
- [ ] **Step 5: Run tests.** Expected: PASS. Run `go vet ./...`.
- [ ] **Step 6: Commit**

```bash
git add daemon/go.mod daemon/go.sum daemon/internal/awss3
git commit -m "feat(daemon): add AWS S3 adapter with conditional writes"
```

### Task 6: Queue and snapshot publishing

**Files:**
- Create: `daemon/internal/queue/queue.go`
- Test: `daemon/internal/queue/queue_test.go`

**Interfaces:**
- Consumes: `uploader.Settings`, `uploader.Request`, `uploader.Callbacks`, `uploader.Message` (Task 4).
- Produces:
  - `type State int` with `Queued, Uploading, Finished, Failed`; `type Snapshot struct{ ID, FileName, LocalPath, ObjectKey string; BytesTotal, BytesSent int64; State State; ErrorMessage string }`.
  - `type Runner interface{ Run(ctx context.Context, s uploader.Settings, req uploader.Request, cb uploader.Callbacks) error }`
  - `var ErrInvalidPath = errors.New(...)`
  - `func New(r Runner, now func() time.Time) *Queue` (min interval between progress snapshots per upload: 100 ms)
  - `func (q *Queue) Enqueue(s uploader.Settings, localPath string) (string, error)` (stats and opens the file; regular and readable or `ErrInvalidPath`)
  - `func (q *Queue) Subscribe() (initial []Snapshot, updates <-chan Snapshot, cancel func())`
  - `func (q *Queue) Run(ctx context.Context)` (blocks, processes FIFO, returns after ctx is cancelled and the current upload has stopped)

- [ ] **Step 1: Write failing tests** with a fake `Runner` and a fake clock:
  - `TestFIFOOrderOneAtATime`: three enqueues; runner records start order a,b,c and never runs two at once.
  - `TestSnapshotSequenceSuccess`: subscriber sees `Queued` with empty `ObjectKey`, `Uploading` with the key, progress, `Finished` with `BytesSent == BytesTotal`.
  - `TestSnapshotSequenceFailure`: runner error yields `Failed` with `ErrorMessage == uploader.Message(err)` and key as last known.
  - `TestProgressThrottledToTenPerSecond`: 50 progress calls within 100 ms of fake time yield at most 1 progress snapshot; state changes and the final snapshot are always published.
  - `TestSubscribeReplaysKnownUploads`: a subscriber that joins late gets one initial snapshot per upload, then only later changes.
  - `TestSlowSubscriberNeverBlocksRunner`.
  - `TestEnqueueRejectsDirectoryAndMissingFile` (both `ErrInvalidPath`); `TestZeroByteFileAccepted`.
  - `TestSettingsCapturedAtEnqueue`: runner receives the settings value passed at enqueue even when the caller later passes different settings for another job.
  - `TestRunCancelsCurrentUpload`: cancelling ctx cancels the runner's ctx and `Run` returns.
- [ ] **Step 2: Run** `go test ./internal/queue/ -v`. Expected: FAIL.
- [ ] **Step 3: Implement.** IDs from `crypto/rand` hex. Subscribers get a buffered channel; a full buffer drops that subscriber's channel instead of blocking.
- [ ] **Step 4: Run tests** with `-race`. Expected: PASS.
- [ ] **Step 5: Commit**

```bash
git add daemon/internal/queue
git commit -m "feat(daemon): add FIFO queue with throttled snapshot publishing"
```

### Task 7: gRPC server

**Files:**
- Create: `daemon/internal/server/server.go`
- Test: `daemon/internal/server/server_test.go`

**Interfaces:**
- Consumes: generated `pb` package (Task 1), `queue.Queue` (Task 6), `uploader.Settings`, `logging.Logger` (Task 2).
- Produces: `func New(q *queue.Queue, log *logging.Logger) *Server` implementing `pb.DaemonServer`.

- [ ] **Step 1: Write failing tests** using an in-process `bufconn` gRPC server and a fake queue runner:
  - `TestEnqueueBeforeConfigureFailsPrecondition`: code `FAILED_PRECONDITION`.
  - `TestConfigureRejectsEmptyFields`: each of key, secret, region, bucket empty gives `INVALID_ARGUMENT`; empty prefix is accepted.
  - `TestEnqueueInvalidPath`: directory and missing file give `INVALID_ARGUMENT`.
  - `TestEnqueueReturnsUploadID` and `TestWatchStreamsSnapshotsInOrder`: mapping of `queue.State` to `pb.UploadState` and all snapshot fields.
  - `TestWatchReplaysExistingUploadsOnSubscribe`.
  - `TestSettingsCapturedAtEnqueue`: `Configure(A)`, enqueue, `Configure(B)`, enqueue; the runner sees A then B.
  - `TestSecretNeverLogged`: logger writes to a buffer; after `Configure` and an enqueue, the buffer contains neither the key ID nor the secret.
- [ ] **Step 2: Run** `go test ./internal/server/ -v`. Expected: FAIL.
- [ ] **Step 3: Implement** the three RPCs; `Configure` stores a copy of the settings under a mutex and calls no AWS API. `WatchUploads` ends when the client context ends.
- [ ] **Step 4: Run tests** with `-race`. Expected: PASS.
- [ ] **Step 5: Commit**

```bash
git add daemon/internal/server
git commit -m "feat(daemon): add gRPC server for configure, enqueue and watch"
```

### Task 8: Daemon application composition, socket and shutdown

**Files:**
- Create: `daemon/internal/app/app.go`, `daemon/cmd/rabbitholed/main.go`
- Test: `daemon/internal/app/app_test.go`

**Interfaces:**
- Consumes: everything above.
- Produces: `func Run(ctx context.Context, args []string, stdin io.Reader, stderr io.Writer) int` (exit code); `main.go` is `os.Exit(app.Run(context.Background(), os.Args[1:], os.Stdin, os.Stderr))` and nothing else. Log level comes from `RABBITHOLE_LOG_LEVEL` (never a credential).

- [ ] **Step 1: Write failing tests** (temp dir sockets, `os.Pipe` for stdin):
  - `TestMissingSocketFlagPrintsOneJSONLineAndExits2`: stderr is exactly one line of valid JSON with `time`, `level`, `msg`, `service`.
  - `TestSocketModeIs0600`: after start, `os.Stat(sock).Mode().Perm() == 0600`.
  - `TestStaleSocketFileIsReplaced`: a leftover plain file at the path does not stop startup.
  - `TestExitsWithin1500msOfStdinEOF`: close the pipe writer; `Run` returns 0 within 1.5 s.
  - `TestExitsWithin1500msOfSIGTERM`: send `syscall.SIGTERM` on the injected signal channel (an unexported constructor option; never signal the test process itself); same bound.
  - `TestShutdownDeadlineWhenAbortHangs`: a stuck runner (fake via an unexported constructor option) still lets `Run` return within the bound.
  - `TestNoTCPListener`: only a Unix address is listened on (`net.Listen` is called with `"unix"`; assert via the listener type returned by an injected listen func).
- [ ] **Step 2: Run** `go test ./internal/app/ -v`. Expected: FAIL.
- [ ] **Step 3: Implement.** Parse `--socket`, create the socket directory if missing, remove a stale file, listen on `unix`, `chmod 0600`, build logger, S3 factory (`awss3.New`), uploader, queue, server by constructors. The queue's `Runner` is an unexported adapter in this package holding the `*uploader.Uploader` and the S3 factory: `Run` calls the factory with the job's `Settings`, then `Uploader.Upload`. Shutdown starts on stdin EOF, SIGTERM or ctx cancel: cancel uploads, `GracefulStop` bounded by a 1.2 s internal timer measured from the signal (so the process is gone inside the 1.5 s limit even when an abort hangs), then `Stop`, remove the socket, return.
- [ ] **Step 4: Run tests** with `-race`, then `cd daemon && go build -o bin/rabbitholed ./cmd/rabbitholed && echo ok`. Expected: PASS, `ok`.
- [ ] **Step 5: Smoke test the binary.** Run `daemon/bin/rabbitholed --socket /tmp/rh-test.sock < /dev/null; echo "exit=$?"` (stdin is at end of file from the start). Expected: it returns by itself in under 1.5 seconds with `exit=0`, and `pgrep rabbitholed || echo none` prints `none`. Never use a broad `pkill` on this machine.
- [ ] **Step 6: Commit**

```bash
git add daemon/internal/app daemon/cmd
git commit -m "feat(daemon): compose app, listen on unix socket and shut down on parent exit"
```

### Task 9: Swift project scaffolding and daemon client

**Files:**
- Create: `app/project.yml`, `app/Sources/Rabbithole/Info.plist` (via project.yml), `app/Sources/Rabbithole/DaemonClient.swift`, `app/Sources/Rabbithole/GRPCDaemonClient.swift`, `app/Sources/Rabbithole/Models.swift`, `app/Tests/RabbitholeTests/GRPCDaemonClientTests.swift`
- Modify: `Makefile` (real `build`, `test`, `run`)

**Interfaces:**
- Produces:
  - `struct AWSSettings: Equatable { var accessKeyID, secretAccessKey, region, bucket: String }`
  - `enum UploadState { case queued, uploading, finished, failed }`
  - `struct UploadSnapshot: Equatable, Sendable { let id, fileName, localPath, objectKey: String; let bytesTotal, bytesSent: Int64; let state: UploadState; let errorMessage: String }`
  - `protocol DaemonClient: Sendable { func configure(_ settings: AWSSettings) async throws; func enqueue(localPath: String) async throws -> String; func watch() -> AsyncThrowingStream<UploadSnapshot, Error> }`
  - `final class GRPCDaemonClient: DaemonClient { init(socketPath: String) }`; generated types never leave this file.

- [ ] **Step 1: Write `app/project.yml`**: target `Rabbithole` (macOS application, bundle id `com.rabbithole.app`, `LSUIElement: true`, no sandbox entitlement, `CODE_SIGN_IDENTITY: "-"`), unit test target `RabbitholeTests`, the Swift gRPC packages verified in Task 1, sources `Sources/Rabbithole` plus `Sources/Generated`. A pre-sign run-script phase copies `$SRCROOT/../daemon/bin/rabbitholed` to `Contents/Resources/rabbitholed` and signs it with `$EXPANDED_CODE_SIGN_IDENTITY`. Update the Makefile so `build` runs the daemon build, `xcodegen generate` in `app/`, and `xcodebuild -project app/Rabbithole.xcodeproj -scheme Rabbithole -configuration Debug build`; `test` adds `xcodebuild test -destination 'platform=macOS'`.
- [ ] **Step 2: Write failing tests.** Start the real Go daemon (built by `make build`'s daemon step) in the test with a temp socket and a held stdin pipe. `testConfigureThenEnqueueThenWatchDeliversFinishedSnapshot` needs AWS, so instead assert contract behavior that needs none: `testEnqueueBeforeConfigureThrowsFailedPrecondition`, `testConfigureWithEmptyBucketThrowsInvalidArgument`, `testWatchStreamEndsWhenTaskCancelled`. Mapping of `UploadState` and fields is covered by `testSnapshotMapping` against a generated message built in the test.
- [ ] **Step 3: Run** `make build` then `xcodebuild test -project app/Rabbithole.xcodeproj -scheme Rabbithole -destination 'platform=macOS'`. Expected: FAIL (types missing), then compile errors fixed by Step 4.
- [ ] **Step 4: Implement** the models, protocol and the grpc-swift client over a Unix domain socket transport (verify the transport API in the grpc-swift docs). Calls are `async` and never run on the main actor.
- [ ] **Step 5: Run the tests.** Expected: PASS. Run `xcodebuild ... build` for the app itself.
- [ ] **Step 6: Commit**

```bash
git add app/project.yml app/Sources app/Tests Makefile
git commit -m "feat(app): scaffold Swift project and gRPC daemon client"
```

### Task 10: Daemon supervisor

**Files:**
- Create: `app/Sources/Rabbithole/DaemonSupervisor.swift`
- Test: `app/Tests/RabbitholeTests/DaemonSupervisorTests.swift`

**Interfaces:**
- Consumes: `DaemonClient` (Task 9).
- Produces:
  - `protocol DaemonProcess { func terminate(); var terminationEvents: AsyncStream<Void> { get } }`
  - `protocol ProcessLauncher { func launch(executable: URL, arguments: [String]) throws -> DaemonProcess }` (the real one keeps a stdin `Pipe` open for the child's lifetime)
  - `enum DaemonEvent: Equatable { case ready, restarted, unavailable }`
  - `final class DaemonSupervisor { init(executable: URL?, socketURL: URL, launcher: ProcessLauncher, socketProbe: @escaping () async -> Bool, makeClient: @escaping (String) -> DaemonClient, maxRestarts: Int = 3); var events: AsyncStream<DaemonEvent>; var client: DaemonClient? ; func start() async; func stop() }`

- [ ] **Step 1: Write failing tests** with fake launcher, probe and client:
  - `testLaunchesWithSocketArgument`: arguments are exactly `["--socket", <path>]`.
  - `testCreatesSocketDirectoryWithMode0700`: the parent directory of the socket exists with `0o700`.
  - `testEmitsReadyOnlyAfterProbeSucceeds`.
  - `testUnexpectedExitRestartsAndEmitsRestarted`.
  - `testGivesUpAfterThreeRestartsAndEmitsUnavailable`: fourth crash emits `.unavailable`, no fifth launch.
  - `testMissingExecutableEmitsUnavailable` (executable `nil`, Review Focus 5).
  - `testStopTerminatesProcessWithoutRestart`.
- [ ] **Step 2: Run** `xcodebuild test ... -only-testing:RabbitholeTests/DaemonSupervisorTests`. Expected: FAIL.
- [ ] **Step 3: Implement.** Real launcher uses `Process` with a `Pipe` as `standardInput`, retained by the returned `DaemonProcess`; stderr goes to the app's own stderr; no credentials appear in arguments or environment. The probe retries a connect to the socket every 100 ms up to 5 s.
- [ ] **Step 4: Run tests.** Expected: PASS.
- [ ] **Step 5: Commit**

```bash
git add app/Sources app/Tests
git commit -m "feat(app): supervise the daemon process with bounded restarts"
```

### Task 11: Keychain, settings store and AWS settings window

**Files:**
- Create: `app/Sources/Rabbithole/CredentialStore.swift`, `app/Sources/Rabbithole/SettingsStore.swift`, `app/Sources/Rabbithole/AWSSettingsView.swift`, `app/Sources/Rabbithole/AWSSettingsWindow.swift`
- Test: `app/Tests/RabbitholeTests/SettingsStoreTests.swift`

**Interfaces:**
- Consumes: `AWSSettings` (Task 9).
- Produces:
  - `protocol CredentialStore { func load() throws -> (accessKeyID: String, secret: String)?; func save(accessKeyID: String, secret: String) throws }`; `KeychainCredentialStore(service: String = "com.rabbithole.app")` using the Security framework generic password items (accounts `aws-access-key-id`, `aws-secret-access-key`).
  - `final class SettingsStore { init(credentials: CredentialStore, defaults: UserDefaults); func load() throws -> AWSSettings?; func save(_ s: AWSSettings) throws }` (region and bucket in `UserDefaults` keys `region`, `bucket`).
  - `static func SettingsStore.validate(_ s: AWSSettings) -> String?` (first problem as a one-line message, or nil).
  - `AWSSettingsWindowController(store: SettingsStore, onSaved: @escaping (AWSSettings) -> Void)`.

- [ ] **Step 1: Write failing tests** (in-memory `CredentialStore` fake, `UserDefaults(suiteName:)` removed in tearDown):
  - `testLoadReturnsNilWhenNothingSaved`; `testSaveThenLoadRoundTrips`; `testSecretNeverWrittenToDefaults`: after save, no value in the defaults domain equals the key ID or secret; `testLoadReturnsNilWhenKeychainMissing` even if region and bucket exist; `testValidateRejectsEmptyFields` (each field), `testValidateTrimsWhitespace`.
  - `testKeychainRoundTrip` against `KeychainCredentialStore(service: "com.rabbithole.app.tests")`, deleting its items in tearDown. Note: with ad-hoc signing macOS may prompt for keychain access on a rebuilt test host; this is the known signing question in the spec, not a defect.
- [ ] **Step 2: Run** the test class. Expected: FAIL.
- [ ] **Step 3: Implement** the store and the Keychain implementation (update-or-add semantics, `kSecAttrAccessibleWhenUnlocked`). Build the plain form (access key ID, secure field for the secret, region, bucket, Save and Cancel; inline validation message); saving calls `SettingsStore.save` then `onSaved`.
- [ ] **Step 4: Run tests.** Expected: PASS.
- [ ] **Step 5: Commit**

```bash
git add app/Sources app/Tests
git commit -m "feat(app): store AWS settings in keychain and preferences with settings window"
```

### Task 12: Tray view model with batch counting

**Files:**
- Create: `app/Sources/Rabbithole/BatchTracker.swift`, `app/Sources/Rabbithole/TrayViewModel.swift`
- Test: `app/Tests/RabbitholeTests/BatchTrackerTests.swift`, `app/Tests/RabbitholeTests/TrayViewModelTests.swift`

**Interfaces:**
- Consumes: `DaemonClient`, `UploadSnapshot`, `AWSSettings`, `DaemonEvent`.
- Produces:
  - `struct BatchTracker { mutating func register(id: String); mutating func apply(_ s: UploadSnapshot); mutating func interrupted(); var remaining: Int; var total: Int; var fraction: Double; var isActive: Bool; var firstError: String? }` (snapshots for unregistered ids are held and claimed when the id is registered).
  - `enum TrayState: Equatable { case unavailable, notConfigured, idle, uploading(remaining: Int, total: Int, fraction: Double), finished, failed(String) }`
  - `enum DropFeedback: Equatable { case none, hovering, confirmed, refused(String) }`
  - `@MainActor @Observable final class TrayViewModel { init(client: DaemonClient?, settings: AWSSettings?, isRegularFile: @escaping (URL) -> Bool, sleep: @escaping (Duration) async throws -> Void); var state: TrayState; var dropFeedback: DropFeedback; var statusText: String; func drop(_ urls: [URL]) async; func setHovering(_ over: Bool); func settingsSaved(_ s: AWSSettings) async; func handle(_ e: DaemonEvent) }`

- [ ] **Step 1: Write failing tests.** `BatchTrackerTests`: `testRemainingCountsUnfinishedUploads` (3 registered, 1 finished: remaining 2, total 3); `testFractionIsBytesSentOverTotal` (100 of 400 bytes is 0.25); `testBatchEndsWhenAllFinishedOrFailed` and `testNextRegisterStartsNewBatch` (total resets to 1); `testSnapshotsOfEarlierBatchesIgnored`; `testReplayedSnapshotsOfUnregisteredIdsIgnored`; `testSnapshotArrivingBeforeRegisterIsClaimed`; `testInterruptedMarksUnfinishedFailedWithUploadInterrupted`. `TrayViewModelTests` with a fake client: `testNotConfiguredWhenNoSettings`; `testIdleWhenConfigured`; `testUploadingShowsOneOfOneFilesLeft` (`statusText == "1 of 1 files left"`); `testFinishedState`; `testFailedShowsErrorMessageUntilNextUploadStarts`; `testFolderIsRefused` (real temp directory, message "Folders are not supported yet", `enqueue` not called); `testMultipleItemsRefused` ("Drop one file at a time", not called); `testPackageDirectoryIsRefused`; `testConfirmationLastsTwoSeconds` (fake `sleep` records `.seconds(2)`, then feedback returns to `.none`); `testDaemonRestartMarksUploadsInterrupted` and `testUnavailableAfterEvent`; `testSettingsSavedConfiguresClientThenEnablesDrops`.
- [ ] **Step 2: Run** the two test classes. Expected: FAIL.
- [ ] **Step 3: Implement** `BatchTracker` per the spec's counting rule, then the view model. Status text: `"\(remaining) of \(total) files left"` while uploading, the error message when failed, `"Upload finished"` when finished, `"Ready"` when idle, `"Uploads are unavailable"` when unavailable.
- [ ] **Step 4: Run tests.** Expected: PASS.
- [ ] **Step 5: Commit**

```bash
git add app/Sources app/Tests
git commit -m "feat(app): add tray view model with batch counting"
```

### Task 13: Tray window UI, drag and drop, app wiring

**Files:**
- Create: `app/Sources/Rabbithole/RabbitholeApp.swift` (entry, `AppDelegate`), `app/Sources/Rabbithole/TrayPanel.swift`, `app/Sources/Rabbithole/TrayPanelPositioner.swift`, `app/Sources/Rabbithole/TrayView.swift`
- Test: `app/Tests/RabbitholeTests/TrayPanelPositionerTests.swift`

**Interfaces:**
- Consumes: all app types above.
- Produces: `enum TrayPanelPositioner { static let width: CGFloat = 232; static let gap: CGFloat = 3; static func frame(statusItemFrame: CGRect, contentHeight: CGFloat) -> CGRect }` (top edge is `statusItemFrame.minY - 3`, right-aligned to the icon's right edge).

- [ ] **Step 1: Write the failing test** `testFrameIsThreePointsBelowIconAndTwoThirtyTwoWide`: for icon frame `(1000, 1056, 24, 24)` and content height 150, the result has `width == 232`, `maxY == 1053`, `maxX == 1024`.
- [ ] **Step 2: Run** the test. Expected: FAIL.
- [ ] **Step 3: Implement the positioner**, then the UI by reading `tray-popover.html`, `tray-setup.html`, `tray-drag.html` for geometry and copy:
  - `NSStatusItem` whose button toggles an `NSPanel` (borderless, floating, `hidesOnDeactivate = false`, can become key) hosting `TrayView`; outside clicks do not close it; clicking the icon again does.
  - Glass background with the system material API available on macOS 27 (check the docs; fall back to `NSVisualEffectView`). Minimum deployment target: macOS 26.
  - `TrayView`: setup block when `notConfigured` ("Connect your AWS account", "Rabbithole needs it before it can send files.", button "Set up Rabbithole" opens the AWS settings window); otherwise the 64 pt solid drop area ("Drop a file" idle, "Release to upload" while hovering with the whole panel outlined, a green confirmation for 2 s, "Drop more to queue" while uploading), the status line (`statusText` left, percentage right) and the 2 pt progress bar; menu with "Choose file…" (`NSOpenPanel`, single regular file, disabled until configured) and "Quit". Menu items not in this slice are omitted.
  - Drops accept file URLs on the whole panel and call `viewModel.drop`.
  - `AppDelegate` composes: `SettingsStore`, `DaemonSupervisor` (executable from `Bundle.main.url(forResource: "rabbitholed", withExtension: nil)`), subscribes to `client.watch()` and `supervisor.events` on a background task, forwards to the view model on the main actor. On every `.ready` and `.restarted` event it calls `configure` with the saved settings (a restarted daemon has none) and starts a fresh `watch()` subscription; if the watch stream ends while the daemon is still alive it resubscribes after 500 ms. Quit and `applicationWillTerminate` call `supervisor.stop()`.
- [ ] **Step 4: Run** `make build && make test`. Expected: all Go and Swift tests PASS, app builds.
- [ ] **Step 5: Launch** with `make run`, confirm the menu bar icon appears, no Dock icon, the setup block shows, the window stays open after clicking elsewhere and closes on the second icon click, then Quit from the menu and run `pgrep rabbitholed || echo none`. Expected: `none`.
- [ ] **Step 6: Commit**

```bash
git add app/Sources app/Tests
git commit -m "feat(app): add tray window, drag and drop and application wiring"
```

### Task 14: Manual end-to-end check against a real bucket

**Files:** none changed. Needs the owner's AWS credentials and a bucket whose policy allows `s3:PutObject`, `s3:AbortMultipartUpload`, `s3:ListBucket`. Use `BUCKET=<bucket> REGION=<region>` below. Do not paste credentials into any command, file or chat.

- [ ] **Step 1: Prepare files.** `mkdir -p /tmp/rh-e2e && cd /tmp/rh-e2e && head -c 1000000 /dev/urandom > one-mb.bin && head -c 100000000 /dev/urandom > hundred-mb.bin`.
- [ ] **Step 2: Start** with `make run`; open the tray window; enter the credentials, region and bucket in the AWS settings window; Save. Expected: the setup block is replaced by the drop area. Keychain may prompt (ad-hoc signing); allow it.
- [ ] **Step 3 (Done when 1):** Drop `one-mb.bin`, then `hundred-mb.bin`. For each: `aws s3api head-object --bucket $BUCKET --key quick-uploads/one-mb.bin --query ContentLength` (and `hundred-mb.bin`). Expected: `1000000` and `100000000`.
- [ ] **Step 4 (Done when 2):** While `hundred-mb.bin` uploads (drop it under a new name, `cp hundred-mb.bin hundred-mb-2.bin`), watch the status line: "1 of 1 files left", the percentage and bar advance, and the window still opens, closes and accepts hover. Expected: no freeze.
- [ ] **Step 5 (Done when 3):** Drop `one-mb.bin` again. `aws s3api list-objects-v2 --bucket $BUCKET --prefix quick-uploads/one-mb --query 'Contents[].Key'`. Expected: two keys, `quick-uploads/one-mb.bin` and `quick-uploads/one-mb-<YYYYMMDD-HHMMSS>.bin`.
- [ ] **Step 6 (Done when 4):** Choose Quit from the menu, then `sleep 2; pgrep rabbitholed || echo none`. Expected: `none`. Relaunch with `make run`, then `pkill -9 -x Rabbithole; sleep 2; pgrep rabbitholed || echo none`. Expected: `none`.
- [ ] **Step 7 (Done when 5):** Confirm no credential leaked. Put the key ID in `AKID=<access key id>` in the shell only, then `grep -rl "$AKID" ~/Desenvolvimento/projetos/pessoais/myBackupTool "$HOME/Library/Application Support/Rabbithole" || echo clean`. Expected: `clean`. Run `lsof -iTCP -sTCP:LISTEN -n -P | grep rabbitholed || echo no-tcp` while the app runs. Expected: `no-tcp`.
- [ ] **Step 8 (refusals):** Drop a folder, then two files at once. Expected: a one-line refusal in the drop area, no new objects (`list-objects-v2` count unchanged).
- [ ] **Step 9 (failure message):** Change the bucket name to one that does not exist and drop a file. Expected: the status line shows "Bucket not found". Restore the bucket name, then run `pkill -x rabbitholed` while the app is open and drop a file. Expected: the daemon is restarted and the upload succeeds.
- [ ] **Step 10 (Done when 6):** `make test`. Expected: Go and Swift suites pass.
- [ ] **Step 11: Clean up.** Ask the owner before deleting anything from the bucket. Then `aws s3 rm s3://$BUCKET/quick-uploads/ --recursive --exclude '*' --include 'one-mb*' --include 'hundred-mb*'`, `rm -rf /tmp/rh-e2e`, and `pgrep -fl "rabbitholed|Rabbithole" || echo none`. Report that nothing is left running.
- [ ] **Step 12: Advise the owner** to add a bucket lifecycle rule that aborts incomplete multipart uploads after a few days.
