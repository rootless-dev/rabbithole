import Foundation

/// S3 destination settings handed to the daemon.
struct AWSSettings: Equatable, Sendable {
    var accessKeyID: String
    var secretAccessKey: String
    var region: String
    var bucket: String
}

enum UploadState: Equatable, Sendable {
    case queued, uploading, finished, failed
}

struct UploadSnapshot: Equatable, Sendable {
    let id: String
    let fileName: String
    let localPath: String
    let objectKey: String
    let bytesTotal: Int64
    let bytesSent: Int64
    let state: UploadState
    let errorMessage: String
}

/// Failures reported by a `DaemonClient`, independent of the transport underneath.
enum DaemonError: Error, Equatable, Sendable {
    /// The daemon has no AWS settings yet (`Configure` has not succeeded).
    case notConfigured
    /// The daemon rejected the request payload; carries the daemon's message.
    case invalidArgument(String)
    /// The daemon is not reachable (not started, restarting or crashed).
    case unavailable
    /// Anything else, including malformed responses.
    case other(String)
}
