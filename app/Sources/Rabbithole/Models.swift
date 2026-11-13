import Foundation

/// S3 destination settings handed to the daemon.
struct AWSSettings: Equatable, Sendable {
    var accessKeyID: String
    var secretAccessKey: String
    var region: String
    var bucket: String

    /// Where quick uploads land in the bucket, sent to the daemon with every configuration.
    var uploadsPrefix: String = AWSSettings.quickUploadsPrefix

    /// Ask the daemon to put uploads that a previous exit cut off back in the queue. It is
    /// the "Resume uploads automatically" preference, added when the settings are sent; it
    /// is not saved with them.
    var resumeInterrupted = false

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
    /// Not sending, with what was already sent kept: paused by the user, or held with every
    /// other upload. It goes back to `queued` when that ends.
    case paused
    /// Stopped for good by the user. Files already sent stay; like `failed` it can be retried.
    case canceled

    /// Finished, failed or canceled: nothing more happens to it by itself.
    var hasEnded: Bool { self == .finished || self == .failed || self == .canceled }
}

/// Why an upload is paused.
enum PauseReason: Equatable, Sendable {
    /// The user paused this upload.
    case byUser
    /// Every upload is on hold, which the app asks for while the Mac runs on battery.
    case onHold
}

/// The options that apply to every upload. They are always sent together.
struct DaemonOptions: Equatable, Sendable {
    /// The most bytes per second all uploads together may send; zero means no limit.
    var speedLimitBytesPerSecond: Int64 = 0
    /// Have S3 check every upload against a checksum of the local file.
    var verifyUploads = false
    /// Nothing is sent while this is set.
    var holdUploads = false
}

enum DownloadState: Equatable, Sendable {
    case queued, downloading, finished, failed, canceled

    var isActive: Bool { self == .queued || self == .downloading }
}

/// One download of an upload's files back to this Mac, as the daemon's downloads stream
/// reports it. Downloads are not part of the history: they are gone when the daemon exits.
struct DownloadSnapshot: Equatable, Sendable {
    let id: String
    let uploadID: String
    /// The files being downloaded, by `FileSnapshot.index`.
    let fileIndexes: [Int]
    /// The file name or the folder name.
    let name: String
    /// Where the result is: the file for a single file, the folder otherwise.
    let destinationPath: String
    let bytesTotal: Int64
    let bytesDone: Int64
    var filesTotal = 1
    var filesDone = 0
    var filesFailed = 0
    let state: DownloadState
    var errorMessage = ""

    /// Progress from 0 to 1. A finished download is always 1.
    var fraction: Double {
        if state == .finished { return 1 }
        guard bytesTotal > 0 else { return 0 }
        return min(max(Double(bytesDone) / Double(bytesTotal), 0), 1)
    }

    /// The folder the result was written into.
    var destinationFolder: String { (destinationPath as NSString).deletingLastPathComponent }
}

/// A bucket of the account, as `ListBuckets` reports it.
struct Bucket: Equatable, Sendable {
    let name: String
    /// The region the bucket lives in; empty when it could not be read.
    let region: String
}

/// The credentials and region the bucket calls take, so they work before anything is saved.
/// Never logged and never part of an error text.
struct AWSAccess: Equatable, Sendable {
    var accessKeyID: String
    var secretAccessKey: String
    var region: String
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
    /// True on the last snapshot of an upload that left the history. Only `id` means anything
    /// then.
    let removed: Bool
    /// When the upload was enqueued, by the daemon's record; nil when it did not say.
    let createdAt: Date?
    /// When the upload finished or failed, by the daemon's record; nil while it has not ended
    /// or when the daemon did not say.
    let endedAt: Date?
    /// Why the upload is paused; nil in any other state, or when the daemon did not say.
    let pauseReason: PauseReason?

    init(
        id: String, fileName: String, localPath: String, objectKey: String, bytesTotal: Int64,
        bytesSent: Int64, state: UploadState, errorMessage: String, kind: UploadKind = .singleFile,
        rootPaths: [String]? = nil, filesTotal: Int = 1, filesFinished: Int? = nil, filesFailed: Int = 0,
        removed: Bool = false, createdAt: Date? = nil, endedAt: Date? = nil, pauseReason: PauseReason? = nil
    ) {
        self.pauseReason = state == .paused ? pauseReason : nil
        self.removed = removed
        self.createdAt = createdAt
        self.endedAt = endedAt
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

    /// The last snapshot of an upload that left the history.
    static func removed(id: String) -> UploadSnapshot {
        UploadSnapshot(
            id: id, fileName: "", localPath: "", objectKey: "", bytesTotal: 0, bytesSent: 0,
            state: .failed, errorMessage: "", removed: true)
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
    /// True on the last snapshot of a file that left its upload. Only `uploadID` and `index`
    /// mean anything then.
    var removed = false

    /// The last snapshot of a file that left its upload.
    static func removed(uploadID: String, index: Int) -> FileSnapshot {
        FileSnapshot(
            uploadID: uploadID, index: index, relativePath: "", localPath: "", objectKey: "",
            bytesTotal: 0, bytesSent: 0, state: .failed, errorMessage: "", removed: true)
    }
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
    /// The daemon would not or could not do what was asked of an upload (not allowed in its
    /// current state, a missing bucket permission, no connection); carries the daemon's
    /// readable message.
    case rejected(String)
    /// What was asked to be created already exists (a bucket name that is taken); carries
    /// the daemon's readable message.
    case alreadyExists(String)
    /// Anything else, including malformed responses.
    case other(String)
}
