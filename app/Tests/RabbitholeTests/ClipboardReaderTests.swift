import AppKit
import XCTest

@testable import Rabbithole

@MainActor
final class ClipboardReaderTests: XCTestCase {
    private var pasteboard: NSPasteboard!
    private var directory: URL!
    /// 13 November 2026, 14:05:33 in the current calendar's time zone.
    private let now = Calendar.current.date(
        from: DateComponents(year: 2026, month: 11, day: 13, hour: 14, minute: 5, second: 33))!

    override func setUp() async throws {
        pasteboard = NSPasteboard(name: NSPasteboard.Name("rabbithole-tests-\(UUID().uuidString)"))
        pasteboard.clearContents()
        directory = FileManager.default.temporaryDirectory
            .appending(path: "rabbithole-clipboard-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    override func tearDown() async throws {
        pasteboard.releaseGlobally()
        try? FileManager.default.removeItem(at: directory)
    }

    private func read() throws -> [URL] {
        try ClipboardReader.files(from: pasteboard, savingIn: directory, now: now)
    }

    private func pngData(side: Int = 4) throws -> Data {
        let rep = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    func testAnEmptyClipboardHasNothingToUpload() {
        XCTAssertThrowsError(try read()) { XCTAssertEqual($0 as? ClipboardReader.Failure, .empty) }
    }

    func testTextThatIsOnlySpacesHasNothingToUpload() {
        pasteboard.setString("  \n\t ", forType: .string)
        XCTAssertThrowsError(try read()) { XCTAssertEqual($0 as? ClipboardReader.Failure, .empty) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path), "nothing is saved for it")
    }

    func testCopiedFilesAreUsedAsTheyAre() throws {
        let copied = [URL(fileURLWithPath: "/tmp/report.pdf"), URL(fileURLWithPath: "/tmp/photos", isDirectory: true)]
        pasteboard.writeObjects(copied.map { $0 as NSURL })

        XCTAssertEqual(try read().map(\.path), ["/tmp/report.pdf", "/tmp/photos"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path), "nothing is saved for copied files")
    }

    func testACopiedFileWinsOverTheTextAndImageCopiedWithIt() throws {
        let item = NSPasteboardItem()
        item.setString(URL(fileURLWithPath: "/tmp/report.pdf").absoluteString, forType: .fileURL)
        item.setString("report.pdf", forType: .string)
        item.setData(try pngData(), forType: .png)
        pasteboard.writeObjects([item])

        XCTAssertEqual(try read().map(\.path), ["/tmp/report.pdf"])
    }

    func testAWebAddressIsNotAFile() throws {
        pasteboard.writeObjects([URL(string: "https://example.com/picture.png")! as NSURL])
        pasteboard.setString("https://example.com/picture.png", forType: .string)

        let files = try read()

        XCTAssertEqual(files.map(\.pathExtension), ["txt"], "the address is uploaded as the text it is")
    }

    func testAnImageIsSavedAsAPNGFile() throws {
        let png = try pngData()
        pasteboard.setData(png, forType: .png)

        let files = try read()

        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].lastPathComponent, "Clipboard 2026-11-13 at 14.05.33.png")
        XCTAssertEqual(files[0].deletingLastPathComponent().standardizedFileURL, directory.standardizedFileURL)
        XCTAssertEqual(try Data(contentsOf: files[0]), png)
    }

    func testATIFFImageIsConvertedToPNG() throws {
        let image = try XCTUnwrap(NSBitmapImageRep(data: try pngData(side: 6)))
        pasteboard.setData(try XCTUnwrap(image.tiffRepresentation), forType: .tiff)

        let files = try read()

        XCTAssertEqual(files.map(\.pathExtension), ["png"])
        let saved = try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: files[0])))
        XCTAssertEqual(saved.pixelsWide, 6)
        XCTAssertEqual(saved.pixelsHigh, 6)
    }

    func testAnImageWinsOverText() throws {
        pasteboard.declareTypes([.png, .string], owner: nil)
        pasteboard.setData(try pngData(), forType: .png)
        pasteboard.setString("a caption", forType: .string)

        XCTAssertEqual(try read().map(\.pathExtension), ["png"])
    }

    func testTextIsSavedAsATextFileInUTF8() throws {
        pasteboard.setString("olá, coelho 🐇", forType: .string)

        let files = try read()

        XCTAssertEqual(files.map(\.lastPathComponent), ["Clipboard 2026-11-13 at 14.05.33.txt"])
        XCTAssertEqual(try String(contentsOf: files[0], encoding: .utf8), "olá, coelho 🐇")
    }

    func testTwoCopiesInTheSameSecondBecomeTwoFiles() throws {
        pasteboard.setString("first", forType: .string)
        let first = try read()
        pasteboard.clearContents()
        pasteboard.setString("second", forType: .string)
        let second = try read()

        XCTAssertEqual(second.map(\.lastPathComponent), ["Clipboard 2026-11-13 at 14.05.33 2.txt"])
        XCTAssertEqual(try String(contentsOf: first[0], encoding: .utf8), "first", "the first file is not replaced")
        XCTAssertEqual(try String(contentsOf: second[0], encoding: .utf8), "second")
    }

    func testAFolderThatCannotBeCreatedIsReportedAsNotSaved() throws {
        let blocker = FileManager.default.temporaryDirectory.appending(path: "rabbithole-blocker-\(UUID().uuidString)")
        try Data().write(to: blocker)
        defer { try? FileManager.default.removeItem(at: blocker) }
        pasteboard.setString("text", forType: .string)

        XCTAssertThrowsError(
            try ClipboardReader.files(from: pasteboard, savingIn: blocker.appending(path: "inside"), now: now)
        ) { XCTAssertEqual($0 as? ClipboardReader.Failure, .notSaved) }
    }

    func testPruneRemovesOnlySavedFilesOlderThanAWeek() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let old = directory.appending(path: "old.png")
        let recent = directory.appending(path: "recent.png")
        for url in [old, recent] { try Data("x".utf8).write(to: url) }
        let eightDaysAgo = now.addingTimeInterval(-8 * 24 * 60 * 60)
        let sixDaysAgo = now.addingTimeInterval(-6 * 24 * 60 * 60)
        try FileManager.default.setAttributes([.modificationDate: eightDaysAgo], ofItemAtPath: old.path)
        try FileManager.default.setAttributes([.modificationDate: sixDaysAgo], ofItemAtPath: recent.path)

        ClipboardReader.prune(directory, now: now)

        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recent.path))
    }

    func testPruneOfAFolderThatDoesNotExistDoesNothing() {
        ClipboardReader.prune(directory.appending(path: "missing"), now: now)
    }
}
