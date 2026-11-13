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
}
