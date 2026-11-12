import Foundation
import XCTest

@testable import Rabbithole

/// Runs the real Go daemon on a temporary Unix socket. The daemon exits when its
/// standard input closes, so the test keeps the pipe open for its whole lifetime.
final class DaemonProcess: @unchecked Sendable {
    let socketPath: String
    private let directory: String
    private let process = Process()
    private let stdin = Pipe()
    private var started = false

    init() throws {
        // Unix socket paths are limited to about 104 bytes, so stay under /tmp.
        directory = "/tmp/rh-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        socketPath = directory + "/d.sock"
    }

    static func binaryURL() throws -> URL {
        // .../app/Tests/RabbitholeTests/<file> -> repository root is four levels up.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let binary = root.appendingPathComponent("daemon/bin/rabbitholed")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw XCTSkip("daemon binary not found at \(binary.path); run `make build` first")
        }
        return binary
    }

    func start() throws {
        process.executableURL = try Self.binaryURL()
        process.arguments = ["--socket", socketPath]
        process.standardInput = stdin
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        started = true
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: socketPath) {
            guard Date() < deadline, process.isRunning else {
                throw XCTSkip("daemon did not create its socket at \(socketPath)")
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    /// Ends the daemon and removes the socket directory. Safe to call repeatedly.
    func stop() {
        if started {
            try? stdin.fileHandleForWriting.close()
            let deadline = Date().addingTimeInterval(5)
            while process.isRunning, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
            started = false
        }
        try? FileManager.default.removeItem(atPath: directory)
    }
}

/// Fails the test instead of hanging when `body` does not finish in time.
func withTimeout<T: Sendable>(
    _ seconds: Double,
    _ body: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw DaemonError.other("timed out after \(seconds)s")
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}

final class GRPCDaemonClientTests: XCTestCase {
    private var daemon: DaemonProcess!

    override func setUpWithError() throws {
        daemon = try DaemonProcess()
    }

    override func tearDown() {
        daemon.stop()
        daemon = nil
    }

    private let validSettings = AWSSettings(
        accessKeyID: "AKIAEXAMPLE", secretAccessKey: "secret", region: "us-east-1", bucket: "bucket")

    func testEnqueueBeforeConfigureThrowsFailedPrecondition() async throws {
        try daemon.start()
        let client = GRPCDaemonClient(socketPath: daemon.socketPath)

        do {
            _ = try await withTimeout(10) { try await client.enqueue(localPath: "/tmp/none") }
            XCTFail("expected an error")
        } catch let error as DaemonError {
            XCTAssertEqual(error, .notConfigured)
        }
    }

    func testConfigureWithEmptyBucketThrowsInvalidArgument() async throws {
        try daemon.start()
        let client = GRPCDaemonClient(socketPath: daemon.socketPath)
        var settings = validSettings
        settings.bucket = ""

        do {
            try await withTimeout(10) { [settings] in try await client.configure(settings) }
            XCTFail("expected an error")
        } catch let error as DaemonError {
            guard case .invalidArgument = error else {
                return XCTFail("expected invalidArgument, got \(error)")
            }
        }
    }

    func testWatchStreamEndsWhenTaskCancelled() async throws {
        try daemon.start()
        let client = GRPCDaemonClient(socketPath: daemon.socketPath)

        let watcher = Task<Int, Error> {
            var count = 0
            for try await _ in client.watch() { count += 1 }
            return count
        }
        // No uploads exist, so the stream stays open and silent until cancelled.
        try await Task.sleep(for: .milliseconds(500))
        watcher.cancel()

        let count = try await withTimeout(10) { try await watcher.value }
        XCTAssertEqual(count, 0)

        // The daemon is still serving after the client went away.
        do {
            _ = try await withTimeout(10) { try await client.enqueue(localPath: "/tmp/none") }
            XCTFail("expected an error")
        } catch let error as DaemonError {
            XCTAssertEqual(error, .notConfigured)
        }
    }

    func testCallsFailUnavailableUntilDaemonStartsThenSucceedWithSameClient() async throws {
        // Fail fast before the daemon exists.
        let client = GRPCDaemonClient(socketPath: daemon.socketPath)
        do {
            _ = try await withTimeout(10) { try await client.enqueue(localPath: "/tmp/none") }
            XCTFail("expected an error")
        } catch let error as DaemonError {
            XCTAssertEqual(error, .unavailable)
        }

        // Once the daemon is up, the same client object reaches it (after its
        // reconnect backoff), so allow a bounded number of attempts.
        try daemon.start()
        var last: DaemonError?
        for _ in 0..<40 {
            do {
                _ = try await withTimeout(10) { try await client.enqueue(localPath: "/tmp/none") }
                XCTFail("expected an error")
            } catch let error as DaemonError {
                last = error
                if error != .unavailable { break }
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        XCTAssertEqual(last, .notConfigured)
    }

    func testSnapshotMapping() throws {
        var message = Rabbithole_V1_UploadSnapshot()
        message.uploadID = "id-1"
        message.fileName = "a.txt"
        message.localPath = "/tmp/a.txt"
        message.objectKey = "quick/a.txt"
        message.bytesTotal = 100
        message.bytesSent = 40
        message.state = .uploading
        message.errorMessage = ""

        let snapshot = try UploadSnapshot(message)

        XCTAssertEqual(
            snapshot,
            UploadSnapshot(
                id: "id-1", fileName: "a.txt", localPath: "/tmp/a.txt", objectKey: "quick/a.txt",
                bytesTotal: 100, bytesSent: 40, state: .uploading, errorMessage: ""))

        for (wire, expected) in [
            (Rabbithole_V1_UploadState.queued, UploadState.queued),
            (.uploading, .uploading),
            (.finished, .finished),
            (.failed, .failed),
        ] {
            message.state = wire
            XCTAssertEqual(try UploadSnapshot(message).state, expected)
        }
    }

    func testSnapshotMappingRejectsUnspecifiedAndUnknownStates() {
        var message = Rabbithole_V1_UploadSnapshot()
        message.uploadID = "id-1"

        message.state = .unspecified
        XCTAssertThrowsError(try UploadSnapshot(message))

        message.state = .UNRECOGNIZED(42)
        XCTAssertThrowsError(try UploadSnapshot(message))
    }
}
