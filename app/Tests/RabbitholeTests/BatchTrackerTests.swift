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

    func testFinishedStateIsNotOverwrittenByLateNonFinalSnapshot() {
        var tracker = BatchTracker()
        tracker.register(id: "a")
        tracker.apply(snapshot("a", .finished, sent: 100))
        tracker.apply(snapshot("a", .uploading, sent: 50))

        XCTAssertEqual(tracker.remaining, 0)
    }
}
