import Foundation
import XCTest

@testable import Rabbithole

final class UploadTextTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// Thursday 12 November 2026, 12:00 UTC.
    private let noon = Date(timeIntervalSince1970: 1_794_484_800)

    private func record(
        _ state: UploadState, total: Int64 = 1_900_000_000, sent: Int64 = 800_000_000,
        speed: Double? = nil, error: String = "", endedAt: Date? = nil
    ) -> UploadRecord {
        UploadRecord(
            id: "a", fileName: "vacation.zip", localPath: "/Users/x/vacation.zip", objectKey: "",
            bytesTotal: total, bytesSent: sent, state: state, errorMessage: error,
            startedAt: noon, endedAt: endedAt, bytesPerSecond: speed)
    }

    func testBytesUseTheMockupsUnits() {
        XCTAssertEqual(UploadText.bytes(0), "0 bytes")
        XCTAssertEqual(UploadText.bytes(1), "1 byte")
        XCTAssertEqual(UploadText.bytes(999), "999 bytes")
        XCTAssertEqual(UploadText.bytes(184_000), "184 KB")
        XCTAssertEqual(UploadText.bytes(2_100_000), "2.1 MB")
        XCTAssertEqual(UploadText.bytes(8_000_000), "8.0 MB")
        XCTAssertEqual(UploadText.bytes(800_000_000), "800 MB")
        XCTAssertEqual(UploadText.bytes(999_700_000), "1.0 GB")
        XCTAssertEqual(UploadText.bytes(1_900_000_000), "1.9 GB")
        XCTAssertEqual(UploadText.bytes(48_200_000_000), "48.2 GB")
        XCTAssertEqual(UploadText.bytes(999_600), "1.0 MB")
        XCTAssertEqual(UploadText.bytes(-5), "0 bytes")
        XCTAssertEqual(UploadText.speed(6_200_000), "6.2 MB/s")
    }

    func testTimeLeftRoundsUp() {
        XCTAssertEqual(UploadText.timeLeft(seconds: 20), "less than a minute")
        XCTAssertEqual(UploadText.timeLeft(seconds: 61), "about 2 min")
        XCTAssertEqual(UploadText.timeLeft(seconds: 180), "about 3 min")
        XCTAssertEqual(UploadText.timeLeft(seconds: 3600), "about 1 h")
        XCTAssertEqual(UploadText.timeLeft(seconds: 5400), "about 2 h")
    }

    func testProgressLinesFollowTheMockupWording() {
        XCTAssertEqual(
            UploadText.progressLine(record(.uploading, speed: 6_200_000)),
            .init(text: "800 MB of 1.9 GB sent, 1.1 GB left, about 3 min", tone: .normal))
        XCTAssertEqual(
            UploadText.progressLine(record(.uploading)).text, "800 MB of 1.9 GB sent, 1.1 GB left",
            "no estimate without a measured speed")
        XCTAssertEqual(
            UploadText.progressLine(record(.queued, total: 640_000_000, sent: 0)),
            .init(text: "Waiting, 640 MB to send", tone: .normal))
        XCTAssertEqual(
            UploadText.progressLine(record(.finished, total: 184_000, sent: 184_000)),
            .init(text: "Finished, 184 KB sent", tone: .ok))
        XCTAssertEqual(
            UploadText.progressLine(record(.failed, error: "No internet connection")),
            .init(text: "Failed, no internet connection", tone: .bad))
        XCTAssertEqual(
            UploadText.progressLine(record(.failed, error: "AWS rejected the access key")).text,
            "Failed, AWS rejected the access key")
    }

    func testStoppedLinesSayHowFarTheUploadGotAndWhy() {
        let failed = record(.failed, error: "No internet connection")
        XCTAssertEqual(
            UploadText.stoppedLine(failed, condition: .offline),
            .init(text: "Stopped at 800 MB of 1.9 GB, no internet connection", tone: .warn))
        XCTAssertEqual(
            UploadText.stoppedLine(failed, condition: .keyRejected),
            .init(text: "Stopped at 800 MB of 1.9 GB, access key rejected", tone: .bad))
        XCTAssertEqual(UploadText.stoppedLine(failed, condition: .none), UploadText.progressLine(failed))
        XCTAssertEqual(UploadText.menuBarClock(noon.addingTimeInterval(58 * 60), calendar: calendar), "Thu 12:58")
    }

    func testHistoryLinesSayWhenAnUploadEnded() {
        let now = noon
        let today = noon.addingTimeInterval(-4 * 60)
        let yesterday = noon.addingTimeInterval(-86_400 + 6 * 3600 + 20 * 60)
        let tuesday = noon.addingTimeInterval(-2 * 86_400 - 2 * 3600 - 46 * 60)
        XCTAssertEqual(
            UploadText.historyLine(
                record(.finished, total: 184_000, sent: 184_000, endedAt: today), now: now, calendar: calendar
            ).text, "Finished today at 11:56, 184 KB sent")
        XCTAssertEqual(
            UploadText.historyLine(
                record(.finished, total: 480_000_000, endedAt: yesterday), now: now, calendar: calendar
            ).text, "Finished yesterday at 18:20, 480 MB sent")
        XCTAssertEqual(
            UploadText.historyLine(
                record(.failed, error: "No internet connection", endedAt: tuesday), now: now, calendar: calendar),
            .init(text: "Failed on Tuesday at 09:14, no internet connection", tone: .bad))
        XCTAssertEqual(
            UploadText.historyLine(
                record(.finished, total: 1_000, endedAt: noon.addingTimeInterval(-9 * 86_400)),
                now: now, calendar: calendar
            ).text, "Finished on 3 Nov at 12:00, 1 KB sent")
        XCTAssertEqual(
            UploadText.historyLine(record(.queued, total: 5_000, sent: 0), now: now, calendar: calendar).text,
            "Waiting, 5 KB to send")
    }

    func testFileLines() {
        func line(_ state: UploadState, total: Int64, sent: Int64 = 0, error: String = "") -> UploadText.Line {
            UploadText.fileLine(.make(0, "IMG_4410.jpg", total: total, sent: sent, state, error: error))
        }
        XCTAssertEqual(line(.uploading, total: 8_000_000, sent: 5_100_000).text, "5.1 MB of 8.0 MB")
        XCTAssertEqual(line(.queued, total: 7_400_000).text, "Waiting, 7.4 MB")
        XCTAssertEqual(line(.finished, total: 7_800_000), .init(text: "Finished, 7.8 MB", tone: .ok))
        XCTAssertEqual(line(.failed, total: 1, error: ""), .init(text: "Failed, upload failed", tone: .bad))
        XCTAssertEqual(line(.failed, total: 1, error: "Connection lost").text, "Failed, connection lost")
    }

    func testAFolderIsNamedWithASlashAndSeveralItemsAfterTheFirstPlusHowManyMore() {
        var upload = record(.uploading)
        XCTAssertEqual(UploadText.name(upload), "vacation.zip")
        XCTAssertEqual(UploadText.location(upload, home: "/Users/x"), "~/vacation.zip")

        upload.kind = .folder
        upload.fileName = "vacation-2026"
        upload.localPath = "/Users/x/Pictures/vacation-2026"
        upload.rootPaths = ["/Users/x/Pictures/vacation-2026"]
        XCTAssertEqual(UploadText.name(upload), "vacation-2026/")
        XCTAssertEqual(UploadText.location(upload, home: "/Users/x"), "~/Pictures/vacation-2026")

        upload.kind = .multiple
        upload.fileName = "report-q3.pdf"
        upload.localPath = "/Users/x/Downloads/report-q3.pdf"
        upload.rootPaths = ["report-q3.pdf", "a.png", "b.png", "c", "d", "e", "f", "g"].map { "/Users/x/Downloads/\($0)" }
        XCTAssertEqual(UploadText.name(upload), "report-q3.pdf and 7 more")
        XCTAssertEqual(UploadText.location(upload, home: "/Users/x"), "~/Downloads")

        upload.rootPaths = ["/Users/x/Downloads/report-q3.pdf", "/Users/x/Documents/legal/contract.pdf"]
        XCTAssertEqual(UploadText.name(upload), "report-q3.pdf and 1 more")
        XCTAssertEqual(UploadText.location(upload, home: "/Users/x"), "~", "items from different folders share an ancestor")
        XCTAssertEqual(UploadText.commonFolder(of: ["/a/b/c.txt", "/a/b/d/e.txt"]), "/a/b")
        XCTAssertEqual(UploadText.commonFolder(of: ["/a/x.txt", "/b/y.txt"]), "/")
    }

    func testFilesFactAndTheLineOfAnUploadWhoseFilesPartlyFailed() {
        var upload = record(.uploading)
        upload.kind = .folder
        upload.filesTotal = 12
        upload.filesFinished = 5
        upload.filesFailed = 1
        XCTAssertEqual(UploadText.filesSent(upload), "5 of 12 sent")
        XCTAssertEqual(UploadText.filesSent(record(.queued)), "0 of 1 sent")

        upload.state = .failed
        upload.errorMessage = "3 of 12 files could not be sent"
        XCTAssertEqual(UploadText.progressLine(upload).text, "Failed, 3 of 12 files could not be sent")
    }

    func testFilesOfAFolderAreListedWithoutTheFoldersOwnName() {
        var folder = record(.uploading)
        folder.kind = .folder
        folder.fileName = "vacation-2026"
        let prefix = UploadText.hiddenFilePrefix(folder)
        XCTAssertEqual(prefix, "vacation-2026/")
        XCTAssertEqual(
            UploadText.fileName(.make(0, "vacation-2026/IMG_4410.jpg", total: 1, .queued), hiding: prefix), "IMG_4410.jpg")
        XCTAssertEqual(
            UploadText.fileName(.make(1, "vacation-2026/day1/beach.mp4", total: 1, .queued), hiding: prefix),
            "day1/beach.mp4")

        var several = record(.uploading)
        several.kind = .multiple
        XCTAssertEqual(UploadText.hiddenFilePrefix(several), "")
        XCTAssertEqual(
            UploadText.fileName(.make(0, "photos/a.jpg", total: 1, .queued), hiding: ""), "photos/a.jpg",
            "several items keep their folder, which tells them apart")
        XCTAssertEqual(UploadText.hiddenFilePrefix(record(.uploading)), "")
    }

    func testAges() {
        XCTAssertEqual(UploadText.started(noon.addingTimeInterval(-480), now: noon, calendar: calendar), "Today, 11:52")
        XCTAssertEqual(UploadText.shortAge(noon.addingTimeInterval(-30), now: noon, calendar: calendar), "now")
        XCTAssertEqual(UploadText.shortAge(noon.addingTimeInterval(-125), now: noon, calendar: calendar), "2m")
        XCTAssertEqual(UploadText.shortAge(noon.addingTimeInterval(-3 * 3600), now: noon, calendar: calendar), "3h")
        XCTAssertEqual(UploadText.shortAge(noon.addingTimeInterval(-2 * 86_400), now: noon, calendar: calendar), "Tue")
        XCTAssertEqual(UploadText.longAge(noon.addingTimeInterval(-10), now: noon), "Just now")
        XCTAssertEqual(UploadText.longAge(noon.addingTimeInterval(-60), now: noon), "1 minute ago")
        XCTAssertEqual(UploadText.longAge(noon.addingTimeInterval(-125), now: noon), "2 minutes ago")
        XCTAssertEqual(UploadText.longAge(noon.addingTimeInterval(-2 * 3600), now: noon), "2 hours ago")
        XCTAssertEqual(UploadText.longAge(noon.addingTimeInterval(-86_400), now: noon), "Yesterday")
        XCTAssertEqual(UploadText.longAge(noon.addingTimeInterval(-3 * 86_400), now: noon), "3 days ago")
    }

    func testPathsAndDestination() {
        XCTAssertEqual(UploadText.displayPath("/Users/x/Pictures/a.jpg", home: "/Users/x"), "~/Pictures/a.jpg")
        XCTAssertEqual(UploadText.displayPath("/Users/x", home: "/Users/x"), "~")
        XCTAssertEqual(UploadText.displayPath("/Users/xavier/a.jpg", home: "/Users/x"), "/Users/xavier/a.jpg")
        XCTAssertEqual(UploadText.displayPath("/Volumes/Disk/a.jpg", home: "/Users/x"), "/Volumes/Disk/a.jpg")

        var queued = record(.queued)
        XCTAssertEqual(UploadText.destination(queued, prefix: "inbox/"), "inbox/vacation.zip")
        queued.objectKey = "inbox/vacation-20261112-120000.zip"
        XCTAssertEqual(UploadText.destination(queued, prefix: "inbox/"), "inbox/vacation-20261112-120000.zip")

        var folder = record(.queued)
        folder.kind = .folder
        folder.fileName = "vacation-2026"
        XCTAssertEqual(UploadText.destination(folder, prefix: "inbox/"), "inbox/vacation-2026")
        folder.objectKey = "inbox/vacation-2026-1/"
        XCTAssertEqual(UploadText.destination(folder, prefix: "inbox/"), "inbox/vacation-2026-1")

        var several = record(.queued)
        several.kind = .multiple
        XCTAssertEqual(UploadText.destination(several, prefix: "inbox/"), "inbox")
    }
}
