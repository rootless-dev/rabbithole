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
    /// How many items `dropFeedback` is about: the ones held over the window while it is
    /// `.hovering`, the ones just added while it is `.confirmed`.
    private(set) var feedbackItemCount = 1
    /// Every upload seen in this run; the main window and "Recent uploads" read it.
    let uploads: UploadStore

    /// True when dropping or choosing files can start an upload right now.
    var acceptsUploads: Bool { refusalForState() == nil }

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
    /// Builds the daemon request for the paths of one upload, adding the saved preferences.
    @ObservationIgnored private let makeRequest: ([String]) -> EnqueueRequest
    @ObservationIgnored private let sleep: (Duration) async throws -> Void
    @ObservationIgnored private var tracker = BatchTracker()
    @ObservationIgnored private var feedbackGeneration = 0

    init(
        client: DaemonClient?,
        sleep: @escaping (Duration) async throws -> Void,
        uploads: UploadStore? = nil,
        makeRequest: @escaping ([String]) -> EnqueueRequest = { EnqueueRequest(paths: $0) }
    ) {
        self.uploads = uploads ?? UploadStore()
        self.client = client
        self.makeRequest = makeRequest
        self.sleep = sleep
        if client == nil {
            state = .restartRequired
        } else {
            state = .starting
        }
    }

    func setHovering(_ over: Bool, itemCount: Int = 1) {
        if over {
            feedbackItemCount = max(itemCount, 1)
            setFeedback(.hovering)
        } else if dropFeedback == .hovering {
            setFeedback(.none)
        }
    }

    /// Sends everything that was dropped, picked or copied as one upload. Files and folders
    /// are told apart by the daemon, which walks the folders before it answers.
    func drop(_ urls: [URL]) async {
        guard !urls.isEmpty else {
            setFeedback(.none)
            return
        }
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
            id = try await client.enqueue(makeRequest(urls.map(\.path)))
        } catch {
            setFeedback(.none)
            if refusalForState() == nil {
                state = .failed(Self.message(forEnqueueError: error))
            }
            return
        }
        tracker.register(id: id, items: urls.count)
        refreshState()
        await confirm(itemCount: urls.count)
    }

    /// "Upload from clipboard": uploads the files and folders copied in Finder, if there are
    /// any. Clipboard contents that are not files (text, an image) cannot be uploaded yet and
    /// are refused.
    func uploadFromClipboard(_ urls: [URL]) async {
        guard !urls.isEmpty else {
            refuse("The clipboard has no file to upload")
            return
        }
        await drop(urls)
    }

    /// Sends failed uploads again: everything a failed upload was handed is enqueued as one
    /// new upload. Returns how many uploads were enqueued.
    @discardableResult
    func retry(_ records: [UploadRecord]) async -> Int {
        uploads.clearCondition()
        guard refusalForState() == nil, let client else { return 0 }
        var enqueued = 0
        for record in records {
            do {
                let id = try await client.enqueue(makeRequest(record.handedPaths))
                tracker.register(id: id, items: record.handedPaths.count)
                refreshState()
                enqueued += 1
            } catch {
                if refusalForState() == nil, !tracker.isActive {
                    state = .failed(Self.message(forEnqueueError: error))
                }
            }
        }
        return enqueued
    }

    /// The forwarder's outcome after it configured the daemon (or found nothing to configure):
    /// `nil` means no AWS settings are saved. An upload's `.failed` message and a running batch
    /// are left alone.
    func configured(with settings: AWSSettings?) {
        if state == .restartRequired { return }
        settingsNotApplied = false
        // New settings (or a fresh daemon) get a new chance: a rejected key is forgotten.
        uploads.clearCondition()
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
            uploads.interrupt()
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
        default:
            // AWS refused the key on the last upload: nothing new is sent until new settings
            // are saved, which clears the condition.
            uploads.ledger.condition == .keyRejected ? ServiceCondition.keyRejectedMessage : nil
        }
    }

    /// Feeds one snapshot from the daemon's stream to the upload ledger and the batch tracker.
    func apply(_ snapshot: UploadSnapshot) {
        uploads.apply(snapshot)
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
            uploads.interrupt()
            settingsNotApplied = false
            switch state {
            case .notConfigured, .settingsUnreadable, .restartRequired: break
            default: state = .starting
            }
        case .unavailable:
            tracker.interrupted()
            uploads.interrupt()
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

    private func confirm(itemCount: Int) async {
        feedbackItemCount = max(itemCount, 1)
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
        // The daemon says which path it could not use, or that there was nothing to send.
        case .invalidArgument(let message): message.isEmpty ? "This file cannot be read" : message
        default: "Upload could not be started"
        }
    }
}
