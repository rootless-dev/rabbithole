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
    /// The batch is not over but nothing is being sent: every upload left in it is paused,
    /// by the user or (`onHold`) because the Mac runs on battery.
    case paused(remaining: Int, total: Int, fraction: Double, reason: PauseReason)
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
    /// The upload history as the daemon tells it; the main window and "Recent uploads" read it.
    let uploads: UploadStore
    /// The downloads the daemon is running or ran since it started.
    let downloads: DownloadStore

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
        case .paused(let remaining, let total, _, let reason):
            "\(UploadText.pausedLead(reason)), \(remaining) of \(total) files left"
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
        downloads: DownloadStore? = nil,
        makeRequest: @escaping ([String]) -> EnqueueRequest = { EnqueueRequest(paths: $0) }
    ) {
        self.uploads = uploads ?? UploadStore()
        self.downloads = downloads ?? DownloadStore()
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

    /// "Upload from clipboard": uploads the files the clipboard gave, which are the files and
    /// folders copied in Finder, or an image or text saved as a file. An empty clipboard and
    /// a failed save are refused with their reason.
    func uploadFromClipboard(_ files: Result<[URL], any Error>) async {
        switch files {
        case .success(let urls) where !urls.isEmpty:
            await drop(urls)
        case .failure(ClipboardReader.Failure.notSaved):
            refuse("The clipboard contents could not be saved")
        default:
            refuse("The clipboard has nothing to upload")
        }
    }

    /// Sends every failed file of each upload again. The uploads keep their ids and go back
    /// to waiting. Returns how many uploads the daemon accepted.
    @discardableResult
    func retry(_ records: [UploadRecord]) async -> Int {
        var accepted = 0
        for record in records {
            if await retry(uploadID: record.id, fileIndexes: [], files: record.filesFailed) {
                accepted += 1
            }
        }
        return accepted
    }

    /// Sends failed files of one upload again: the ones listed by their index, or every
    /// failed file when `fileIndexes` is empty. `files` is how many that is, as far as the
    /// caller knows. Returns whether the daemon accepted.
    @discardableResult
    func retry(uploadID: String, fileIndexes: [Int], files: Int? = nil) async -> Bool {
        uploads.clearCondition()
        guard refusalForState() == nil, let client else { return false }
        tracker.willRetry(id: uploadID)
        do {
            try await client.retry(uploadID: uploadID, fileIndexes: fileIndexes)
        } catch DaemonError.notFound {
            // Already gone from the history: the same as hearing that it was removed. For
            // listed files it can be only the files that are gone, so the upload is kept.
            if fileIndexes.isEmpty { forget(uploadID) }
            return false
        } catch {
            if refusalForState() == nil, !tracker.isActive {
                state = .failed(Self.message(forRetryError: error))
            }
            return false
        }
        tracker.retried(id: uploadID, files: max(files ?? fileIndexes.count, 1))
        refreshState()
        return true
    }

    /// Takes an upload, or the listed files of it, out of the history, and out of the bucket
    /// too when asked. Returns once the daemon has done it. An upload the daemon no longer
    /// knows counts as removed; any other failure is thrown for the caller to show.
    func remove(uploadID: String, fileIndexes: [Int], deleteFromBucket: Bool) async throws {
        guard let client else { throw DaemonError.unavailable }
        do {
            try await client.remove(
                uploadID: uploadID, fileIndexes: fileIndexes, deleteFromBucket: deleteFromBucket)
        } catch DaemonError.notFound {
            // Not found for listed files can mean only that those files are gone, so the
            // upload is kept; the caller drops the files, as after a removal.
            if fileIndexes.isEmpty { forget(uploadID) }
            return
        }
        if fileIndexes.isEmpty { forget(uploadID) }
    }

    // MARK: Pause, resume, cancel

    /// Stops sending an upload and keeps what was sent. The daemon's snapshot shows it paused.
    func pause(uploadID: String) async {
        await act(on: uploadID) { try await $0.pause(uploadID: uploadID) }
    }

    /// Puts an upload the user paused back in the queue.
    func resume(uploadID: String) async {
        await act(on: uploadID) { try await $0.resume(uploadID: uploadID) }
    }

    /// Stops an upload for good. What it already sent stays in the bucket and the history.
    func cancel(uploadID: String) async {
        await act(on: uploadID) { try await $0.cancel(uploadID: uploadID) }
    }

    /// Asks the daemon to do something to one upload. A refusal is noted on the upload, so
    /// its row says why until its state changes; an upload the daemon no longer knows is
    /// forgotten here too.
    private func act(on uploadID: String, _ call: (DaemonClient) async throws -> Void) async {
        uploads.noteActionError(nil, for: uploadID)
        guard let client else {
            uploads.noteActionError(RemovalSheetModel.message(for: DaemonError.unavailable), for: uploadID)
            return
        }
        do {
            try await call(client)
        } catch DaemonError.notFound {
            forget(uploadID)
        } catch {
            uploads.noteActionError(RemovalSheetModel.message(for: error), for: uploadID)
        }
    }

    // MARK: Downloads

    /// Copies an upload, or one file of it, from the bucket into `destination`. Progress
    /// and the end arrive on the downloads stream; a refusal is shown where a failed
    /// download is. Returns the download's id, or nil when it was not started.
    @discardableResult
    func download(_ target: UploadActionTarget, to destination: String) async -> String? {
        guard let client else {
            downloads.refused(target, message: RemovalSheetModel.message(for: DaemonError.unavailable))
            return nil
        }
        do {
            let id = try await client.startDownload(
                uploadID: target.uploadID, fileIndexes: target.fileIndexes, destinationDir: destination)
            downloads.started(id: id, target: target)
            return id
        } catch DaemonError.notFound where target.fileIndexes.isEmpty {
            forget(target.uploadID)
        } catch {
            downloads.refused(target, message: RemovalSheetModel.message(for: error))
        }
        return nil
    }

    /// Stops the download of `target` that is waiting or running, if there is one.
    func cancelDownload(_ target: UploadActionTarget) async {
        guard let client, let download = downloads.active(target) else { return }
        // A download that is already over on the daemon's side says so on the stream.
        try? await client.cancelDownload(downloadID: download.id)
    }

    /// Feeds one snapshot from the daemon's downloads stream to the download store.
    func apply(_ snapshot: DownloadSnapshot) {
        downloads.apply(snapshot)
    }

    /// The upload left the history: every list and the current batch stop showing it.
    private func forget(_ id: String) {
        uploads.remove(id)
        downloads.forget(uploadID: id)
        if tracker.remove(id) { batchChanged() }
    }

    /// The batch gained, lost or changed an upload: the state follows it. A batch that is
    /// left empty (its uploads were removed or canceled) has nothing more to report.
    private func batchChanged() {
        if tracker.total > 0 {
            refreshState()
            return
        }
        switch state {
        case .uploading, .paused, .finished, .failed:
            state = settingsNotApplied ? .failed(Self.settingsNotAppliedMessage) : .idle
        default:
            break
        }
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
        case .failed, .uploading, .paused, .finished, .restartRequired:
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
        if snapshot.removed {
            forget(snapshot.id)
            return
        }
        uploads.apply(snapshot)
        if tracker.apply(snapshot) {
            batchChanged()
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
            downloads.clear()
            settingsNotApplied = false
            switch state {
            case .notConfigured, .settingsUnreadable, .restartRequired: break
            default: state = .starting
            }
        case .unavailable:
            tracker.interrupted()
            uploads.interrupt()
            downloads.clear()
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
        if let reason = tracker.pause {
            state = .paused(
                remaining: tracker.remaining, total: tracker.total, fraction: tracker.fraction, reason: reason)
        } else if tracker.isActive {
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

    private static func message(forRetryError error: Error) -> String {
        switch error as? DaemonError {
        case .notConfigured: "Connect your AWS account first"
        case .unavailable: "Uploads are unavailable"
        // The daemon says why it cannot send these files again.
        case .rejected(let message), .invalidArgument(let message):
            message.isEmpty ? "Upload could not be started" : message
        default: "Upload could not be started"
        }
    }
}
