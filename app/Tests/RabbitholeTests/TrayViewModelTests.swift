import Foundation
import Synchronization
import XCTest

@testable import Rabbithole

private final class FakeDaemonClient: DaemonClient, Sendable {
    private struct Calls {
        var configured: [AWSSettings] = []
        var requests: [EnqueueRequest] = []
        var nextID = 1
        var enqueueError: DaemonError?
    }

    private let calls = Mutex(Calls())

    var configured: [AWSSettings] { calls.withLock { $0.configured } }
    /// One request per upload.
    var requests: [EnqueueRequest] { calls.withLock { $0.requests } }
    /// The paths of every request, flattened.
    var enqueued: [String] { requests.flatMap(\.paths) }

    func failEnqueue(with error: DaemonError) {
        calls.withLock { $0.enqueueError = error }
    }

    func configure(_ settings: AWSSettings) async throws {
        calls.withLock { $0.configured.append(settings) }
    }

    func enqueue(_ request: EnqueueRequest) async throws -> String {
        try calls.withLock { state in
            if let error = state.enqueueError { throw error }
            state.requests.append(request)
            defer { state.nextID += 1 }
            return "up-\(state.nextID)"
        }
    }

    func watch() -> AsyncThrowingStream<UploadSnapshot, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func watchFiles(uploadID: String) -> AsyncThrowingStream<FileSnapshot, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private final class SleepRecorder: Sendable {
    private let recorded = Mutex<[Duration]>([])
    var durations: [Duration] { recorded.withLock { $0 } }
    func sleep(_ duration: Duration) async throws {
        recorded.withLock { $0.append(duration) }
    }
}

@MainActor
final class TrayViewModelTests: XCTestCase {
    private static let sampleSettings = AWSSettings(
        accessKeyID: "AKIAEXAMPLEKEYID",
        secretAccessKey: "example-secret-value-123",
        region: "us-east-1",
        bucket: "my-backup-bucket"
    )
    private let settings = TrayViewModelTests.sampleSettings
    private let file = URL(fileURLWithPath: "/tmp/photo.jpg")

    private func makeViewModel(
        client: FakeDaemonClient = FakeDaemonClient(),
        settings: AWSSettings? = TrayViewModelTests.sampleSettings,
        recorder: SleepRecorder = SleepRecorder(),
        ready: Bool = true,
        makeRequest: @escaping ([String]) -> EnqueueRequest = { EnqueueRequest(paths: $0) }
    ) -> TrayViewModel {
        let model = TrayViewModel(
            client: client,
            sleep: { try await recorder.sleep($0) },
            makeRequest: makeRequest
        )
        // The model always starts in `starting`; most tests want a configured daemon.
        if ready { model.configured(with: settings) }
        return model
    }

    func testStartsInStartingUntilTheDaemonIsConfigured() {
        let model = makeViewModel(ready: false)

        XCTAssertEqual(model.state, .starting)
        XCTAssertEqual(model.statusText, "Starting…")
    }

    func testDropWhileStartingIsRefusedWithoutEnqueue() async {
        let client = FakeDaemonClient()
        let model = makeViewModel(client: client, ready: false)
        await model.drop([file])

        XCTAssertEqual(client.enqueued, [])
        XCTAssertEqual(model.dropFeedback, .refused("Rabbithole is still starting"))
        XCTAssertEqual(model.state, .starting)
    }

    func testConfiguredWithSettingsGoesIdleAndWithNilGoesNotConfigured() {
        let withSettings = makeViewModel(ready: false)
        withSettings.configured(with: settings)
        XCTAssertEqual(withSettings.state, .idle)

        let withoutSettings = makeViewModel(ready: false)
        withoutSettings.configured(with: nil)
        XCTAssertEqual(withoutSettings.state, .notConfigured)
    }

    func testConfiguredKeepsAnActiveBatch() async {
        let model = makeViewModel()
        await model.drop([file])
        model.apply(snapshot("up-1", .uploading, sent: 25))
        model.configured(with: settings)

        XCTAssertEqual(model.state, .uploading(remaining: 1, total: 1, fraction: 0.25))
    }

    func testUnreadableSettingsHaveTheirOwnStateAndASaveRecovers() {
        let model = makeViewModel(ready: false)
        model.settingsUnreadable()
        XCTAssertEqual(model.state, .settingsUnreadable)
        XCTAssertEqual(model.statusText, "Saved AWS settings could not be read")

        model.configured(with: settings)
        XCTAssertEqual(model.state, .idle)
    }

    func testDropWithUnreadableSettingsIsRefusedWithoutEnqueueAndKeepsTheMessage() async {
        let client = FakeDaemonClient()
        client.failEnqueue(with: .notConfigured)
        let model = makeViewModel(client: client, ready: false)
        model.settingsUnreadable()

        await model.drop([file])

        XCTAssertEqual(client.enqueued, [])
        XCTAssertEqual(model.dropFeedback, .refused("Saved AWS settings could not be read"))
        XCTAssertEqual(model.state, .settingsUnreadable)
        XCTAssertEqual(model.statusText, "Saved AWS settings could not be read")
    }

    func testRestartKeepsUnreadableSettingsAndFailedConfigureDoesNotClearThem() {
        let model = makeViewModel(ready: false)
        model.settingsUnreadable()

        model.handle(.restarted)
        XCTAssertEqual(model.state, .settingsUnreadable)

        model.configureFailed(keepingPreviousSettings: false)
        XCTAssertEqual(model.state, .settingsUnreadable)
    }

    func testSettingsSavedBeforeTheDaemonIsUpMovesUnreadableToStarting() {
        let model = makeViewModel(ready: false)
        model.settingsUnreadable()

        model.settingsSaved()

        XCTAssertEqual(model.state, .starting)
    }

    func testTerminalUnavailableTextRefusalAndSettingsSavedChangeNothing() async {
        let client = FakeDaemonClient()
        let model = makeViewModel(client: client)
        model.handle(.unavailable)
        let text = "Uploads are unavailable. Quit and reopen Rabbithole."

        XCTAssertEqual(model.state, .restartRequired)
        XCTAssertEqual(model.statusText, text)
        await model.drop([file])
        XCTAssertEqual(model.dropFeedback, .refused(text))
        XCTAssertEqual(client.enqueued, [])

        model.settingsSaved()
        model.configureFailed(keepingPreviousSettings: false)
        model.configured(with: settings)
        XCTAssertEqual(model.state, .restartRequired)
    }

    func testFailedConfigureWithPreviousSettingsKeepsAnActiveBatchAndShowsTheMessageWhenItEnds() async {
        let model = makeViewModel()
        await model.drop([file])
        model.apply(snapshot("up-1", .uploading, sent: 25))

        model.configureFailed(keepingPreviousSettings: true)
        XCTAssertEqual(model.state, .uploading(remaining: 1, total: 1, fraction: 0.25))

        model.apply(snapshot("up-1", .finished, sent: 100))
        XCTAssertEqual(model.state, .failed("AWS settings could not be applied"))

        model.configured(with: settings)
        XCTAssertEqual(model.state, .finished)
    }

    func testFailedConfigureWithPreviousSettingsWhenIdleShowsTheMessageAndStillAcceptsDrops() async {
        let client = FakeDaemonClient()
        let model = makeViewModel(client: client)

        model.configureFailed(keepingPreviousSettings: true)

        XCTAssertEqual(model.state, .failed("AWS settings could not be applied"))
        await model.drop([file])
        XCTAssertEqual(client.enqueued, [file.path])
    }

    func testFailedConfigureWithoutSettingsRefusesDropsWithTheNonTerminalText() async {
        let client = FakeDaemonClient()
        let model = makeViewModel(client: client)

        model.configureFailed(keepingPreviousSettings: false)

        XCTAssertEqual(model.state, .unavailable)
        XCTAssertEqual(model.statusText, "Uploads are unavailable")
        await model.drop([file])
        XCTAssertEqual(model.dropFeedback, .refused("Uploads are unavailable"))
        XCTAssertEqual(client.enqueued, [])
    }

    func testRestartGoesBackToStartingAndRefusesDrops() async {
        let client = FakeDaemonClient()
        let model = makeViewModel(client: client)
        model.handle(.restarted)

        XCTAssertEqual(model.state, .starting)
        await model.drop([file])
        XCTAssertEqual(client.enqueued, [])
    }

    func testFailedUploadMessageSurvivesBecomingReady() async {
        let model = makeViewModel()
        await model.drop([file])
        model.apply(snapshot("up-1", .failed, sent: 10, error: "access denied"))
        model.configured(with: settings)

        XCTAssertEqual(model.state, .failed("access denied"))
    }

    func testRefusalClearsAfterTwoSecondsOnTheInjectedSleep() async {
        let recorder = SleepRecorder()
        let model = makeViewModel(recorder: recorder, ready: false)
        await model.drop([file])
        XCTAssertEqual(model.dropFeedback, .refused("Rabbithole is still starting"))

        for _ in 0..<50 where model.dropFeedback != .none { await Task.yield() }

        XCTAssertEqual(model.dropFeedback, .none)
        XCTAssertEqual(recorder.durations, [.seconds(2)])
    }

    func testNewerHoverIsNotClearedByAnEarlierRefusal() async {
        let model = makeViewModel(ready: false)
        await model.drop([file])
        model.setHovering(true)

        for _ in 0..<50 { await Task.yield() }

        XCTAssertEqual(model.dropFeedback, .hovering)
    }


    private func snapshot(
        _ id: String,
        _ state: UploadState,
        sent: Int64 = 0,
        total: Int64 = 100,
        error: String = ""
    ) -> UploadSnapshot {
        UploadSnapshot(
            id: id, fileName: "photo.jpg", localPath: "/tmp/photo.jpg", objectKey: "k/\(id)",
            bytesTotal: total, bytesSent: sent, state: state, errorMessage: error)
    }

    func testNotConfiguredWhenNoSettings() async {
        let client = FakeDaemonClient()
        let model = makeViewModel(client: client, settings: nil)

        XCTAssertEqual(model.state, .notConfigured)
        await model.drop([file])

        XCTAssertEqual(client.enqueued, [])
        XCTAssertEqual(model.dropFeedback, .refused("Connect your AWS account first"))
    }

    func testIdleWhenConfigured() {
        let model = makeViewModel()

        XCTAssertEqual(model.state, .idle)
        XCTAssertEqual(model.statusText, "Ready")
    }

    func testUploadingShowsOneOfOneFilesLeft() async {
        let model = makeViewModel()
        await model.drop([file])
        model.apply(snapshot("up-1", .uploading, sent: 25))

        XCTAssertEqual(model.state, .uploading(remaining: 1, total: 1, fraction: 0.25))
        XCTAssertEqual(model.statusText, "1 of 1 files left")
    }

    func testStateIsUploadingRightAfterDropBeforeAnySnapshot() async {
        let model = makeViewModel()
        await model.drop([file])

        XCTAssertEqual(model.state, .uploading(remaining: 1, total: 1, fraction: 0))
    }

    func testFinishedState() async {
        let model = makeViewModel()
        await model.drop([file])
        model.apply(snapshot("up-1", .finished, sent: 100))

        XCTAssertEqual(model.state, .finished)
        XCTAssertEqual(model.statusText, "Upload finished")
    }

    func testFirstSnapshotAlreadyFinishedBeforeEnqueueReturns() async {
        let model = makeViewModel()
        model.apply(snapshot("up-1", .finished, sent: 100))
        await model.drop([file])

        XCTAssertEqual(model.state, .finished)
    }

    func testQueuedGoesStraightToFinished() async {
        let model = makeViewModel()
        await model.drop([file])
        model.apply(snapshot("up-1", .queued))
        model.apply(snapshot("up-1", .finished, sent: 100))

        XCTAssertEqual(model.state, .finished)
    }

    func testZeroByteFileFinishes() async {
        let model = makeViewModel()
        await model.drop([file])
        model.apply(snapshot("up-1", .uploading, sent: 0, total: 0))
        XCTAssertEqual(model.state, .uploading(remaining: 1, total: 1, fraction: 0))

        model.apply(snapshot("up-1", .finished, sent: 0, total: 0))
        XCTAssertEqual(model.state, .finished)
    }

    func testFailedShowsErrorMessageUntilNextUploadStarts() async {
        let model = makeViewModel()
        await model.drop([file])
        model.apply(snapshot("up-1", .failed, sent: 10, error: "access denied"))

        XCTAssertEqual(model.state, .failed("access denied"))
        XCTAssertEqual(model.statusText, "access denied")

        await model.drop([file])
        XCTAssertEqual(model.state, .uploading(remaining: 1, total: 1, fraction: 0))
    }

    func testReplayedSnapshotsDoNotChangeState() {
        let model = makeViewModel()
        model.apply(snapshot("old", .finished, sent: 100))
        model.apply(snapshot("old2", .failed, error: "old failure"))

        XCTAssertEqual(model.state, .idle)
    }

    func testReplayedSnapshotDoesNotOverwriteEnqueueFailure() async {
        let client = FakeDaemonClient()
        let model = makeViewModel(client: client)
        client.failEnqueue(with: .unavailable)
        await model.drop([file])
        model.apply(snapshot("old", .finished, sent: 100))

        XCTAssertEqual(model.state, .failed("Uploads are unavailable"))
    }

    func testEnqueueFailureMessages() async {
        let cases: [(DaemonError, String)] = [
            (.notConfigured, "Connect your AWS account first"),
            (.unavailable, "Uploads are unavailable"),
            (.invalidArgument("\"notes\" has no files to send"), "\"notes\" has no files to send"),
            (.invalidArgument(""), "This file cannot be read"),
            (.other("rpc error: code = Internal"), "Upload could not be started"),
        ]
        for (error, message) in cases {
            let client = FakeDaemonClient()
            client.failEnqueue(with: error)
            let model = makeViewModel(client: client)
            await model.drop([file])

            XCTAssertEqual(model.state, .failed(message), "for \(error)")
            XCTAssertEqual(model.statusText, message)
        }
    }

    func testEnqueueFailureRegistersNothing() async {
        let client = FakeDaemonClient()
        client.failEnqueue(with: .other("x"))
        let model = makeViewModel(client: client)
        await model.drop([file])
        model.apply(snapshot("up-1", .uploading, sent: 10))

        XCTAssertEqual(model.state, .failed("Upload could not be started"))
    }

    func testSeveralItemsAndFoldersBecomeOneUpload() async {
        let client = FakeDaemonClient()
        let model = makeViewModel(client: client)
        let folder = URL(fileURLWithPath: "/tmp/vacation-2026", isDirectory: true)
        let other = URL(fileURLWithPath: "/tmp/other.jpg")
        await model.drop([file, folder, other])

        XCTAssertEqual(
            client.requests, [EnqueueRequest(paths: ["/tmp/photo.jpg", "/tmp/vacation-2026", "/tmp/other.jpg"])],
            "one enqueue call with every path, in the order they were handed over")
        XCTAssertEqual(
            model.state, .uploading(remaining: 3, total: 3, fraction: 0),
            "until the daemon reports its count, each item stands for one file")
        XCTAssertEqual(model.statusText, "3 of 3 files left")
    }

    func testEveryUploadCarriesTheSkipPatternsAndParallelFilesItIsBuiltWith() async {
        let client = FakeDaemonClient()
        let model = makeViewModel(
            client: client,
            makeRequest: { EnqueueRequest(paths: $0, skipPatterns: [".DS_Store", "*.tmp"], parallelFiles: 6) })
        await model.drop([file])
        model.apply(snapshot("up-1", .failed, error: "Bucket not found"))
        await model.retry(model.uploads.ledger.records)

        let expected = EnqueueRequest(paths: [file.path], skipPatterns: [".DS_Store", "*.tmp"], parallelFiles: 6)
        XCTAssertEqual(client.requests, [expected, expected])
    }

    func testFilesLeftCountsFilesNotUploads() async {
        let model = makeViewModel()
        await model.drop([URL(fileURLWithPath: "/tmp/vacation-2026", isDirectory: true)])
        XCTAssertEqual(model.statusText, "1 of 1 files left")

        model.apply(.folder("up-1", "vacation-2026", files: 12, finished: 4, failed: 1, total: 1200, sent: 500, .uploading))
        XCTAssertEqual(model.statusText, "7 of 12 files left")

        await model.drop([file])
        XCTAssertEqual(model.statusText, "8 of 13 files left", "a second upload joins the batch with its files")

        model.apply(.folder("up-1", "vacation-2026", files: 12, finished: 11, failed: 1, total: 1200, sent: 1100, .failed, error: "1 of 12 files could not be sent"))
        XCTAssertEqual(model.statusText, "1 of 13 files left")

        model.apply(snapshot("up-2", .finished, sent: 100))
        XCTAssertEqual(model.state, .failed("1 of 12 files could not be sent"))
    }

    func testConfirmationSaysHowManyItemsWereAdded() async {
        var observed: (DropFeedback, String)?
        var modelRef: TrayViewModel?
        let model = TrayViewModel(
            client: FakeDaemonClient(),
            sleep: { _ in
                if let model = modelRef { observed = (model.dropFeedback, TrayPresentation(model).dropTitle) }
            })
        modelRef = model
        model.configured(with: settings)
        await model.drop([file, URL(fileURLWithPath: "/tmp/a"), URL(fileURLWithPath: "/tmp/b")])

        XCTAssertEqual(observed?.0, .confirmed)
        XCTAssertEqual(observed?.1, "3 items added")
        XCTAssertEqual(TrayPresentation(model).dropTitle, "Drop more to queue", "then back to normal")
    }

    func testConfirmationLastsTwoSeconds() async {
        let recorder = SleepRecorder()
        let model = makeViewModel(recorder: recorder)
        await model.drop([file])

        XCTAssertEqual(recorder.durations, [.seconds(2)])
        XCTAssertEqual(model.dropFeedback, .none)
    }

    func testConfirmedShowsWhileSleeping() async {
        let client = FakeDaemonClient()
        var observed: DropFeedback?
        var modelRef: TrayViewModel?
        let model = TrayViewModel(
            client: client,
            sleep: { _ in observed = modelRef?.dropFeedback }
        )
        modelRef = model
        model.configured(with: settings)
        await model.drop([file])

        XCTAssertEqual(observed, .confirmed)
        XCTAssertEqual(model.dropFeedback, .none)
    }

    func testHoveringFeedback() {
        let model = makeViewModel()
        model.setHovering(true)
        XCTAssertEqual(model.dropFeedback, .hovering)
        model.setHovering(false)
        XCTAssertEqual(model.dropFeedback, .none)
    }

    func testDaemonRestartMarksUploadsInterrupted() async {
        let model = makeViewModel()
        await model.drop([file])
        model.apply(snapshot("up-1", .uploading, sent: 10))
        model.handle(.restarted)
        XCTAssertEqual(model.state, .starting)

        model.configured(with: settings)

        XCTAssertEqual(model.state, .failed("Upload interrupted"))
        XCTAssertEqual(model.statusText, "Upload interrupted")
    }

    func testRestartWithNothingInFlightReturnsToIdleOnceConfigured() {
        let model = makeViewModel()
        model.handle(.restarted)
        model.configured(with: settings)

        XCTAssertEqual(model.state, .idle)
    }

    func testUnavailableEventInterruptsUploads() async {
        let model = makeViewModel()
        await model.drop([file])
        model.apply(snapshot("up-1", .uploading, sent: 10))
        model.handle(.unavailable)

        XCTAssertEqual(model.state, .restartRequired)
    }

    func testFailedConfigureInterruptsUploadsSoSettingsSavedDoesNotShowStaleUploading() async {
        let model = makeViewModel()
        await model.drop([file])
        model.apply(snapshot("up-1", .uploading, sent: 10))
        model.configureFailed(keepingPreviousSettings: false)
        model.configured(with: settings)

        XCTAssertEqual(model.state, .failed("Upload interrupted"))
    }

    func testConfiguredClearsUnavailable() {
        let model = makeViewModel()
        model.configureFailed(keepingPreviousSettings: false)
        model.configured(with: settings)

        XCTAssertEqual(model.state, .idle)
    }

    func testConfiguredWithNilClearsUnavailableToNotConfigured() {
        let model = makeViewModel(settings: .none)
        model.configureFailed(keepingPreviousSettings: false)
        model.configured(with: nil)

        XCTAssertEqual(model.state, .notConfigured)
    }

    func testConfiguredAfterSaveEnablesDrops() async {
        let client = FakeDaemonClient()
        let model = makeViewModel(client: client, settings: .none)
        XCTAssertEqual(model.state, .notConfigured)

        model.configured(with: settings)

        XCTAssertEqual(model.state, .idle)
        await model.drop([file])
        XCTAssertEqual(client.enqueued, [file.path])
    }
}
