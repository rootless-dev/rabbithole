import Foundation
import GRPCCore
import XCTest

@testable import Rabbithole

final class UploadActionMenuTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_794_500_000)

    private func record(_ snapshot: UploadSnapshot) -> UploadRecord {
        var ledger = UploadLedger()
        ledger.apply(snapshot, now: start)
        return ledger[snapshot.id]!
    }

    func testAnUploadThatIsSendingOrWaitingCanBePausedOrCanceled() {
        let running: [UploadAction] = [.pause, .cancelUpload]
        XCTAssertEqual(UploadAction.available(for: record(.make("a", "a.bin", total: 10, .queued))), running)
        XCTAssertEqual(
            UploadAction.available(for: record(.make("a", "a.bin", total: 10, sent: 4, .uploading))), running)
        XCTAssertEqual(
            UploadAction.available(
                for: record(.folder("a", "trip", files: 12, finished: 5, failed: 1, total: 100, sent: 40, .uploading))),
            running, "nothing else, not even with a failed file, until it has ended")
    }

    func testTheMenuByKindOfUploadAsTheMockupListsIt() {
        let finished = record(.folder("a", "trip", files: 12, finished: 12, total: 100, sent: 100, .finished))
        XCTAssertEqual(UploadAction.available(for: finished), [.download, .remove, .deleteFromBucket])

        let failedEmpty = record(.make("b", "armadillo.png", total: 10, sent: 3, .failed, error: "Connection lost"))
        XCTAssertEqual(
            UploadAction.available(for: failedEmpty), [.retry, .remove], "nothing of it is in the bucket")

        let failedPartly = record(
            .folder("c", "trip", files: 12, finished: 9, failed: 3, total: 100, sent: 80, .failed, error: "x"))
        XCTAssertEqual(UploadAction.available(for: failedPartly), [.retry, .download, .remove, .deleteFromBucket])

        XCTAssertEqual(
            [UploadAction.retry, .remove, .deleteFromBucket].map(\.title),
            ["Try again", "Remove from history…", "Delete from bucket…"])
    }

    func testTheMenuOfAFileFollowsTheFileNotItsUpload() {
        XCTAssertEqual(UploadAction.available(for: .make(0, "a.jpg", total: 10, sent: 10, .finished)), [.download, .remove, .deleteFromBucket])
        XCTAssertEqual(UploadAction.available(for: .make(1, "b.jpg", total: 10, sent: 2, .failed, error: "x")), [.retry, .remove])
        XCTAssertEqual(UploadAction.available(for: .make(2, "c.jpg", total: 10, sent: 2, .uploading)), [])
        XCTAssertEqual(UploadAction.available(for: .make(3, "d.jpg", total: 10, .queued)), [])
    }

    func testTargetsKnowWhatTheDaemonCallTakes() {
        XCTAssertEqual(UploadActionTarget.upload(id: "a").uploadID, "a")
        XCTAssertEqual(UploadActionTarget.upload(id: "a").fileIndexes, [], "none means the whole upload")
        XCTAssertEqual(UploadActionTarget.file(uploadID: "a", index: 7).uploadID, "a")
        XCTAssertEqual(UploadActionTarget.file(uploadID: "a", index: 7).fileIndexes, [7])
    }

    func testAMenuHangsUnderItsButtonAndMovesWhenTheWindowEndsFirst() {
        let button = ActionsMenuLayer.Spot.button(CGRect(x: 900, y: 100, width: 26, height: 26))
        XCTAssertEqual(ActionsMenuLayer.left(button, width: 198, within: 988), 926 - 198, "right edges aligned")
        XCTAssertEqual(ActionsMenuLayer.top(button, height: 62, within: 640), 130, "4 points under the button")

        let low = ActionsMenuLayer.Spot.button(CGRect(x: 900, y: 600, width: 26, height: 26))
        XCTAssertEqual(ActionsMenuLayer.top(low, height: 62, within: 640), 600 - 4 - 62, "above when there is no room below")

        let pointer = ActionsMenuLayer.Spot.pointer(CGPoint(x: 400, y: 300))
        XCTAssertEqual(ActionsMenuLayer.left(pointer, width: 198, within: 988), 400)
        XCTAssertEqual(ActionsMenuLayer.top(pointer, height: 62, within: 640), 300)
        let nearEdge = ActionsMenuLayer.Spot.pointer(CGPoint(x: 950, y: 630))
        XCTAssertEqual(ActionsMenuLayer.left(nearEdge, width: 198, within: 988), 950 - 198)
        XCTAssertEqual(ActionsMenuLayer.top(nearEdge, height: 62, within: 640), 630 - 62)
        XCTAssertEqual(
            ActionsMenuLayer.left(.button(CGRect(x: 20, y: 0, width: 26, height: 26)), width: 198, within: 988),
            ActionsMenuLayer.margin, "never out of the window")
    }

    func testTookSaysSecondsMinutesAndHours() {
        XCTAssertEqual(UploadText.took(seconds: 0.2), "0 s")
        XCTAssertEqual(UploadText.took(seconds: 12), "12 s")
        XCTAssertEqual(UploadText.took(seconds: 312), "5 min 12 s")
        XCTAssertEqual(UploadText.took(seconds: 7_500), "2 h 5 min")
    }
}

final class RemovalPromptTests: XCTestCase {
    private func upload(_ name: String = "vacation-2026/", inBucket: Int = 12, total: Int = 12) -> RemovalPrompt.Subject {
        .upload(name: name, filesInBucket: inBucket, filesTotal: total)
    }

    private func prompt(
        _ subject: RemovalPrompt.Subject, _ intent: RemovalPrompt.Intent, alsoDelete: Bool = false
    ) -> RemovalPrompt {
        RemovalPrompt(target: .upload(id: "up-1"), subject: subject, intent: intent, alsoDelete: alsoDelete)
    }

    func testRemoveFromHistoryUncheckedAsFirstShown() {
        let sheet = prompt(upload(), .remove)
        XCTAssertEqual(sheet.title, "Remove “vacation-2026/” from the history?")
        XCTAssertEqual(
            sheet.message, "It leaves this list. Its 12 files stay in the bucket, and nothing on this Mac is touched.")
        XCTAssertEqual(sheet.checkboxTitle, "Also delete its 12 files from the bucket")
        XCTAssertNil(sheet.warning)
        XCTAssertEqual(sheet.confirmTitle, "Remove")
        XCTAssertEqual(sheet.confirmStyle, .primary)
        XCTAssertFalse(sheet.deletesFromBucket)
    }

    func testRemoveFromHistoryChecked() {
        let sheet = prompt(upload(), .remove, alsoDelete: true)
        XCTAssertEqual(sheet.title, "Remove “vacation-2026/” from the history?")
        XCTAssertEqual(
            sheet.message,
            "It leaves this list and its 12 files are deleted from the bucket. Nothing on this Mac is touched.")
        XCTAssertEqual(sheet.checkboxTitle, "Also delete its 12 files from the bucket")
        XCTAssertEqual(sheet.warning, "Files deleted from the bucket cannot be recovered.")
        XCTAssertEqual(sheet.confirmTitle, "Remove and delete")
        XCTAssertEqual(sheet.confirmStyle, .destructive)
        XCTAssertTrue(sheet.deletesFromBucket)
    }

    func testRemoveOneFileFromItsUpload() {
        let file = RemovalPrompt.Subject.file(name: "IMG_4402.jpg", uploadName: "vacation-2026/", inBucket: true)
        let sheet = prompt(file, .remove)
        XCTAssertEqual(sheet.title, "Remove “IMG_4402.jpg” from this upload?")
        XCTAssertEqual(
            sheet.message,
            "It leaves the list of “vacation-2026/”. The file stays in the bucket, and nothing on this Mac is touched.")
        XCTAssertEqual(sheet.checkboxTitle, "Also delete the file from the bucket")
        XCTAssertEqual(sheet.confirmTitle, "Remove")

        let checked = prompt(file, .remove, alsoDelete: true)
        XCTAssertEqual(
            checked.message,
            "It leaves the list of “vacation-2026/” and the file is deleted from the bucket. Nothing on this Mac is touched.")
        XCTAssertEqual(checked.confirmTitle, "Remove and delete")
        XCTAssertNotNil(checked.warning)
    }

    func testAFailedUploadWithNothingInTheBucketHasNoCheckbox() {
        let sheet = prompt(upload("armadillo.png", inBucket: 0, total: 1), .remove)
        XCTAssertEqual(sheet.title, "Remove “armadillo.png” from the history?")
        XCTAssertEqual(sheet.message, "This upload failed, so there is nothing in the bucket to delete.")
        XCTAssertNil(sheet.checkboxTitle)
        XCTAssertNil(sheet.warning)
        XCTAssertEqual(sheet.confirmTitle, "Remove")
        XCTAssertEqual(sheet.confirmStyle, .primary)

        // Nothing to delete stays nothing to delete, whatever the checkbox was left at.
        XCTAssertFalse(prompt(upload("armadillo.png", inBucket: 0, total: 1), .remove, alsoDelete: true).deletesFromBucket)

        let failedFile = prompt(.file(name: "IMG_4407.jpg", uploadName: "vacation-2026/", inBucket: false), .remove)
        XCTAssertEqual(failedFile.message, "This file failed, so there is nothing in the bucket to delete.")
        XCTAssertNil(failedFile.checkboxTitle)
    }

    func testDeleteFromBucketForAnUploadAndForOneFile() {
        let sheet = prompt(upload(), .delete)
        XCTAssertEqual(sheet.title, "Delete “vacation-2026/” from the bucket?")
        XCTAssertEqual(
            sheet.message,
            "Its 12 files are deleted from the bucket and it leaves the history. Nothing on this Mac is touched.")
        XCTAssertNil(sheet.checkboxTitle, "Delete always deletes: there is nothing to tick")
        XCTAssertEqual(sheet.warning, "Files deleted from the bucket cannot be recovered.")
        XCTAssertEqual(sheet.confirmTitle, "Delete")
        XCTAssertEqual(sheet.confirmStyle, .destructive)
        XCTAssertTrue(sheet.deletesFromBucket)

        let file = prompt(.file(name: "IMG_4402.jpg", uploadName: "vacation-2026/", inBucket: true), .delete)
        XCTAssertEqual(file.title, "Delete “IMG_4402.jpg” from the bucket?")
        XCTAssertEqual(
            file.message,
            "The file is deleted from the bucket and leaves the list of “vacation-2026/”. Nothing on this Mac is touched.")
        XCTAssertEqual(file.confirmTitle, "Delete")
    }

    func testCountsAndTheSingleFileWording() {
        let single = prompt(upload("invoice-october.pdf", inBucket: 1, total: 1), .remove)
        XCTAssertEqual(
            single.message, "It leaves this list. The file stays in the bucket, and nothing on this Mac is touched.")
        XCTAssertEqual(single.checkboxTitle, "Also delete the file from the bucket")
        XCTAssertEqual(
            prompt(upload("invoice-october.pdf", inBucket: 1, total: 1), .delete).message,
            "The file is deleted from the bucket and it leaves the history. Nothing on this Mac is touched.")

        // A failed folder with part of it sent: only what is in the bucket is counted.
        let partly = prompt(upload(inBucket: 5, total: 12), .remove)
        XCTAssertEqual(
            partly.message,
            "It leaves this list. The 5 files already sent stay in the bucket, and nothing on this Mac is touched.")
        XCTAssertEqual(partly.checkboxTitle, "Also delete the 5 files already sent from the bucket")
        XCTAssertEqual(
            prompt(upload(inBucket: 1, total: 12), .delete).message,
            "The 1 file already sent is deleted from the bucket and it leaves the history. Nothing on this Mac is touched.")
    }

    func testPromptsAreBuiltFromWhatTheHistoryHolds() {
        var ledger = UploadLedger()
        let now = Date(timeIntervalSince1970: 1_794_500_000)
        ledger.apply(.folder("up-7", "vacation-2026", files: 12, finished: 9, failed: 3, total: 100, sent: 80, .failed, error: "x"), now: now)
        let record = ledger["up-7"]!

        let whole = RemovalPrompt(upload: record, intent: .delete)
        XCTAssertEqual(whole.target, .upload(id: "up-7"))
        XCTAssertEqual(whole.subject, .upload(name: "vacation-2026/", filesInBucket: 9, filesTotal: 12))

        let file = RemovalPrompt(
            file: .make(4, "vacation-2026/day-2/IMG_4402.jpg", of: "up-7", total: 10, sent: 10, .finished),
            of: record, intent: .remove)
        XCTAssertEqual(file.target, .file(uploadID: "up-7", index: 4))
        XCTAssertEqual(file.subject, .file(name: "IMG_4402.jpg", uploadName: "vacation-2026/", inBucket: true))
    }
}

@MainActor
final class RemovalSheetModelTests: XCTestCase {
    private struct Call: Equatable {
        let uploadID: String
        let fileIndexes: [Int]
        let deleteFromBucket: Bool
    }

    private func prompt(_ intent: RemovalPrompt.Intent = .remove) -> RemovalPrompt {
        RemovalPrompt(
            target: .file(uploadID: "up-7", index: 4),
            subject: .file(name: "IMG_4402.jpg", uploadName: "vacation-2026/", inBucket: true), intent: intent)
    }

    func testConfirmAsksOnceWithWhatTheSheetSaysAndClosesWhenTheDaemonIsDone() async {
        var calls: [Call] = []
        var closed: [Bool] = []
        let model = RemovalSheetModel(
            prompt: prompt(),
            perform: { calls.append(Call(uploadID: $0, fileIndexes: $1, deleteFromBucket: $2)) },
            close: { closed.append($0) })
        model.alsoDelete = true
        XCTAssertEqual(model.prompt.confirmTitle, "Remove and delete")

        await model.confirm()
        XCTAssertEqual(calls, [Call(uploadID: "up-7", fileIndexes: [4], deleteFromBucket: true)])
        XCTAssertEqual(closed, [true])
        XCTAssertFalse(model.isWorking)
        XCTAssertNil(model.errorMessage)
    }

    func testWhileTheDaemonWorksTheSheetCannotBeConfirmedAgainCancelledOrChanged() async {
        var calls = 0
        var closed: [Bool] = []
        let (gate, release) = AsyncStream<Void>.makeStream()
        let model = RemovalSheetModel(
            prompt: prompt(),
            perform: { _, _, _ in
                calls += 1
                for await _ in gate { break }
            },
            close: { closed.append($0) })

        let first = Task { await model.confirm() }
        while !model.isWorking { await Task.yield() }
        await model.confirm()
        model.cancel()
        model.alsoDelete = true
        XCTAssertEqual(calls, 1, "the second confirmation did nothing")
        XCTAssertEqual(closed, [], "and it cannot be cancelled half way")
        XCTAssertFalse(model.prompt.alsoDelete, "nor changed into something that was not confirmed")

        release.yield()
        await first.value
        XCTAssertEqual(closed, [true])
        XCTAssertFalse(model.isWorking)
    }

    func testAFailureIsShownInTheSheetWhichStaysOpenAndCanBeTriedAgain() async {
        var failure: DaemonError? = .rejected("AWS denied permission to delete from the bucket (s3:DeleteObject)")
        var closed: [Bool] = []
        let model = RemovalSheetModel(
            prompt: prompt(.delete),
            perform: { _, _, _ in if let failure { throw failure } },
            close: { closed.append($0) })

        await model.confirm()
        XCTAssertEqual(model.errorMessage, "AWS denied permission to delete from the bucket (s3:DeleteObject)")
        XCTAssertEqual(closed, [], "the sheet stays open")
        XCTAssertFalse(model.isWorking, "and can be confirmed again")

        failure = nil
        await model.confirm()
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(closed, [true])
    }

    func testCancelClosesWithoutRemovingAndFailuresHaveWordsForEveryKind() {
        var closed: [Bool] = []
        let model = RemovalSheetModel(prompt: prompt(), perform: { _, _, _ in }, close: { closed.append($0) })
        model.cancel()
        XCTAssertEqual(closed, [false])

        XCTAssertEqual(RemovalSheetModel.message(for: DaemonError.rejected("No internet connection")), "No internet connection")
        XCTAssertEqual(
            RemovalSheetModel.message(for: DaemonError.unavailable),
            "Uploads are unavailable right now. Try again in a moment.")
        XCTAssertEqual(RemovalSheetModel.message(for: DaemonError.notConfigured), "Connect your AWS account first.")
        XCTAssertEqual(
            RemovalSheetModel.message(for: DaemonError.other("internal: boom")),
            "This could not be done. Try again in a moment.", "nothing technical is shown")
        XCTAssertEqual(
            RemovalSheetModel.message(for: DaemonError.rejected("")), "This could not be done. Try again in a moment.")
    }
}

/// The whole path: a menu entry, the confirmation, the daemon call and what the screen does
/// with the answer.
@MainActor
final class UploadActionFlowTests: XCTestCase {
    private func settle(_ condition: () -> Bool) async {
        for _ in 0..<400 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
    }

    /// A finished folder of twelve files with its detail open.
    private func fixtureWithFinishedFolder() async throws -> UIFixture {
        let fixture = await UIFixture()
        fixture.tray.apply(.folder("up-7", "vacation-2026", files: 12, finished: 12, total: 1200, sent: 1200, .finished))
        fixture.client.setFiles(
            (0..<12).map { .make($0, "vacation-2026/IMG_44\($0).jpg", of: "up-7", total: 100, sent: 100, .finished) },
            of: "up-7")
        try await fixture.openDetail("up-7", from: .history, expecting: 12)
        return fixture
    }

    func testTheButtonOpensAndClosesItsMenuAndOnlyOneIsOpen() async {
        let fixture = await UIFixture()
        let model = fixture.context.model
        let first = UploadActionTarget.upload(id: "a")
        let second = UploadActionTarget.file(uploadID: "a", index: 2)

        model.toggleActionsMenu(for: first, actions: [.remove, .deleteFromBucket])
        XCTAssertEqual(model.actionsMenu, OpenActionsMenu(target: first, actions: [.remove, .deleteFromBucket]))
        model.toggleActionsMenu(for: second, actions: [.retry, .remove])
        XCTAssertEqual(model.actionsMenu?.target, second, "opening another closes the first")
        model.toggleActionsMenu(for: second, actions: [.retry, .remove])
        XCTAssertNil(model.actionsMenu, "a second click on the same button closes it")

        model.openActionsMenu(for: first, actions: [.remove], at: CGPoint(x: 300, y: 200))
        XCTAssertEqual(model.actionsMenu?.point, CGPoint(x: 300, y: 200), "a right click opens it at the pointer")
        model.toggleActionsMenu(for: first, actions: [.remove])
        XCTAssertNil(model.actionsMenu?.point, "and the button then hangs it from itself")

        model.openActionsMenu(for: first, actions: [])
        XCTAssertNil(model.actionsMenu, "nothing to offer, no menu")

        model.openActionsMenu(for: first, actions: [.remove])
        model.show(.overview)
        XCTAssertNil(model.actionsMenu, "leaving the screen closes it")
    }

    func testTryAgainOnAFileCallsRetryWithItsIndexForAnyKindOfUpload() async throws {
        let fixture = await UIFixture()
        fixture.tray.apply(.folder("up-7", "vacation-2026", files: 12, finished: 11, failed: 1, total: 1200, sent: 1100, .failed, error: "1 of 12 files could not be sent"))
        fixture.context.choose(.retry, for: .file(uploadID: "up-7", index: 5))
        await settle { !fixture.client.retries.isEmpty }
        XCTAssertEqual(fixture.client.retries, [.init(uploadID: "up-7", fileIndexes: [5])])
        XCTAssertNil(fixture.context.model.removal, "Try again asks nothing")

        fixture.context.choose(.retry, for: .upload(id: "up-7"))
        await settle { fixture.client.retries.count == 2 }
        XCTAssertEqual(fixture.client.retries.last, .init(uploadID: "up-7", fileIndexes: []))
    }

    func testTheOnlyFileOfASingleFileUploadStandsForTheUpload() async {
        let fixture = await UIFixture()
        fixture.tray.apply(.make("up-1", "armadillo.png", total: 900, sent: 300, .failed, error: "Connection lost"))
        fixture.context.choose(.retry, for: .file(uploadID: "up-1", index: 0))
        await settle { !fixture.client.retries.isEmpty }
        XCTAssertEqual(fixture.client.retries, [.init(uploadID: "up-1", fileIndexes: [])])

        fixture.context.choose(.remove, for: .file(uploadID: "up-1", index: 0))
        XCTAssertEqual(fixture.context.model.removal?.prompt.target, .upload(id: "up-1"))
        XCTAssertEqual(fixture.context.model.removal?.prompt.title, "Remove “armadillo.png” from the history?")
        XCTAssertNil(fixture.context.model.removal?.prompt.checkboxTitle)
    }

    func testRemovingAnUploadFromItsDetailGoesBackToTheListWhenTheDaemonIsDone() async throws {
        let fixture = try await fixtureWithFinishedFolder()
        let model = fixture.context.model
        model.toggleActionsMenu(for: .upload(id: "up-7"), actions: [.remove, .deleteFromBucket])

        fixture.context.choose(.remove, for: .upload(id: "up-7"))
        XCTAssertNil(model.actionsMenu, "choosing closes the menu")
        let sheet = try XCTUnwrap(model.removal)
        XCTAssertEqual(sheet.prompt.checkboxTitle, "Also delete its 12 files from the bucket")
        XCTAssertTrue(fixture.client.removals.isEmpty, "nothing happens before the confirmation")

        sheet.alsoDelete = true
        await sheet.confirm()
        XCTAssertEqual(fixture.client.removals, [.init(uploadID: "up-7", fileIndexes: [], deleteFromBucket: true)])
        XCTAssertNil(model.removal, "the sheet closed")
        XCTAssertNil(fixture.tray.uploads.ledger["up-7"])
        XCTAssertNil(model.detail, "the detail of an upload that is gone closes")
        XCTAssertEqual(model.section, .history)
    }

    func testRemovingOneFileKeepsTheDetailAndDropsTheRow() async throws {
        let fixture = try await fixtureWithFinishedFolder()
        let model = fixture.context.model

        fixture.context.choose(.deleteFromBucket, for: .file(uploadID: "up-7", index: 3))
        let sheet = try XCTUnwrap(model.removal)
        XCTAssertEqual(sheet.prompt.title, "Delete “IMG_443.jpg” from the bucket?")
        await sheet.confirm()

        XCTAssertEqual(fixture.client.removals, [.init(uploadID: "up-7", fileIndexes: [3], deleteFromBucket: true)])
        XCTAssertNil(model.removal)
        XCTAssertEqual(model.detail?.id, "up-7", "the upload is still there")
        XCTAssertEqual(model.detailFiles.count, 11)
        XCTAssertNil(model.detailFiles.file(at: 3))
        XCTAssertFalse(model.detailFiles.indexes(.all).contains(3))
    }

    func testAnErrorStaysInTheSheetAndNothingIsRemoved() async throws {
        let fixture = try await fixtureWithFinishedFolder()
        let model = fixture.context.model
        fixture.client.failRemove(with: .rejected("AWS denied permission to delete from the bucket (s3:DeleteObject)"))

        fixture.context.choose(.deleteFromBucket, for: .upload(id: "up-7"))
        let sheet = try XCTUnwrap(model.removal)
        await sheet.confirm()
        XCTAssertTrue(model.removal === sheet, "still open")
        XCTAssertEqual(sheet.errorMessage, "AWS denied permission to delete from the bucket (s3:DeleteObject)")
        XCTAssertNotNil(fixture.tray.uploads.ledger["up-7"])
        XCTAssertEqual(model.detail?.id, "up-7")

        // Already gone on the daemon's side counts as removed.
        fixture.client.failRemove(with: .notFound)
        await sheet.confirm()
        XCTAssertNil(model.removal)
        XCTAssertNil(fixture.tray.uploads.ledger["up-7"])
        XCTAssertNil(model.detail)
    }

    func testARemovedSnapshotClosesTheDetailTheMenuAndAnIdleSheetOfThatUpload() async throws {
        let fixture = try await fixtureWithFinishedFolder()
        let model = fixture.context.model
        fixture.tray.apply(.make("other", "notes.txt", total: 5, sent: 5, .finished))

        fixture.context.choose(.remove, for: .upload(id: "up-7"))
        model.openActionsMenu(for: .file(uploadID: "up-7", index: 2), actions: [.remove])
        XCTAssertNotNil(model.removal)

        fixture.tray.apply(.removed(id: "other"))
        XCTAssertEqual(model.detail?.id, "up-7", "another upload leaving changes nothing here")
        XCTAssertNotNil(model.removal)
        XCTAssertNotNil(model.actionsMenu)

        // Removed elsewhere: no longer in the bucket, or the bucket changed.
        fixture.tray.apply(.removed(id: "up-7"))
        XCTAssertNil(model.detail)
        XCTAssertEqual(model.section, .history, "back on the History list")
        XCTAssertNil(model.actionsMenu)
        XCTAssertNil(model.removal)
        XCTAssertEqual(fixture.tray.uploads.ledger.records.map(\.id), [])
    }

    func testAFileStreamThatBreaksIsAskedForAgainWhileTheDetailStaysOpen() async throws {
        let client = StubDaemonClient()
        let model = MainWindowModel(
            detailFiles: UploadFilesModel(publishInterval: .zero), refollowDelay: .milliseconds(5))
        model.watchFiles = { client.watchFiles(uploadID: $0) }
        client.setFiles([.make(0, "a.jpg", total: 10, sent: 4, .uploading)], of: "up-1")
        client.failFiles(with: .unavailable)

        model.openDetail(id: "up-1", from: .history)
        await settle { client.watchedFiles.count >= 2 }
        XCTAssertGreaterThanOrEqual(client.watchedFiles.count, 2, "the daemon restarted: ask again")
        XCTAssertEqual(model.detailFiles.file(at: 0)?.errorMessage, "Upload interrupted")

        // The restarted daemon replays the file as it stored it; then the stream stays quiet.
        client.setFiles([.make(0, "a.jpg", total: 10, sent: 4, .failed, error: "Upload interrupted")], of: "up-1")
        client.failFiles(with: nil)
        await settle { model.detailFiles.file(at: 0)?.state == .failed }
        try await Task.sleep(for: .milliseconds(60))
        let asked = client.watchedFiles.count
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(client.watchedFiles.count, asked, "a stream that ended by itself is not asked for again")
        XCTAssertEqual(model.detailFiles.count, 1, "the same file, not a second one")
        XCTAssertEqual(model.detailFiles.indexes(.failed), [0])
        model.closeDetail()
    }
}

final class RemovedFileTests: XCTestCase {
    private func file(_ index: Int, _ state: UploadState) -> FileSnapshot {
        .make(index, "trip/IMG_\(index).jpg", total: 100, state)
    }

    func testARemovedFileLeavesTheListingAndItsStateGroup() {
        var list = UploadFileList()
        for (index, state) in [(0, UploadState.finished), (1, .finished), (2, .failed), (3, .finished)] {
            list.apply(file(index, state))
        }
        XCTAssertTrue(list.apply(.removed(uploadID: "up-1", index: 1)), "the listing changed")
        XCTAssertEqual(list.count, 3)
        XCTAssertNil(list[1])
        XCTAssertEqual(list.indexes(.finished), [0, 3])
        XCTAssertEqual(list.indexes(.all), [2, 0, 3])
        XCTAssertEqual(list.count(.finished), 2)

        XCTAssertFalse(list.apply(.removed(uploadID: "up-1", index: 1)), "already gone")
        XCTAssertFalse(list.remove(9))
        XCTAssertTrue(list.remove(2))
        XCTAssertEqual(list.indexes(.failed), [])
    }

    @MainActor
    func testTheFilesModelDropsRemovedFilesFromTheStreamAndOnRequest() async {
        let model = UploadFilesModel(publishInterval: .zero)
        let stream = AsyncThrowingStream<FileSnapshot, Error> { continuation in
            for index in 0..<4 { continuation.yield(self.file(index, .finished)) }
            continuation.yield(.removed(uploadID: "up-1", index: 2))
            continuation.finish()
        }
        let end = await model.follow(uploadID: "up-1", stream: stream)
        XCTAssertEqual(end, .done)
        XCTAssertEqual(model.indexes(.all), [0, 1, 3])

        model.remove(indexes: [0, 7], of: "up-1")
        XCTAssertEqual(model.indexes(.all), [1, 3])
        model.remove(indexes: [1], of: "another-upload")
        XCTAssertEqual(model.count, 2, "files of an upload that is not the one on screen are not touched")
    }

    @MainActor
    func testFollowTellsWhyItEnded() async {
        func stream(failing error: DaemonError?) -> AsyncThrowingStream<FileSnapshot, Error> {
            AsyncThrowingStream { $0.finish(throwing: error) }
        }
        let model = UploadFilesModel(publishInterval: .zero)
        let done = await model.follow(uploadID: "a", stream: stream(failing: nil))
        XCTAssertEqual(done, .done)
        let interrupted = await model.follow(uploadID: "a", stream: stream(failing: .unavailable))
        XCTAssertEqual(interrupted, .interrupted)
        let unknown = await model.follow(uploadID: "a", stream: stream(failing: .notFound))
        XCTAssertEqual(unknown, .unknownUpload)
    }
}

final class UploadActionErrorMappingTests: XCTestCase {
    func testTheDaemonsWordsSurviveUnderAnyStatusCode() {
        func map(_ code: RPCError.Code, _ message: String, fromDaemon: Bool = true) -> DaemonError {
            GRPCDaemonClient.mapUploadAction(code: code, message: message, fromDaemon: fromDaemon)
        }
        XCTAssertEqual(map(.notFound, "unknown upload"), .notFound)
        XCTAssertEqual(
            map(.failedPrecondition, "This upload is still being sent"), .rejected("This upload is still being sent"),
            "not the 'not configured' that the same code means for an enqueue")
        XCTAssertEqual(
            map(.permissionDenied, "AWS denied permission to delete from the bucket (s3:DeleteObject)"),
            .rejected("AWS denied permission to delete from the bucket (s3:DeleteObject)"))
        XCTAssertEqual(map(.internalError, "Bucket not found"), .rejected("Bucket not found"))
        XCTAssertEqual(
            map(.unavailable, "No internet connection"), .rejected("No internet connection"),
            "said by the daemon: it is about the bucket, not about the daemon")
        XCTAssertEqual(
            map(.unavailable, "connection refused", fromDaemon: false), .unavailable,
            "said by the transport: the daemon cannot be reached")
        XCTAssertEqual(map(.unavailable, ""), .unavailable)
        XCTAssertEqual(map(.internalError, ""), .other("internalError"))
        guard case .other = map(.unimplemented, "unknown method RemoveUpload") else {
            return XCTFail("a daemon without the call is not a message for the user")
        }
    }

    func testARemovedSnapshotNeedsNothingButItsId() {
        let upload = UploadSnapshot.removed(id: "up-3")
        XCTAssertTrue(upload.removed)
        XCTAssertEqual(upload.id, "up-3")
        let file = FileSnapshot.removed(uploadID: "up-3", index: 4)
        XCTAssertTrue(file.removed)
        XCTAssertEqual(file.index, 4)
        XCTAssertFalse(UploadSnapshot.make("a", "a", total: 1, .queued).removed)
        XCTAssertNil(UploadSnapshot.make("a", "a", total: 1, .queued).createdAt)
        XCTAssertNil(UploadSnapshot.date(milliseconds: 0), "zero means the daemon did not say")
        XCTAssertEqual(
            UploadSnapshot.date(milliseconds: 1_794_500_000_500), Date(timeIntervalSince1970: 1_794_500_000.5))
    }
}
