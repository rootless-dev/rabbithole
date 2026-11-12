import Foundation
import Observation

enum TrayState: Equatable {
    case unavailable
    case notConfigured
    /// Saved settings exist but the daemon is not up and configured yet (launch or restart).
    case starting
    case idle
    case uploading(remaining: Int, total: Int, fraction: Double)
    case finished
    case failed(String)
}

enum DropFeedback: Equatable {
    case none
    case hovering
    case confirmed
    case refused(String)
}

/// Logic behind the menu bar window. It does not own the snapshot subscription: the app's
/// composition code reads `DaemonClient.watch()` and forwards each snapshot to `apply(_:)`.
@MainActor
@Observable
final class TrayViewModel {
    private(set) var state: TrayState
    private(set) var dropFeedback: DropFeedback = .none

    var statusText: String {
        switch state {
        case .unavailable: "Uploads are unavailable"
        case .notConfigured: "Connect your AWS account first"
        case .starting: "Starting…"
        case .idle: "Ready"
        case .uploading(let remaining, let total, _): "\(remaining) of \(total) files left"
        case .finished: "Upload finished"
        case .failed(let message): message
        }
    }

    @ObservationIgnored private let client: DaemonClient?
    /// True while `.failed` shows the unreadable-settings message rather than an upload error.
    @ObservationIgnored private var settingsUnreadableShown = false
    @ObservationIgnored private let isRegularFile: @Sendable (URL) async -> Bool
    @ObservationIgnored private let sleep: (Duration) async throws -> Void
    @ObservationIgnored private var tracker = BatchTracker()
    @ObservationIgnored private var feedbackGeneration = 0

    init(
        client: DaemonClient?,
        isRegularFile: @escaping @Sendable (URL) async -> Bool,
        sleep: @escaping (Duration) async throws -> Void
    ) {
        self.client = client
        self.isRegularFile = isRegularFile
        self.sleep = sleep
        if client == nil {
            state = .unavailable
        } else {
            state = .starting
        }
    }

    /// True for plain files; false for folders, packages and anything unreadable.
    nonisolated static func isRegularFileOnDisk(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
    }

    /// The same check, run off the main actor: it can block on a stalled network volume.
    @Sendable
    nonisolated static func isRegularFileOffMain(_ url: URL) async -> Bool {
        await Task.detached { isRegularFileOnDisk(url) }.value
    }

    func setHovering(_ over: Bool) {
        if over {
            setFeedback(.hovering)
        } else if dropFeedback == .hovering {
            setFeedback(.none)
        }
    }

    func drop(_ urls: [URL]) async {
        guard let url = urls.first else {
            setFeedback(.none)
            return
        }
        if let message = refusalForState() {
            refuse(message)
            return
        }
        guard urls.count == 1 else {
            refuse("Drop one file at a time")
            return
        }
        guard await isRegularFile(url) else {
            refuse("Folders are not supported yet")
            return
        }
        // The check may have taken a while: the daemon can have changed state meanwhile.
        if let message = refusalForState() {
            refuse(message)
            return
        }
        guard let client else {
            refuse("Uploads are unavailable")
            return
        }

        let id: String
        do {
            id = try await client.enqueue(localPath: url.path)
        } catch {
            setFeedback(.none)
            if refusalForState() == nil {
                settingsUnreadableShown = false
                state = .failed(Self.message(forEnqueueError: error))
            }
            return
        }
        tracker.register(id: id)
        refreshState()
        await confirm()
    }

    /// The forwarder's outcome after it configured the daemon (or found nothing to configure):
    /// `nil` means no AWS settings are saved. An upload's `.failed` message and a running batch
    /// are left alone.
    func configured(with settings: AWSSettings?) {
        switch state {
        case .failed where settingsUnreadableShown:
            settingsUnreadableShown = false
        case .starting, .unavailable, .notConfigured, .idle:
            break
        case .failed, .uploading, .finished:
            return
        }
        state = settings == nil ? .notConfigured : .idle
        refreshState()
    }

    /// The saved settings could not be read; the window offers the settings form instead of
    /// pretending nothing is saved.
    func settingsUnreadable() {
        settingsUnreadableShown = true
        state = .failed("Saved AWS settings could not be read")
    }

    /// Why a drop cannot be accepted in the current state, or nil when it can.
    private func refusalForState() -> String? {
        switch state {
        case .unavailable: "Uploads are unavailable"
        case .notConfigured: "Connect your AWS account first"
        case .starting: "Rabbithole is still starting"
        default: nil
        }
    }

    /// Feeds one snapshot from the daemon's stream to the batch tracker.
    func apply(_ snapshot: UploadSnapshot) {
        if tracker.apply(snapshot) {
            refreshState()
        }
    }

    func handle(_ e: DaemonEvent) {
        switch e {
        case .ready:
            // Readiness is reported through `configured(with:)`, once the daemon has its settings.
            break
        case .restarted:
            // The new daemon has no settings until `configured(with:)` is called.
            tracker.interrupted()
            switch state {
            case .notConfigured: break
            case .failed where settingsUnreadableShown: break
            default: state = .starting
            }
        case .unavailable:
            tracker.interrupted()
            settingsUnreadableShown = false
            state = .unavailable
        }
    }

    /// Derives the state from the current batch. Does nothing before any upload was registered.
    private func refreshState() {
        guard tracker.total > 0 else { return }
        switch state {
        case .unavailable, .notConfigured, .starting:
            return
        default:
            break
        }
        if tracker.isActive {
            state = .uploading(
                remaining: tracker.remaining, total: tracker.total, fraction: tracker.fraction)
        } else if let error = tracker.firstError {
            state = .failed(error)
        } else {
            state = .finished
        }
    }

    private func setFeedback(_ feedback: DropFeedback) {
        feedbackGeneration += 1
        dropFeedback = feedback
    }

    /// Shows a refusal in the drop area and clears it after 2 seconds, unless a newer drop or
    /// hover replaced it.
    private func refuse(_ message: String) {
        setFeedback(.refused(message))
        let generation = feedbackGeneration
        Task {
            try? await sleep(.seconds(2))
            if feedbackGeneration == generation {
                dropFeedback = .none
            }
        }
    }

    private func confirm() async {
        setFeedback(.confirmed)
        let generation = feedbackGeneration
        try? await sleep(.seconds(2))
        if feedbackGeneration == generation {
            dropFeedback = .none
        }
    }

    private static func message(forEnqueueError error: Error) -> String {
        switch error as? DaemonError {
        case .notConfigured: "Connect your AWS account first"
        case .unavailable: "Uploads are unavailable"
        case .invalidArgument: "This file cannot be read"
        default: "Upload could not be started"
        }
    }
}
