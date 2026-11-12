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
    @MainActor
    init(
        client: DaemonClient,
        events: AsyncStream<DaemonEvent>,
        viewModel: TrayViewModel,
        loadSettings: @escaping @Sendable () throws -> AWSSettings?,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.client = client
        self.events = events
        self.viewModel = viewModel
        self.loadSettings = loadSettings
        self.sleep = sleep
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

        for await command in commands {
            if Task.isCancelled { return }
            switch command {
            case .event(.ready):
                daemonUp = true
                await bringUp(saved, replacingWatch: true)
            case .event(.restarted):
                daemonUp = true
                // Uploads are interrupted and the new daemon has no settings: say so first.
                await viewModel.handle(.restarted)
                replaceWatch(with: nil)
                await bringUp(saved, replacingWatch: true)
            case .event(.unavailable):
                daemonUp = false
                await viewModel.handle(.unavailable)
                replaceWatch(with: nil)
            case .settingsChanged(let settings):
                saved = .value(settings)
                if daemonUp { await bringUp(saved, replacingWatch: false) }
            }
        }
    }

    /// Configures the daemon with `saved` and reports the outcome to the view model.
    private func bringUp(_ saved: Saved, replacingWatch: Bool) async {
        let settings: AWSSettings?
        switch saved {
        case .unreadable:
            return
        case .nothing:
            settings = nil
        case .value(let value):
            guard await configurator.configure(value) else {
                if Task.isCancelled { return }
                await viewModel.handle(.unavailable)
                return
            }
            settings = value
        }
        // A stop() during configure or the hop to the main actor must not leave a watch behind.
        if Task.isCancelled { return }
        await viewModel.configured(with: settings)
        if Task.isCancelled { return }
        if replacingWatch || tasks.withLock({ $0.watch == nil }) {
            replaceWatch(with: startWatching())
        }
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

    /// Resubscribes after a short pause whenever the stream ends or fails, until cancelled.
    private func startWatching() -> Task<Void, Never> {
        Task { [self] in
            while !Task.isCancelled {
                do {
                    for try await snapshot in client.watch() {
                        await viewModel.apply(snapshot)
                    }
                } catch {
                    // The daemon is gone or restarting; try again below.
                }
                try? await sleep(DaemonConfigurator.retryDelay)
            }
        }
    }
}
