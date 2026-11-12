import Foundation
import Synchronization
import XCTest

@testable import Rabbithole

private final class FakeDaemonClient: DaemonClient, Sendable {
    private struct Calls {
        var configured: [AWSSettings] = []
        var enqueued: [String] = []
        var nextID = 1
        var enqueueError: DaemonError?
    }

    private let calls = Mutex(Calls())

    var configured: [AWSSettings] { calls.withLock { $0.configured } }
    var enqueued: [String] { calls.withLock { $0.enqueued } }

    func failEnqueue(with error: DaemonError) {
        calls.withLock { $0.enqueueError = error }
    }

    func configure(_ settings: AWSSettings) async throws {
        calls.withLock { $0.configured.append(settings) }
    }

    func enqueue(localPath: String) async throws -> String {
        try calls.withLock { state in
            if let error = state.enqueueError { throw error }
            state.enqueued.append(localPath)
            defer { state.nextID += 1 }
            return "up-\(state.nextID)"
        }
    }

    func watch() -> AsyncThrowingStream<UploadSnapshot, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

@MainActor
private final class ModelBox: Sendable {
    var model: TrayViewModel?
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
        isRegularFile: @escaping @Sendable (URL) async -> Bool = { _ in true }
    ) -> TrayViewModel {
        let model = TrayViewModel(
            client: client,
            isRegularFile: isRegularFile,
            sleep: { try await recorder.sleep($0) }
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

    func testUnreadableSettingsShowFailedAndASaveRecovers() {
        let model = makeViewModel(ready: false)
        model.settingsUnreadable()
        XCTAssertEqual(model.state, .failed("Saved AWS settings could not be read"))

        model.configured(with: settings)
        XCTAssertEqual(model.state, .idle)
    }

    func testDropIsRefusedWhenTheStateChangesDuringTheFileCheck() async {
        let client = FakeDaemonClient()
        let box = ModelBox()
        let model = makeViewModel(
            client: client,
            isRegularFile: { _ in
                await box.model?.handle(.restarted)
                return true
            })
        box.model = model
        await model.drop([file])

        XCTAssertEqual(client.enqueued, [])
        XCTAssertEqual(model.dropFeedback, .refused("Rabbithole is still starting"))
    }

    func testUnavailableDuringFileCheckStaysUnavailableAndSkipsEnqueue() async {
        let client = FakeDaemonClient()
        client.failEnqueue(with: .unavailable)
        let box = ModelBox()
        let model = makeViewModel(
            client: client,
            isRegularFile: { _ in
                await box.model?.handle(.unavailable)
                return true
            })
        box.model = model
        model.configured(with: settings)
        // The state flips to unavailable during the file check, so enqueue is never reached.
        await model.drop([file])

        XCTAssertEqual(model.state, .unavailable)
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
        let model = makeViewModel(recorder: recorder)
        await model.drop([file, URL(fileURLWithPath: "/tmp/other.jpg")])
        XCTAssertEqual(model.dropFeedback, .refused("Drop one file at a time"))

        for _ in 0..<50 where model.dropFeedback != .none { await Task.yield() }

        XCTAssertEqual(model.dropFeedback, .none)
        XCTAssertEqual(recorder.durations, [.seconds(2)])
    }

    func testNewerHoverIsNotClearedByAnEarlierRefusal() async {
        let model = makeViewModel()
        await model.drop([file, URL(fileURLWithPath: "/tmp/other.jpg")])
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
            (.invalidArgument("path is empty"), "This file cannot be read"),
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

    func testFolderIsRefused() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rabbithole-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let client = FakeDaemonClient()
        let model = makeViewModel(client: client, isRegularFile: TrayViewModel.isRegularFileOffMain)
        await model.drop([directory])

        XCTAssertEqual(model.dropFeedback, .refused("Folders are not supported yet"))
        XCTAssertEqual(client.enqueued, [])
    }

    func testPackageDirectoryIsRefused() async throws {
        let package = FileManager.default.temporaryDirectory
            .appendingPathComponent("rabbithole-\(UUID().uuidString).app")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: package) }

        let client = FakeDaemonClient()
        let model = makeViewModel(client: client, isRegularFile: TrayViewModel.isRegularFileOffMain)
        await model.drop([package])

        XCTAssertEqual(model.dropFeedback, .refused("Folders are not supported yet"))
        XCTAssertEqual(client.enqueued, [])
    }

    func testRegularFileOnDiskIsAccepted() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rabbithole-\(UUID().uuidString).txt")
        try Data("hi".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let client = FakeDaemonClient()
        let model = makeViewModel(client: client, isRegularFile: TrayViewModel.isRegularFileOffMain)
        await model.drop([url])

        XCTAssertEqual(client.enqueued, [url.path])
    }

    func testMultipleItemsRefused() async {
        let client = FakeDaemonClient()
        let model = makeViewModel(client: client)
        await model.drop([file, URL(fileURLWithPath: "/tmp/other.jpg")])

        XCTAssertEqual(model.dropFeedback, .refused("Drop one file at a time"))
        XCTAssertEqual(client.enqueued, [])
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
            client: client, isRegularFile: { _ in true },
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

    func testUnavailableAfterEvent() async {
        let client = FakeDaemonClient()
        let model = makeViewModel(client: client)
        model.handle(.unavailable)

        XCTAssertEqual(model.state, .unavailable)
        XCTAssertEqual(model.statusText, "Uploads are unavailable")

        await model.drop([file])
        XCTAssertEqual(client.enqueued, [])
        XCTAssertEqual(model.dropFeedback, .refused("Uploads are unavailable"))
    }

    func testUnavailableInterruptsUploadsSoSettingsSavedDoesNotShowStaleUploading() async {
        let model = makeViewModel()
        await model.drop([file])
        model.apply(snapshot("up-1", .uploading, sent: 10))
        model.handle(.unavailable)
        model.configured(with: settings)

        XCTAssertEqual(model.state, .failed("Upload interrupted"))
    }

    func testConfiguredClearsUnavailable() {
        let model = makeViewModel()
        model.handle(.unavailable)
        model.configured(with: settings)

        XCTAssertEqual(model.state, .idle)
    }

    func testConfiguredWithNilClearsUnavailableToNotConfigured() {
        let model = makeViewModel(settings: .none)
        model.handle(.unavailable)
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
