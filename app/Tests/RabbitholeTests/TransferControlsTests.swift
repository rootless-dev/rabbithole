import Foundation
import GRPCCore
import Synchronization
import XCTest

@testable import Rabbithole

/// A power source tests switch by hand.
@MainActor
final class FakePowerSource: PowerSource {
    var isOnBattery = false
    var onChange: (() -> Void)?

    func set(onBattery: Bool) {
        isOnBattery = onBattery
        onChange?()
    }
}

/// Records what the forwarder sends while it brings the daemon up.
private final class RecordingClient: DaemonClient, Sendable {
    enum Sent: Equatable {
        case configure(resumeInterrupted: Bool)
        case options(DaemonOptions)
    }

    private let sent = Mutex<[Sent]>([])
    var log: [Sent] { sent.withLock { $0 } }

    func configure(_ settings: AWSSettings) async throws {
        sent.withLock { $0.append(.configure(resumeInterrupted: settings.resumeInterrupted)) }
    }
    func setOptions(_ options: DaemonOptions) async throws {
        sent.withLock { $0.append(.options(options)) }
    }
    func enqueue(_ request: EnqueueRequest) async throws -> String { "up-1" }
    func watch() -> AsyncThrowingStream<UploadSnapshot, Error> { AsyncThrowingStream { _ in } }
    func watchFiles(uploadID: String) -> AsyncThrowingStream<FileSnapshot, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func retry(uploadID: String, fileIndexes: [Int]) async throws {}
    func remove(uploadID: String, fileIndexes: [Int], deleteFromBucket: Bool) async throws {}
}

/// The options a test hands to the forwarder, changed by hand.
private final class OptionsBox: Sendable {
    private let stored: Mutex<DaemonOptions>

    init(_ options: DaemonOptions) { stored = Mutex(options) }

    var value: DaemonOptions {
        get { stored.withLock { $0 } }
        set { stored.withLock { $0 = newValue } }
    }
}

extension UploadSnapshot {
    /// A folder upload that is paused, by the user unless told otherwise.
    static func paused(
        _ id: String, _ name: String, in parent: String = "/Users/someone/Pictures", files: Int = 12,
        finished: Int = 5, total: Int64, sent: Int64, reason: PauseReason? = .byUser
    ) -> UploadSnapshot {
        UploadSnapshot(
            id: id, fileName: name, localPath: "\(parent)/\(name)", objectKey: "quick-uploads/\(name)/",
            bytesTotal: total, bytesSent: sent, state: .paused, errorMessage: "", kind: .folder,
            filesTotal: files, filesFinished: finished, pauseReason: reason)
    }
}

extension DownloadSnapshot {
    static func make(
        _ id: String, of uploadID: String, files: [Int] = [], to path: String = "/Users/someone/Downloads/thing",
        total: Int64 = 480_000_000, done: Int64 = 120_000_000, _ state: DownloadState, error: String = ""
    ) -> DownloadSnapshot {
        DownloadSnapshot(
            id: id, uploadID: uploadID, fileIndexes: files, name: (path as NSString).lastPathComponent,
            destinationPath: path, bytesTotal: total, bytesDone: done, state: state, errorMessage: error)
    }
}

@MainActor
final class TransferControlsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_794_500_000)

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition(), "condition not met within 3s")
    }

    private func record(_ snapshot: UploadSnapshot) -> UploadRecord {
        var ledger = UploadLedger()
        ledger.apply(snapshot, now: now)
        return ledger[snapshot.id]!
    }

    // MARK: States in the ledger

    func testPausedUploadKeepsItsReasonAndGoesBackToWaitingWhenResumed() {
        var ledger = UploadLedger()
        ledger.apply(.make("a", "a.zip", total: 100, sent: 40, .uploading), now: now)
        XCTAssertNil(ledger.apply(.paused("a", "a.zip", total: 100, sent: 40), now: now))
        XCTAssertEqual(ledger["a"]?.state, .paused)
        XCTAssertEqual(ledger["a"]?.pauseReason, .byUser)
        XCTAssertEqual(ledger["a"]?.isOpen, true)
        XCTAssertNil(ledger["a"]?.endedAt)

        ledger.apply(.make("a", "a.zip", total: 100, sent: 40, .queued), now: now)
        XCTAssertEqual(ledger["a"]?.state, .queued)
        XCTAssertNil(ledger["a"]?.pauseReason)
    }

    func testCanceledUploadEndsWithoutBeingAnnouncedOrBlamedOnTheService() {
        var ledger = UploadLedger()
        ledger.apply(.make("a", "a.zip", total: 100, sent: 40, .uploading), now: now)
        let announced = ledger.apply(.make("a", "a.zip", total: 100, sent: 40, .canceled), now: now)
        XCTAssertNil(announced)
        XCTAssertEqual(ledger["a"]?.state, .canceled)
        XCTAssertEqual(ledger["a"]?.endedAt, now)
        XCTAssertEqual(ledger["a"]?.errorMessage, "")
        XCTAssertEqual(ledger.condition, .none)
    }

    func testCanceledUploadComesBackWhenItIsSentAgain() {
        var ledger = UploadLedger()
        ledger.apply(.make("a", "a.zip", total: 100, sent: 40, .canceled), now: now)
        ledger.apply(.make("a", "a.zip", total: 100, sent: 40, .queued), now: now)
        XCTAssertEqual(ledger["a"]?.state, .queued)
        XCTAssertNil(ledger["a"]?.endedAt)
    }

    func testListOrderPutsPausedAfterWaitingAndBeforeEnded() {
        var ledger = UploadLedger()
        ledger.apply(.make("done", "d", total: 1, sent: 1, .finished), now: now)
        ledger.apply(.paused("held", "h", total: 10, sent: 1, reason: .onHold), now: now)
        ledger.apply(.make("wait", "w", total: 1, .queued), now: now)
        ledger.apply(.make("gone", "g", total: 1, .canceled), now: now.addingTimeInterval(5))
        ledger.apply(.make("send", "s", total: 2, sent: 1, .uploading), now: now)
        XCTAssertEqual(ledger.ordered.map(\.id), ["send", "wait", "held", "gone", "done"])
    }

    func testDaemonGoingAwayCutsOffHeldUploadsButLeavesTheOnesTheUserPaused() {
        var ledger = UploadLedger()
        ledger.apply(.paused("mine", "m", total: 10, sent: 1, reason: .byUser), now: now)
        ledger.apply(.paused("held", "h", total: 10, sent: 1, reason: .onHold), now: now)
        ledger.interrupt(now: now)
        XCTAssertEqual(ledger["mine"]?.state, .paused)
        XCTAssertEqual(ledger["held"]?.state, .failed)
        XCTAssertEqual(ledger["held"]?.errorMessage, UploadLedger.interruptedMessage)
    }

    // MARK: Words

    func testProgressLinesOfThePausedAndCanceledStates() {
        let paused = record(.paused("a", "vacation-2026", total: 1_900_000_000, sent: 800_000_000))
        XCTAssertEqual(UploadText.progressLine(paused), .init(text: "Paused, 800 MB of 1.9 GB sent", tone: .hold))

        let held = record(.paused("b", "design-assets", total: 640_000_000, sent: 76_000_000, reason: .onHold))
        XCTAssertEqual(
            UploadText.progressLine(held),
            .init(text: "Paused while on battery, 76.0 MB of 640 MB sent", tone: .hold))

        let canceled = record(
            .folder("c", "raw-footage", files: 12, finished: 5, total: 100, sent: 40, .canceled))
        XCTAssertEqual(UploadText.progressLine(canceled), .init(text: "Canceled, 5 of 12 files sent", tone: .normal))

        let file = record(.make("d", "a.zip", total: 900_000, sent: 300_000, .canceled))
        XCTAssertEqual(UploadText.progressLine(file).text, "Canceled, 300 KB of 900 KB sent")
    }

    func testHistoryLineOfACanceledUploadSaysWhen() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let ended = calendar.date(from: DateComponents(year: 2026, month: 11, day: 12, hour: 18, minute: 20))!
        let today = calendar.date(from: DateComponents(year: 2026, month: 11, day: 13, hour: 9))!
        var ledger = UploadLedger()
        ledger.apply(
            UploadSnapshot(
                id: "c", fileName: "raw-footage", localPath: "/m/raw-footage", objectKey: "", bytesTotal: 100,
                bytesSent: 40, state: .canceled, errorMessage: "", kind: .folder, filesTotal: 12,
                filesFinished: 5, endedAt: ended), now: today)
        XCTAssertEqual(
            UploadText.historyLine(ledger["c"]!, now: today, calendar: calendar),
            .init(text: "Canceled yesterday at 18:20, 5 of 12 files sent", tone: .normal))
    }

    func testFileLinesOfThePausedAndCanceledStates() {
        XCTAssertEqual(
            UploadText.fileLine(.make(0, "a.jpg", total: 7_600_000, sent: 2_900_000, .paused)),
            .init(text: "Paused, 2.9 MB of 7.6 MB", tone: .hold))
        XCTAssertEqual(
            UploadText.fileLine(.make(0, "a.jpg", total: 7_600_000, .canceled)),
            .init(text: "Canceled, 7.6 MB", tone: .normal))
    }

    func testDownloadLines() {
        let home = "/Users/someone"
        let running = DownloadSnapshot.make("d", of: "u", to: "\(home)/Downloads/archive-2025", .downloading)
        XCTAssertEqual(
            UploadText.downloadLine(running, home: home),
            .init(text: "Downloading to ~/Downloads, 120 MB of 480 MB", tone: .down))
        let done = DownloadSnapshot.make("d", of: "u", to: "\(home)/Downloads/invoice.pdf", .finished)
        XCTAssertEqual(UploadText.downloadLine(done, home: home), .init(text: "Downloaded to ~/Downloads", tone: .normal))
        let failed = DownloadSnapshot.make("d", of: "u", .failed, error: "No internet connection")
        XCTAssertEqual(
            UploadText.downloadLine(failed, home: home),
            .init(text: "Download failed, no internet connection", tone: .bad))
        XCTAssertNil(UploadText.downloadLine(.make("d", of: "u", .canceled), home: home))
        XCTAssertEqual(UploadText.fileDownloadLine(running).text, "Downloading, 120 MB of 480 MB")
    }

    // MARK: Menu contents by state

    func testMenuByStateIsTheMockupsMenuRow() {
        let sending = record(.make("a", "a.zip", total: 10, sent: 3, .uploading))
        let waiting = record(.make("a", "a.zip", total: 10, .queued))
        let pausedByUser = record(.paused("a", "f", total: 10, sent: 3))
        let pausedOnBattery = record(.paused("a", "f", total: 10, sent: 3, reason: .onHold))
        let canceled = record(.folder("a", "f", files: 12, finished: 5, total: 10, sent: 4, .canceled))
        let finished = record(.make("a", "a.zip", total: 10, sent: 10, .finished))

        XCTAssertEqual(UploadAction.available(for: sending), [.pause, .cancelUpload])
        XCTAssertEqual(UploadAction.available(for: waiting), [.pause, .cancelUpload])
        XCTAssertEqual(UploadAction.available(for: pausedByUser), [.resume, .cancelUpload])
        XCTAssertEqual(UploadAction.available(for: pausedOnBattery), [.cancelUpload])
        XCTAssertEqual(UploadAction.available(for: canceled), [.retry, .download, .remove, .deleteFromBucket])
        XCTAssertEqual(UploadAction.available(for: finished), [.download, .remove, .deleteFromBucket])
        XCTAssertEqual(UploadAction.available(for: finished, isDownloading: true), [.cancelDownload])
    }

    func testMenuOfEndedUploadsWithNothingInTheBucketOffersNoDownload() {
        let canceled = record(.make("a", "a.zip", total: 10, sent: 3, .canceled))
        let failed = record(.make("a", "a.zip", total: 10, sent: 3, .failed, error: "x"))
        XCTAssertEqual(UploadAction.available(for: canceled), [.retry, .remove])
        XCTAssertEqual(UploadAction.available(for: failed), [.retry, .remove])
    }

    func testMenuOfAFileByState() {
        XCTAssertEqual(UploadAction.available(for: .make(0, "a", total: 1, .paused)), [])
        XCTAssertEqual(UploadAction.available(for: .make(0, "a", total: 1, .uploading)), [])
        XCTAssertEqual(UploadAction.available(for: .make(0, "a", total: 1, .canceled)), [.retry, .remove])
        XCTAssertEqual(
            UploadAction.available(for: .make(0, "a", total: 1, sent: 1, .finished)),
            [.download, .remove, .deleteFromBucket])
        XCTAssertEqual(
            UploadAction.available(for: .make(0, "a", total: 1, sent: 1, .finished), isDownloading: true),
            [.cancelDownload])
    }

    func testMenuTitlesAndRedEntries() {
        XCTAssertEqual(
            [UploadAction.pause, .resume, .cancelUpload, .download, .cancelDownload].map(\.title),
            ["Pause", "Resume", "Cancel upload", "Download…", "Cancel download"])
        XCTAssertTrue(UploadAction.cancelUpload.isDestructive)
        XCTAssertTrue(UploadAction.deleteFromBucket.isDestructive)
        XCTAssertFalse(UploadAction.cancelDownload.isDestructive)
    }

    func testDetailHeaderButtonsAndFileTabsByState() {
        XCTAssertEqual(UploadDetailView.headerButtonKind(.resume), .primary)
        XCTAssertEqual(UploadDetailView.headerButtonKind(.cancelUpload), .danger)
        XCTAssertEqual(UploadDetailView.headerButtonKind(.pause), .plain)

        let paused = record(.paused("a", "f", total: 10, sent: 3))
        XCTAssertEqual(UploadDetailView.fileTabs(for: paused).map(\.title), ["All", "Paused", "Finished", "Failed"])
        let canceled = record(.make("a", "a.zip", total: 10, sent: 3, .canceled))
        XCTAssertEqual(
            UploadDetailView.fileTabs(for: canceled).map(\.title), ["All", "Finished", "Failed", "Canceled"])
        XCTAssertEqual(UploadDetailView.fileFilter(.waiting, for: paused), .all)
    }

    // MARK: Filters

    func testHistoryShowsPausedAndCanceledTabsOnlyWhileUsed() {
        var ledger = UploadLedger()
        ledger.apply(.make("a", "a.zip", total: 10, sent: 10, .finished), now: now)
        var query = UploadQuery()
        XCTAssertEqual(
            query.historyTabs(in: ledger.records).map(\.filter), [.all, .inProgress, .waiting, .finished, .failed])

        ledger.apply(.paused("b", "f", total: 10, sent: 3), now: now)
        ledger.apply(.make("c", "c.zip", total: 10, .canceled), now: now)
        let tabs = query.historyTabs(in: ledger.records)
        XCTAssertEqual(tabs.map(\.filter), UploadStateFilter.allCases)
        XCTAssertEqual(tabs.first { $0.filter == .paused }?.count, 1)

        query.state = .canceled
        XCTAssertEqual(query.apply(to: ledger.records).map(\.id), ["c"])
        XCTAssertEqual(query.emptyTitle, "No canceled uploads")
    }

    func testOverviewCountsPausedAsInProgressAndLeavesCanceledUnderAll() {
        var ledger = UploadLedger()
        ledger.apply(.paused("b", "f", total: 10, sent: 3), now: now)
        ledger.apply(.make("c", "c.zip", total: 10, .canceled), now: now)
        var query = UploadQuery(waitingCountsAsInProgress: true)
        query.state = .inProgress
        XCTAssertEqual(query.apply(to: ledger.records).map(\.id), ["b"])
        query.state = .failed
        XCTAssertEqual(query.apply(to: ledger.records), [])
    }

    func testFileListGroupsPausedAndCanceledFiles() {
        var list = UploadFileList()
        list.apply(.make(0, "a", total: 1, sent: 1, .finished))
        list.apply(.make(1, "b", total: 1, .paused))
        list.apply(.make(2, "c", total: 1, .canceled))
        list.apply(.make(3, "d", total: 1, .failed))
        XCTAssertEqual(list.indexes(.all), [3, 1, 2, 0])
        XCTAssertEqual(list.indexes(.paused), [1])
        XCTAssertEqual(list.indexes(.canceled), [2])
    }

    // MARK: Tray status, batch and icon

    func testBatchWhoseUploadsAreAllPausedIsPausedAndShowsNoBarInTheMenuBar() async {
        let client = StubDaemonClient()
        let tray = TrayViewModel(client: client, sleep: { _ in })
        tray.configured(with: AWSSettings(accessKeyID: "k", secretAccessKey: "s", region: "r", bucket: "b"))
        await tray.drop([URL(fileURLWithPath: "/tmp/a")])
        await tray.drop([URL(fileURLWithPath: "/tmp/b")])
        tray.apply(.paused("up-1", "a", files: 12, finished: 5, total: 100, sent: 40))
        // One upload still waits: the batch is not paused yet.
        tray.apply(.make("up-2", "b", total: 100, .queued))
        guard case .uploading = tray.state else { return XCTFail("\(tray.state)") }
        XCTAssertNotNil(TrayIcon.progress(for: tray.state))

        tray.apply(.paused("up-2", "b", files: 1, finished: 0, total: 100, sent: 0))
        XCTAssertEqual(tray.state, .paused(remaining: 8, total: 13, fraction: 0.2, reason: .byUser))
        XCTAssertEqual(tray.statusText, "Paused, 8 of 13 files left")
        XCTAssertNil(TrayIcon.progress(for: tray.state))
        let look = TrayPresentation(tray)
        XCTAssertEqual(look.status?.isPaused, true)
        XCTAssertEqual(look.status?.fraction, 0.2)
        XCTAssertEqual(look.dropTitle, "Drop more to queue")

        tray.apply(.paused("up-2", "b", files: 1, finished: 0, total: 100, sent: 0, reason: .onHold))
        XCTAssertEqual(tray.statusText, "Paused while on battery, 8 of 13 files left")

        tray.apply(.make("up-2", "b", total: 100, .queued))
        guard case .uploading = tray.state else { return XCTFail("\(tray.state)") }
    }

    func testCancelingTheOnlyUploadOfABatchLeavesTheTrayIdle() async {
        let client = StubDaemonClient()
        let tray = TrayViewModel(client: client, sleep: { _ in })
        tray.configured(with: AWSSettings(accessKeyID: "k", secretAccessKey: "s", region: "r", bucket: "b"))
        await tray.drop([URL(fileURLWithPath: "/tmp/a")])
        tray.apply(.make("up-1", "a", total: 100, sent: 10, .uploading))
        tray.apply(.make("up-1", "a", total: 100, sent: 10, .canceled))
        XCTAssertEqual(tray.state, .idle)
        XCTAssertEqual(tray.uploads.ledger["up-1"]?.state, .canceled)
    }

    func testCanceledUploadStopsCountingInABatchThatGoesOn() {
        var tracker = BatchTracker()
        tracker.register(id: "a")
        tracker.register(id: "b")
        tracker.apply(.make("a", "a", total: 100, sent: 50, .uploading))
        tracker.apply(.make("b", "b", total: 100, sent: 50, .uploading))
        XCTAssertTrue(tracker.apply(.make("a", "a", total: 100, sent: 50, .canceled)))
        XCTAssertEqual(tracker.total, 1)
        XCTAssertEqual(tracker.fraction, 0.5)
        XCTAssertNil(tracker.pause)
    }

    func testDaemonRestartKeepsUserPausedUploadsInTheBatch() {
        var tracker = BatchTracker()
        tracker.register(id: "a")
        tracker.register(id: "b")
        tracker.apply(.paused("a", "a", total: 100, sent: 50, reason: .byUser))
        tracker.apply(.paused("b", "b", total: 100, sent: 50, reason: .onHold))
        tracker.interrupted()
        XCTAssertEqual(tracker.pause, .byUser)
        XCTAssertEqual(tracker.firstError, BatchTracker.interruptedMessage)
    }

    // MARK: Pause, resume, cancel

    func testPauseResumeAndCancelAskTheDaemonAndShowARefusalOnTheRow() async {
        let fixture = await UIFixture()
        await fixture.enqueue(1)
        fixture.tray.apply(.make("up-1", "a.zip", total: 100, sent: 10, .uploading))
        await fixture.tray.pause(uploadID: "up-1")
        await fixture.tray.resume(uploadID: "up-1")
        await fixture.tray.cancel(uploadID: "up-1")
        XCTAssertEqual(fixture.client.log, [.pause("up-1"), .resume("up-1"), .cancel("up-1")])
        XCTAssertNil(fixture.tray.uploads.ledger["up-1"]?.actionError)

        fixture.client.failActions(with: .rejected("This upload has already finished"))
        await fixture.tray.pause(uploadID: "up-1")
        let refused = fixture.tray.uploads.ledger["up-1"]!
        XCTAssertEqual(UploadText.progressLine(refused), .init(text: "This upload has already finished", tone: .bad))

        // The refusal goes away when the upload changes state.
        fixture.tray.apply(.make("up-1", "a.zip", total: 100, sent: 100, .finished))
        XCTAssertNil(fixture.tray.uploads.ledger["up-1"]?.actionError)
    }

    func testPausingAnUploadTheDaemonNoLongerKnowsForgetsIt() async {
        let fixture = await UIFixture()
        await fixture.enqueue(1)
        fixture.tray.apply(.make("up-1", "a.zip", total: 100, sent: 10, .uploading))
        fixture.client.failActions(with: .notFound)
        await fixture.tray.pause(uploadID: "up-1")
        XCTAssertNil(fixture.tray.uploads.ledger["up-1"])
    }

    func testChoosingMenuEntriesReachesTheDaemon() async throws {
        let fixture = await UIFixture()
        await fixture.enqueue(1)
        fixture.tray.apply(.make("up-1", "a.zip", total: 100, sent: 10, .uploading))
        fixture.context.choose(.pause, for: .upload(id: "up-1"))
        fixture.context.choose(.cancelUpload, for: .upload(id: "up-1"))
        try await waitUntil { fixture.client.log.count == 2 }
        XCTAssertEqual(Set(fixture.client.log), [.pause("up-1"), .cancel("up-1")])
    }

    // MARK: Options

    func testOptionsFromPreferencesAndPowerSource() {
        let scratch = ScratchDefaults()
        let preferences = AppPreferences(defaults: scratch.defaults)
        preferences.checkAfterSending = true
        XCTAssertEqual(
            preferences.daemonOptions(onBattery: true),
            DaemonOptions(speedLimitBytesPerSecond: 0, verifyUploads: true, holdUploads: false))

        preferences.limitSpeed = true
        preferences.speedLimitMBps = 10
        preferences.checkAfterSending = false
        preferences.pauseOnBattery = true
        XCTAssertEqual(
            preferences.daemonOptions(onBattery: true),
            DaemonOptions(speedLimitBytesPerSecond: 10_000_000, verifyUploads: false, holdUploads: true))
        XCTAssertFalse(preferences.daemonOptions(onBattery: false).holdUploads)
    }

    func testOptionsAreReportedWhenAPreferenceOrThePowerSourceChangesThem() async throws {
        let scratch = ScratchDefaults()
        let preferences = AppPreferences(defaults: scratch.defaults)
        let power = FakePowerSource()
        var changes = 0
        let sync = UploadOptionsSync(preferences: preferences, power: power, changed: { changes += 1 })
        sync.start()
        XCTAssertEqual(changes, 0)

        // On battery without the preference: nothing to hold, nothing to say.
        power.set(onBattery: true)
        XCTAssertEqual(changes, 0)

        preferences.pauseOnBattery = true
        try await waitUntil { changes == 1 }
        XCTAssertTrue(sync.options.holdUploads)

        power.set(onBattery: false)
        XCTAssertEqual(changes, 2)
        XCTAssertFalse(sync.options.holdUploads)

        preferences.limitSpeed = true
        try await waitUntil { changes == 3 }
        preferences.speedLimitMBps = 25
        try await waitUntil { changes == 4 }
        XCTAssertEqual(sync.options.speedLimitBytesPerSecond, 25_000_000)

        // A preference that is not a daemon option changes nothing.
        preferences.notifyWhenUploadsEnd.toggle()
        preferences.retryCount = 7
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(changes, 4)
    }

    func testForwarderSendsTheHoldAtLaunchThenConfiguresThenSendsOptionsOnEveryChange() async throws {
        let client = RecordingClient()
        let (events, sink) = AsyncStream<DaemonEvent>.makeStream()
        let tray = TrayViewModel(client: client, sleep: { _ in })
        let settings = AWSSettings(accessKeyID: "k", secretAccessKey: "s", region: "r", bucket: "b")
        let current = OptionsBox(DaemonOptions(speedLimitBytesPerSecond: 0, verifyUploads: true, holdUploads: true))
        let forwarder = DaemonEventForwarder(
            client: client, events: events, viewModel: tray, loadSettings: { settings },
            sleep: { try await Task.sleep(for: $0) },
            resumeInterrupted: { true },
            options: { current.value })
        forwarder.start()
        defer { forwarder.stop() }

        // Nothing is sent before the daemon is up.
        forwarder.optionsChanged()
        sink.yield(.ready)
        let held = DaemonOptions(speedLimitBytesPerSecond: 0, verifyUploads: true, holdUploads: true)
        try await waitUntil { client.log.count == 3 }
        XCTAssertEqual(client.log, [.options(held), .configure(resumeInterrupted: true), .options(held)])

        let free = DaemonOptions(speedLimitBytesPerSecond: 5_000_000, verifyUploads: false, holdUploads: false)
        current.value = free
        forwarder.optionsChanged()
        try await waitUntil { client.log.count == 4 }
        XCTAssertEqual(client.log.last, .options(free))
    }

    // MARK: Downloads

    func testDownloadFlowFromTheMenuToTheFinishedLine() async throws {
        let fixture = await UIFixture()
        await fixture.loadEndedUploads()
        let target = UploadActionTarget.upload(id: "up-2")
        let folder = "\(UIFixture.home)/Downloads"

        fixture.context.choose(.download, for: target)
        try await waitUntil { !fixture.client.log.isEmpty }
        XCTAssertEqual(fixture.client.log, [.startDownload(uploadID: "up-2", fileIndexes: [], destinationDir: folder)])

        fixture.tray.apply(DownloadSnapshot.make("dl-1", of: "up-2", to: "\(folder)/vacation-2026", .downloading))
        let running = try XCTUnwrap(fixture.context.download(of: target))
        XCTAssertEqual(running.fraction, 0.25)
        let record = try XCTUnwrap(fixture.tray.uploads.ledger["up-2"])
        XCTAssertEqual(
            UploadAction.available(for: record, isDownloading: fixture.context.downloads.active(target) != nil),
            [.cancelDownload])

        fixture.context.choose(.cancelDownload, for: target)
        try await waitUntil { fixture.client.log.count == 2 }
        XCTAssertEqual(fixture.client.log.last, .cancelDownload("dl-1"))

        fixture.tray.apply(
            DownloadSnapshot.make(
                "dl-1", of: "up-2", to: "\(folder)/vacation-2026", done: 480_000_000, .finished))
        XCTAssertNil(fixture.context.downloads.active(target))
        XCTAssertEqual(
            UploadText.downloadLine(try XCTUnwrap(fixture.context.download(of: target)))?.text,
            "Downloaded to ~/Downloads")
    }

    func testDownloadOfOneFileIsKeptApartFromItsUpload() async throws {
        let fixture = await UIFixture()
        await fixture.loadEndedUploads()
        let file = UploadActionTarget.file(uploadID: "up-2", index: 3)
        // The snapshot can arrive before the call that started the download returns.
        fixture.tray.apply(DownloadSnapshot.make("dl-1", of: "up-2", files: [3], .downloading))
        XCTAssertNotNil(fixture.context.downloads[.upload(id: "up-2")])

        let id = await fixture.tray.download(file, to: "/tmp/out")
        XCTAssertEqual(id, "dl-1")
        XCTAssertEqual(
            fixture.client.log, [.startDownload(uploadID: "up-2", fileIndexes: [3], destinationDir: "/tmp/out")])
        XCTAssertNil(fixture.context.downloads[.upload(id: "up-2")])
        XCTAssertEqual(fixture.context.downloads[file]?.id, "dl-1")

        // The only file of a single-file upload is downloaded as the upload.
        XCTAssertEqual(fixture.context.resolved(.file(uploadID: "up-1", index: 0)), .upload(id: "up-1"))
    }

    func testDownloadTheDaemonRefusesOrThatFailsIsShownOnTheRow() async throws {
        let fixture = await UIFixture()
        await fixture.loadEndedUploads()
        let target = UploadActionTarget.upload(id: "up-1")
        fixture.client.failActions(with: .rejected("AWS denied permission to download: the access key needs the s3:GetObject permission"))
        let id = await fixture.tray.download(target, to: "/tmp/out")
        XCTAssertNil(id)
        XCTAssertEqual(
            UploadText.downloadLine(try XCTUnwrap(fixture.context.downloads[target])),
            .init(
                text: "Download failed, AWS denied permission to download: the access key needs the s3:GetObject permission",
                tone: .bad))

        // Trying again replaces the refusal with the new download.
        fixture.client.failActions(with: nil)
        await fixture.tray.download(target, to: "/tmp/out")
        XCTAssertNil(fixture.context.downloads[target])
        fixture.tray.apply(DownloadSnapshot.make("dl-1", of: "up-1", .failed, error: "No internet connection"))
        XCTAssertEqual(fixture.context.downloads[target]?.state, .failed)
    }

    func testCanceledDownloadLeavesNothingAndARemovedUploadTakesItsDownloadsAlong() async {
        let store = DownloadStore()
        store.apply(.make("d1", of: "a", .downloading))
        store.apply(.make("d1", of: "a", .canceled))
        XCTAssertNil(store[.upload(id: "a")])

        store.apply(.make("d2", of: "a", .finished))
        store.apply(.make("d3", of: "a", .downloading))
        // The older download's end does not hide the one that is running.
        store.apply(.make("d2", of: "a", .finished))
        XCTAssertEqual(store[.upload(id: "a")]?.id, "d3")

        store.forget(uploadID: "a")
        XCTAssertNil(store[.upload(id: "a")])
    }

    func testDaemonRestartForgetsDownloads() async {
        let fixture = await UIFixture()
        fixture.tray.apply(DownloadSnapshot.make("d1", of: "a", .downloading))
        fixture.tray.handle(.restarted)
        XCTAssertNil(fixture.tray.downloads[.upload(id: "a")])
    }

    // MARK: Buckets

    private static let three = [
        Bucket(name: "site-assets", region: "sa-east-1"), Bucket(name: "carlos-backups", region: "sa-east-1"),
        Bucket(name: "photos-archive", region: "us-east-1"),
    ]

    func testBucketListLoadsWithTheSavedKeyAndSaysHowManyWereFound() async {
        let fixture = await UIFixture()
        fixture.client.setBuckets(Self.three)
        let buckets = fixture.context.buckets
        XCTAssertFalse(buckets.offersList)

        await buckets.loadIfNeeded()
        XCTAssertEqual(buckets.phase, .loaded)
        XCTAssertTrue(buckets.offersList)
        XCTAssertEqual(buckets.buckets.map(\.name), ["carlos-backups", "photos-archive", "site-assets"])
        XCTAssertEqual(buckets.note, "3 buckets found in this account.")
        XCTAssertEqual(fixture.client.log, [.listBuckets(region: "sa-east-1")])

        // Already loaded for this key and region: not asked again, until "Reload list".
        await buckets.loadIfNeeded()
        XCTAssertEqual(fixture.client.log.count, 1)
        await buckets.reload()
        XCTAssertEqual(fixture.client.log.count, 2)
        XCTAssertEqual(BucketListModel.foundNote(1), "1 bucket found in this account.")
    }

    func testWhenListingIsDeniedTheNameCanStillBeTyped() async {
        let fixture = await UIFixture()
        let denied = "AWS denied permission to list buckets: the access key needs the s3:ListAllMyBuckets permission"
        fixture.client.failList(with: .rejected(denied))
        let buckets = fixture.context.buckets
        await buckets.loadIfNeeded()
        XCTAssertEqual(buckets.phase, .failed(denied))
        XCTAssertFalse(buckets.offersList)
        XCTAssertEqual(buckets.note, "\(denied). You can still type the bucket's name.")

        // The typed name is saved as before.
        fixture.context.account.bucket = "typed-by-hand"
        await fixture.context.account.commitDestination()
        XCTAssertEqual(fixture.store.loadDestination().bucket, "typed-by-hand")

        fixture.client.failList(with: nil)
        await buckets.reload()
        XCTAssertTrue(buckets.offersList)
    }

    func testWithoutAnAccountThereIsNothingToList() async {
        let fixture = await UIFixture(configured: false)
        await fixture.context.buckets.loadIfNeeded()
        XCTAssertEqual(fixture.context.buckets.phase, .noAccount)
        XCTAssertEqual(fixture.client.log, [])
    }

    func testChoosingABucketInAnotherRegionSavesThatRegionToo() async throws {
        let fixture = await UIFixture()
        fixture.client.setBuckets(Self.three)
        let buckets = fixture.context.buckets
        await buckets.loadIfNeeded()
        buckets.toggle()
        XCTAssertTrue(buckets.isOpen)

        buckets.choose(Bucket(name: "photos-archive", region: "us-east-1"))
        XCTAssertFalse(buckets.isOpen)
        try await waitUntil { fixture.store.loadDestination().bucket == "photos-archive" }
        XCTAssertEqual(fixture.store.loadDestination().region, "us-east-1")
        XCTAssertEqual(buckets.selectedName, "photos-archive")

        // A bucket whose region could not be read keeps the saved region.
        buckets.choose(Bucket(name: "site-assets", region: ""))
        try await waitUntil { fixture.store.loadDestination().bucket == "site-assets" }
        XCTAssertEqual(fixture.store.loadDestination().region, "us-east-1")
    }

    func testCreateAndUseCreatesInTheChosenRegionAndSelectsTheNewBucket() async throws {
        let fixture = await UIFixture()
        fixture.client.setBuckets(Self.three)
        let buckets = fixture.context.buckets
        await buckets.loadIfNeeded()
        var closed = false
        let create = buckets.makeCreateModel { closed = true }
        XCTAssertEqual(create.region, "sa-east-1")

        create.name = "  carlos-backups-2026 "
        create.region = "eu-west-1"
        await create.confirm()
        XCTAssertTrue(closed)
        XCTAssertNil(create.failure)
        XCTAssertEqual(fixture.client.log.last, .createBucket(name: "carlos-backups-2026", region: "eu-west-1"))
        XCTAssertTrue(buckets.buckets.contains(Bucket(name: "carlos-backups-2026", region: "eu-west-1")))
        try await waitUntil { fixture.store.loadDestination().bucket == "carlos-backups-2026" }
        XCTAssertEqual(fixture.store.loadDestination().region, "eu-west-1")
    }

    func testCreateFailuresStayOpenAndArePlacedByTheKindOfError() async {
        let fixture = await UIFixture()
        var closes = 0
        let create = fixture.context.buckets.makeCreateModel { closes += 1 }
        create.name = "backups"

        let taken = "This name is already taken by another AWS account. Bucket names are unique in all of AWS: try another one."
        fixture.client.failCreate(with: .alreadyExists(taken))
        await create.confirm()
        XCTAssertEqual(create.failure, .name(taken))
        XCTAssertEqual(create.nameError, taken)
        XCTAssertNil(create.boxError)

        // Typing another name forgets what was wrong with the old one.
        create.name = "backups-2"
        XCTAssertNil(create.failure)

        let invalid = "This name is not valid. Use 3 to 63 lowercase letters, numbers and hyphens, starting and ending with a letter or a number."
        fixture.client.failCreate(with: .invalidArgument(invalid))
        await create.confirm()
        XCTAssertEqual(create.failure, .name(invalid))

        let denied = "AWS denied permission to create buckets: the access key needs the s3:CreateBucket permission"
        fixture.client.failCreate(with: .rejected(denied))
        await create.confirm()
        XCTAssertEqual(create.failure, .box(denied))
        // A problem that is not about the name survives typing.
        create.name = "backups-3"
        XCTAssertEqual(create.boxError, denied)

        fixture.client.failCreate(with: .other("unimplemented"))
        await create.confirm()
        XCTAssertEqual(create.failure, .box("The bucket could not be created"))
        XCTAssertEqual(closes, 0)
        XCTAssertFalse(create.isWorking)

        create.cancel()
        XCTAssertEqual(closes, 1)
    }

    func testBucketCallErrorsKeepTheNameProblemsApart() {
        typealias Client = GRPCDaemonClient
        XCTAssertEqual(
            Client.mapBucketCall(code: .alreadyExists, message: "taken", fromDaemon: true), .alreadyExists("taken"))
        XCTAssertEqual(
            Client.mapBucketCall(code: .invalidArgument, message: "not valid", fromDaemon: true),
            .invalidArgument("not valid"))
        XCTAssertEqual(
            Client.mapBucketCall(code: .permissionDenied, message: "denied", fromDaemon: true), .rejected("denied"))
        // Not configured is no obstacle for these calls: the message is still for reading.
        XCTAssertEqual(
            Client.mapBucketCall(code: .failedPrecondition, message: "limit reached", fromDaemon: true),
            .rejected("limit reached"))
        XCTAssertEqual(
            Client.mapBucketCall(code: .unavailable, message: "No internet connection", fromDaemon: true),
            .rejected("No internet connection"))
        XCTAssertEqual(
            Client.mapBucketCall(code: .unavailable, message: "connect failed", fromDaemon: false), .unavailable)
        guard case .other = Client.mapBucketCall(code: .unimplemented, message: "unknown method", fromDaemon: true)
        else { return XCTFail("an unknown method is not a message for the user") }
    }

    func testSetupListsWithTheTypedKeyAndTakesTheRegionOfTheChosenBucket() async {
        let fixture = await UIFixture(configured: false)
        fixture.client.setBuckets(Self.three)
        let setup = SetupModel(
            store: fixture.store, buckets: BucketService(client: fixture.client), onSaved: { _ in },
            onFinished: { _, _ in })
        await setup.buckets.loadIfNeeded()
        XCTAssertEqual(setup.buckets.phase, .noAccount)

        setup.accessKeyID = "AKIAIOSFODNN7EXAMPLE"
        setup.secret = "not-a-real-secret-value"
        setup.region = "sa-east-1"
        await setup.buckets.loadIfNeeded()
        XCTAssertEqual(setup.buckets.note, "3 buckets found in this account.")
        XCTAssertEqual(fixture.client.log, [.listBuckets(region: "sa-east-1")])

        setup.buckets.choose(Bucket(name: "photos-archive", region: "us-east-1"))
        XCTAssertEqual(setup.bucket, "photos-archive")
        XCTAssertEqual(setup.region, "us-east-1")
    }

    func testRegionNamesOfTheCreateWindow() {
        let title = { (code: String) in AWSRegion.all.first { $0.code == code }?.longTitle }
        XCTAssertEqual(title("sa-east-1"), "South America (São Paulo)")
        XCTAssertEqual(title("us-east-1"), "US East (N. Virginia)")
        XCTAssertEqual(title("ca-central-1"), "Canada (Central)")
    }
}
