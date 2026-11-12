import Foundation

/// The app's view of the upload daemon. Implementations must not block the main actor.
protocol DaemonClient: Sendable {
    /// Supplies AWS settings. Throws `DaemonError.invalidArgument` when a required field is empty.
    func configure(_ settings: AWSSettings) async throws

    /// Queues a local file and returns the upload id.
    /// Throws `DaemonError.notConfigured` before a successful `configure`.
    func enqueue(localPath: String) async throws -> String

    /// Streams upload snapshots until the consuming task is cancelled or the daemon fails.
    func watch() -> AsyncThrowingStream<UploadSnapshot, Error>
}
