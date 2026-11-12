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

    func testFinishingReturnsTheRecordOnceAndLaterSnapshotsAreIgnored() {
        var ledger = UploadLedger()
        ledger.apply(.make("a", "f.bin", total: 100, sent: 10, .uploading), now: start)
        let ended = ledger.apply(
            .make("a", "f.bin", total: 100, sent: 100, .finished), now: start.addingTimeInterval(5))
        XCTAssertEqual(ended?.state, .finished)
        XCTAssertEqual(ended?.endedAt, start.addingTimeInterval(5))
        XCTAssertEqual(ended?.fraction, 1)
        // A replay after resubscribing, or a late progress snapshot, changes nothing.
        XCTAssertNil(ledger.apply(.make("a", "f.bin", total: 100, sent: 100, .finished), now: start.addingTimeInterval(9)))
        XCTAssertNil(ledger.apply(.make("a", "f.bin", total: 100, sent: 50, .uploading), now: start.addingTimeInterval(9)))
        XCTAssertEqual(ledger["a"]?.state, .finished)
        XCTAssertEqual(ledger["a"]?.endedAt, start.addingTimeInterval(5))
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
}
