import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import GRPCProtobuf

/// `DaemonClient` over gRPC on the daemon's Unix domain socket.
///
/// The connection is established lazily and re-established by the transport, so
/// the daemon may start after this object or restart while it lives. Calls made
/// while the socket does not accept connections fail with `DaemonError.unavailable`.
/// Generated and gRPC types stay inside this file.
final class GRPCDaemonClient: DaemonClient {
    private typealias Stub = Rabbithole_V1_Daemon.Client<HTTP2ClientTransport.Posix>

    private let stub: Stub?
    private let grpcClient: GRPCClient<HTTP2ClientTransport.Posix>?
    private let connectionTask: Task<Void, Never>?
    private let setupError: String?

    init(socketPath: String) {
        do {
            let transport = try HTTP2ClientTransport.Posix(
                target: .unixDomainSocket(path: socketPath, authority: nil),
                transportSecurity: .plaintext,
                config: .defaults { config in
                    // The client outlives daemon restarts and the app's configure
                    // retries give up after about 2.5 s, so reconnect quickly
                    // instead of using the library's 1 s to 120 s backoff.
                    config.backoff = .init(
                        initial: .milliseconds(100), max: .seconds(1), multiplier: 1.6, jitter: 0.2)
                })
            let client = GRPCClient(transport: transport)
            grpcClient = client
            stub = Stub(wrapping: client)
            connectionTask = Task { try? await client.runConnections() }
            setupError = nil
        } catch {
            grpcClient = nil
            stub = nil
            connectionTask = nil
            setupError = "\(error)"
        }
    }

    deinit {
        grpcClient?.beginGracefulShutdown()
        connectionTask?.cancel()
    }

    private func requireStub() throws -> Stub {
        guard let stub else { throw DaemonError.other(setupError ?? "client not initialised") }
        return stub
    }

    // MARK: DaemonClient

    func configure(_ settings: AWSSettings) async throws {
        let stub = try requireStub()
        var request = Rabbithole_V1_ConfigureRequest()
        request.accessKeyID = settings.accessKeyID
        request.secretAccessKey = settings.secretAccessKey
        request.region = settings.region
        request.bucket = settings.bucket
        request.quickUploadsPrefix = AWSSettings.normalizedPrefix(settings.uploadsPrefix)
        do {
            _ = try await stub.configure(request)
        } catch {
            throw Self.map(error)
        }
    }

    func enqueue(_ request: EnqueueRequest) async throws -> String {
        let stub = try requireStub()
        var message = Rabbithole_V1_EnqueueUploadRequest()
        message.localPaths = request.paths
        // The daemon ignores this when `local_paths` is set; it keeps a single file working
        // against a daemon from before uploads could hold several paths.
        message.localPath = request.paths.first ?? ""
        message.skipPatterns = request.skipPatterns
        message.parallelFiles = Int32(clamping: max(request.parallelFiles, 0))
        do {
            return try await stub.enqueueUpload(message).uploadID
        } catch {
            throw Self.map(error)
        }
    }

    func watch() -> AsyncThrowingStream<UploadSnapshot, Error> {
        stream { stub, yield in
            try await stub.watchUploads(Rabbithole_V1_WatchUploadsRequest()) { response in
                for try await message in response.messages {
                    yield(try UploadSnapshot(message))
                }
            }
        }
    }

    func watchFiles(uploadID: String) -> AsyncThrowingStream<FileSnapshot, Error> {
        stream { stub, yield in
            var request = Rabbithole_V1_WatchUploadFilesRequest()
            request.uploadID = uploadID
            try await stub.watchUploadFiles(request) { response in
                for try await message in response.messages {
                    yield(try FileSnapshot(message))
                }
            }
        }
    }

    func retry(uploadID: String, fileIndexes: [Int]) async throws {
        let stub = try requireStub()
        var request = Rabbithole_V1_RetryUploadRequest()
        request.uploadID = uploadID
        request.fileIndexes = fileIndexes.map { Int32(clamping: $0) }
        do {
            _ = try await stub.retryUpload(request)
        } catch {
            throw Self.map(error, ofUploadAction: true)
        }
    }

    func remove(uploadID: String, fileIndexes: [Int], deleteFromBucket: Bool) async throws {
        let stub = try requireStub()
        var request = Rabbithole_V1_RemoveUploadRequest()
        request.uploadID = uploadID
        request.fileIndexes = fileIndexes.map { Int32(clamping: $0) }
        request.deleteFromBucket = deleteFromBucket
        do {
            _ = try await stub.removeUpload(request)
        } catch {
            throw Self.map(error, ofUploadAction: true)
        }
    }

    /// Runs a server-streaming call in a task that lives as long as the returned stream is
    /// consumed. Cancelling the consumer ends the call quietly; any other failure is mapped.
    private func stream<Element: Sendable>(
        _ call: @escaping @Sendable (Stub, @escaping @Sendable (Element) -> Void) async throws -> Void
    ) -> AsyncThrowingStream<Element, Error> {
        let stub = stub
        let setupError = setupError
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let stub else { throw DaemonError.other(setupError ?? "client not initialised") }
                    try await call(stub) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    if Task.isCancelled {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: Self.map(error))
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Error mapping

    private static func map(_ error: any Error, ofUploadAction: Bool = false) -> DaemonError {
        if let daemonError = error as? DaemonError { return daemonError }
        if let rpcError = error as? RPCError {
            if ofUploadAction {
                return mapUploadAction(
                    code: rpcError.code, message: rpcError.message, fromDaemon: rpcError.cause == nil)
            }
            switch rpcError.code {
            case .failedPrecondition: return .notConfigured
            case .invalidArgument: return .invalidArgument(rpcError.message)
            case .unavailable: return .unavailable
            case .notFound: return .notFound
            default: return .other("\(rpcError.code): \(rpcError.message)")
            }
        }
        return .other("\(error)")
    }

    /// The mapping for RetryUpload and RemoveUpload. Whatever the daemon answers with a
    /// message is something to show the user as it is (not allowed in the current state, a
    /// missing bucket permission, no connection), so the message survives under any status
    /// code. `fromDaemon` is false when the transport produced the error by itself: then
    /// "unavailable" means the daemon could not be reached, and its text is not for reading.
    static func mapUploadAction(code: RPCError.Code, message: String, fromDaemon: Bool) -> DaemonError {
        switch code {
        case .notFound:
            return .notFound
        case .unavailable where !fromDaemon || message.isEmpty:
            return .unavailable
        case .unimplemented, .cancelled, .deadlineExceeded:
            return .other("\(code): \(message)")
        default:
            return message.isEmpty ? .other("\(code)") : .rejected(message)
        }
    }
}

extension UploadState {
    /// Maps a wire state. An unspecified or unrecognised state is a protocol violation, so it
    /// throws rather than guessing a state.
    fileprivate init(_ state: Rabbithole_V1_UploadState, of what: String) throws {
        switch state {
        case .queued: self = .queued
        case .uploading: self = .uploading
        case .finished: self = .finished
        case .failed: self = .failed
        case .unspecified, .UNRECOGNIZED:
            throw DaemonError.other("\(what) has unspecified or unknown state")
        }
    }
}

extension UploadSnapshot {
    /// Maps a wire message; see `UploadState.init` for the states that throw. A message
    /// without a kind comes from a daemon that only knows single files and is read as one.
    init(_ message: Rabbithole_V1_UploadSnapshot) throws {
        // The last word about an upload that left the history: nothing but its id matters,
        // so its state is not held to the rule below.
        if message.removed {
            self = .removed(id: message.uploadID)
            return
        }
        let state = try UploadState(message.state, of: "snapshot \(message.uploadID)")
        let kind: UploadKind
        switch message.kind {
        case .singleFile: kind = .singleFile
        case .folder: kind = .folder
        case .multiple: kind = .multiple
        case .unspecified, .UNRECOGNIZED:
            self.init(
                id: message.uploadID, fileName: message.fileName, localPath: message.localPath,
                objectKey: message.objectKey, bytesTotal: message.bytesTotal,
                bytesSent: message.bytesSent, state: state, errorMessage: message.errorMessage,
                createdAt: Self.date(milliseconds: message.createdAtMs),
                endedAt: Self.date(milliseconds: message.endedAtMs))
            return
        }
        self.init(
            id: message.uploadID,
            fileName: message.fileName,
            localPath: message.localPath,
            objectKey: message.objectKey,
            bytesTotal: message.bytesTotal,
            bytesSent: message.bytesSent,
            state: state,
            errorMessage: message.errorMessage,
            kind: kind,
            rootPaths: message.rootPaths.isEmpty ? [message.localPath] : message.rootPaths,
            filesTotal: Int(message.filesTotal),
            filesFinished: Int(message.filesFinished),
            filesFailed: Int(message.filesFailed),
            createdAt: Self.date(milliseconds: message.createdAtMs),
            endedAt: Self.date(milliseconds: message.endedAtMs))
    }

    /// A wire time in milliseconds since the Unix epoch; zero means it was not set.
    static func date(milliseconds: Int64) -> Date? {
        milliseconds > 0 ? Date(timeIntervalSince1970: Double(milliseconds) / 1000) : nil
    }
}

extension FileSnapshot {
    init(_ message: Rabbithole_V1_FileSnapshot) throws {
        if message.removed {
            self = .removed(uploadID: message.uploadID, index: Int(message.index))
            return
        }
        self.init(
            uploadID: message.uploadID,
            index: Int(message.index),
            relativePath: message.relativePath,
            localPath: message.localPath,
            objectKey: message.objectKey,
            bytesTotal: message.bytesTotal,
            bytesSent: message.bytesSent,
            state: try UploadState(message.state, of: "file \(message.index) of \(message.uploadID)"),
            errorMessage: message.errorMessage)
    }
}
