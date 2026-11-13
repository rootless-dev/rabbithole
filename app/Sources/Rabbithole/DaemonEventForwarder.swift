import Foundation
import Synchronization

/// The one owner of the daemon's configuration, and the bridge to the view model.
///
/// Supervisor events and saves from the settings window arrive on one queue and are handled
/// strictly in arrival order, so two configure sequences never run at the same time. The
/// saved settings live in memory here: read once when the forwarder starts, replaced on every
/// save. The view model hears that the daemon is usable only after `configure` has returned.
final class DaemonEventForwarder: Sendable {
    private enum Command: Sendable {
        case event(DaemonEvent)
        case settingsChanged(AWSSettings)
        case optionsChanged
    }

    /// What is saved, as far as the forwarder knows.
    private enum Saved {
        case nothing
        case value(AWSSettings)
        /// Reading failed: not the same as nothing saved, and the daemon stays unconfigured.
        case unreadable
    }

    private let client: DaemonClient
    private let events: AsyncStream<DaemonEvent>
    private let loadSettings: @Sendable () throws -> AWSSettings?
    private let sleep: @Sendable (Duration) async throws -> Void
    private let resumeInterrupted: @Sendable () async -> Bool
    private let options: (@Sendable () async -> DaemonOptions)?
    private let configurator: DaemonConfigurator
    private let viewModel: TrayViewModel
    private let commands: AsyncStream<Command>
    private let commandSink: AsyncStream<Command>.Continuation
    private let tasks = Mutex<(pump: Task<Void, Never>?, loop: Task<Void, Never>?, watch: Task<Void, Never>?)>(
        (nil, nil, nil))

    /// - Parameters:
    ///   - loadSettings: may block (keychain) and is only called off the main actor. Returning
    ///     nil means nothing is saved; throwing means the saved settings could not be read.
    ///   - sleep: the pause between retries and the attempt timeout, injected so tests do not wait.
    ///   - resumeInterrupted: the "Resume uploads automatically" preference, read each time
    ///     the daemon is configured.
    ///   - options: the options that apply to every upload, read each time they are sent:
    ///     when the daemon comes up, after it is configured and on `optionsChanged()`.
    ///     Nil sends none.
    @MainActor
    init(
        client: DaemonClient,
        events: AsyncStream<DaemonEvent>,
        viewModel: TrayViewModel,
        loadSettings: @escaping @Sendable () throws -> AWSSettings?,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        resumeInterrupted: @escaping @Sendable () async -> Bool = { false },
        options: (@Sendable () async -> DaemonOptions)? = nil
    ) {
        self.client = client
        self.events = events
        self.viewModel = viewModel
        self.loadSettings = loadSettings
        self.sleep = sleep
        self.resumeInterrupted = resumeInterrupted
        self.options = options
        configurator = DaemonConfigurator(client: client, sleep: sleep)
        (commands, commandSink) = AsyncStream<Command>.makeStream()
    }

    func start() {
        let pump = Task { [self] in
            for await event in events { commandSink.yield(.event(event)) }
        }
        let loop = Task { [self] in await run() }
        tasks.withLock { $0.pump = pump; $0.loop = loop }
    }

    /// The user saved new settings in the settings window.
    func settingsChanged(_ settings: AWSSettings) {
        commandSink.yield(.settingsChanged(settings))
    }

    /// An upload option changed (a preference, or the power source): the daemon gets the
    /// options again, in turn with everything else that is sent to it.
    func optionsChanged() {
        commandSink.yield(.optionsChanged)
    }

    func stop() {
        let (pump, loop, watch) = tasks.withLock { state in
            defer { state = (nil, nil, nil) }
            return state
        }
        commandSink.finish()
        pump?.cancel()
        loop?.cancel()
        watch?.cancel()
    }

    // MARK: - Serialized command loop

    private func run() async {
        var saved: Saved
        do {
            saved = try loadSettings().map(Saved.value) ?? .nothing
        } catch {
            saved = .unreadable
            await viewModel.settingsUnreadable()
        }
        // True from the supervisor's ready or restarted until it reports unavailable.
        var daemonUp = false
        // True once the daemon has accepted settings since it came up.
        var daemonConfigured = false
        // The supervisor gave up: no ready follows, so a save is only stored.
        var terminal = false

        for await command in commands {
            if Task.isCancelled { return }
            switch command {
            case .event(.ready):
                daemonUp = true
                daemonConfigured = await bringUp(
                    saved, daemonConfigured: false, replacingWatch: true)
            case .event(.restarted):
                daemonUp = true
                // The old stream goes first, so nothing it still holds lands after the
                // uploads were marked interrupted. Then say so: the new daemon has no
                // settings yet, and once it has them it replays the history, where the same
                // uploads are recorded as interrupted.
                replaceWatch(with: nil)
                await viewModel.handle(.restarted)
                daemonConfigured = await bringUp(
                    saved, daemonConfigured: false, replacingWatch: true)
            case .event(.unavailable):
                daemonUp = false
                daemonConfigured = false
                terminal = true
                replaceWatch(with: nil)
                await viewModel.handle(.unavailable)
            case .settingsChanged(let settings):
                saved = .value(settings)
                if terminal {
                    // Stored above for the record; there is no daemon left to configure.
                } else if daemonUp {
                    daemonConfigured = await bringUp(
                        saved, daemonConfigured: daemonConfigured, replacingWatch: false)
                } else {
                    await viewModel.settingsSaved()
                }
            case .optionsChanged:
                // A daemon that is not up yet gets them when it is configured.
                if daemonUp, daemonConfigured { await sendOptions() }
            }
        }
    }

    /// Sends the current options. A failure is not retried here: a daemon that could not be
    /// reached gets them when it is configured again, and one that does not know the call
    /// keeps working without them. The call is bounded like a configure attempt.
    private func sendOptions() async {
        guard let options else { return }
        let value = await options()
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [client] in try? await client.setOptions(value) }
            group.addTask { [sleep] in try? await sleep(DaemonConfigurator.attemptTimeout) }
            await group.next()
            group.cancelAll()
        }
    }

    /// Configures the daemon with `saved` and reports the outcome to the view model. Returns
    /// whether the daemon now holds settings: `daemonConfigured` is what it held before, kept
    /// when the attempt fails.
    private func bringUp(
        _ saved: Saved, daemonConfigured: Bool, replacingWatch: Bool
    ) async -> Bool {
        let settings: AWSSettings?
        switch saved {
        case .unreadable:
            return daemonConfigured
        case .nothing:
            settings = nil
        case .value(let value):
            // A daemon that just came up gets the options before its settings too, so that
            // a hold (the Mac is on battery) is already in place when Configure puts the
            // interrupted uploads back in the queue.
            if replacingWatch { await sendOptions() }
            var sent = value
            sent.resumeInterrupted = await resumeInterrupted()
            guard await configurator.configure(sent) else {
                if Task.isCancelled { return daemonConfigured }
                await viewModel.configureFailed(keepingPreviousSettings: daemonConfigured)
                return daemonConfigured
            }
            await sendOptions()
            settings = value
        }
        // A stop() during configure or the hop to the main actor must not leave a watch behind.
        if Task.isCancelled { return daemonConfigured }
        await viewModel.configured(with: settings)
        if Task.isCancelled { return settings != nil }
        if replacingWatch || tasks.withLock({ $0.watch == nil }) {
            replaceWatch(with: startWatching())
        }
        return settings != nil
    }

    // MARK: - Watch subscription

    private func replaceWatch(with new: Task<Void, Never>?) {
        let old = tasks.withLock { state -> Task<Void, Never>? in
            let old = state.watch
            state.watch = new
            return old
        }
        old?.cancel()
    }

    /// Reads the uploads stream and the downloads stream side by side. Each resubscribes
    /// after a short pause whenever it ends or fails, until cancelled.
    private func startWatching() -> Task<Void, Never> {
        Task { [self] in
            await withTaskGroup(of: Void.self) { group in
                group.addTask { [self] in
                    await follow({ self.client.watch() }) { await self.viewModel.apply($0) }
                }
                group.addTask { [self] in
                    await follow({ self.client.watchDownloads() }) { await self.viewModel.apply($0) }
                }
            }
        }
    }

    private func follow<Snapshot: Sendable>(
        _ open: @Sendable () -> AsyncThrowingStream<Snapshot, Error>,
        _ apply: @Sendable (Snapshot) async -> Void
    ) async {
        while !Task.isCancelled {
            do {
                for try await snapshot in open() {
                    // A stream that was replaced must not report anything more.
                    if Task.isCancelled { return }
                    await apply(snapshot)
                }
            } catch {
                // The daemon is gone or restarting; try again below.
            }
            try? await sleep(DaemonConfigurator.retryDelay)
        }
    }
}
