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
    @ObservationIgnored private var settings: AWSSettings?
    @ObservationIgnored private let isRegularFile: @Sendable (URL) async -> Bool
    @ObservationIgnored private let sleep: (Duration) async throws -> Void
    @ObservationIgnored private var tracker = BatchTracker()
    @ObservationIgnored private var feedbackGeneration = 0

    init(
        client: DaemonClient?,
        settings: AWSSettings?,
        isRegularFile: @escaping @Sendable (URL) async -> Bool,
        sleep: @escaping (Duration) async throws -> Void
    ) {
        self.client = client
        self.settings = settings
        self.isRegularFile = isRegularFile
        self.sleep = sleep
        if client == nil {
            state = .unavailable
        } else {
            state = settings == nil ? .notConfigured : .starting
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
        switch state {
        case .unavailable:
            refuse("Uploads are unavailable")
            return
        case .notConfigured:
            refuse("Connect your AWS account first")
            return
        case .starting:
            refuse("Rabbithole is still starting")
            return
        default:
            break
        }
        guard urls.count == 1 else {
            refuse("Drop one file at a time")
            return
        }
        guard await isRegularFile(url) else {
            refuse("Folders are not supported yet")
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
            state = .failed(Self.message(forEnqueueError: error))
            return
        }
        tracker.register(id: id)
        refreshState()
        await confirm()
    }

    func settingsSaved(_ s: AWSSettings) async {
        guard let client else { return }
        do {
            try await client.configure(s)
        } catch {
            if case DaemonError.unavailable = error {
                state = .unavailable
            } else {
                state = .failed("Settings could not be saved")
            }
            return
        }
        settings = s
        if state == .notConfigured || state == .unavailable || state == .starting {
            state = .idle
            refreshState()
        }
    }

    /// The daemon accepted the saved settings after a launch or restart: leave `starting`.
    func configured() {
        guard state == .starting || state == .unavailable else { return }
        state = settings == nil ? .notConfigured : .idle
        refreshState()
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
            // Leaves `starting` and `unavailable`; an upload's `.failed` message stays.
            configured()
        case .restarted:
            // The new daemon has no settings until `configured()` is called.
            tracker.interrupted()
            if settings != nil {
                state = .starting
            }
        case .unavailable:
            tracker.interrupted()
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
