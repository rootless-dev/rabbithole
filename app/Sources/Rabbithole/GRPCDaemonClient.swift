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
                transportSecurity: .plaintext)
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
        do {
            _ = try await stub.configure(request)
        } catch {
            throw Self.map(error)
        }
    }

    func enqueue(localPath: String) async throws -> String {
        let stub = try requireStub()
        var request = Rabbithole_V1_EnqueueUploadRequest()
        request.localPath = localPath
        do {
            return try await stub.enqueueUpload(request).uploadID
        } catch {
            throw Self.map(error)
        }
    }

    func watch() -> AsyncThrowingStream<UploadSnapshot, Error> {
        let stub = stub
        let setupError = setupError
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let stub else { throw DaemonError.other(setupError ?? "client not initialised") }
                    try await stub.watchUploads(Rabbithole_V1_WatchUploadsRequest()) { response in
                        for try await message in response.messages {
                            continuation.yield(try UploadSnapshot(message))
                        }
                    }
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

    private static func map(_ error: any Error) -> DaemonError {
        if let daemonError = error as? DaemonError { return daemonError }
        if let rpcError = error as? RPCError {
            switch rpcError.code {
            case .failedPrecondition: return .notConfigured
            case .invalidArgument: return .invalidArgument(rpcError.message)
            case .unavailable: return .unavailable
            default: return .other("\(rpcError.code): \(rpcError.message)")
            }
        }
        return .other("\(error)")
    }
}

extension UploadSnapshot {
    /// Maps a wire message. An unspecified or unrecognised state is a protocol
    /// violation, so it throws rather than guessing a state.
    init(_ message: Rabbithole_V1_UploadSnapshot) throws {
        let state: UploadState
        switch message.state {
        case .queued: state = .queued
        case .uploading: state = .uploading
        case .finished: state = .finished
        case .failed: state = .failed
        case .unspecified, .UNRECOGNIZED:
            throw DaemonError.other("snapshot \(message.uploadID) has unspecified or unknown state")
        }
        self.init(
            id: message.uploadID,
            fileName: message.fileName,
            localPath: message.localPath,
            objectKey: message.objectKey,
            bytesTotal: message.bytesTotal,
            bytesSent: message.bytesSent,
            state: state,
            errorMessage: message.errorMessage)
    }
}
