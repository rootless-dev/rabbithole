import Foundation

/// S3 destination settings handed to the daemon.
struct AWSSettings: Equatable, Sendable {
    var accessKeyID: String
    var secretAccessKey: String
    var region: String
    var bucket: String

    /// Where quick uploads land in the bucket, sent to the daemon with every configuration.
    var uploadsPrefix: String = AWSSettings.quickUploadsPrefix

    /// The default quick uploads folder.
    static let quickUploadsPrefix = "quick-uploads/"

    /// A folder name as the daemon expects it: trimmed, no leading slash, one trailing slash.
    /// Returns the default when nothing usable is left.
    static func normalizedPrefix(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasPrefix("/") { value.removeFirst() }
        while value.hasSuffix("/") { value.removeLast() }
        return value.isEmpty ? quickUploadsPrefix : value + "/"
    }
}

enum UploadState: Equatable, Sendable {
    case queued, uploading, finished, failed
}

/// What was handed over as one upload.
enum UploadKind: Equatable, Sendable {
    case singleFile, folder, multiple
}

struct UploadSnapshot: Equatable, Sendable {
    let id: String
    /// The file name, the folder name, or the name of the first item of several.
    let fileName: String
    /// The first path the upload was enqueued with.
    let localPath: String
    /// The key of a single file, the key prefix (ending in "/") of a folder, empty for several items.
    let objectKey: String
    /// Sums over every file of the upload.
    let bytesTotal: Int64
    let bytesSent: Int64
    let state: UploadState
    let errorMessage: String
    let kind: UploadKind
    /// Every path the upload was enqueued with, in order.
    let rootPaths: [String]
    let filesTotal: Int
    let filesFinished: Int
    let filesFailed: Int

    init(
        id: String, fileName: String, localPath: String, objectKey: String, bytesTotal: Int64,
        bytesSent: Int64, state: UploadState, errorMessage: String, kind: UploadKind = .singleFile,
        rootPaths: [String]? = nil, filesTotal: Int = 1, filesFinished: Int? = nil, filesFailed: Int = 0
    ) {
        self.id = id
        self.fileName = fileName
        self.localPath = localPath
        self.objectKey = objectKey
        self.bytesTotal = bytesTotal
        self.bytesSent = bytesSent
        self.state = state
        self.errorMessage = errorMessage
        self.kind = kind
        self.rootPaths = rootPaths ?? [localPath]
        self.filesTotal = filesTotal
        self.filesFinished = filesFinished ?? (state == .finished ? filesTotal : 0)
        self.filesFailed = filesFailed
    }
}

/// One file of an upload, as the daemon's files stream reports it.
struct FileSnapshot: Equatable, Sendable {
    let uploadID: String
    /// Position of the file inside its upload, stable for the upload's life.
    let index: Int
    /// The file name for a file handed over directly, "<folder name>/<path inside it>" for a
    /// file found inside a folder.
    let relativePath: String
    let localPath: String
    let objectKey: String
    let bytesTotal: Int64
    let bytesSent: Int64
    let state: UploadState
    let errorMessage: String
}

/// What one enqueue call hands to the daemon: the files and folders that become one upload
/// and the two preferences that shape it.
struct EnqueueRequest: Equatable, Sendable {
    var paths: [String]
    /// Name patterns of files and folders left out when a folder is walked.
    var skipPatterns: [String] = []
    /// How many files are sent at the same time; zero lets the daemon decide.
    var parallelFiles: Int = 0
}

/// Failures reported by a `DaemonClient`, independent of the transport underneath.
enum DaemonError: Error, Equatable, Sendable {
    /// The daemon has no AWS settings yet (`Configure` has not succeeded).
    case notConfigured
    /// The daemon rejected the request payload; carries the daemon's message.
    case invalidArgument(String)
    /// The daemon is not reachable (not started, restarting or crashed).
    case unavailable
    /// The daemon does not know the upload that was asked for.
    case notFound
    /// Anything else, including malformed responses.
    case other(String)
}
