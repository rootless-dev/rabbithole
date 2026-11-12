# Rabbithole, first slice: drop a file on the tray and it lands in the bucket

Date: 2026-11-12. Status: awaiting approval.

## Intent

Rabbithole is a personal macOS backup tool. It sends files to an S3 bucket in the
owner's own AWS account. It has two faces: a menu bar ("tray") window for quick
uploads and a main window for following and managing uploads.

This document covers only the first working slice. Its purpose is to prove the whole
path once, end to end, with the real architecture: native UI, a separate upload
engine, and the contract between them. Every later feature is added on top of this
path, so the slice favors getting the seams right over features.

## Decisions already made by the owner

- macOS only. The UI is a native Swift app.
- The upload engine is a daemon written in Go.
- The daemon lives and dies with the tray app process. It is not a launchd service.
- The two talk over gRPC on a Unix domain socket, never a TCP port.
- Upload progress reaches the UI through a server-streaming RPC.
- AWS credentials are stored in the macOS keychain. The Swift app reads them and
  hands them to the daemon at startup. The daemon never touches the keychain.
- Small files are sent in one request; large files are sent in parts.
- The approved visual design is in `design/mockups/`. For this slice the relevant
  files are `tray-popover.html`, `tray-setup.html` and `tray-drag.html`. They are a
  visual reference, not code to reuse.

## Goal of this slice

A user who has saved valid AWS settings can drop one file on the tray window, watch
its progress, and find the object in the bucket.

## What the slice does

1. The app starts with no Dock icon and puts an icon in the menu bar. On start it
   launches the daemon as a child process and connects to it.
2. Clicking the icon opens the tray window under it; clicking the icon again closes
   it. Clicking elsewhere does not close it.
3. With no saved AWS settings, the tray window shows the setup block from
   `tray-setup.html`. Its button opens the AWS settings window.
4. The AWS settings window is a plain form: access key ID, secret access key, region,
   bucket. Saving stores them and configures the daemon.
5. With settings saved, the tray window shows the drop area, the status line and the
   menu. Dropping one regular file, or picking one with "Choose file…", enqueues it.
6. The daemon uploads the file to `quick-uploads/<file name>` in the bucket.
7. The tray window shows "1 of 1 files left", an overall percentage and the thin
   progress bar, all driven by the progress stream.
8. "Quit" stops the app and the daemon.

## Non-goals of this slice

Folders, several files in one drop, clipboard upload, recent uploads, resuming after
the app is closed, the main window (overview, history, upload detail), file
thumbnails, the full settings screen, the styled first-launch flow, encryption,
update checks, notifications, open at login, retry policy, speed limit, concurrent
uploads, storage class choice, light/dark switch in the app (the app follows the
system appearance), distribution (signing for others, notarization).

A dropped folder, or a drop of more than one item, is refused with a one-line message
in the drop area and nothing is enqueued.

## Anti-goals

These make the slice a failure even if a file reaches the bucket:

- Credentials written to a file, a log line, an environment variable or a command
  line argument.
- The daemon listening on a TCP port.
- A daemon left running after the app is gone, including after the app is killed.
- The app freezing while a large file uploads.
- Silently overwriting an object that already exists in the bucket.

## Architecture

```
+-----------------------------+         +------------------------------+
| Rabbithole.app (Swift)      |  gRPC   | rabbitholed (Go, child proc) |
|  tray window, AWS settings  | <-----> |  queue, S3 uploader          |
|  keychain, daemon supervisor|  Unix   |  credentials in memory only  |
+-----------------------------+  socket +------------------------------+
                                                     |
                                                     v  HTTPS
                                                 Amazon S3
```

### Repository layout

```
app/        Swift app (project definition, Sources/, Tests/)
daemon/     Go module (cmd/rabbitholed, internal/...)
proto/      gRPC contract (rabbithole/v1/daemon.proto)
design/     approved mockups
docs/       this spec and the plan
Makefile    build, generate, test, run
```

Generated gRPC code for both languages is committed, so building does not require the
protobuf toolchain.

### The contract (`rabbithole.v1.Daemon`)

- `Configure(access_key_id, secret_access_key, region, bucket, quick_uploads_prefix)`
  Replaces the daemon's AWS settings. Returns OK without calling AWS.
- `EnqueueUpload(local_path)` returns `upload_id`. Fails with `FAILED_PRECONDITION`
  if `Configure` has not been called, and `INVALID_ARGUMENT` if the path is not a
  readable regular file.
- `WatchUploads()` returns a stream of `UploadSnapshot`. On subscribe the daemon
  sends one snapshot per upload it knows, then a new snapshot whenever one changes,
  at most 10 per second per upload, always including the final one.

`UploadSnapshot`: `upload_id`, `file_name`, `local_path`, `object_key`,
`bytes_total`, `bytes_sent`, `state` (`QUEUED`, `UPLOADING`, `FINISHED`, `FAILED`),
`error_message` (set only when `FAILED`, written for a person to read).

Field numbers are never reused. Later slices add RPCs and fields; they do not change
these.

### Daemon (Go)

- Follows the owner's Go rules: `cmd/rabbitholed/main.go` only calls into
  `internal/app`, which owns composition and lifecycle; dependencies are passed
  through constructors.
- Logging uses `phuslu/log`, emitting JSON to stderr with `time`, `level`, `msg` and
  a `service` field. It sits behind a small internal logging package so no other
  package imports the library. An unknown log level falls back to info. A failure
  before the logger exists still prints one JSON line to stderr.
- Started by the app as `rabbitholed --socket <path>`. It creates the socket with
  mode 0600 and removes a stale socket file left by a previous run.
- Parent supervision: the app keeps a pipe connected to the daemon's stdin. When
  stdin reaches end of file the daemon cancels uploads and exits. It also exits
  cleanly on SIGTERM. Either way it exits within 1.5 seconds, which leaves margin for
  the 2 second check in "Done when".
- Queue: in memory, first in first out, one upload at a time. Nothing is persisted.
- Upload rule: files smaller than 16 MiB are sent with a single `PutObject`. Files of
  16 MiB or more are sent as a multipart upload with 8 MiB parts. S3 allows at most
  10,000 parts, which with 8 MiB parts is 80,000 MiB (78.125 GiB). Above 80,000 MiB
  the part size grows to the smallest whole number of MiB that keeps the upload
  within 10,000 parts. A zero-byte file is a valid upload.
- A failed multipart upload is aborted so no orphan parts are left billed. On
  shutdown the abort is best effort: the daemon gives itself a hard deadline of 1.5
  seconds from the shutdown signal and exits when it expires, aborted or not.
- Orphan parts after a daemon crash or a killed app are accepted in this slice. The
  daemon does not sweep incomplete uploads on start, because that could abort
  uploads made by other tools. The owner is advised to add a bucket lifecycle rule
  that aborts incomplete multipart uploads after a few days.
- Object key: `<quick_uploads_prefix><file name>`. The key is resolved when the
  upload starts, not when it is enqueued, so `object_key` is empty while `QUEUED`.
  The daemon checks whether the key exists; if it does, it tries
  `<prefix><base name>-<YYYYMMDD-HHMMSS><extension>` (local time), and if that exists
  too, the same name with `-2`, `-3` and so on appended to the timestamp, until a
  free key is found.
- The existence check is backed by a conditional write (`If-None-Match: *`) on
  `PutObject` and on completing a multipart upload, so an object that appears between
  the check and the write is never overwritten. For a single-request upload a
  rejected conditional write moves on to the next candidate key. For a multipart
  upload it ends in `FAILED` with a readable message.
- Required permissions on the bucket: `s3:PutObject`, `s3:AbortMultipartUpload` and
  `s3:ListBucket`. Without `s3:ListBucket` S3 cannot tell a missing object from a
  forbidden one; in that case the upload ends in `FAILED` with a message naming the
  missing permission, rather than risking an overwrite.
- AWS settings are captured when an upload is enqueued. Calling `Configure` later
  affects only uploads enqueued after it.
- Progress: `bytes_sent` is the number of bytes handed to the AWS SDK, never above
  `bytes_total`, and equal to `bytes_total` when the state is `FINISHED`.
- S3 access goes through a narrow interface defined by the uploader, so tests use a
  fake and never call AWS.
- AWS failures become `FAILED` with a short readable message (for example "AWS
  rejected the access key", "Bucket not found", "No internet connection").

### App (Swift)

- No Dock icon; menu bar item only.
- Tray window: 232 points wide, 3 points under the menu bar, system glass material,
  drop area with a solid background 64 points tall, following `tray-popover.html`.
  It stays open until the menu bar icon is clicked again.
- Menu in this slice: "Choose file…" and "Quit". Other menu items from the mockup
  arrive with the features they open. "Choose file…" is disabled until AWS settings
  are saved.
- Drag feedback follows `tray-drag.html`: highlighted drop area with "Release to
  upload" while a file is held over the window, then a confirmation for 2 seconds.
- A failed upload shows its `error_message` in the status line until the next upload
  starts.
- Counting rule for the status line: a batch is every upload enqueued since the queue
  was last empty. "N of M files left" uses M for the uploads in the current batch and
  N for those not yet finished or failed. The percentage is the batch's bytes sent over
  its total bytes. When every upload in the batch is finished or failed the batch ends,
  and the next drop starts a new one. Uploads from earlier batches are ignored,
  including the ones replayed when the app subscribes.
- If the daemon is restarted, uploads that were queued or in progress are lost; the app
  shows them as failed with "Upload interrupted".
- AWS settings: the access key ID and the secret are stored in the keychain. Region,
  bucket and the quick uploads prefix are stored in the app's preferences. The prefix
  is fixed to `quick-uploads/` in this slice and is not shown in the form.
- Daemon supervisor: launches the daemon binary embedded in the app bundle, passes
  the socket path, waits until the socket accepts a connection, then calls
  `Configure` if settings exist and subscribes to `WatchUploads`. If the daemon
  exits unexpectedly it is restarted, up to 3 times, after which the tray window
  shows that uploads are unavailable.
- Socket path: `~/Library/Application Support/Rabbithole/daemon.sock`, inside a
  directory with mode 0700.
- All gRPC calls run off the main thread; the UI only observes state.
- The app is not sandboxed: it must read any file the user drops and launch the
  daemon. It is signed for local running only.
- Signing identity is an open question for the owner. The machine has no code signing
  identity today. Keychain access is tied to the code signature, so with ad-hoc signing
  macOS asks for keychain permission again after every rebuild. The identity is a
  single build setting, so the choice does not change the code.

## Testing

- Daemon unit tests, with a fake S3: the 16 MiB boundary (one byte below uses a
  single request, exactly 16 MiB uses multipart), the part size at exactly
  80,000 MiB (still 8 MiB) and one byte above it (9 MiB), a zero-byte file, the object
  key rule including an existing key and an existing timestamped key, queue order, the
  snapshot sequence for a successful and a failed upload, `EnqueueUpload`
  preconditions, exit on stdin end of file, a rejected conditional write for both
  upload kinds, a forbidden existence check, and settings captured at enqueue.
- App unit tests, with a fake daemon client: the tray state for each situation (not
  configured, idle, uploading, finished, failed), and refusal of folders and multiple
  items.
- Manual check against a real bucket, which needs the owner's AWS credentials.

## Done when

1. Dropping a 1 MB file and a 100 MB file each produces an object under
   `quick-uploads/` whose size matches the local file.
2. During the 100 MB upload the percentage and bar advance and the tray window stays
   responsive.
3. Dropping the same file twice produces two objects.
4. After "Quit", and after killing the app process, no `rabbitholed` process remains
   2 seconds later.
5. No credential appears in the daemon's log output or in any file under the project
   or the app's support directory.
6. Automated tests for both sides pass.

## Calls made by the author, not the owner

The owner can veto any of these:

- Repository layout and committing generated gRPC code.
- 16 MiB threshold and 8 MiB parts.
- Keeping both objects by adding a timestamp when the key already exists. This is
  guarded by a conditional write and requires `s3:ListBucket`.
- Accepting orphan parts after a crash, with a bucket lifecycle rule as the remedy.
- The batch counting rule for "N of M files left".
- AWS settings captured at enqueue.
- One upload at a time and no persistence in this slice.
- The plain AWS settings window instead of the designed first-launch flow.
- Region, bucket and prefix in preferences; only the key pair in the keychain.
- Socket location, and stdin end of file as the parent-death signal.
- Restarting a crashed daemon up to 3 times.
- Placeholder identifiers: bundle identifier `com.rabbithole.app`, Go module path
  `rabbithole/daemon`.

## Open question for the owner

Which signing identity to use during development: ad-hoc signing (nothing to set up,
but a keychain prompt after every rebuild) or a free Apple Development certificate
created by signing in to Xcode with an Apple ID (stable identity, no repeated
prompts). Until answered, the build uses ad-hoc signing.

## Left to the builder

- Whether the tray window is a popover or a borderless panel, as long as it behaves
  as described.
- The exact glass material API and the minimum macOS version, given the owner runs
  macOS 27.
- gRPC library versions and code generators for Swift and Go, and how the Xcode
  project is defined (a generated project is preferred over a hand-edited one).
- How progress is measured inside the uploader.
- Internal package and type names.
