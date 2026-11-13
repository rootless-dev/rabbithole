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
}
