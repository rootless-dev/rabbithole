import Foundation

/// The app's view of the upload daemon. Implementations must not block the main actor.
protocol DaemonClient: Sendable {
    /// Supplies AWS settings. Throws `DaemonError.invalidArgument` when a required field is empty.
    func configure(_ settings: AWSSettings) async throws

    /// Queues local files and folders as one upload and returns its id. The daemon walks the
    /// folders before answering. Throws `DaemonError.notConfigured` before a successful
    /// `configure`, and `DaemonError.invalidArgument` with a readable message when a path
    /// cannot be used or there is nothing to send.
    func enqueue(_ request: EnqueueRequest) async throws -> String

    /// Streams upload snapshots until the consuming task is cancelled or the daemon fails.
    func watch() -> AsyncThrowingStream<UploadSnapshot, Error>

    /// Streams every file of one upload once, then each file that changes, until the consuming
    /// task is cancelled or the daemon fails. An unknown id fails with `DaemonError.notFound`.
    func watchFiles(uploadID: String) -> AsyncThrowingStream<FileSnapshot, Error>

    /// Sends failed files of an upload again, inside the same upload, which goes back to
    /// waiting. `fileIndexes` are `FileSnapshot.index` values; empty means every failed file.
    /// Throws `DaemonError.notFound` when the upload is no longer in the history and
    /// `DaemonError.rejected` with a readable message when it cannot be done.
    func retry(uploadID: String, fileIndexes: [Int]) async throws

    /// Takes an upload, or the listed files of it, out of the history, and deletes their
    /// objects from the bucket when `deleteFromBucket` is set. `fileIndexes` empty means the
    /// whole upload. Returns once the work is done, which can take a while for a big folder.
    /// Throws `DaemonError.notFound` when it is already gone and `DaemonError.rejected` with a
    /// readable message when it cannot be done.
    func remove(uploadID: String, fileIndexes: [Int], deleteFromBucket: Bool) async throws

    /// Replaces the options that apply to every upload: speed limit, checking and the hold.
    func setOptions(_ options: DaemonOptions) async throws

    /// Stops sending an upload and keeps what was sent. Like every call about one upload
    /// below, it throws `DaemonError.notFound` when the upload is no longer in the history
    /// and `DaemonError.rejected` with a readable message when it cannot be done.
    func pause(uploadID: String) async throws

    /// Puts an upload the user paused back in the queue.
    func resume(uploadID: String) async throws

    /// Stops an upload for good. Files it already sent stay in the bucket and the history.
    func cancel(uploadID: String) async throws

    /// Copies files of an upload from the bucket into `destinationDir` and returns the
    /// download's id. `fileIndexes` empty means every finished file. Nothing on disk is
    /// overwritten.
    func startDownload(uploadID: String, fileIndexes: [Int], destinationDir: String) async throws -> String

    /// Stops a download and removes the file it was writing.
    func cancelDownload(downloadID: String) async throws

    /// Streams download snapshots until the consuming task is cancelled or the daemon fails.
    func watchDownloads() -> AsyncThrowingStream<DownloadSnapshot, Error>

    /// The buckets the access key can see. Works before `configure`. A failure with words
    /// for the user is `DaemonError.rejected`.
    func listBuckets(_ access: AWSAccess) async throws -> [Bucket]

    /// Creates a private bucket in the region of `access`. Works before `configure`. A
    /// problem with the name is `DaemonError.alreadyExists` or `DaemonError.invalidArgument`,
    /// any other failure with words for the user is `DaemonError.rejected`.
    func createBucket(_ access: AWSAccess, name: String) async throws
}
