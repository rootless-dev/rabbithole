import Foundation
import Synchronization
import XCTest

@testable import Rabbithole

private final class ScriptedClient: DaemonClient, Sendable {
    private struct State {
        var configured: [AWSSettings] = []
        var watchCount = 0
    }

    private let state = Mutex(State())
    var configured: [AWSSettings] { state.withLock { $0.configured } }
    var watchCount: Int { state.withLock { $0.watchCount } }

    func configure(_ settings: AWSSettings) async throws {
        state.withLock { $0.configured.append(settings) }
    }

    func enqueue(localPath: String) async throws -> String { "up-1" }

    /// Each subscription fails at once, like a stream that dies with the daemon.
    func watch() -> AsyncThrowingStream<UploadSnapshot, Error> {
        state.withLock { $0.watchCount += 1 }
        return AsyncThrowingStream { $0.finish(throwing: DaemonError.unavailable) }
    }
}

@MainActor
final class DaemonEventForwarderTests: XCTestCase {
    private let settings = AWSSettings(
        accessKeyID: "AKIAEXAMPLEKEYID", secretAccessKey: "example-secret-value-123",
        region: "us-east-1", bucket: "my-backup-bucket")

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !condition(), Date() < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition(), "condition not met within 2s")
    }

    private func makeForwarder(
        client: ScriptedClient, saved: AWSSettings?
    ) -> (DaemonEventForwarder, AsyncStream<DaemonEvent>.Continuation) {
        let (events, continuation) = AsyncStream<DaemonEvent>.makeStream()
        let viewModel = TrayViewModel(
            client: client, settings: saved, isRegularFile: { _ in true },
            sleep: { _ in })
        let forwarder = DaemonEventForwarder(
            client: client, events: events, viewModel: viewModel,
            retryDelay: .milliseconds(10), loadSettings: { saved })
        return (forwarder, continuation)
    }

    func testReadyConfiguresWithSavedSettingsAndWatches() async throws {
        let client = ScriptedClient()
        let (forwarder, events) = makeForwarder(client: client, saved: settings)
        forwarder.start()
        defer { forwarder.stop() }

        events.yield(.ready)

        try await waitUntil { client.configured == [self.settings] && client.watchCount >= 1 }
    }

    func testRestartConfiguresAgainAndWatchResubscribesAfterFailure() async throws {
        let client = ScriptedClient()
        let (forwarder, events) = makeForwarder(client: client, saved: settings)
        forwarder.start()
        defer { forwarder.stop() }

        events.yield(.ready)
        try await waitUntil { client.watchCount >= 3 }  // failed streams are retried
        events.yield(.restarted)

        try await waitUntil { client.configured.count == 2 }
    }

    func testNoSavedSettingsMeansNoConfigureCall() async throws {
        let client = ScriptedClient()
        let (forwarder, events) = makeForwarder(client: client, saved: nil)
        forwarder.start()
        defer { forwarder.stop() }

        events.yield(.ready)

        try await waitUntil { client.watchCount >= 1 }
        XCTAssertTrue(client.configured.isEmpty)
    }
}
