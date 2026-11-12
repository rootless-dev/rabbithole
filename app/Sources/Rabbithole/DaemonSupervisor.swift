import Darwin
import Foundation
import Synchronization

/// A running daemon, as the supervisor sees it.
protocol DaemonProcess: Sendable {
    /// Asks the process to end. Must be safe to call on a process that already exited.
    func terminate()
    /// Yields once and finishes when the process has exited, for any reason.
    var terminationEvents: AsyncStream<Void> { get }
}

protocol ProcessLauncher: Sendable {
    func launch(executable: URL, arguments: [String]) throws -> DaemonProcess
}

enum DaemonEvent: Equatable, Sendable {
    /// The daemon is accepting connections. Emitted the first time only.
    case ready
    /// The daemon came back after an unexpected exit.
    case restarted
    /// The daemon cannot be started or kept alive; uploads do not work.
    case unavailable
}

/// Starts the daemon, waits until it accepts connections and restarts it, a bounded number
/// of times, when it exits unexpectedly.
final class DaemonSupervisor: Sendable {
    private struct Generation {
        var id: Int
        var process: DaemonProcess
        var handled = false
    }

    private struct State {
        var client: DaemonClient?
        var started = false
        var stopped = false
        var hasBeenReady = false
        // The restart budget lasts for the app's lifetime in this slice: a successful
        // start does not give restarts back.
        var restarts = 0
        var nextID = 0
        var current: Generation?
        var monitors: [Task<Void, Never>] = []
    }

    let events: AsyncStream<DaemonEvent>
    private let continuation: AsyncStream<DaemonEvent>.Continuation
    private let executable: URL?
    private let socketURL: URL
    private let launcher: ProcessLauncher
    private let socketProbe: @Sendable () async -> Bool
    private let makeClient: @Sendable (String) -> DaemonClient
    private let maxRestarts: Int
    private let restartDelay: @Sendable () async -> Void
    private let state = Mutex(State())

    /// - Parameter restartDelay: awaited between an unexpected exit and the next launch, so a
    ///   daemon that dies at once does not spin. Injected so tests do not sleep.
    init(
        executable: URL?,
        socketURL: URL,
        launcher: ProcessLauncher,
        socketProbe: @escaping @Sendable () async -> Bool,
        makeClient: @escaping @Sendable (String) -> DaemonClient,
        maxRestarts: Int = 3,
        restartDelay: @escaping @Sendable () async -> Void = {
            try? await Task.sleep(for: .milliseconds(500))
        }
    ) {
        (events, continuation) = AsyncStream<DaemonEvent>.makeStream()
        self.executable = executable
        self.socketURL = socketURL
        self.launcher = launcher
        self.socketProbe = socketProbe
        self.makeClient = makeClient
        self.maxRestarts = maxRestarts
        self.restartDelay = restartDelay
    }

    /// One client for the supervisor's whole life: its transport reconnects by itself after
    /// the daemon comes back, so restarts do not replace it. `nil` before `start()` and when
    /// the daemon could not be set up at all.
    var client: DaemonClient? { state.withLock { $0.client } }

    /// Launches the daemon and returns once the first attempt has settled; later restarts
    /// continue in the background and report through `events`.
    func start() async {
        let shouldRun = state.withLock { state -> Bool in
            guard !state.started, !state.stopped else { return false }
            state.started = true
            return true
        }
        guard shouldRun else { return }

        guard let executable, prepareSocketDirectory() else {
            continuation.yield(.unavailable)
            return
        }
        let client = makeClient(socketURL.path)
        state.withLock { $0.client = client }
        await bringUp(executable: executable)
    }

    /// Ends the daemon for good: no restart follows.
    func stop() {
        let (process, monitors) = state.withLock { state -> (DaemonProcess?, [Task<Void, Never>]) in
            state.stopped = true
            let result = (state.current?.process, state.monitors)
            state.current = nil
            state.monitors = []
            return result
        }
        monitors.forEach { $0.cancel() }
        process?.terminate()
        continuation.finish()
    }

    // MARK: - Launching

    /// Launches until the daemon answers the probe or the restart budget runs out.
    private func bringUp(executable: URL) async {
        while true {
            guard let id = launch(executable: executable) else {
                guard await prepareRestart() else { return }
                continue
            }
            let ready = await socketProbe()
            if ready {
                markReady(id: id)
                return
            }
            // Not answering counts as an unexpected exit.
            guard claimFailure(id: id) else { return }
            guard await prepareRestart() else { return }
        }
    }

    /// Starts the process and its exit monitor. Returns its generation id, or `nil` when the
    /// supervisor was stopped or the launch failed.
    private func launch(executable: URL) -> Int? {
        if state.withLock({ $0.stopped }) { return nil }
        let process: DaemonProcess
        do {
            process = try launcher.launch(
                executable: executable, arguments: ["--socket", socketURL.path])
        } catch {
            return nil
        }
        let id: Int? = state.withLock { state in
            guard !state.stopped else { return nil }
            let id = state.nextID
            state.nextID += 1
            state.current = Generation(id: id, process: process)
            return id
        }
        guard let id else {
            process.terminate()
            return nil
        }
        let monitor = Task { [weak self] in
            for await _ in process.terminationEvents {}
            await self?.processExited(id: id, executable: executable)
        }
        state.withLock { state in
            if state.stopped { monitor.cancel() } else { state.monitors.append(monitor) }
        }
        return id
    }

    private func processExited(id: Int, executable: URL) async {
        guard claimFailure(id: id, terminate: false) else { return }
        guard await prepareRestart() else { return }
        await bringUp(executable: executable)
    }

    /// Marks the generation as failed, once. `false` when it was already handled or is no
    /// longer current (including after `stop()`), so only one path restarts it.
    private func claimFailure(id: Int, terminate: Bool = true) -> Bool {
        let process: DaemonProcess? = state.withLock { state in
            guard !state.stopped, var current = state.current, current.id == id, !current.handled
            else { return nil }
            current.handled = true
            state.current = current
            return current.process
        }
        guard let process else { return false }
        if terminate { process.terminate() }
        return true
    }

    /// Spends one restart and waits before the next launch. `false` when the budget is gone
    /// (after announcing `.unavailable`) or the supervisor was stopped meanwhile.
    private func prepareRestart() async -> Bool {
        let allowed = state.withLock { state -> Bool in
            guard !state.stopped else { return false }
            guard state.restarts < maxRestarts else { return false }
            state.restarts += 1
            return true
        }
        guard allowed else {
            if !state.withLock({ $0.stopped }) { continuation.yield(.unavailable) }
            return false
        }
        await restartDelay()
        return !state.withLock { $0.stopped }
    }

    private func markReady(id: Int) {
        let event: DaemonEvent? = state.withLock { state in
            guard !state.stopped, let current = state.current, current.id == id, !current.handled
            else { return nil }
            let event: DaemonEvent = state.hasBeenReady ? .restarted : .ready
            state.hasBeenReady = true
            return event
        }
        if let event { continuation.yield(event) }
    }

    /// Creates the socket's directory and forces mode 0700, also when it already existed
    /// with wider permissions.
    private func prepareSocketDirectory() -> Bool {
        let directory = socketURL.deletingLastPathComponent().path
        let manager = FileManager.default
        do {
            try manager.createDirectory(
                atPath: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory)
            return true
        } catch {
            return false
        }
    }
}

// MARK: - Real process

/// The daemon as a child process. It owns the write end of the child's standard input for
/// the child's whole life: the daemon exits when that pipe closes, so it also dies with the
/// app, however the app ends.
final class SystemDaemonProcess: DaemonProcess, Sendable {
    let terminationEvents: AsyncStream<Void>
    private let process: Process
    private let standardInput: Pipe

    fileprivate init(process: Process, standardInput: Pipe, terminationEvents: AsyncStream<Void>) {
        self.process = process
        self.standardInput = standardInput
        self.terminationEvents = terminationEvents
    }

    var isRunning: Bool { process.isRunning }

    func terminate() {
        try? standardInput.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }
}

struct SystemProcessLauncher: ProcessLauncher {
    func launch(executable: URL, arguments: [String]) throws -> DaemonProcess {
        let process = Process()
        let standardInput = Pipe()
        let (terminationEvents, continuation) = AsyncStream<Void>.makeStream()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = standardInput
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.standardError
        process.terminationHandler = { _ in
            continuation.yield(())
            continuation.finish()
        }
        try process.run()
        return SystemDaemonProcess(
            process: process, standardInput: standardInput, terminationEvents: terminationEvents)
    }
}

// MARK: - Probe

enum UnixSocketProbe {
    /// Retries a connect to the socket until it is accepted. `false` after `timeout`.
    static func waitUntilAccepting(
        path: String,
        interval: Duration = .milliseconds(100),
        timeout: Duration = .seconds(5)
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !Task.isCancelled {
            if canConnect(path: path) { return true }
            guard clock.now < deadline else { return false }
            try? await Task.sleep(for: interval)
        }
        return false
    }

    private static func canConnect(path: String) -> Bool {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else { return false }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path.utf8)
            buffer[path.utf8.count] = 0
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return result == 0
    }
}
