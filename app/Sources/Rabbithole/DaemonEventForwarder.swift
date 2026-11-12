import Foundation
import Synchronization

/// Connects the daemon to the view model: forwards supervisor events, re-sends the saved
/// settings to every fresh daemon and keeps one `watch()` subscription alive, forwarding each
/// snapshot to the view model on the main actor.
///
/// The view model hears that the daemon is usable only after `configure` has returned, so the
/// window never offers uploads over an unconfigured daemon.
final class DaemonEventForwarder: Sendable {
    /// Attempts to configure a fresh daemon before giving up and reporting it unavailable.
    private static let configureAttempts = 5
    private static let retryDelay: Duration = .milliseconds(500)

    private let client: DaemonClient
    private let events: AsyncStream<DaemonEvent>
    private let loadSettings: @Sendable () throws -> AWSSettings?
    private let sleep: @Sendable (Duration) async throws -> Void
    private let viewModel: TrayViewModel
    private let tasks = Mutex<(loop: Task<Void, Never>?, watch: Task<Void, Never>?)>((nil, nil))

    /// - Parameters:
    ///   - loadSettings: may block (keychain) and is only called off the main actor. Returning
    ///     nil means nothing is saved; throwing means the saved settings could not be read.
    ///   - sleep: the pause between retries, injected so tests do not wait.
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
    }

    func start() {
        let loop = Task { [self] in
            for await event in events {
                if Task.isCancelled { return }
                await handle(event)
            }
        }
        tasks.withLock { $0.loop = loop }
    }

    func stop() {
        let (loop, watch) = tasks.withLock { state -> (Task<Void, Never>?, Task<Void, Never>?) in
            defer { state = (nil, nil) }
            return state
        }
        loop?.cancel()
        watch?.cancel()
    }

    private func handle(_ event: DaemonEvent) async {
        switch event {
        case .ready:
            let configured = await configureWithSavedSettings()
            // A stop() that landed during configure must not leave a subscription behind.
            if Task.isCancelled { return }
            if configured {
                await viewModel.handle(.ready)
                replaceWatch(with: startWatching())
            } else {
                await viewModel.handle(.unavailable)
                replaceWatch(with: nil)
            }
        case .restarted:
            // Uploads are interrupted and the new daemon has no settings: say so first.
            await viewModel.handle(.restarted)
            replaceWatch(with: nil)
            let configured = await configureWithSavedSettings()
            if Task.isCancelled { return }
            if configured {
                await viewModel.configured()
                replaceWatch(with: startWatching())
            } else {
                await viewModel.handle(.unavailable)
            }
        case .unavailable:
            await viewModel.handle(.unavailable)
            replaceWatch(with: nil)
        }
    }

    /// True when the daemon is ready for uploads: configured, or nothing is saved to configure.
    /// False when the saved settings cannot be read or `configure` keeps failing.
    private func configureWithSavedSettings() async -> Bool {
        let settings: AWSSettings?
        do {
            settings = try loadSettings()
        } catch {
            return false
        }
        guard let settings else { return true }

        for attempt in 1...Self.configureAttempts {
            do {
                try await client.configure(settings)
                return true
            } catch {
                if Task.isCancelled || attempt == Self.configureAttempts { break }
                try? await sleep(Self.retryDelay)
            }
        }
        return false
    }

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
                try? await sleep(Self.retryDelay)
            }
        }
    }
}
