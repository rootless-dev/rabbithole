import Foundation
import XCTest

@testable import Rabbithole

final class UploadLedgerTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_794_500_000)

    func testFirstSnapshotCreatesARecordStampedWithTheTimeItWasSeen() {
        var ledger = UploadLedger()
        XCTAssertNil(ledger.apply(.make("a", "photo.jpg", total: 100, .queued), now: start))
        let record = ledger["a"]
        XCTAssertEqual(record?.fileName, "photo.jpg")
        XCTAssertEqual(record?.state, .queued)
        XCTAssertEqual(record?.startedAt, start)
        XCTAssertNil(record?.endedAt)
        XCTAssertEqual(record?.fraction, 0)
    }

    func testProgressNeverGoesBackAndTheObjectKeyIsKeptOnceKnown() {
        var ledger = UploadLedger()
        ledger.apply(.make("a", "f.bin", total: 100, sent: 60, .uploading), now: start)
        var stale = UploadSnapshot.make("a", "f.bin", total: 100, sent: 40, .uploading)
        stale = UploadSnapshot(
            id: stale.id, fileName: stale.fileName, localPath: stale.localPath, objectKey: "",
            bytesTotal: 100, bytesSent: 40, state: .uploading, errorMessage: "")
        ledger.apply(stale, now: start.addingTimeInterval(1))
        XCTAssertEqual(ledger["a"]?.bytesSent, 60)
        XCTAssertEqual(ledger["a"]?.objectKey, "quick-uploads/f.bin")
        XCTAssertEqual(ledger["a"]?.fraction, 0.6)
    }

    func testFinishingReturnsTheRecordOnceAndAReplayChangesNothing() {
        var ledger = UploadLedger()
        ledger.apply(.make("a", "f.bin", total: 100, sent: 10, .uploading), now: start)
        let ended = ledger.apply(
            .make("a", "f.bin", total: 100, sent: 100, .finished), now: start.addingTimeInterval(5))
        XCTAssertEqual(ended?.state, .finished)
        XCTAssertEqual(ended?.endedAt, start.addingTimeInterval(5))
        XCTAssertEqual(ended?.fraction, 1)
        // The daemon replays the history on every subscription.
        XCTAssertNil(ledger.apply(.make("a", "f.bin", total: 100, sent: 100, .finished), now: start.addingTimeInterval(9)))
        XCTAssertEqual(ledger["a"]?.state, .finished)
        XCTAssertEqual(ledger["a"]?.endedAt, start.addingTimeInterval(5))
    }

    // MARK: A history that outlives the run

    private func stored(
        _ id: String, _ state: UploadState, created: TimeInterval, ended: TimeInterval?, error: String = ""
    ) -> UploadSnapshot {
        UploadSnapshot(
            id: id, fileName: "\(id).bin", localPath: "/tmp/\(id).bin", objectKey: "quick-uploads/\(id).bin",
            bytesTotal: 100, bytesSent: state == .finished ? 100 : 40, state: state, errorMessage: error,
            createdAt: start.addingTimeInterval(created), endedAt: ended.map(start.addingTimeInterval))
    }

    func testTheDaemonsTimesAreUsedInsteadOfTheClock() {
        var ledger = UploadLedger()
        ledger.apply(stored("a", .finished, created: -90_000, ended: -89_700), now: start)
        XCTAssertEqual(ledger["a"]?.startedAt, start.addingTimeInterval(-90_000))
        XCTAssertEqual(ledger["a"]?.endedAt, start.addingTimeInterval(-89_700))
        XCTAssertEqual(ledger["a"]?.duration, 300)

        ledger.apply(stored("b", .uploading, created: -60, ended: nil), now: start)
        ledger.apply(stored("b", .finished, created: -60, ended: -2), now: start)
        XCTAssertEqual(ledger["b"]?.endedAt, start.addingTimeInterval(-2), "not the moment the app heard of it")
    }

    func testReplayedHistoryIsListedButIsNotNewsAndSaysNothingAboutTheServiceNow() {
        var ledger = UploadLedger()
        ledger.liveSince = start
        XCTAssertNil(
            ledger.apply(stored("old-ok", .finished, created: -500, ended: -400), now: start),
            "an upload of an earlier run is not announced again")
        XCTAssertNil(
            ledger.apply(
                stored("old-offline", .failed, created: -300, ended: -200, error: "No internet connection"),
                now: start))
        XCTAssertEqual(ledger.records.map(\.id), ["old-ok", "old-offline"])
        XCTAssertEqual(ledger.condition, .none, "a failure of last week does not mean there is no connection now")
        XCTAssertFalse(ledger.hasFinishedLive)
        XCTAssertEqual(ledger.finishedCount, 1)

        let fresh = ledger.apply(
            stored("new-offline", .failed, created: 5, ended: 9, error: "No internet connection"),
            now: start.addingTimeInterval(9))
        XCTAssertEqual(fresh?.id, "new-offline", "first seen already ended, but it ended in this run")
        XCTAssertEqual(ledger.condition, .offline)
        XCTAssertEqual(
            ledger.failedByCondition.map(\.id), ["new-offline"],
            "Try now sends what this outage stopped, not every old failure with the same words")

        XCTAssertEqual(
            ledger.apply(stored("new-ok", .finished, created: 10, ended: 12), now: start.addingTimeInterval(12))?.id,
            "new-ok")
        XCTAssertTrue(ledger.hasFinishedLive)
    }

    func testARetriedUploadComesBackUnderTheSameIdAndEndsAgain() {
        var ledger = UploadLedger()
        ledger.apply(.folder("a", "trip", files: 12, finished: 9, failed: 3, total: 1200, sent: 900, .failed, error: "3 of 12 files could not be sent"), now: start)
        XCTAssertEqual(ledger["a"]?.filesFailed, 3)

        // RetryUpload: the same upload goes back to waiting with nothing failed.
        XCTAssertNil(ledger.apply(.folder("a", "trip", files: 12, finished: 9, total: 1200, sent: 900, .queued), now: start.addingTimeInterval(60)))
        XCTAssertEqual(ledger.records.count, 1, "no second entry for the new attempt")
        XCTAssertEqual(ledger["a"]?.state, .queued)
        XCTAssertEqual(ledger["a"]?.filesFailed, 0)
        XCTAssertEqual(ledger["a"]?.errorMessage, "")
        XCTAssertNil(ledger["a"]?.endedAt)
        XCTAssertEqual(ledger["a"]?.startedAt, start, "it is still the upload that was handed over then")

        ledger.apply(.folder("a", "trip", files: 12, finished: 10, total: 1200, sent: 1000, .uploading), now: start.addingTimeInterval(61))
        let ended = ledger.apply(.folder("a", "trip", files: 12, finished: 12, total: 1200, sent: 1200, .finished), now: start.addingTimeInterval(70))
        XCTAssertEqual(ended?.state, .finished, "the new end is announced")
        XCTAssertEqual(ledger["a"]?.endedAt, start.addingTimeInterval(70))
    }

    func testACoalescedRetryThatGoesStraightFromFailedToFinishedIsAnnounced() {
        var ledger = UploadLedger()
        ledger.apply(.make("a", "a.bin", total: 10, sent: 4, .failed, error: "Connection lost"), now: start)
        let ended = ledger.apply(.make("a", "a.bin", total: 10, sent: 10, .finished), now: start.addingTimeInterval(30))
        XCTAssertEqual(ended?.state, .finished)
        XCTAssertEqual(ledger["a"]?.errorMessage, "")
        XCTAssertEqual(ledger.condition, .none)
    }

    func testTheDaemonsInterruptedRecordMeetsTheAppsOwnMarkWithoutASecondEntryOrAnnouncement() {
        var ledger = UploadLedger()
        ledger.apply(stored("a", .uploading, created: -30, ended: nil), now: start)
        ledger.interrupt(now: start.addingTimeInterval(1))
        let marked = ledger["a"]

        // The restarted daemon replays the upload as it stored it.
        let replayed = ledger.apply(
            stored("a", .failed, created: -30, ended: 0.5, error: "Upload interrupted"), now: start.addingTimeInterval(4))
        XCTAssertNil(replayed, "the app already showed it as interrupted")
        XCTAssertEqual(ledger.records.count, 1)
        XCTAssertEqual(ledger["a"]?.state, marked?.state)
        XCTAssertEqual(ledger["a"]?.errorMessage, marked?.errorMessage, "the row does not change its words")
        XCTAssertEqual(ledger["a"]?.endedAt, start.addingTimeInterval(0.5), "only the daemon's time of the end comes in")
    }

    func testARemovedSnapshotTakesTheUploadOutAndTheOthersKeepTheirPlaces() {
        var ledger = UploadLedger()
        for id in ["a", "b", "c"] { ledger.apply(.make(id, "\(id).bin", total: 10, sent: 10, .finished), now: start) }
        XCTAssertNil(ledger.apply(.removed(id: "b"), now: start))
        XCTAssertEqual(ledger.records.map(\.id), ["a", "c"])
        XCTAssertNil(ledger["b"])
        XCTAssertEqual(ledger["c"]?.fileName, "c.bin", "the index still finds what moved up")
        XCTAssertEqual(ledger.finishedCount, 2)

        XCTAssertNil(ledger.apply(.removed(id: "never-seen"), now: start), "removing what is not there is harmless")
        XCTAssertFalse(ledger.remove("b"))
        XCTAssertTrue(ledger.remove("a"))
        XCTAssertEqual(ledger.ordered.map(\.id), ["c"])
    }

    func testRecentGoesByWhenUploadsWereHandedOverNotByReplayOrder() {
        var ledger = UploadLedger()
        ledger.apply(stored("newest", .finished, created: -10, ended: -5), now: start)
        ledger.apply(stored("oldest", .finished, created: -900, ended: -800), now: start)
        ledger.apply(stored("middle", .failed, created: -100, ended: -90), now: start)
        XCTAssertEqual(ledger.recent(limit: 2).map(\.id), ["newest", "middle"])
        XCTAssertEqual(ledger.ordered.map(\.id), ["newest", "middle", "oldest"])
    }

    func testAnUploadFirstSeenAlreadyFinishedIsReportedAsEnded() {
        var ledger = UploadLedger()
        let ended = ledger.apply(.make("a", "empty.txt", total: 0, .finished), now: start)
        XCTAssertEqual(ended?.state, .finished)
        XCTAssertEqual(ledger["a"]?.fraction, 1, "an empty file that finished is complete")
    }

    func testFailureKeepsTheDaemonMessageAndAnEmptyOneGetsADefault() {
        var ledger = UploadLedger()
        ledger.apply(.make("a", "f.bin", total: 10, .failed, error: "Bucket not found"), now: start)
        ledger.apply(.make("b", "g.bin", total: 10, .failed), now: start)
        XCTAssertEqual(ledger["a"]?.errorMessage, "Bucket not found")
        XCTAssertEqual(ledger["b"]?.errorMessage, "Upload failed")
        XCTAssertEqual(ledger.condition, .none)
    }

    func testConditionFollowsTheLastEndedUpload() {
        var ledger = UploadLedger()
        ledger.apply(.make("a", "a", total: 10, .failed, error: "No internet connection"), now: start)
        XCTAssertEqual(ledger.condition, .offline)
        XCTAssertEqual(ledger.failedByCondition.map(\.id), ["a"])
        ledger.apply(.make("b", "b", total: 10, .failed, error: "AWS rejected the access key"), now: start)
        XCTAssertEqual(ledger.condition, .keyRejected)
        XCTAssertEqual(ledger.failedByCondition.map(\.id), ["b"])
        ledger.apply(.make("c", "c", total: 10, sent: 10, .finished), now: start)
        XCTAssertEqual(ledger.condition, .none)
        XCTAssertTrue(ledger.failedByCondition.isEmpty)

        ledger.apply(.make("d", "d", total: 10, .failed, error: "AWS rejected the access key"), now: start)
        ledger.clearCondition()
        XCTAssertEqual(ledger.condition, .none)
    }

    func testInterruptFailsOnlyActiveUploads() {
        var ledger = UploadLedger()
        ledger.apply(.make("done", "a", total: 10, sent: 10, .finished), now: start)
        ledger.apply(.make("running", "b", total: 10, sent: 4, .uploading), now: start)
        ledger.apply(.make("waiting", "c", total: 10, .queued), now: start)
        ledger.interrupt(now: start.addingTimeInterval(3))
        XCTAssertEqual(ledger["done"]?.state, .finished)
        XCTAssertEqual(ledger["running"]?.state, .failed)
        XCTAssertEqual(ledger["running"]?.errorMessage, "Upload interrupted")
        XCTAssertEqual(ledger["running"]?.endedAt, start.addingTimeInterval(3))
        XCTAssertEqual(ledger["waiting"]?.state, .failed)
        XCTAssertEqual(ledger.condition, .none)
    }

    func testSpeedIsMeasuredBetweenSamplesAndSmoothed() {
        var ledger = UploadLedger()
        ledger.apply(.make("a", "a", total: 10_000, sent: 0, .uploading), now: start)
        XCTAssertNil(ledger["a"]?.bytesPerSecond)
        XCTAssertNil(ledger["a"]?.secondsLeft)
        // Too soon after the last sample: not counted.
        ledger.apply(.make("a", "a", total: 10_000, sent: 100, .uploading), now: start.addingTimeInterval(0.1))
        XCTAssertNil(ledger["a"]?.bytesPerSecond)
        ledger.apply(.make("a", "a", total: 10_000, sent: 2_000, .uploading), now: start.addingTimeInterval(2))
        XCTAssertEqual(ledger["a"]?.bytesPerSecond, 1_000)
        XCTAssertEqual(ledger["a"]?.secondsLeft, 8)
        ledger.apply(.make("a", "a", total: 10_000, sent: 6_000, .uploading), now: start.addingTimeInterval(4))
        XCTAssertEqual(ledger["a"]?.bytesPerSecond ?? 0, 1_000 * 0.7 + 2_000 * 0.3, accuracy: 0.001)
        ledger.apply(.make("a", "a", total: 10_000, sent: 10_000, .finished), now: start.addingTimeInterval(5))
        XCTAssertNil(ledger["a"]?.bytesPerSecond)
    }

    func testOrderedPutsRunningFirstThenWaitingThenEndedNewestFirst() {
        var ledger = UploadLedger()
        ledger.apply(.make("old", "a", total: 1, sent: 1, .finished), now: start)
        ledger.apply(.make("wait", "b", total: 1, .queued), now: start)
        ledger.apply(.make("run", "c", total: 2, sent: 1, .uploading), now: start)
        ledger.apply(.make("new", "d", total: 1, .failed, error: "x"), now: start.addingTimeInterval(60))
        XCTAssertEqual(ledger.ordered.map(\.id), ["run", "wait", "new", "old"])
    }

    func testRecentIsNewestFirstAndLimitedAndTheSummaryCountsFinishedOnly() {
        var ledger = UploadLedger()
        for index in 1...7 {
            ledger.apply(
                .make("u\(index)", "f\(index)", total: 1_000, sent: 1_000, index == 7 ? .failed : .finished),
                now: start.addingTimeInterval(Double(index)))
        }
        XCTAssertEqual(ledger.recent(limit: 5).map(\.id), ["u7", "u6", "u5", "u4", "u3"])
        XCTAssertEqual(ledger.finishedCount, 6)
        XCTAssertEqual(ledger.finishedBytes, 6_000)
        XCTAssertEqual(ledger.lastFinished?.id, "u6")
    }

    @MainActor
    func testStoreAnnouncesEachEndedUploadOnceWithItsClock() {
        let clock = TestClock()
        let store = UploadStore(now: { clock.now })
        var ended: [String] = []
        store.onEnded = { ended.append($0.id) }
        store.apply(.make("a", "a", total: 1, .queued))
        clock.advance(10)
        store.apply(.make("a", "a", total: 1, sent: 1, .finished))
        store.apply(.make("a", "a", total: 1, sent: 1, .finished))
        XCTAssertEqual(ended, ["a"])
        XCTAssertEqual(store.ledger["a"]?.endedAt, clock.now)
        store.apply(.make("b", "b", total: 1, .uploading))
        store.interrupt()
        XCTAssertEqual(store.ledger["b"]?.state, .failed)
    }

    @MainActor
    func testStoreDoesNotAnnounceHistoryAndTellsWhenAnUploadLeaves() {
        let clock = TestClock()
        let store = UploadStore(now: { clock.now })
        var ended: [String] = []
        var removed: [String] = []
        store.onEnded = { ended.append($0.id) }
        store.onRemoved = { removed.append($0) }

        store.apply(
            UploadSnapshot(
                id: "yesterday", fileName: "a", localPath: "/tmp/a", objectKey: "k", bytesTotal: 1, bytesSent: 1,
                state: .finished, errorMessage: "", createdAt: clock.now.addingTimeInterval(-90_000),
                endedAt: clock.now.addingTimeInterval(-89_000)))
        XCTAssertEqual(ended, [], "no notification for what an earlier run sent")
        XCTAssertEqual(store.ledger.records.count, 1)

        store.apply(.removed(id: "yesterday"))
        store.apply(.removed(id: "yesterday"))
        XCTAssertEqual(removed, ["yesterday"], "told once")
        XCTAssertTrue(store.ledger.records.isEmpty)
    }
}

final class UploadQueryTests: XCTestCase {
    private var records: [UploadRecord] {
        var ledger = UploadLedger()
        let now = Date(timeIntervalSince1970: 1_794_500_000)
        ledger.apply(.make("1", "report.pdf", in: "/Users/x/Documents", total: 5, sent: 5, .finished), now: now)
        ledger.apply(.make("2", "beach.jpg", in: "/Users/x/Pictures", total: 5, sent: 1, .uploading), now: now)
        ledger.apply(.make("3", "dump.sql.gz", in: "/Users/x/Work", total: 5, .queued), now: now)
        ledger.apply(.make("4", "clip.mp4", in: "/Users/x/Movies", total: 5, .failed, error: "x"), now: now)
        return ledger.records
    }

    func testStateFiltersAndTheOverviewTreatmentOfWaiting() {
        var query = UploadQuery()
        XCTAssertEqual(query.apply(to: records).count, 4)
        query.state = .inProgress
        XCTAssertEqual(query.apply(to: records).map(\.id), ["2"])
        query.waitingCountsAsInProgress = true
        XCTAssertEqual(query.apply(to: records).map(\.id), ["2", "3"])
        query.state = .waiting
        XCTAssertEqual(query.apply(to: records).map(\.id), ["3"])
        query.state = .finished
        XCTAssertEqual(query.apply(to: records).map(\.id), ["1"])
        query.state = .failed
        XCTAssertEqual(query.apply(to: records).map(\.id), ["4"])
    }

    func testSearchMatchesNameOrFolderWithoutCase() {
        var query = UploadQuery(text: "  PICTURES ")
        XCTAssertEqual(query.apply(to: records).map(\.id), ["2"])
        query.text = "dump"
        XCTAssertEqual(query.apply(to: records).map(\.id), ["3"])
    }

    func testKindsCombineAndCountsIgnoreTheSelectedState() {
        var query = UploadQuery(kinds: [.images, .videos])
        XCTAssertEqual(query.apply(to: records).map(\.id), ["2", "4"])
        query.state = .failed
        XCTAssertEqual(query.count(.all, in: records), 2)
        XCTAssertEqual(query.count(.inProgress, in: records), 1)
        XCTAssertEqual(query.count(.failed, in: records), 1)
        XCTAssertEqual(query.count(.finished, in: records), 0)
    }

    func testEmptyTitleNamesTheStateAndTheSearch() {
        var query = UploadQuery(text: "tax-report-2019", state: .finished)
        XCTAssertTrue(query.isFiltering)
        XCTAssertEqual(query.emptyTitle, "No finished uploads match \"tax-report-2019\"")
        query.text = ""
        query.kinds = [.audio]
        XCTAssertEqual(query.emptyTitle, "No finished uploads match these file types")
        query.kinds = []
        query.state = .failed
        XCTAssertEqual(query.emptyTitle, "No failed uploads")
        query.clear()
        XCTAssertFalse(query.isFiltering)
        XCTAssertEqual(query, UploadQuery())
    }

    func testFileKinds() {
        XCTAssertEqual(FileKind.of(fileName: "invoice.pdf"), .documents)
        XCTAssertEqual(FileKind.of(fileName: "notes.TXT"), .documents)
        XCTAssertEqual(FileKind.of(fileName: "IMG_4410.jpg"), .images)
        XCTAssertEqual(FileKind.of(fileName: "beach-day.mp4"), .videos)
        XCTAssertEqual(FileKind.of(fileName: "song.mp3"), .audio)
        XCTAssertEqual(FileKind.of(fileName: "db-dump.sql.gz"), .archives)
        XCTAssertEqual(FileKind.of(fileName: "bundle.zip"), .archives)
        XCTAssertEqual(FileKind.of(fileName: "Makefile"), .other)
        XCTAssertEqual(FileKind.of(fileName: "data.unknownext"), .other)
        XCTAssertEqual(FileKind.folders.title, "Folders")
    }

    private let start = Date(timeIntervalSince1970: 1_794_500_000)

    func testTheFoldersFilterMatchesFolderUploadsAndSeveralItemsGoByTheirFirst() {
        var ledger = UploadLedger()
        ledger.apply(.folder("folder", "vacation-2026", files: 12, total: 100, .uploading), now: start)
        ledger.apply(.make("file", "notes.txt", total: 5, .uploading), now: start)
        ledger.apply(
            .several("several", ["/Users/someone/Downloads/report-q3.pdf", "/Users/someone/Desktop/cover.png"], total: 9, .uploading),
            now: start)
        let all = ledger.records

        XCTAssertEqual(FileKind.of(ledger["folder"]!), .folders)
        XCTAssertEqual(FileKind.of(ledger["several"]!), .documents)
        XCTAssertEqual(UploadQuery(kinds: [.folders]).apply(to: all).map(\.id), ["folder"])
        XCTAssertEqual(UploadQuery(kinds: [.documents]).apply(to: all).map(\.id), ["file", "several"])
        XCTAssertEqual(
            UploadQuery(text: "desktop").apply(to: all).map(\.id), ["several"],
            "search looks at every path the upload was handed")
    }

    func testFileCountersFollowTheSnapshotsAndTheSummaryCountsFiles() {
        var ledger = UploadLedger()
        ledger.apply(.folder("a", "vacation-2026", files: 12, total: 1200, .queued), now: start)
        XCTAssertEqual(ledger["a"]?.kind, .folder)
        XCTAssertEqual(ledger["a"]?.handedPaths, ["/Users/someone/Pictures/vacation-2026"])
        XCTAssertEqual(ledger["a"]?.filesTotal, 12)

        ledger.apply(.folder("a", "vacation-2026", files: 12, finished: 5, failed: 1, total: 1200, sent: 600, .uploading), now: start)
        XCTAssertEqual(ledger["a"]?.filesFinished, 5)
        XCTAssertEqual(ledger["a"]?.filesFailed, 1)
        // The failed file is sent again while the rest still runs: it is no longer failed,
        // and what was sent does not go back.
        ledger.apply(.folder("a", "vacation-2026", files: 12, finished: 5, total: 1200, sent: 560, .uploading), now: start)
        XCTAssertEqual(ledger["a"]?.filesFinished, 5)
        XCTAssertEqual(ledger["a"]?.filesFailed, 0)
        XCTAssertEqual(ledger["a"]?.bytesSent, 600)

        ledger.apply(.folder("a", "vacation-2026", files: 12, finished: 12, total: 1200, sent: 1200, .finished), now: start)
        ledger.apply(.make("b", "notes.txt", total: 5, sent: 5, .finished), now: start)
        XCTAssertEqual(ledger.finishedCount, 2, "uploads")
        XCTAssertEqual(ledger.finishedFileCount, 13, "files")
    }
}
