import Foundation
import Synchronization

/// Connects the daemon to the view model: forwards supervisor events, re-sends the saved
/// settings to every fresh daemon and keeps one `watch()` subscription alive, forwarding each
/// snapshot to the view model on the main actor.
final class DaemonEventForwarder: Sendable {
    private let client: DaemonClient
    private let events: AsyncStream<DaemonEvent>
    private let loadSettings: @Sendable () -> AWSSettings?
    private let viewModel: TrayViewModel
    private let retryDelay: Duration
    private let tasks = Mutex<(loop: Task<Void, Never>?, watch: Task<Void, Never>?)>((nil, nil))

    /// - Parameter loadSettings: may block (keychain); it is only called off the main actor.
    @MainActor
    init(
        client: DaemonClient,
        events: AsyncStream<DaemonEvent>,
        viewModel: TrayViewModel,
        retryDelay: Duration = .milliseconds(500),
        loadSettings: @escaping @Sendable () -> AWSSettings?
    ) {
        self.client = client
        self.events = events
        self.viewModel = viewModel
        self.retryDelay = retryDelay
        self.loadSettings = loadSettings
    }

    func start() {
        let loop = Task { [self] in
            for await event in events {
                await viewModel.handle(event)
                if Task.isCancelled { return }
                switch event {
                case .ready, .restarted:
                    if let settings = loadSettings() {
                        try? await client.configure(settings)
                    }
                    replaceWatch(with: startWatching())
                case .unavailable:
                    replaceWatch(with: nil)
                }
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
                try? await Task.sleep(for: retryDelay)
            }
        }
    }
}
