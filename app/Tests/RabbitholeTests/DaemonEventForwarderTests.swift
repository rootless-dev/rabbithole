import Foundation
import Synchronization
import XCTest

@testable import Rabbithole

private final class ScriptedClient: DaemonClient, Sendable {
    private struct State {
        var configured: [AWSSettings] = []
        var configureCalls = 0
        var inFlight = 0
        var maxInFlight = 0
        var failuresLeft = 0
        var watchCount = 0
        var holdWatch = false
        var gate: CheckedContinuation<Void, Never>?
        var holdConfigure = false
        var hangConfigure = false
        var configureDelay = false
    }

    private let state = Mutex(State())
    var configured: [AWSSettings] { state.withLock { $0.configured } }
    var configureCalls: Int { state.withLock { $0.configureCalls } }
    var maxInFlight: Int { state.withLock { $0.maxInFlight } }
    var watchCount: Int { state.withLock { $0.watchCount } }
    var isHoldingConfigure: Bool { state.withLock { $0.gate != nil } }

    /// The next `count` configure calls throw.
    func failConfigure(times count: Int) { state.withLock { $0.failuresLeft = count } }
    /// Streams stay open until cancelled instead of failing at once.
    func keepWatchesOpen() { state.withLock { $0.holdWatch = true } }
    /// The next configure call suspends until `releaseConfigure()`.
    func holdNextConfigure() { state.withLock { $0.holdConfigure = true } }
    /// Every configure call takes a moment, so overlapping calls would be visible.
    func slowConfigure() { state.withLock { $0.configureDelay = true } }
    /// Configure never returns on its own; it ends only when cancelled.
    func hangConfigure() { state.withLock { $0.hangConfigure = true } }

    func releaseConfigure() {
        let gate = state.withLock { state -> CheckedContinuation<Void, Never>? in
            defer { state.gate = nil }
            return state.gate
        }
        gate?.resume()
    }

    func configure(_ settings: AWSSettings) async throws {
        let (hold, hang, delay) = state.withLock { state -> (Bool, Bool, Bool) in
            state.configureCalls += 1
            state.inFlight += 1
            state.maxInFlight = max(state.maxInFlight, state.inFlight)
            defer { state.holdConfigure = false }
            return (state.holdConfigure, state.hangConfigure, state.configureDelay)
        }
        defer { state.withLock { $0.inFlight -= 1 } }
        if hold {
            await withCheckedContinuation { continuation in
                state.withLock { $0.gate = continuation }
            }
        }
        if hang { try await Task.sleep(for: .seconds(60)) }
        if delay { try await Task.sleep(for: .milliseconds(20)) }
        try state.withLock { state in
            if state.failuresLeft > 0 {
                state.failuresLeft -= 1
                throw DaemonError.unavailable
            }
            state.configured.append(settings)
        }
    }

    func enqueue(localPath: String) async throws -> String { "up-1" }

    func watch() -> AsyncThrowingStream<UploadSnapshot, Error> {
        let hold = state.withLock { state -> Bool in
            state.watchCount += 1
            return state.holdWatch
        }
        if hold { return AsyncThrowingStream { _ in } }
        // Fails at once, like a stream that dies with the daemon.
        return AsyncThrowingStream { $0.finish(throwing: DaemonError.unavailable) }
    }
}

private final class SleepLog: Sendable {
    private let recorded = Mutex<[Duration]>([])
    var durations: [Duration] { recorded.withLock { $0 } }
    func record(_ duration: Duration) { recorded.withLock { $0.append(duration) } }
}

private struct SettingsReadFailure: Error {}

private let sampleSettings = AWSSettings(
    accessKeyID: "AKIAEXAMPLEKEYID", secretAccessKey: "example-secret-value-123",
    region: "us-east-1", bucket: "my-backup-bucket")

private let newSettings = AWSSettings(
    accessKeyID: "AKIANEWKEYID", secretAccessKey: "new-secret-value-456",
    region: "eu-west-1", bucket: "other-bucket")

@MainActor
final class DaemonEventForwarderTests: XCTestCase {
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition(), "condition not met within 3s")
    }

    private struct Rig {
        let forwarder: DaemonEventForwarder
        let events: AsyncStream<DaemonEvent>.Continuation
        let viewModel: TrayViewModel
        let sleeps: SleepLog
    }

    private func makeRig(
        client: ScriptedClient,
        saved: @escaping @Sendable () throws -> AWSSettings?
    ) -> Rig {
        let (events, continuation) = AsyncStream<DaemonEvent>.makeStream()
        let sleeps = SleepLog()
        let viewModel = TrayViewModel(client: client, isRegularFile: { _ in true }, sleep: { _ in })
        let forwarder = DaemonEventForwarder(
            client: client, events: events, viewModel: viewModel,
            loadSettings: saved,
            sleep: { duration in
                sleeps.record(duration)
                // The 3 second attempt timeout stays long enough for a normal configure call.
                try await Task.sleep(for: duration == .seconds(3) ? .milliseconds(150) : .milliseconds(2))
            })
        return Rig(forwarder: forwarder, events: continuation, viewModel: viewModel, sleeps: sleeps)
    }

    func testReadyConfiguresWithSavedSettingsAndWatches() async throws {
        let client = ScriptedClient()
        let rig = makeRig(client: client, saved: { sampleSettings })
        rig.forwarder.start()
        defer { rig.forwarder.stop() }

        rig.events.yield(.ready)

        try await waitUntil { client.configured == [sampleSettings] && client.watchCount >= 1 }
        try await waitUntil { rig.viewModel.state == .idle }
    }

    func testViewModelIsToldConfiguredOnlyAfterConfigureReturns() async throws {
        let client = ScriptedClient()
        client.holdNextConfigure()
        let rig = makeRig(client: client, saved: { sampleSettings })
        rig.forwarder.start()
        defer { rig.forwarder.stop() }

        rig.events.yield(.ready)
        try await waitUntil { client.isHoldingConfigure }
        XCTAssertEqual(rig.viewModel.state, .starting)
        XCTAssertEqual(client.watchCount, 0)

        client.releaseConfigure()

        try await waitUntil { rig.viewModel.state == .idle }
        XCTAssertEqual(client.configured, [sampleSettings])
    }

    func testRestartMarksStartingAtOnceThenIdleAfterConfigure() async throws {
        let client = ScriptedClient()
        client.keepWatchesOpen()
        let rig = makeRig(client: client, saved: { sampleSettings })
        rig.forwarder.start()
        defer { rig.forwarder.stop() }
        rig.events.yield(.ready)
        try await waitUntil { rig.viewModel.state == .idle }

        client.holdNextConfigure()
        rig.events.yield(.restarted)
        try await waitUntil { client.isHoldingConfigure }
        XCTAssertEqual(rig.viewModel.state, .starting)

        client.releaseConfigure()

        try await waitUntil { rig.viewModel.state == .idle }
        XCTAssertEqual(client.configured.count, 2)
    }

    func testFailedWatchStreamsAreRetried() async throws {
        let client = ScriptedClient()
        let rig = makeRig(client: client, saved: { sampleSettings })
        rig.forwarder.start()
        defer { rig.forwarder.stop() }

        rig.events.yield(.ready)

        try await waitUntil { client.watchCount >= 3 }
        XCTAssertTrue(rig.sleeps.durations.contains(.milliseconds(500)))
    }

    func testNilSettingsSkipConfigureMarkNotConfiguredAndStartTheWatch() async throws {
        let client = ScriptedClient()
        let rig = makeRig(client: client, saved: { nil })
        rig.forwarder.start()
        defer { rig.forwarder.stop() }

        rig.events.yield(.ready)

        try await waitUntil { client.watchCount >= 1 && rig.viewModel.state == .notConfigured }
        XCTAssertEqual(client.configureCalls, 0)
    }

    func testConfigureIsRetriedEveryHalfSecondUpToFiveAttempts() async throws {
        let client = ScriptedClient()
        client.keepWatchesOpen()
        client.failConfigure(times: 4)
        let rig = makeRig(client: client, saved: { sampleSettings })
        rig.forwarder.start()
        defer { rig.forwarder.stop() }

        rig.events.yield(.ready)

        try await waitUntil { rig.viewModel.state == .idle }
        XCTAssertEqual(client.configureCalls, 5)
        XCTAssertEqual(rig.sleeps.durations.filter { $0 == .milliseconds(500) }.count, 4)
    }

    func testUnavailableAfterFiveFailedConfigureAttempts() async throws {
        let client = ScriptedClient()
        client.failConfigure(times: 99)
        let rig = makeRig(client: client, saved: { sampleSettings })
        rig.forwarder.start()
        defer { rig.forwarder.stop() }

        rig.events.yield(.ready)

        try await waitUntil { rig.viewModel.state == .unavailable }
        XCTAssertEqual(client.configureCalls, 5)
        XCTAssertEqual(client.watchCount, 0)
    }

    func testAttemptThatNeverReturnsIsAbandonedAfterTheThreeSecondTimeoutAndCounted() async throws {
        let client = ScriptedClient()
        client.hangConfigure()
        let rig = makeRig(client: client, saved: { sampleSettings })
        rig.forwarder.start()
        defer { rig.forwarder.stop() }

        rig.events.yield(.ready)

        try await waitUntil { rig.viewModel.state == .unavailable }
        XCTAssertEqual(client.configureCalls, 5)
        XCTAssertEqual(rig.sleeps.durations.filter { $0 == .seconds(3) }.count, 5)
    }

    func testThrownSettingsReadShowsFailedStateAndDoesNotConfigure() async throws {
        let client = ScriptedClient()
        let rig = makeRig(client: client, saved: { throw SettingsReadFailure() })
        rig.forwarder.start()
        defer { rig.forwarder.stop() }

        try await waitUntil {
            rig.viewModel.state == .failed("Saved AWS settings could not be read")
        }
        rig.events.yield(.ready)
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(client.configureCalls, 0)
        XCTAssertEqual(rig.viewModel.state, .failed("Saved AWS settings could not be read"))

        // A later save recovers normally.
        rig.forwarder.settingsChanged(newSettings)
        try await waitUntil { rig.viewModel.state == .idle }
        XCTAssertEqual(client.configured, [newSettings])
    }

    func testSaveDuringAFailingRetryLoopEndsWithTheNewSettingsAndIdle() async throws {
        let client = ScriptedClient()
        client.keepWatchesOpen()
        client.holdNextConfigure()
        client.failConfigure(times: 5)
        let rig = makeRig(client: client, saved: { sampleSettings })
        rig.forwarder.start()
        defer { rig.forwarder.stop() }

        rig.events.yield(.ready)
        try await waitUntil { client.isHoldingConfigure }
        rig.forwarder.settingsChanged(newSettings)
        client.releaseConfigure()

        try await waitUntil { rig.viewModel.state == .idle }
        XCTAssertEqual(client.configured, [newSettings])
        XCTAssertEqual(client.configureCalls, 6)
    }

    func testConfigureCallsNeverOverlap() async throws {
        let client = ScriptedClient()
        client.keepWatchesOpen()
        client.slowConfigure()
        let rig = makeRig(client: client, saved: { sampleSettings })
        rig.forwarder.start()
        defer { rig.forwarder.stop() }

        rig.events.yield(.ready)
        try await waitUntil { client.configureCalls == 1 }  // in flight now
        rig.forwarder.settingsChanged(newSettings)  // queued behind it
        rig.events.yield(.restarted)

        try await waitUntil { client.configureCalls == 3 && rig.viewModel.state == .idle }
        XCTAssertEqual(client.maxInFlight, 1)
        XCTAssertEqual(client.configured.last, newSettings)
    }

    func testSuccessfulSaveStartsTheWatchWhenNoneIsRunning() async throws {
        let client = ScriptedClient()
        client.keepWatchesOpen()
        client.failConfigure(times: 5)
        let rig = makeRig(client: client, saved: { sampleSettings })
        rig.forwarder.start()
        defer { rig.forwarder.stop() }
        rig.events.yield(.ready)
        try await waitUntil { rig.viewModel.state == .unavailable }
        XCTAssertEqual(client.watchCount, 0)

        rig.forwarder.settingsChanged(newSettings)

        try await waitUntil { rig.viewModel.state == .idle }
        XCTAssertEqual(client.watchCount, 1)
    }

    func testNoWatchStartsWhenStoppedDuringConfigure() async throws {
        let client = ScriptedClient()
        client.holdNextConfigure()
        let rig = makeRig(client: client, saved: { sampleSettings })
        rig.forwarder.start()
        rig.events.yield(.ready)
        try await waitUntil { client.isHoldingConfigure }

        rig.forwarder.stop()
        client.releaseConfigure()
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(client.watchCount, 0)
        XCTAssertEqual(rig.viewModel.state, .starting)
    }
}
