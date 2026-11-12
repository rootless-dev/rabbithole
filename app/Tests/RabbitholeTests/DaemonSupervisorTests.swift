import Foundation
import Synchronization
import XCTest

@testable import Rabbithole

// The test module already has a `DaemonProcess` class (GRPCDaemonClientTests), so the
// app's protocol is always spelled `Rabbithole.DaemonProcess` here.

private final class FakeProcess: Rabbithole.DaemonProcess, Sendable {
    let terminationEvents: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private let terminations = Mutex(0)

    init() {
        (terminationEvents, continuation) = AsyncStream<Void>.makeStream()
    }

    var terminateCount: Int { terminations.withLock { $0 } }

    func terminate() {
        terminations.withLock { $0 += 1 }
        exit()
    }

    /// Simulates the daemon dying on its own.
    func crash() { exit() }

    private func exit() {
        continuation.yield(())
        continuation.finish()
    }
}

private final class FakeLauncher: ProcessLauncher, Sendable {
    struct LaunchError: Error {}

    private struct State {
        var launches: [(executable: URL, arguments: [String])] = []
        var processes: [FakeProcess] = []
        var failingLaunches = 0
    }
    private let state = Mutex(State())

    var launches: [(executable: URL, arguments: [String])] { state.withLock { $0.launches } }
    var processes: [FakeProcess] { state.withLock { $0.processes } }

    /// Makes the next `count` launches throw.
    func failNextLaunches(_ count: Int) { state.withLock { $0.failingLaunches = count } }

    func launch(executable: URL, arguments: [String]) throws -> Rabbithole.DaemonProcess {
        try state.withLock { state in
            state.launches.append((executable, arguments))
            if state.failingLaunches > 0 {
                state.failingLaunches -= 1
                throw LaunchError()
            }
            let process = FakeProcess()
            state.processes.append(process)
            return process
        }
    }
}

private final class FakeClient: DaemonClient {
    func configure(_ settings: AWSSettings) async throws {}
    func enqueue(localPath: String) async throws -> String { "id" }
    func watch() -> AsyncThrowingStream<UploadSnapshot, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

/// Counts calls and hands out one scripted answer per call; `true` once the script runs out.
private final class ProbeScript: Sendable {
    private let answers: Mutex<[Bool]>
    private let calls = Mutex(0)

    init(_ answers: [Bool] = []) { self.answers = Mutex(answers) }

    var callCount: Int { calls.withLock { $0 } }

    func probe() async -> Bool {
        calls.withLock { $0 += 1 }
        return answers.withLock { $0.isEmpty ? true : $0.removeFirst() }
    }
}

private final class Counter: Sendable {
    private let value = Mutex(0)
    var count: Int { value.withLock { $0 } }
    func increment() { value.withLock { $0 += 1 } }
}

/// Reads supervisor events one batch at a time and fails instead of hanging.
private final class EventReader: @unchecked Sendable {
    private var iterator: AsyncStream<DaemonEvent>.AsyncIterator

    init(_ events: AsyncStream<DaemonEvent>) { iterator = events.makeAsyncIterator() }

    func read(_ count: Int) async throws -> [DaemonEvent] {
        try await withTimeout(10) {
            var result: [DaemonEvent] = []
            while result.count < count, let event = await self.iterator.next() {
                result.append(event)
            }
            return result
        }
    }

    func expect(
        _ expected: [DaemonEvent], file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let events = try await read(expected.count)
        XCTAssertEqual(events, expected, file: file, line: line)
    }

    /// Everything still buffered; only returns once the stream is finished.
    func drain() async throws -> [DaemonEvent] {
        try await withTimeout(10) {
            var result: [DaemonEvent] = []
            while let event = await self.iterator.next() { result.append(event) }
            return result
        }
    }
}

final class DaemonSupervisorTests: XCTestCase {
    private let executable = URL(fileURLWithPath: "/opt/rabbitholed")
    private var directory: URL!
    private var socketURL: URL { directory.appendingPathComponent("run/d.sock") }

    override func setUpWithError() throws {
        // Unix socket paths are limited to about 104 bytes, so stay under /tmp.
        directory = URL(fileURLWithPath: "/tmp/rh-sup-\(UUID().uuidString.prefix(8))")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeSupervisor(
        executable: URL? = URL(fileURLWithPath: "/opt/rabbitholed"),
        launcher: FakeLauncher,
        probe: @escaping @Sendable () async -> Bool = { true },
        restartDelay: @escaping @Sendable () async -> Void = {},
        makeClient: @escaping @Sendable (String) -> DaemonClient = { _ in FakeClient() }
    ) -> DaemonSupervisor {
        DaemonSupervisor(
            executable: executable, socketURL: socketURL, launcher: launcher,
            socketProbe: probe, makeClient: makeClient, restartDelay: restartDelay)
    }

    private func mode(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as! NSNumber).intValue
    }

    func testLaunchesWithSocketArgument() async throws {
        let launcher = FakeLauncher()
        let supervisor = makeSupervisor(launcher: launcher)

        await supervisor.start()
        supervisor.stop()

        XCTAssertEqual(launcher.launches.count, 1)
        XCTAssertEqual(launcher.launches[0].executable, executable)
        XCTAssertEqual(launcher.launches[0].arguments, ["--socket", socketURL.path])
    }

    func testCreatesSocketDirectoryWithMode0700() async throws {
        let supervisor = makeSupervisor(launcher: FakeLauncher())

        await supervisor.start()
        supervisor.stop()

        XCTAssertEqual(try mode(of: socketURL.deletingLastPathComponent()), 0o700)
    }

    func testTightensExistingSocketDirectoryToMode0700() async throws {
        let parent = socketURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755])
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent.path)
        XCTAssertEqual(try mode(of: parent), 0o755)
        let supervisor = makeSupervisor(launcher: FakeLauncher())

        await supervisor.start()
        supervisor.stop()

        XCTAssertEqual(try mode(of: parent), 0o700)
    }

    func testEmitsReadyOnlyAfterProbeSucceeds() async throws {
        let (entered, enteredSignal) = AsyncStream<Void>.makeStream()
        let (gate, gateRelease) = AsyncStream<Void>.makeStream()
        let supervisor = makeSupervisor(
            launcher: FakeLauncher(),
            probe: {
                enteredSignal.yield(())
                for await _ in gate { break }
                return true
            })
        let reader = EventReader(supervisor.events)

        let starting = Task { await supervisor.start() }
        var enteredIterator = entered.makeAsyncIterator()
        _ = await enteredIterator.next()  // the probe is running and has not answered yet
        supervisor.stop()  // finishes the stream; whatever was emitted so far stays buffered
        let before = try await reader.drain()
        gateRelease.yield(())
        await starting.value

        XCTAssertEqual(before, [])
    }

    func testEmitsReadyAfterProbeSucceeds() async throws {
        let supervisor = makeSupervisor(launcher: FakeLauncher())
        let reader = EventReader(supervisor.events)

        await supervisor.start()

        try await reader.expect([.ready])
        XCTAssertNotNil(supervisor.client)
        supervisor.stop()
    }

    func testUnexpectedExitRestartsAndEmitsRestarted() async throws {
        let launcher = FakeLauncher()
        let delays = Counter()
        let clients = Counter()
        let supervisor = makeSupervisor(
            launcher: launcher,
            restartDelay: { delays.increment() },
            makeClient: { _ in
                clients.increment()
                return FakeClient()
            })
        let reader = EventReader(supervisor.events)

        await supervisor.start()
        try await reader.expect([.ready])
        let clientBefore = try XCTUnwrap(supervisor.client)
        launcher.processes[0].crash()

        try await reader.expect([.restarted])
        XCTAssertEqual(launcher.launches.count, 2)
        XCTAssertEqual(delays.count, 1)
        // One client lives across restarts; its transport reconnects by itself.
        XCTAssertEqual(clients.count, 1)
        XCTAssertTrue(supervisor.client as AnyObject === clientBefore as AnyObject)
        supervisor.stop()
    }

    func testProbeFailureTerminatesProcessAndRestarts() async throws {
        let launcher = FakeLauncher()
        let probe = ProbeScript([false, true])
        let supervisor = makeSupervisor(launcher: launcher, probe: { await probe.probe() })
        let reader = EventReader(supervisor.events)

        await supervisor.start()

        try await reader.expect([.ready])
        XCTAssertEqual(launcher.launches.count, 2)
        XCTAssertEqual(launcher.processes[0].terminateCount, 1)
        XCTAssertEqual(probe.callCount, 2)
        supervisor.stop()
    }

    func testLaunchFailureCountsAsAnUnexpectedExit() async throws {
        let launcher = FakeLauncher()
        launcher.failNextLaunches(1)
        let supervisor = makeSupervisor(launcher: launcher)
        let reader = EventReader(supervisor.events)

        await supervisor.start()

        try await reader.expect([.ready])
        XCTAssertEqual(launcher.launches.count, 2)
        supervisor.stop()
    }

    func testGivesUpAfterThreeRestartsAndEmitsUnavailable() async throws {
        let launcher = FakeLauncher()
        let delays = Counter()
        let supervisor = makeSupervisor(launcher: launcher, restartDelay: { delays.increment() })
        let reader = EventReader(supervisor.events)

        await supervisor.start()
        try await reader.expect([.ready])
        for restart in 1...3 {
            launcher.processes[restart - 1].crash()
            try await reader.expect([.restarted])
        }
        launcher.processes[3].crash()

        try await reader.expect([.unavailable])
        XCTAssertEqual(launcher.launches.count, 4)  // the first launch plus three restarts
        XCTAssertEqual(delays.count, 3)
        supervisor.stop()
    }

    func testMissingExecutableEmitsUnavailable() async throws {
        let launcher = FakeLauncher()
        let supervisor = makeSupervisor(executable: nil, launcher: launcher)
        let reader = EventReader(supervisor.events)

        await supervisor.start()

        try await reader.expect([.unavailable])
        XCTAssertEqual(launcher.launches.count, 0)
        supervisor.stop()
    }

    func testStopTerminatesProcessWithoutRestart() async throws {
        let launcher = FakeLauncher()
        let supervisor = makeSupervisor(launcher: launcher)
        let reader = EventReader(supervisor.events)

        await supervisor.start()
        supervisor.stop()  // terminating the fake also ends its termination stream

        XCTAssertEqual(launcher.processes[0].terminateCount, 1)
        let events = try await reader.drain()
        XCTAssertEqual(events, [.ready])  // nothing follows the stop
        XCTAssertEqual(launcher.launches.count, 1)
    }
}

/// Runs the real daemon binary through the real launcher.
final class DaemonSupervisorIntegrationTests: XCTestCase {
    private final class RecordingLauncher: ProcessLauncher, Sendable {
        private let inner = SystemProcessLauncher()
        private let launched = Mutex<SystemDaemonProcess?>(nil)
        var process: SystemDaemonProcess? { launched.withLock { $0 } }

        func launch(executable: URL, arguments: [String]) throws -> Rabbithole.DaemonProcess {
            let process = try inner.launch(executable: executable, arguments: arguments)
            launched.withLock { $0 = process as? SystemDaemonProcess }
            return process
        }
    }

    func testRealDaemonStartsAndStopsWithTheSupervisor() async throws {
        let binary = try DaemonProcess.binaryURL()  // skips when the binary is missing
        let directory = URL(fileURLWithPath: "/tmp/rh-int-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: directory) }
        let socketURL = directory.appendingPathComponent("run/d.sock")
        let launcher = RecordingLauncher()
        let supervisor = DaemonSupervisor(
            executable: binary, socketURL: socketURL, launcher: launcher,
            socketProbe: { await UnixSocketProbe.waitUntilAccepting(path: socketURL.path) },
            makeClient: { GRPCDaemonClient(socketPath: $0) })
        let reader = EventReader(supervisor.events)

        await supervisor.start()
        defer { supervisor.stop() }

        try await reader.expect([.ready])
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketURL.path))
        let process = try XCTUnwrap(launcher.process)
        XCTAssertTrue(process.isRunning)

        supervisor.stop()

        // The exit of a real child process is the one thing here that cannot be injected.
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(process.isRunning, "daemon still running 2s after stop()")
    }
}
