import XCTest

@testable import Rabbithole

final class BatchTrackerTests: XCTestCase {
    private func snapshot(
        _ id: String,
        _ state: UploadState,
        sent: Int64 = 0,
        total: Int64 = 100,
        error: String = ""
    ) -> UploadSnapshot {
        UploadSnapshot(
            id: id,
            fileName: "\(id).bin",
            localPath: "/tmp/\(id).bin",
            objectKey: "key/\(id)",
            bytesTotal: total,
            bytesSent: sent,
            state: state,
            errorMessage: error
        )
    }

    func testRemainingCountsUnfinishedUploads() {
        var tracker = BatchTracker()
        for id in ["a", "b", "c"] { tracker.register(id: id) }
        tracker.apply(snapshot("a", .finished, sent: 100))

        XCTAssertEqual(tracker.remaining, 2)
        XCTAssertEqual(tracker.total, 3)
        XCTAssertTrue(tracker.isActive)
    }

    func testTotalAndRemainingCountTheFilesOfEveryUploadInTheBatch() {
        var tracker = BatchTracker()
        tracker.register(id: "folder")
        tracker.register(id: "items", items: 3)
        XCTAssertEqual(tracker.total, 4, "until a snapshot arrives, each item handed over stands for one file")
        XCTAssertEqual(tracker.remaining, 4)

        tracker.apply(.folder("folder", "vacation-2026", files: 12, finished: 4, failed: 1, total: 1200, sent: 500, .uploading))
        XCTAssertEqual(tracker.total, 15)
        XCTAssertEqual(tracker.remaining, 10, "failed files are not left to send")

        tracker.apply(.several("items", ["/tmp/a", "/tmp/photos", "/tmp/b"], files: 40, finished: 40, total: 400, sent: 400, .uploading))
        XCTAssertEqual(tracker.total, 52)
        XCTAssertEqual(tracker.remaining, 8, "an upload that is not done yet still has a file to go")
        XCTAssertTrue(tracker.isActive)

        tracker.apply(.several("items", ["/tmp/a", "/tmp/photos", "/tmp/b"], files: 40, finished: 40, total: 400, sent: 400, .finished))
        tracker.apply(.folder("folder", "vacation-2026", files: 12, finished: 9, failed: 3, total: 1200, sent: 900, .failed, error: "3 of 12 files could not be sent"))
        XCTAssertEqual(tracker.remaining, 0)
        XCTAssertEqual(tracker.total, 52)
        XCTAssertFalse(tracker.isActive)
        XCTAssertEqual(tracker.firstError, "3 of 12 files could not be sent")
    }

    func testFractionIsBytesSentOverTotal() {
        var tracker = BatchTracker()
        tracker.register(id: "a")
        tracker.apply(snapshot("a", .uploading, sent: 100, total: 400))

        XCTAssertEqual(tracker.fraction, 0.25, accuracy: 0.0001)
    }

    func testFractionIsRawRatioWhenFileJoinsBatch() {
        var tracker = BatchTracker()
        // B joins while A is still unfinished, so both belong to the same batch.
        tracker.register(id: "a")
        tracker.apply(snapshot("a", .uploading, sent: 50, total: 100))
        tracker.register(id: "b")
        tracker.apply(snapshot("a", .finished, sent: 100, total: 100))
        tracker.apply(snapshot("b", .queued, sent: 0, total: 900))

        XCTAssertEqual(tracker.fraction, 0.1, accuracy: 0.0001)
        XCTAssertEqual(tracker.remaining, 1)
        XCTAssertEqual(tracker.total, 2)

        tracker.apply(snapshot("b", .uploading, sent: 450, total: 900))
        XCTAssertEqual(tracker.fraction, 0.55, accuracy: 0.0001)
    }

    func testPerUploadBytesNeverDecrease() {
        var tracker = BatchTracker()
        tracker.register(id: "a")
        tracker.apply(snapshot("a", .uploading, sent: 500, total: 1000))
        tracker.apply(snapshot("a", .uploading, sent: 300, total: 1000))

        XCTAssertEqual(tracker.fraction, 0.5, accuracy: 0.0001)
    }

    func testFractionNeverExceedsOne() {
        var tracker = BatchTracker()
        tracker.register(id: "a")
        tracker.apply(snapshot("a", .uploading, sent: 500, total: 100))

        XCTAssertEqual(tracker.fraction, 1, accuracy: 0.0001)
    }

    func testZeroByteBatchHasFractionZeroAndEndsWhenFinished() {
        var tracker = BatchTracker()
        tracker.register(id: "a")
        tracker.apply(snapshot("a", .uploading, sent: 0, total: 0))
        XCTAssertEqual(tracker.fraction, 0)
        XCTAssertTrue(tracker.isActive)

        tracker.apply(snapshot("a", .finished, sent: 0, total: 0))
        XCTAssertEqual(tracker.fraction, 0)
        XCTAssertFalse(tracker.isActive)
        XCTAssertNil(tracker.firstError)
    }

    func testFinishedUploadCountsAllItsBytes() {
        var tracker = BatchTracker()
        tracker.register(id: "a")
        tracker.apply(snapshot("a", .finished, sent: 0, total: 100))

        XCTAssertEqual(tracker.fraction, 1, accuracy: 0.0001)
    }

    func testBatchEndsWhenAllFinishedOrFailed() {
        var tracker = BatchTracker()
        tracker.register(id: "a")
        tracker.register(id: "b")
        tracker.apply(snapshot("a", .finished, sent: 100))
        XCTAssertTrue(tracker.isActive)

        tracker.apply(snapshot("b", .failed, sent: 10, error: "boom"))
        XCTAssertFalse(tracker.isActive)
        XCTAssertEqual(tracker.remaining, 0)
        XCTAssertEqual(tracker.firstError, "boom")
    }

    func testNextRegisterStartsNewBatch() {
        var tracker = BatchTracker()
        tracker.register(id: "a")
        tracker.apply(snapshot("a", .finished, sent: 100))
        XCTAssertFalse(tracker.isActive)

        tracker.register(id: "b")
        XCTAssertEqual(tracker.total, 1)
        XCTAssertEqual(tracker.remaining, 1)
        XCTAssertNil(tracker.firstError)
        XCTAssertEqual(tracker.fraction, 0)
    }

    func testRegisterWhileActiveJoinsTheBatch() {
        var tracker = BatchTracker()
        tracker.register(id: "a")
        tracker.register(id: "b")

        XCTAssertEqual(tracker.total, 2)
    }

    func testSnapshotsOfEarlierBatchesIgnored() {
        var tracker = BatchTracker()
        tracker.register(id: "a")
        tracker.apply(snapshot("a", .finished, sent: 100))
        tracker.register(id: "b")

        XCTAssertFalse(tracker.apply(snapshot("a", .uploading, sent: 50)))
        XCTAssertEqual(tracker.total, 1)
        XCTAssertEqual(tracker.remaining, 1)
    }

    func testReplayedSnapshotsOfUnregisteredIdsIgnored() {
        var tracker = BatchTracker()
        XCTAssertFalse(tracker.apply(snapshot("old", .finished, sent: 100)))
        XCTAssertFalse(tracker.apply(snapshot("old2", .uploading, sent: 5)))

        XCTAssertEqual(tracker.total, 0)
        XCTAssertEqual(tracker.remaining, 0)
        XCTAssertFalse(tracker.isActive)

        tracker.register(id: "new")
        XCTAssertEqual(tracker.total, 1)
        XCTAssertEqual(tracker.remaining, 1)
    }

    func testSnapshotArrivingBeforeRegisterIsClaimed() {
        var tracker = BatchTracker()
        tracker.apply(snapshot("a", .uploading, sent: 50))
        tracker.register(id: "a")

        XCTAssertEqual(tracker.total, 1)
        XCTAssertEqual(tracker.fraction, 0.5, accuracy: 0.0001)
    }

    func testFinishedSnapshotArrivingBeforeRegisterEndsTheBatchOnRegister() {
        var tracker = BatchTracker()
        tracker.apply(snapshot("a", .finished, sent: 100))
        tracker.register(id: "a")

        XCTAssertEqual(tracker.total, 1)
        XCTAssertEqual(tracker.remaining, 0)
        XCTAssertFalse(tracker.isActive)
    }

    func testHeldFinishedSnapshotIsDroppedWhenNewBatchStarts() {
        var tracker = BatchTracker()
        tracker.apply(snapshot("stale", .finished, sent: 100))
        tracker.register(id: "a")

        // "stale" was dropped at batch start, so registering it now finds nothing to claim.
        tracker.register(id: "stale")
        XCTAssertEqual(tracker.total, 2)
        XCTAssertEqual(tracker.remaining, 2)
    }

    func testHeldSnapshotsKeepOnlyTheLatestPerId() {
        var tracker = BatchTracker()
        tracker.apply(snapshot("a", .uploading, sent: 10))
        tracker.apply(snapshot("a", .uploading, sent: 70))
        tracker.register(id: "a")

        XCTAssertEqual(tracker.fraction, 0.7, accuracy: 0.0001)
    }

    func testHeldCountIsBoundedPerId() {
        var tracker = BatchTracker()
        for _ in 0..<1000 { tracker.apply(snapshot("a", .uploading, sent: 10)) }

        XCTAssertEqual(tracker.heldCount, 1)
    }

    func testInterruptedMarksUnfinishedFailedWithUploadInterrupted() {
        var tracker = BatchTracker()
        tracker.register(id: "a")
        tracker.register(id: "b")
        tracker.apply(snapshot("a", .finished, sent: 100))
        tracker.interrupted()

        XCTAssertFalse(tracker.isActive)
        XCTAssertEqual(tracker.remaining, 0)
        XCTAssertEqual(tracker.firstError, "Upload interrupted")
    }

    func testFirstErrorIsTheEarliestFailureInRegistrationOrder() {
        var tracker = BatchTracker()
        tracker.register(id: "a")
        tracker.register(id: "b")
        tracker.apply(snapshot("b", .failed, error: "second"))
        tracker.apply(snapshot("a", .failed, error: "first"))

        XCTAssertEqual(tracker.firstError, "first")
    }

    func testAnEndedUploadIsNotChangedByAnotherReportOfItsEnd() {
        var tracker = BatchTracker()
        tracker.register(id: "a")
        tracker.apply(snapshot("a", .failed, sent: 40, error: "first"))
        XCTAssertFalse(tracker.apply(snapshot("a", .failed, sent: 40, error: "replayed")))

        XCTAssertEqual(tracker.remaining, 0)
        XCTAssertEqual(tracker.firstError, "first")
    }

    // MARK: Retry inside the same upload

    func testARetriedUploadOfTheBatchIsCountedAgainByItsNextSnapshot() {
        var tracker = BatchTracker()
        tracker.register(id: "ok")
        tracker.register(id: "bad")
        tracker.apply(snapshot("ok", .finished, sent: 100))
        tracker.apply(snapshot("bad", .failed, sent: 40, error: "Connection lost"))
        XCTAssertFalse(tracker.isActive)

        // The queue was empty, so the retried upload alone is the next batch.
        tracker.willRetry(id: "bad")
        tracker.retried(id: "bad", files: 1)
        XCTAssertFalse(tracker.isActive, "nothing changes until the daemon reports it waiting")
        XCTAssertTrue(tracker.apply(snapshot("bad", .queued, sent: 40)))
        XCTAssertTrue(tracker.isActive)
        XCTAssertEqual(tracker.total, 1)
        XCTAssertEqual(tracker.remaining, 1)
        XCTAssertNil(tracker.firstError)

        tracker.apply(snapshot("bad", .finished, sent: 100))
        XCTAssertFalse(tracker.isActive)
        XCTAssertNil(tracker.firstError)
        XCTAssertEqual(tracker.fraction, 1)
    }

    func testARetriedUploadJoinsABatchThatIsStillRunning() {
        var tracker = BatchTracker()
        tracker.register(id: "bad")
        tracker.register(id: "running")
        tracker.apply(snapshot("bad", .failed, error: "Connection lost"))
        tracker.apply(snapshot("running", .uploading, sent: 50))

        tracker.apply(snapshot("bad", .uploading, sent: 10))
        XCTAssertEqual(tracker.total, 2)
        XCTAssertEqual(tracker.remaining, 2)
        XCTAssertNil(tracker.firstError)
    }

    func testARetriedUploadFromOutsideTheBatchIsRegisteredWithoutItsOldEnd() {
        var tracker = BatchTracker()
        // History replayed on subscription: held, never counted.
        tracker.apply(snapshot("old", .failed, sent: 40, error: "Connection lost"))
        XCTAssertEqual(tracker.heldCount, 1)

        tracker.willRetry(id: "old")
        XCTAssertEqual(tracker.heldCount, 0, "the old failure must not be claimed as the new outcome")
        tracker.retried(id: "old", files: 3)
        XCTAssertTrue(tracker.isActive)
        XCTAssertEqual(tracker.total, 3)
        XCTAssertNil(tracker.firstError)
    }

    func testARetryThatEndedBeforeTheCallReturnedIsClaimedWithItsOutcome() {
        var tracker = BatchTracker()
        tracker.apply(snapshot("old", .failed, error: "Connection lost"))
        tracker.willRetry(id: "old")
        // Coalesced: the new attempt already finished when the call returns.
        tracker.apply(snapshot("old", .finished, sent: 100))
        tracker.retried(id: "old", files: 1)
        XCTAssertFalse(tracker.isActive)
        XCTAssertNil(tracker.firstError)
        XCTAssertEqual(tracker.total, 1)
    }

    // MARK: Removed uploads

    func testARemovedUploadStopsCountingAndAHeldOneIsDropped() {
        var tracker = BatchTracker()
        tracker.register(id: "a")
        tracker.register(id: "b")
        tracker.apply(snapshot("a", .finished, sent: 100))
        tracker.apply(snapshot("b", .failed, error: "Connection lost"))
        tracker.apply(snapshot("history", .finished, sent: 100))
        XCTAssertEqual(tracker.heldCount, 1)

        XCTAssertTrue(tracker.apply(.removed(id: "b")), "the batch changed")
        XCTAssertEqual(tracker.total, 1)
        XCTAssertNil(tracker.firstError)

        XCTAssertFalse(tracker.apply(.removed(id: "history")), "it was never part of the batch")
        XCTAssertEqual(tracker.heldCount, 0)
        XCTAssertFalse(tracker.remove("b"))
        XCTAssertTrue(tracker.remove("a"))
        XCTAssertEqual(tracker.total, 0)
    }
}
