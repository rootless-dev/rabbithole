import AppKit
import Foundation
import XCTest

@testable import Rabbithole

final class TrayPresentationTests: XCTestCase {
    private func look(
        _ state: TrayState, feedback: DropFeedback = .none, hover: Int = 1,
        condition: ServiceCondition = .none, text: String = "status"
    ) -> TrayPresentation {
        TrayPresentation(
            state: state, statusText: text, feedback: feedback, itemCount: hover, condition: condition)
    }

    func testIdleShowsTheDropAreaWithNoStatusAndTheWholeMenu() {
        let idle = look(.idle)
        XCTAssertEqual(idle.topBlock, .drop)
        XCTAssertEqual(idle.dropTitle, "Drop files or folders")
        XCTAssertNil(idle.dropSubtitle)
        XCTAssertEqual(idle.dropStyle, .normal)
        XCTAssertNil(idle.status)
        XCTAssertTrue(idle.uploadsEnabled)
        XCTAssertTrue(idle.recentEnabled)
        XCTAssertFalse(idle.isDragging)
    }

    func testUploadingShowsTheCounterAndInvitesMore() {
        let uploading = look(.uploading(remaining: 7, total: 12, fraction: 0.42), text: "7 of 12 files left")
        XCTAssertEqual(uploading.dropTitle, "Drop more to queue")
        XCTAssertEqual(uploading.status, .init(text: "7 of 12 files left", tone: .normal, fraction: 0.42))
    }

    func testBeforeSetupTheUploadItemsAreOff() {
        let setup = look(.notConfigured, feedback: .hovering)
        XCTAssertEqual(setup.topBlock, .setup)
        XCTAssertFalse(setup.uploadsEnabled)
        XCTAssertFalse(setup.recentEnabled)
        XCTAssertFalse(setup.isDragging, "the setup block is not a drop target")
    }

    func testDraggingAndTheConfirmation() {
        let over = look(.idle, feedback: .hovering)
        XCTAssertEqual(over.dropStyle, .over)
        XCTAssertEqual(over.dropTitle, "Release to upload")
        XCTAssertEqual(over.dropSubtitle, "1 item to Quick uploads")
        XCTAssertTrue(over.isDragging)

        let several = look(.idle, feedback: .hovering, hover: 3)
        XCTAssertEqual(several.dropStyle, .over)
        XCTAssertEqual(several.dropTitle, "Release to upload")
        XCTAssertEqual(several.dropSubtitle, "3 items to Quick uploads")

        let done = look(.uploading(remaining: 1, total: 1, fraction: 0), feedback: .confirmed)
        XCTAssertEqual(done.dropStyle, .done)
        XCTAssertEqual(done.dropTitle, "1 item added")
        XCTAssertEqual(done.dropSubtitle, "Upload started")

        let severalDone = look(.uploading(remaining: 3, total: 3, fraction: 0), feedback: .confirmed, hover: 3)
        XCTAssertEqual(severalDone.dropTitle, "3 items added")
        XCTAssertEqual(severalDone.dropSubtitle, "Upload started")

        let refused = look(.idle, feedback: .refused("Rabbithole is still starting"))
        XCTAssertEqual(refused.dropTitle, "Rabbithole is still starting")
        XCTAssertEqual(refused.dropStyle, .normal)
    }

    func testRejectedKeyReplacesTheDropAreaAndStopsUploads() {
        let rejected = look(.failed("AWS rejected the access key"), condition: .keyRejected)
        XCTAssertEqual(rejected.topBlock, .keyRejected)
        XCTAssertFalse(rejected.uploadsEnabled)
        XCTAssertTrue(rejected.recentEnabled)
    }

    func testLostConnectionIsSaidInTheStatusAndTheDropArea() {
        let offline = look(.failed("No internet connection"), condition: .offline)
        XCTAssertEqual(offline.topBlock, .drop)
        XCTAssertEqual(offline.dropSubtitle, "No connection: uploads may fail")
        XCTAssertEqual(offline.status, .init(text: "No internet connection", tone: .warn, fraction: nil))
        XCTAssertTrue(offline.uploadsEnabled)
    }

    func testStatesWithoutAWorkingDaemonShowTheirTextAndDisableUploads() {
        for state in [TrayState.starting, .unavailable, .restartRequired, .settingsUnreadable] {
            let look = look(state, text: "why")
            XCTAssertEqual(look.status?.text, "why")
            XCTAssertFalse(look.uploadsEnabled)
            XCTAssertTrue(look.recentEnabled)
        }
        XCTAssertEqual(look(.finished, text: "Upload finished").status?.text, "Upload finished")
    }

    func testRecentListLinesUpWithItsRowBesideTheTray() {
        let tray = CGRect(x: 800, y: 600, width: 232, height: 287)
        let frame = TrayPanelPositioner.recentFrame(trayFrame: tray, rowTop: 128, width: 196, contentHeight: 150)
        XCTAssertEqual(frame.maxX, 797, "3 points left of the tray window")
        XCTAssertEqual(frame.width, 196)
        XCTAssertEqual(frame.maxY, 887 - 124, "first row level with the Recent uploads row")
        XCTAssertEqual(frame.height, 150)
    }
}

@MainActor
final class TrayViewModelUploadsTests: XCTestCase {
    private func makeModel(client: StubDaemonClient = StubDaemonClient()) -> TrayViewModel {
        let model = TrayViewModel(client: client, sleep: { _ in })
        model.configured(
            with: AWSSettings(accessKeyID: "id", secretAccessKey: "secret", region: "r", bucket: "b"))
        return model
    }

    func testEverySnapshotReachesTheLedgerEvenWhenTheBatchIgnoresIt() {
        let model = makeModel()
        model.apply(.make("replayed", "old.txt", total: 5, sent: 5, .finished))
        XCTAssertEqual(model.state, .idle, "a replayed upload is not part of a batch")
        XCTAssertEqual(model.uploads.ledger["replayed"]?.state, .finished)
    }

    func testRestartAndTerminalFailureInterruptTheLedger() {
        let model = makeModel()
        model.apply(.make("a", "a.bin", total: 5, sent: 1, .uploading))
        model.handle(.restarted)
        XCTAssertEqual(model.uploads.ledger["a"]?.errorMessage, "Upload interrupted")
        model.apply(.make("b", "b.bin", total: 5, sent: 1, .uploading))
        model.handle(.unavailable)
        XCTAssertEqual(model.uploads.ledger["b"]?.state, .failed)
    }

    func testRejectedKeyRefusesDropsUntilSettingsAreConfiguredAgain() async {
        let client = StubDaemonClient()
        let model = makeModel(client: client)
        await model.drop([URL(fileURLWithPath: "/tmp/a")])
        model.apply(.make("up-1", "a", total: 5, .failed, error: "AWS rejected the access key"))
        XCTAssertFalse(model.acceptsUploads)

        await model.drop([URL(fileURLWithPath: "/tmp/b")])
        XCTAssertEqual(client.enqueued, ["/tmp/a"])
        XCTAssertEqual(model.dropFeedback, .refused("AWS rejected the access key"))

        model.configured(
            with: AWSSettings(accessKeyID: "new", secretAccessKey: "secret", region: "r", bucket: "b"))
        XCTAssertTrue(model.acceptsUploads)
        await model.drop([URL(fileURLWithPath: "/tmp/b")])
        XCTAssertEqual(client.enqueued, ["/tmp/a", "/tmp/b"])
    }

    func testClipboardWithAFileUploadsItAndWithoutOneIsRefused() async {
        let client = StubDaemonClient()
        let model = makeModel(client: client)
        await model.uploadFromClipboard([])
        XCTAssertEqual(model.dropFeedback, .refused("The clipboard has no file to upload"))
        XCTAssertTrue(client.enqueued.isEmpty)

        await model.uploadFromClipboard([URL(fileURLWithPath: "/tmp/copied.pdf")])
        XCTAssertEqual(client.enqueued, ["/tmp/copied.pdf"])
        XCTAssertEqual(model.state, .uploading(remaining: 1, total: 1, fraction: 0))

        let copied = [URL(fileURLWithPath: "/tmp/a.pdf"), URL(fileURLWithPath: "/tmp/photos", isDirectory: true)]
        await model.uploadFromClipboard(copied)
        XCTAssertEqual(
            client.requests.last?.paths, ["/tmp/a.pdf", "/tmp/photos"],
            "several copied files and folders are one upload")
    }

    func testRetryOfAFailedUploadSendsEverythingItWasHandedAsOneUpload() async {
        let client = StubDaemonClient()
        let model = makeModel(client: client)
        let paths = ["/tmp/report-q3.pdf", "/tmp/photos", "/tmp/notes.txt"]
        await model.drop(paths.map { URL(fileURLWithPath: $0) })
        model.apply(.several("up-1", paths, files: 9, finished: 6, failed: 3, total: 900, sent: 600, .failed, error: "3 of 9 files could not be sent"))
        XCTAssertEqual(model.state, .failed("3 of 9 files could not be sent"))

        let count = await model.retry(model.uploads.ledger.records)
        XCTAssertEqual(count, 1)
        XCTAssertEqual(client.requests.map(\.paths), [paths, paths])
        XCTAssertEqual(model.state, .uploading(remaining: 3, total: 3, fraction: 0))
    }

    func testRetryEnqueuesEachFailedFileAgainAndClearsTheCondition() async {
        let client = StubDaemonClient()
        let model = makeModel(client: client)
        await model.drop([URL(fileURLWithPath: "/tmp/a")])
        model.apply(.make("up-1", "a", in: "/tmp", total: 5, .failed, error: "No internet connection"))
        XCTAssertEqual(model.uploads.ledger.condition, .offline)

        let failed = model.uploads.ledger.failedByCondition
        let count = await model.retry(failed)
        XCTAssertEqual(count, 1)
        XCTAssertEqual(client.enqueued, ["/tmp/a", "/tmp/a"])
        XCTAssertEqual(model.uploads.ledger.condition, .none)
        XCTAssertEqual(model.state, .uploading(remaining: 1, total: 1, fraction: 0))
    }

    func testRetryThatCannotEnqueueShowsWhyAndRetryWhileUnavailableDoesNothing() async {
        let client = StubDaemonClient()
        let model = makeModel(client: client)
        await model.drop([URL(fileURLWithPath: "/tmp/a")])
        model.apply(.make("up-1", "a", in: "/tmp", total: 5, .failed, error: "Bucket not found"))
        let failed = model.uploads.ledger.records

        client.failEnqueue(with: .invalidArgument("gone"))
        let none = await model.retry(failed)
        XCTAssertEqual(none, 0)
        XCTAssertEqual(model.state, .failed("gone"), "the daemon's own words are shown")

        client.failEnqueue(with: nil)
        model.handle(.unavailable)
        let refused = await model.retry(failed)
        XCTAssertEqual(refused, 0)
        XCTAssertEqual(client.enqueued, ["/tmp/a"])
    }

    func testHoverRemembersHowManyItemsAreHeld() {
        let model = makeModel()
        model.setHovering(true, itemCount: 3)
        XCTAssertEqual(model.feedbackItemCount, 3)
        XCTAssertEqual(TrayPresentation(model).dropSubtitle, "3 items to Quick uploads")
        model.setHovering(false)
        XCTAssertEqual(model.dropFeedback, .none)
    }
}

final class UploadFileListTests: XCTestCase {
    private func file(_ index: Int, _ state: UploadState, sent: Int64 = 0) -> FileSnapshot {
        .make(index, "vacation-2026/IMG_\(index).jpg", total: 100, sent: sent, state)
    }

    func testFilesAreListedSendingThenFailedThenWaitingThenFinishedEachInTheirOwnOrder() {
        var list = UploadFileList()
        for (index, state) in [(5, UploadState.queued), (0, .finished), (3, .uploading), (4, .queued), (1, .finished), (2, .failed)] {
            XCTAssertTrue(list.apply(file(index, state)), "a new file changes the listing")
        }
        XCTAssertEqual(list.count, 6)
        XCTAssertEqual(list.indexes(.all), [3, 2, 4, 5, 0, 1])
        XCTAssertEqual(list.indexes(.inProgress), [3])
        XCTAssertEqual(list.indexes(.waiting), [4, 5])
        XCTAssertEqual(list.indexes(.finished), [0, 1])
        XCTAssertEqual(list.indexes(.failed), [2])
    }

    func testProgressKeepsTheListingAndAStateChangeMovesOnlyThatFile() {
        var list = UploadFileList()
        for index in 0..<4 { list.apply(file(index, .queued)) }

        XCTAssertTrue(list.apply(file(2, .uploading, sent: 10)))
        XCTAssertFalse(list.apply(file(2, .uploading, sent: 60)), "progress alone does not reorder")
        XCTAssertEqual(list[2]?.bytesSent, 60)
        XCTAssertEqual(list.indexes(.all), [2, 0, 1, 3])

        XCTAssertTrue(list.apply(file(2, .finished, sent: 100)))
        XCTAssertTrue(list.apply(file(0, .failed)))
        XCTAssertEqual(list.indexes(.all), [0, 1, 3, 2])
        XCTAssertEqual(list.count, 4, "the same index is the same file")
    }

    func testInterruptFailsWaitingAndSendingFilesOnly() {
        var list = UploadFileList()
        list.apply(file(0, .finished, sent: 100))
        list.apply(file(1, .uploading, sent: 40))
        list.apply(file(2, .queued))
        XCTAssertTrue(list.interrupt(message: "Upload interrupted"))
        XCTAssertEqual(list.indexes(.failed), [1, 2])
        XCTAssertEqual(list[1]?.errorMessage, "Upload interrupted")
        XCTAssertEqual(list[1]?.bytesSent, 40)
        XCTAssertEqual(list.indexes(.finished), [0])
        XCTAssertFalse(list.interrupt(message: "Upload interrupted"))
    }

    func testTensOfThousandsOfFilesStayCheapToFollow() {
        var list = UploadFileList()
        let count = 50_000
        let started = ContinuousClock.now
        for index in 0..<count { list.apply(file(index, .queued)) }
        // Every file is sent and finishes, four at a time, as a folder upload goes.
        for index in 0..<count {
            list.apply(file(index, .uploading, sent: 50))
            if index >= 4 { list.apply(file(index - 4, .finished, sent: 100)) }
        }
        let elapsed = ContinuousClock.now - started
        XCTAssertEqual(list.indexes(.inProgress), [count - 4, count - 3, count - 2, count - 1])
        XCTAssertEqual(list.indexes(.finished).count, count - 4)
        XCTAssertEqual(list.indexes(.all).prefix(4), [count - 4, count - 3, count - 2, count - 1])
        XCTAssertLessThan(elapsed, .seconds(5), "150,000 updates must not take a sort each")
    }
}

@MainActor
final class UploadFilesModelTests: XCTestCase {
    private func stream(
        _ files: [FileSnapshot], failing error: DaemonError? = nil
    ) -> AsyncThrowingStream<FileSnapshot, Error> {
        AsyncThrowingStream { continuation in
            for file in files { continuation.yield(file) }
            continuation.finish(throwing: error)
        }
    }

    func testFollowLoadsTheFilesOfOneUploadAndANewUploadReplacesThem() async {
        let model = UploadFilesModel(publishInterval: .zero)
        XCTAssertEqual(model.phase, .waiting)
        await model.follow(
            uploadID: "up-1",
            stream: stream([.make(0, "a.jpg", total: 10, .uploading), .make(1, "b.jpg", total: 10, .queued)]))
        XCTAssertEqual(model.phase, .loaded)
        XCTAssertEqual(model.count, 2)
        XCTAssertEqual(model.indexes(.all), [0, 1])
        XCTAssertEqual(model.file(at: 1)?.relativePath, "b.jpg")

        await model.follow(uploadID: "up-2", stream: stream([.make(0, "c.jpg", of: "up-2", total: 10, .finished)]))
        XCTAssertEqual(model.count, 1)
        XCTAssertEqual(model.file(at: 0)?.relativePath, "c.jpg")

        model.clear()
        XCTAssertEqual(model.count, 0)
        XCTAssertEqual(model.phase, .waiting)
        XCTAssertNil(model.uploadID)
    }

    func testAStreamThatFailsLeavesNothingToShowOrInterruptsWhatWasShown() async {
        let unknown = UploadFilesModel(publishInterval: .zero)
        await unknown.follow(uploadID: "gone", stream: stream([], failing: .notFound))
        XCTAssertEqual(unknown.phase, .unavailable)

        let interrupted = UploadFilesModel(publishInterval: .zero)
        await interrupted.follow(
            uploadID: "up-1",
            stream: stream(
                [.make(0, "a.jpg", total: 10, .finished), .make(1, "b.jpg", total: 10, sent: 4, .uploading)],
                failing: .unavailable))
        XCTAssertEqual(interrupted.phase, .loaded)
        XCTAssertEqual(interrupted.indexes(.failed), [1])
        XCTAssertEqual(interrupted.file(at: 1)?.errorMessage, "Upload interrupted")
    }

    func testChangesArePublishedTogetherAfterTheInterval() async throws {
        let model = UploadFilesModel(publishInterval: .milliseconds(20))
        let (stream, continuation) = AsyncThrowingStream<FileSnapshot, Error>.makeStream()
        let following = Task { await model.follow(uploadID: "up-1", stream: stream) }
        for index in 0..<500 { continuation.yield(.make(index, "f\(index).jpg", total: 10, .queued)) }
        XCTAssertEqual(model.phase, .waiting, "nothing is announced before the interval has passed")
        for _ in 0..<200 where model.count < 500 || model.phase != .loaded {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.count, 500)
        XCTAssertEqual(model.phase, .loaded)

        following.cancel()
        await following.value
        XCTAssertEqual(model.count, 500, "a cancelled subscription keeps what it had")
    }

    func testTheWindowModelFollowsFilesOnlyWhileADetailIsOpenAndTheWindowShows() async throws {
        let client = StubDaemonClient()
        client.setFiles([.make(0, "a.jpg", total: 10, .finished)], of: "up-1")
        client.setFiles([.make(0, "b.jpg", of: "up-2", total: 10, .finished)], of: "up-2")
        let model = MainWindowModel(detailFiles: UploadFilesModel(publishInterval: .zero))
        model.watchFiles = { client.watchFiles(uploadID: $0) }
        XCTAssertEqual(client.watchedFiles, [], "nothing is asked for before a detail opens")

        model.openDetail(id: "up-1")
        try await waitUntil { model.detailFiles.count == 1 }
        XCTAssertEqual(client.watchedFiles, ["up-1"])
        XCTAssertEqual(model.detailFiles.file(at: 0)?.relativePath, "a.jpg")

        model.openDetail(id: "up-2")
        try await waitUntil { model.detailFiles.file(at: 0)?.relativePath == "b.jpg" }
        XCTAssertEqual(client.watchedFiles, ["up-1", "up-2"])

        model.windowShowing(false)
        XCTAssertEqual(model.detailFiles.count, 1, "a closed window keeps the list for when it comes back")
        model.windowShowing(true)
        XCTAssertEqual(client.watchedFiles, ["up-1", "up-2", "up-2"])

        model.closeDetail()
        XCTAssertEqual(model.detailFiles.count, 0)
        model.show(.history)
        XCTAssertEqual(client.watchedFiles.count, 3, "leaving the detail asks for nothing more")
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<300 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition())
    }
}

@MainActor
final class SettingsModelsTests: XCTestCase {
    private let sample = AWSSettings(
        accessKeyID: "AKIAIOSFODNN7EXAMPLE", secretAccessKey: "secret-value", region: "sa-east-1",
        bucket: "example-backups")

    func testPreferencesAreStoredAndRestored() {
        let scratch = ScratchDefaults()
        let first = AppPreferences(defaults: scratch.defaults)
        XCTAssertEqual(first.theme, .system)
        XCTAssertTrue(first.notifyWhenUploadsEnd)
        XCTAssertEqual(first.trayShortcut, .standard)
        XCTAssertEqual(first.simultaneousUploads, 4)
        XCTAssertEqual(first.retryCount, 3)
        XCTAssertEqual(first.skipPatterns, ".DS_Store, node_modules, *.tmp")

        first.theme = .dark
        first.notifyWhenUploadsEnd = false
        first.trayShortcut = Shortcut(keyCode: 5, carbonModifiers: 0x0100, display: "⌘G")
        first.resumeAutomatically = false
        first.retryFailed = false
        first.retryCount = 7
        first.simultaneousUploads = 2
        first.limitSpeed = true
        first.speedLimitMBps = 25
        first.pauseOnBattery = true
        first.checkAfterSending = false
        first.skipPatterns = "*.log"

        let second = AppPreferences(defaults: scratch.defaults)
        XCTAssertEqual(second.theme, .dark)
        XCTAssertFalse(second.notifyWhenUploadsEnd)
        XCTAssertEqual(second.trayShortcut, Shortcut(keyCode: 5, carbonModifiers: 0x0100, display: "⌘G"))
        XCTAssertFalse(second.resumeAutomatically)
        XCTAssertFalse(second.retryFailed)
        XCTAssertEqual(second.retryCount, 7)
        XCTAssertEqual(second.simultaneousUploads, 2)
        XCTAssertTrue(second.limitSpeed)
        XCTAssertEqual(second.speedLimitMBps, 25)
        XCTAssertTrue(second.pauseOnBattery)
        XCTAssertFalse(second.checkAfterSending)
        XCTAssertEqual(second.skipPatterns, "*.log")
    }

    func testSkipPatternsAndSimultaneousUploadsGoIntoEveryEnqueueRequest() {
        XCTAssertEqual(AppPreferences.patterns(from: ".DS_Store, node_modules, *.tmp"), [".DS_Store", "node_modules", "*.tmp"])
        XCTAssertEqual(AppPreferences.patterns(from: " *.log ,, ,Thumbs.db,"), ["*.log", "Thumbs.db"])
        XCTAssertEqual(AppPreferences.patterns(from: "  "), [])

        let scratch = ScratchDefaults()
        let preferences = AppPreferences(defaults: scratch.defaults)
        preferences.skipPatterns = "*.log, build"
        preferences.simultaneousUploads = 6
        XCTAssertEqual(
            preferences.enqueueRequest(for: ["/tmp/a", "/tmp/photos"]),
            EnqueueRequest(paths: ["/tmp/a", "/tmp/photos"], skipPatterns: ["*.log", "build"], parallelFiles: 6))
    }

    func testPreferencesOutOfRangeAreClampedAndNoSecretKeysExist() {
        let scratch = ScratchDefaults()
        scratch.defaults.set(900, forKey: "pref.uploads.simultaneous")
        scratch.defaults.set("sepia", forKey: "pref.theme")
        let preferences = AppPreferences(defaults: scratch.defaults)
        XCTAssertEqual(preferences.simultaneousUploads, 16)
        XCTAssertEqual(preferences.theme, .system)
        XCTAssertEqual(ThemeChoice.dark.appearance?.name, .darkAqua)
        XCTAssertNil(ThemeChoice.system.appearance)
    }

    func testAccountSummaryMasksTheKeyAndNeverHoldsTheSecret() async throws {
        let scratch = ScratchDefaults()
        let store = SettingsStore(credentials: StubCredentialStore(), defaults: scratch.defaults)
        try store.save(sample)
        let account = AccountModel(store: store, onSaved: { _ in })
        await account.reload()
        XCTAssertEqual(account.summary.maskedKeyID, "AKIA••••••••••••MPLE")
        XCTAssertTrue(account.summary.hasCredentials)
        XCTAssertEqual(account.region, "sa-east-1")
        XCTAssertEqual(account.bucket, "example-backups")
        XCTAssertEqual(account.folder, "quick-uploads/")
        XCTAssertFalse(String(describing: account.summary).contains("secret-value"))
        XCTAssertEqual(AWSSettingsForm.maskedKeyID("short"), "••••••••••••")
    }

    func testCommittingTheDestinationSavesItWithTheStoredKeyPair() async throws {
        let scratch = ScratchDefaults()
        let store = SettingsStore(credentials: StubCredentialStore(), defaults: scratch.defaults)
        try store.save(sample)
        var saved: [AWSSettings] = []
        let account = AccountModel(store: store, onSaved: { saved.append($0) })
        await account.reload()

        await account.commitDestination()
        XCTAssertTrue(saved.isEmpty, "nothing changed, nothing saved")

        account.bucket = " other-bucket "
        account.folder = "inbox"
        account.region = "eu-west-1"
        await account.commitDestination()
        var expected = sample
        expected.bucket = "other-bucket"
        expected.uploadsPrefix = "inbox/"
        expected.region = "eu-west-1"
        XCTAssertEqual(saved, [expected])
        XCTAssertEqual(try store.load(), expected)
        XCTAssertEqual(account.folder, "inbox/")
        XCTAssertNil(account.message)

        account.bucket = ""
        await account.commitDestination()
        XCTAssertEqual(account.message, "Enter the bucket name.")
        XCTAssertEqual(account.bucket, "other-bucket", "a refused change goes back to what is saved")
        XCTAssertEqual(saved.count, 1)
    }

    func testReplacingCredentialsKeepsTheDestinationAndWorksWhenTheOldOnesAreUnreadable() async throws {
        let scratch = ScratchDefaults()
        let credentials = StubCredentialStore()
        let store = SettingsStore(credentials: credentials, defaults: scratch.defaults)
        try store.save(sample)
        var saved: [AWSSettings] = []
        let account = AccountModel(store: store, onSaved: { saved.append($0) })
        await account.reload()

        let refused = await account.replaceCredentials(accessKeyID: "AKIANEWKEYID0000WXYZ", secret: " ")
        XCTAssertFalse(refused)
        XCTAssertEqual(account.message, "Enter the secret access key.")

        let accepted = await account.replaceCredentials(accessKeyID: "AKIANEWKEYID0000WXYZ", secret: "new-secret")
        XCTAssertTrue(accepted)
        XCTAssertEqual(saved.last?.secretAccessKey, "new-secret")
        XCTAssertEqual(saved.last?.bucket, "example-backups")
        XCTAssertEqual(account.summary.maskedKeyID, "AKIA••••••••••••WXYZ")

        credentials.failReads()
        await account.reload()
        XCTAssertTrue(account.summary.credentialsUnreadable)
        XCTAssertFalse(account.summary.hasCredentials)
        XCTAssertEqual(account.message, "Could not read the saved settings.")
        XCTAssertEqual(account.bucket, "example-backups", "the destination does not need the keychain")
    }

    func testUpdateWithoutSavedSettingsIsRefused() async {
        let scratch = ScratchDefaults()
        let store = SettingsStore(credentials: StubCredentialStore(), defaults: scratch.defaults)
        let result = await AWSSettingsForm.update(store: store) { $0.bucket = "x" }
        XCTAssertEqual(result, .failed("Connect your AWS account first."))
    }

    func testRegionListKeepsAnUnknownSavedRegionSelectable() {
        XCTAssertEqual(AWSRegion.all.first { $0.code == "sa-east-1" }?.title, "sa-east-1, São Paulo")
        XCTAssertEqual(AWSRegion.options(including: "sa-east-1").count, AWSRegion.all.count)
        XCTAssertEqual(AWSRegion.options(including: "xx-test-9").last?.code, "xx-test-9")
        XCTAssertEqual(AWSRegion.options(including: " ").count, AWSRegion.all.count)
    }

    func testSetupWalksThreeStepsSavesAtTheSecondAndDropsTheSecret() async throws {
        let scratch = ScratchDefaults()
        let store = SettingsStore(credentials: StubCredentialStore(), defaults: scratch.defaults)
        var saved: [AWSSettings] = []
        var finished: [(Bool, Bool)] = []
        let setup = SetupModel(
            store: store, onSaved: { saved.append($0) }, onFinished: { finished.append(($0, $1)) })
        XCTAssertEqual(setup.step, .connect)
        XCTAssertFalse(setup.canGoBack)
        XCTAssertEqual(setup.primaryTitle, "Continue")

        await setup.advance()
        XCTAssertEqual(setup.step, .connect)
        XCTAssertEqual(setup.message, "Enter the access key ID.")

        setup.accessKeyID = "AKIAIOSFODNN7EXAMPLE"
        setup.secret = "secret-value"
        setup.region = "sa-east-1"
        await setup.advance()
        XCTAssertEqual(setup.step, .bucket)
        XCTAssertNil(setup.message)
        XCTAssertTrue(saved.isEmpty, "nothing is saved before the bucket is chosen")

        await setup.advance()
        XCTAssertEqual(setup.step, .bucket)
        XCTAssertEqual(setup.message, "Enter the bucket name.")

        setup.bucket = "example-backups"
        setup.folder = "inbox"
        await setup.advance()
        XCTAssertEqual(setup.step, .ready)
        XCTAssertEqual(setup.primaryTitle, "Open dashboard")
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.first?.uploadsPrefix, "inbox/")
        XCTAssertEqual(try store.load()?.secretAccessKey, "secret-value")
        XCTAssertEqual(setup.secret, "", "the typed secret is dropped once saved")

        // Going back and forward again keeps the saved secret.
        setup.back()
        setup.back()
        XCTAssertEqual(setup.step, .connect)
        await setup.advance()
        setup.bucket = "second-bucket"
        await setup.advance()
        XCTAssertEqual(try store.load()?.bucket, "second-bucket")
        XCTAssertEqual(try store.load()?.secretAccessKey, "secret-value")

        setup.openAtLogin = false
        await setup.advance()
        XCTAssertEqual(finished.count, 1)
        XCTAssertEqual(finished.first?.0, false)
        XCTAssertEqual(finished.first?.1, true)

        setup.testConnection()
        XCTAssertNotNil(setup.testNote)
    }

    func testSetupOffersTheRegionAndBucketOfAnEarlierIncompleteSetup() {
        let scratch = ScratchDefaults()
        scratch.defaults.set("eu-west-1", forKey: "region")
        scratch.defaults.set("kept-bucket", forKey: "bucket")
        let store = SettingsStore(credentials: StubCredentialStore(), defaults: scratch.defaults)
        let setup = SetupModel(store: store, onSaved: { _ in }, onFinished: { _, _ in })
        XCTAssertEqual(setup.region, "eu-west-1")
        XCTAssertEqual(setup.bucket, "kept-bucket")
        XCTAssertEqual(setup.folder, "quick-uploads/")
    }

    func testLoginItemSwitchShowsWhatTheSystemHolds() async {
        let working = LoginItemModel(service: StubLoginItemService())
        await working.refresh()
        XCTAssertFalse(working.isOn)
        await working.set(true)
        XCTAssertTrue(working.isOn)
        XCTAssertNil(working.message)

        let refusing = LoginItemModel(service: StubLoginItemService(refuses: true))
        await refusing.set(true)
        XCTAssertFalse(refusing.isOn, "the switch goes back when the system refuses")
        XCTAssertEqual(refusing.message, "macOS did not allow Rabbithole to open at login.")
    }
}

@MainActor
final class SmallLogicTests: XCTestCase {
    func testMainWindowNavigation() {
        let model = MainWindowModel()
        XCTAssertEqual(model.section, .overview)
        model.openDetail(id: "a")
        XCTAssertEqual(model.detail?.origin, .overview)
        model.show(.history)
        XCTAssertNil(model.detail, "choosing a section leaves the detail")
        model.show(pane: .aws)
        XCTAssertEqual(model.section, .settings)
        XCTAssertEqual(model.settingsPane, .aws)
        model.openDetail(id: "b")
        XCTAssertEqual(model.detail?.origin, .history, "an upload opened from elsewhere belongs to History")
        XCTAssertEqual(model.section, .history)
        model.closeDetail()
        XCTAssertNil(model.detail)
        XCTAssertEqual(SettingsPane.allCases.map(\.title), ["App", "Uploads", "Destination", "AWS account", "Security"])
        XCTAssertEqual(MainSection.allCases.map(\.title), ["Overview", "History", "Settings"])
    }

    func testConnectionStatusOnlyClaimsConnectedAfterAFinishedUpload() {
        func status(_ has: Bool, _ unreadable: Bool, _ condition: ServiceCondition, _ finished: Int) -> String {
            ConnectionStatus(
                hasCredentials: has, unreadable: unreadable, condition: condition, finishedCount: finished
            ).short
        }
        XCTAssertEqual(status(false, false, .none, 0), "Not connected")
        XCTAssertEqual(status(true, false, .none, 0), "Key saved")
        XCTAssertEqual(status(true, false, .none, 2), "Connected")
        XCTAssertEqual(status(true, false, .keyRejected, 2), "Key rejected")
        XCTAssertEqual(status(true, false, .offline, 2), "No connection")
        XCTAssertEqual(status(false, true, .none, 0), "Key unreadable")
    }

    func testShortcutFromAKeyPress() {
        let recorded = GlobalHotKey.shortcut(keyCode: 0x20, modifiers: [.option, .command], characters: "u")
        XCTAssertEqual(recorded, .standard)
        XCTAssertEqual(
            GlobalHotKey.shortcut(keyCode: 1, modifiers: [.control, .shift], characters: "s")?.display, "⌃⇧S")
        XCTAssertNil(GlobalHotKey.shortcut(keyCode: 1, modifiers: [.shift], characters: "s"), "needs ⌘, ⌥ or ⌃")
        XCTAssertNil(GlobalHotKey.shortcut(keyCode: 1, modifiers: [.command], characters: nil))
    }

    func testPassphraseStrength() {
        XCTAssertEqual(PassphraseStrength.of(""), .empty)
        XCTAssertNil(PassphraseStrength.of("").hint)
        XCTAssertEqual(PassphraseStrength.of("abc123"), .weak)
        XCTAssertEqual(PassphraseStrength.of("abcdefghij"), .fair)
        XCTAssertEqual(PassphraseStrength.of("Abcdefgh1234"), .strong)
        XCTAssertEqual(PassphraseStrength.of("abcdefghijklmnop"), .strong)
        XCTAssertEqual(PassphraseStrength.of("Abcdefgh1234").hint, "Strong passphrase")
    }

    func testNotificationTextNamesTheFileAndNothingSecret() {
        var ledger = UploadLedger()
        let now = Date()
        let finished = ledger.apply(.make("a", "report.pdf", total: 2_100_000, sent: 2_100_000, .finished), now: now)
        let failed = ledger.apply(.make("b", "clip.mp4", total: 5, .failed, error: "Bucket not found"), now: now)
        XCTAssertEqual(UploadNotifier.content(for: finished!).title, "Upload finished")
        XCTAssertEqual(UploadNotifier.content(for: finished!).body, "report.pdf, 2.1 MB sent")
        XCTAssertEqual(UploadNotifier.content(for: failed!).title, "Upload failed")
        XCTAssertEqual(UploadNotifier.content(for: failed!).body, "clip.mp4: Bucket not found")
    }

    func testThumbnailCacheGeneratesOncePerFileAndSize() async {
        let counter = Counter()
        let cache = ThumbnailCache(generate: { _, _, _ in
            await counter.increment()
            return nil
        })
        XCTAssertNil(cache.image(for: "/tmp/a.jpg", side: 30, scale: 2))
        XCTAssertNil(cache.image(for: "/tmp/a.jpg", side: 30, scale: 2))
        XCTAssertNil(cache.image(for: "/tmp/a.jpg", side: 50, scale: 2))
        var calls = 0
        for _ in 0..<100 {
            calls = await counter.value
            if calls >= 2 { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        // Give a wrong third request the chance to show up.
        try? await Task.sleep(for: .milliseconds(50))
        calls = await counter.value
        XCTAssertEqual(calls, 2)
    }

    func testThumbnailCacheServesTheGeneratedPreviewAtItsPointSize() async {
        let cache = ThumbnailCache(generate: { url, side, _ in UIFixture.picture(for: url, side: side) })
        XCTAssertNil(cache.image(for: "/tmp/a.jpg", side: 30, scale: 2), "nothing until it is generated")
        var image: NSImage?
        for _ in 0..<100 where image == nil {
            try? await Task.sleep(for: .milliseconds(10))
            image = cache.image(for: "/tmp/a.jpg", side: 30, scale: 2)
        }
        XCTAssertEqual(image?.size, CGSize(width: 30, height: 22.5))
    }
}

private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}
