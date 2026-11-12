import Foundation
import Observation

enum TrayState: Equatable {
    /// The daemon is up (or was) but could not be configured; a later save or restart retries.
    case unavailable
    /// The supervisor gave up for good: nothing will recover until the app is reopened.
    case restartRequired
    case notConfigured
    /// Saved settings exist but could not be read. Only a successful configure clears it.
    case settingsUnreadable
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
        case .restartRequired: Self.restartRequiredMessage
        case .notConfigured: "Connect your AWS account first"
        case .settingsUnreadable: Self.settingsUnreadableMessage
        case .starting: "Starting…"
        case .idle: "Ready"
        case .uploading(let remaining, let total, _): "\(remaining) of \(total) files left"
        case .finished: "Upload finished"
        case .failed(let message): message
        }
    }

    private static let restartRequiredMessage = "Uploads are unavailable. Quit and reopen Rabbithole."
    private static let settingsUnreadableMessage = "Saved AWS settings could not be read"
    private static let settingsNotAppliedMessage = "AWS settings could not be applied"

    @ObservationIgnored private let client: DaemonClient?
    /// True from a failed save-triggered configure (the daemon keeps its older settings) until
    /// a configure succeeds. The message waits for an active batch to end.
    @ObservationIgnored private var settingsNotApplied = false
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
            state = .restartRequired
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
            refuse(Self.restartRequiredMessage)
            return
        }

        let id: String
        do {
            id = try await client.enqueue(localPath: url.path)
        } catch {
            setFeedback(.none)
            if refusalForState() == nil {
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
        if state == .restartRequired { return }
        settingsNotApplied = false
        switch state {
        case .failed(Self.settingsNotAppliedMessage):
            break
        case .starting, .unavailable, .notConfigured, .settingsUnreadable, .idle:
            break
        case .failed, .uploading, .finished, .restartRequired:
            return
        }
        state = settings == nil ? .notConfigured : .idle
        refreshState()
    }

    /// The saved settings could not be read; the window offers the settings form instead of
    /// pretending nothing is saved.
    func settingsUnreadable() {
        state = .settingsUnreadable
    }

    /// The user saved settings while the daemon was not up yet: settings exist now, and the
    /// forwarder will configure the daemon once it is ready.
    func settingsSaved() {
        if state == .settingsUnreadable || state == .notConfigured { state = .starting }
    }

    /// Every configure attempt failed. `keepingPreviousSettings` is true when the daemon is up
    /// and still runs with older settings: its uploads and drops are untouched and only a
    /// message is shown. Otherwise the daemon has no settings and drops are refused.
    func configureFailed(keepingPreviousSettings: Bool) {
        switch state {
        case .restartRequired, .settingsUnreadable:
            return
        default:
            break
        }
        if keepingPreviousSettings {
            settingsNotApplied = true
            switch state {
            case .idle, .finished, .failed: state = .failed(Self.settingsNotAppliedMessage)
            default: break
            }
        } else {
            tracker.interrupted()
            settingsNotApplied = false
            state = .unavailable
        }
    }

    /// Why a drop cannot be accepted in the current state, or nil when it can.
    private func refusalForState() -> String? {
        switch state {
        case .unavailable: "Uploads are unavailable"
        case .restartRequired: Self.restartRequiredMessage
        case .settingsUnreadable: Self.settingsUnreadableMessage
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
            settingsNotApplied = false
            switch state {
            case .notConfigured, .settingsUnreadable, .restartRequired: break
            default: state = .starting
            }
        case .unavailable:
            tracker.interrupted()
            settingsNotApplied = false
            state = .restartRequired
        }
    }

    /// Derives the state from the current batch. Does nothing before any upload was registered.
    private func refreshState() {
        guard tracker.total > 0 else { return }
        switch state {
        case .unavailable, .restartRequired, .notConfigured, .settingsUnreadable, .starting:
            return
        default:
            break
        }
        if tracker.isActive {
            state = .uploading(
                remaining: tracker.remaining, total: tracker.total, fraction: tracker.fraction)
        } else if let error = tracker.firstError {
            state = .failed(error)
        } else if settingsNotApplied {
            state = .failed(Self.settingsNotAppliedMessage)
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
