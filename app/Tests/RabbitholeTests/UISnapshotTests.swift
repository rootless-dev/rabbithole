import AppKit
import SwiftUI
import XCTest

@testable import Rabbithole

/// Everything a screen needs, built on fakes: no daemon, no keychain, no real preferences.
@MainActor
final class UIFixture {
    static let home = NSHomeDirectory()

    let clock = TestClock()
    let client = StubDaemonClient()
    let credentials = StubCredentialStore()
    let scratch = ScratchDefaults()
    let store: SettingsStore
    let tray: TrayViewModel
    let context: MainContext
    let thumbnails = ThumbnailCache(generate: { url, side, _ in UIFixture.picture(for: url, side: side) })
    private(set) var savedSettings: [AWSSettings] = []

    init(configured: Bool = true, sleep: @escaping (Duration) async throws -> Void = { _ in }) async {
        let clock = clock
        store = SettingsStore(credentials: credentials, defaults: scratch.defaults)
        let settings = AWSSettings(
            accessKeyID: "AKIAIOSFODNN7EXAMPLE", secretAccessKey: "not-a-real-secret",
            region: "sa-east-1", bucket: "example-backups")
        if configured { try? store.save(settings) }
        tray = TrayViewModel(client: client, sleep: sleep, uploads: UploadStore(now: { clock.now }))
        tray.configured(with: configured ? settings : nil)
        let account = AccountModel(store: store, onSaved: { _ in })
        // Files are shown as soon as they arrive, so a render does not wait for the interval.
        let model = MainWindowModel(detailFiles: UploadFilesModel(publishInterval: .zero))
        model.watchFiles = { [client] in client.watchFiles(uploadID: $0) }
        // The upload actions are wired as the app wires them.
        var actions = AppActions()
        actions.retry = { [tray] records in Task { await tray.retry(records) } }
        actions.retryFiles = { [tray] uploadID, fileIndexes in
            Task { await tray.retry(uploadID: uploadID, fileIndexes: fileIndexes) }
        }
        actions.removeUpload = { [tray] uploadID, fileIndexes, deleteFromBucket in
            try await tray.remove(uploadID: uploadID, fileIndexes: fileIndexes, deleteFromBucket: deleteFromBucket)
        }
        actions.pauseUpload = { [tray] id in Task { await tray.pause(uploadID: id) } }
        actions.resumeUpload = { [tray] id in Task { await tray.resume(uploadID: id) } }
        actions.cancelUpload = { [tray] id in Task { await tray.cancel(uploadID: id) } }
        // The folder panel is the system's: tests download straight into Downloads.
        actions.download = { [tray] target in
            Task { await tray.download(target, to: "\(UIFixture.home)/Downloads") }
        }
        actions.cancelDownload = { [tray] target in Task { await tray.cancelDownload(target) } }
        tray.uploads.onRemoved = { [weak model] id in model?.uploadRemoved(id) }
        let store = store
        let buckets = BucketListModel(
            service: BucketService(client: client),
            access: { await AWSSettingsForm.access(store: store) },
            selection: { (account.bucket, account.region) },
            pick: { bucket in Task { await account.choose(bucket) } })
        context = MainContext(
            model: model, tray: tray, account: account,
            preferences: AppPreferences(defaults: scratch.defaults),
            loginItem: LoginItemModel(service: StubLoginItemService(enabled: true)),
            buckets: buckets, actions: actions)
        await account.reload()
        await context.loginItem.refresh()
    }

    /// Enqueues `names` through the view model, as drops would, and returns their ids.
    func enqueue(_ count: Int) async {
        for index in 1...count {
            await tray.drop([URL(fileURLWithPath: "/tmp/file-\(index)")])
        }
    }

    /// The eight items sent together as one upload, like "report-q3.pdf and 7 more" in the
    /// mockups. The pile shows the first three.
    static let severalPaths = [
        "report-q3.pdf", "summary-q3.pdf", "cover.png", "chart-revenue.png", "chart-costs.png",
        "notes.txt", "budget.xlsx", "appendix.pdf",
    ].map { "\(home)/Downloads/\($0)" }

    /// The twelve files of the "vacation-2026" folder, as the upload detail mockup lists them.
    static let vacationFiles: [FileSnapshot] = {
        let rows: [(String, Int64, Int64, UploadState, String)] = [
            ("IMG_4401.jpg", 7_800_000, 7_800_000, .finished, ""),
            ("IMG_4402.jpg", 8_300_000, 8_300_000, .finished, ""),
            ("IMG_4403.jpg", 6_600_000, 6_600_000, .finished, ""),
            ("IMG_4404.jpg", 7_100_000, 7_100_000, .finished, ""),
            ("IMG_4405.jpg", 7_900_000, 7_900_000, .finished, ""),
            ("IMG_4407.jpg", 7_600_000, 2_900_000, .failed, "Connection lost"),
            ("IMG_4410.jpg", 8_000_000, 5_100_000, .uploading, ""),
            ("beach-day.mp4", 860_000_000, 180_000_000, .uploading, ""),
            ("IMG_4412.jpg", 7_400_000, 0, .queued, ""),
            ("IMG_4413.jpg", 6_900_000, 0, .queued, ""),
            ("IMG_4414.jpg", 7_200_000, 0, .queued, ""),
            ("sunset.mov", 940_000_000, 0, .queued, ""),
        ]
        return rows.enumerated().map { index, row in
            .make(
                index, "vacation-2026/\(row.0)", of: "up-7", in: "\(home)/Pictures", total: row.1, sent: row.2,
                row.3, error: row.4)
        }
    }()

    /// Seven uploads in every state and of every kind, like the lists in the dashboard and
    /// history mockups: a folder being sent, a file, several items sent together, a folder
    /// waiting, two finished files and a failed one.
    func loadMixedUploads() async {
        await enqueue(7)
        let documents = "\(Self.home)/Documents"
        let pictures = "\(Self.home)/Pictures"
        let clientWork = "\(Self.home)/Work/client"
        client.setFiles(Self.vacationFiles, of: "up-7")
        client.setFiles(
            Self.severalPaths.enumerated().map { index, path in
                .make(
                    index, (path as NSString).lastPathComponent, of: "up-4", in: "\(Self.home)/Downloads",
                    total: 60_000_000, sent: index < 5 ? 60_000_000 : 5_000_000, index < 5 ? .finished : .uploading)
            }, of: "up-4")
        clock.advance(-3600 * 26)
        tray.apply(.make("up-6", "armadillo.png", in: "\(Self.home)/Downloads", total: 900_000, sent: 300_000, .failed, error: "No internet connection"))
        clock.advance(3600 * 26 - 900)
        tray.apply(.make("up-2", "contract-signed.pdf", in: "\(documents)/legal", total: 2_100_000, sent: 2_100_000, .finished))
        clock.advance(600)
        tray.apply(.make("up-1", "invoice-october.pdf", in: "\(documents)/finance", total: 184_000, sent: 184_000, .finished))
        clock.advance(170)
        tray.apply(.folder("up-7", "vacation-2026", in: pictures, files: 12, finished: 5, failed: 1, total: 1_900_000_000, sent: 738_000_000, .uploading))
        tray.apply(.make("up-3", "db-dump.sql.gz", in: "\(Self.home)/Work/backups", total: 4_200_000_000, sent: 1_240_000_000, .uploading))
        tray.apply(.several("up-4", Self.severalPaths, finished: 5, total: 480_000_000, sent: 280_000_000, .uploading))
        clock.advance(10)
        tray.apply(.folder("up-7", "vacation-2026", in: pictures, files: 12, finished: 5, failed: 1, total: 1_900_000_000, sent: 800_000_000, .uploading))
        tray.apply(.make("up-3", "db-dump.sql.gz", in: "\(Self.home)/Work/backups", total: 4_200_000_000, sent: 1_300_000_000, .uploading))
        tray.apply(.several("up-4", Self.severalPaths, finished: 5, total: 480_000_000, sent: 310_000_000, .uploading))
        tray.apply(.folder("up-5", "design-assets", in: clientWork, files: 24, total: 640_000_000, .queued))
        clock.advance(120)
        await warmThumbnails()
    }

    /// The three ended uploads of the upload actions mockup, with the daemon's times: a file
    /// finished today, the "vacation-2026" folder finished yesterday after 5 min 12 s, and a
    /// file that failed three days ago with nothing in the bucket. The folder's twelve files
    /// are all finished.
    func loadEndedUploads() async {
        let today = Calendar.current.startOfDay(for: Date())
        func time(daysAgo: Int, _ hour: Int, _ minute: Int, _ second: Int = 0) -> Date {
            today.addingTimeInterval(Double(-daysAgo * 86_400 + hour * 3600 + minute * 60 + second))
        }
        let sizes: [Int64] = [78, 83, 66, 71, 79, 76, 80, 74, 69, 72, 81, 77].map { $0 * 100_000 }
        client.setFiles(
            sizes.enumerated().map { index, size in
                .make(
                    index, "vacation-2026/IMG_44\(String(format: "%02d", index + 1)).jpg", of: "up-2",
                    in: "\(Self.home)/Pictures", total: size, sent: size, .finished)
            }, of: "up-2")
        tray.apply(
            UploadSnapshot(
                id: "up-3", fileName: "armadillo.png", localPath: "\(Self.home)/Downloads/armadillo.png",
                objectKey: "", bytesTotal: 900_000, bytesSent: 300_000, state: .failed,
                errorMessage: "Connection lost", filesFailed: 1,
                createdAt: time(daysAgo: 3, 9, 13), endedAt: time(daysAgo: 3, 9, 14)))
        tray.apply(
            UploadSnapshot(
                id: "up-2", fileName: "vacation-2026", localPath: "\(Self.home)/Pictures/vacation-2026",
                objectKey: "quick-uploads/vacation-2026/", bytesTotal: 1_900_000_000, bytesSent: 1_900_000_000,
                state: .finished, errorMessage: "", kind: .folder, filesTotal: 12, filesFinished: 12,
                createdAt: time(daysAgo: 1, 18, 14, 48), endedAt: time(daysAgo: 1, 18, 20)))
        tray.apply(
            UploadSnapshot(
                id: "up-1", fileName: "invoice-october.pdf",
                localPath: "\(Self.home)/Documents/finance/invoice-october.pdf",
                objectKey: "quick-uploads/invoice-october.pdf", bytesTotal: 184_000, bytesSent: 184_000,
                state: .finished, errorMessage: "",
                createdAt: time(daysAgo: 0, 11, 55), endedAt: time(daysAgo: 0, 11, 56)))
        await warmThumbnails()
    }

    /// The buckets of the mockup's open selector, in its order.
    static let threeBuckets = [
        Bucket(name: "carlos-backups", region: "sa-east-1"), Bucket(name: "photos-archive", region: "us-east-1"),
        Bucket(name: "site-assets", region: "sa-east-1"),
    ]

    /// The six uploads of the pause, cancel and download mockup: one being sent, one the
    /// user paused, one paused on battery, one canceled yesterday at 18:20, one that is
    /// being downloaded and one that was downloaded to ~/Downloads.
    func loadTransferUploads() async {
        let today = Calendar.current.startOfDay(for: Date())
        func time(daysAgo: Int, _ hour: Int, _ minute: Int) -> Date {
            today.addingTimeInterval(Double(-daysAgo * 86_400 + hour * 3600 + minute * 60))
        }
        let home = Self.home
        let downloads = "\(home)/Downloads"
        await enqueue(3)
        tray.apply(.make("up-1", "db-dump.sql.gz", in: "\(home)/Work/backups", total: 4_200_000_000, sent: 1_238_000_000, .uploading))
        clock.advance(10)
        tray.apply(.make("up-1", "db-dump.sql.gz", in: "\(home)/Work/backups", total: 4_200_000_000, sent: 1_300_000_000, .uploading))
        tray.apply(.paused("up-2", "vacation-2026", in: "\(home)/Pictures", total: 1_900_000_000, sent: 800_000_000))
        tray.apply(
            .paused(
                "up-3", "design-assets", in: "\(home)/Work/client", files: 24, finished: 3, total: 640_000_000,
                sent: 76_000_000, reason: .onHold))
        tray.apply(
            UploadSnapshot(
                id: "up-4", fileName: "raw-footage", localPath: "\(home)/Movies/raw-footage",
                objectKey: "quick-uploads/raw-footage/", bytesTotal: 1_000_000_000, bytesSent: 380_000_000,
                state: .canceled, errorMessage: "", kind: .folder, filesTotal: 12, filesFinished: 5,
                createdAt: time(daysAgo: 1, 18, 2), endedAt: time(daysAgo: 1, 18, 20)))
        tray.apply(
            UploadSnapshot(
                id: "up-5", fileName: "archive-2025", localPath: "\(home)/Documents/archive-2025",
                objectKey: "quick-uploads/archive-2025/", bytesTotal: 480_000_000, bytesSent: 480_000_000,
                state: .finished, errorMessage: "", kind: .folder, filesTotal: 40, filesFinished: 40,
                createdAt: time(daysAgo: 2, 9, 0), endedAt: time(daysAgo: 2, 9, 30)))
        tray.apply(
            UploadSnapshot(
                id: "up-6", fileName: "invoice-october.pdf",
                localPath: "\(home)/Documents/finance/invoice-october.pdf",
                objectKey: "quick-uploads/invoice-october.pdf", bytesTotal: 184_000, bytesSent: 184_000,
                state: .finished, errorMessage: "",
                createdAt: time(daysAgo: 0, 11, 55), endedAt: time(daysAgo: 0, 11, 56)))
        tray.apply(
            DownloadSnapshot.make("dl-5", of: "up-5", to: "\(downloads)/archive-2025", .downloading))
        tray.apply(
            DownloadSnapshot.make(
                "dl-6", of: "up-6", to: "\(downloads)/invoice-october.pdf", total: 184_000, done: 184_000, .finished))
        await warmThumbnails()
    }

    /// Opens the actions menu of `target` as a click on its three dots does, with the
    /// pointer resting on `highlighted`.
    func openMenu(of target: UploadActionTarget, actions: [UploadAction], highlighted: UploadAction? = nil) {
        context.model.openActionsMenu(for: target, actions: actions)
        context.model.actionsMenu?.highlighted = highlighted
    }

    /// Generates the stand-in previews before drawing, as they would be on a second look.
    func warmThumbnails(also extra: [String] = []) async {
        let sides: [CGFloat] = [26, 30, 50]
        let paths = (tray.uploads.ledger.records.flatMap(\.handedPaths) + extra)
            .filter { ["png", "jpg"].contains(($0 as NSString).pathExtension) }
        for _ in 0..<50 {
            var missing = false
            for path in paths {
                for side in sides where thumbnails.image(for: path, side: side, scale: 2) == nil {
                    missing = true
                }
            }
            if !missing { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Opens an upload's detail and waits for its files to arrive, as they do a moment
    /// after the screen opens.
    func openDetail(_ id: String, from origin: MainSection, expecting count: Int) async throws {
        context.model.openDetail(id: id, from: origin)
        let files = context.model.detailFiles
        for _ in 0..<200 where files.uploadID != id || files.count < count {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(files.count, count)
        await warmThumbnails(also: files.indexes(.all).compactMap { files.file(at: $0)?.localPath })
    }

    /// Two uploads that failed for the same reason, which raises that service condition.
    func loadFailures(message: String) async {
        await enqueue(2)
        tray.apply(.make("up-1", "vacation-2026.zip", in: "\(Self.home)/Pictures", total: 1_900_000_000, sent: 800_000_000, .failed, error: message))
        tray.apply(.make("up-2", "db-dump.sql.gz", in: "\(Self.home)/Work/backups", total: 4_200_000_000, sent: 1_300_000_000, .failed, error: message))
    }

    func mainView() -> some View {
        MainView(context: context).environment(thumbnails)
    }

    func trayView() -> some View {
        TrayView(viewModel: tray, menu: TrayMenuModel(), actions: AppActions(), heightChanged: { _ in })
            .background(GlassBackdrop())
            .clipShape(.rect(cornerRadius: 11))
    }

    /// A drawn stand-in for a Quick Look preview, for image files only.
    nonisolated static func picture(for url: URL, side: CGFloat) -> CGImage? {
        guard ["png", "jpg"].contains(url.pathExtension) else { return nil }
        let width = Int(side * 2), height = Int(side * 1.5)
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
            let gradient = CGGradient(
                colorsSpace: nil,
                colors: [CGColor(red: 1, green: 0.78, blue: 0.42, alpha: 1), CGColor(red: 0.29, green: 0.25, blue: 0.56, alpha: 1)] as CFArray,
                locations: nil)
        else { return nil }
        context.drawLinearGradient(
            gradient, start: CGPoint(x: 0, y: height), end: CGPoint(x: width, y: 0), options: [])
        return context.makeImage()
    }
}

/// Renders every screen in both appearances to `build/ui/app`. The images are compared with
/// the approved mockups by eye; the tests themselves fail only if a screen cannot be drawn.
@MainActor
final class UISnapshotTests: XCTestCase {
    private func both(_ name: String, size: CGSize? = nil, _ view: () -> some View) throws {
        for dark in [false, true] {
            let rep = try Offscreen.render(view(), size: size, dark: dark, name: name)
            XCTAssertGreaterThan(rep.pixelsWide, 0, name)
        }
    }

    // MARK: Tray

    func testTrayIdleUploadingAndSetup() async throws {
        let idle = await UIFixture()
        try both("tray-idle") { idle.trayView() }

        let uploading = await UIFixture()
        await uploading.loadMixedUploads()
        try both("tray-uploading") { uploading.trayView() }

        let setup = await UIFixture(configured: false)
        try both("tray-setup") { setup.trayView() }
    }

    func testTrayDragStates() async throws {
        let over = await UIFixture()
        over.tray.setHovering(true, itemCount: 3)
        try both("tray-drag-over") { over.trayView() }

        // The confirmation lasts as long as the injected sleep: hold it while drawing.
        let dropped = await UIFixture(sleep: { _ in try await Task.sleep(for: .seconds(600)) })
        let items = (1...3).map { URL(fileURLWithPath: "/tmp/file-\($0)") }
        let drop = Task { await dropped.tray.drop(items) }
        while dropped.tray.dropFeedback != .confirmed { await Task.yield() }
        try both("tray-just-dropped") { dropped.trayView() }
        drop.cancel()
    }

    func testTrayErrorStatesAndRecentList() async throws {
        let offline = await UIFixture()
        await offline.loadFailures(message: ServiceCondition.offlineMessage)
        try both("tray-offline") { offline.trayView() }

        let rejected = await UIFixture()
        await rejected.loadFailures(message: ServiceCondition.keyRejectedMessage)
        try both("tray-key-rejected") { rejected.trayView() }

        let recent = await UIFixture()
        await recent.loadMixedUploads()
        try both("tray-recent") {
            RecentUploadsView(uploads: recent.tray.uploads, actions: AppActions(), heightChanged: { _ in })
                .background(GlassBackdrop())
                .clipShape(.rect(cornerRadius: 11))
        }
    }

    // MARK: Main window

    func testOverviewAndEmptyOverview() async throws {
        let fixture = await UIFixture()
        await fixture.loadMixedUploads()
        try both("overview", size: MainView.size) { fixture.mainView() }

        let empty = await UIFixture()
        try both("overview-empty", size: MainView.size) { empty.mainView() }
    }

    func testHistoryAndNoResults() async throws {
        let fixture = await UIFixture()
        await fixture.loadMixedUploads()
        fixture.context.model.show(.history)
        try both("history", size: MainView.size) { fixture.mainView() }

        fixture.context.model.historyQuery.text = "tax-report-2019"
        fixture.context.model.historyQuery.state = .finished
        try both("history-no-results", size: MainView.size) { fixture.mainView() }
    }

    func testUploadDetail() async throws {
        let fixture = await UIFixture()
        await fixture.loadMixedUploads()
        fixture.context.model.openDetail(id: "up-3", from: .history)
        try both("upload-detail", size: MainView.size) { fixture.mainView() }
        fixture.context.model.openDetail(id: "up-6", from: .history)
        try both("upload-detail-failed", size: MainView.size) { fixture.mainView() }
    }

    func testFolderAndSeveralItemsDetail() async throws {
        let fixture = await UIFixture()
        await fixture.loadMixedUploads()
        try await fixture.openDetail("up-7", from: .history, expecting: 12)
        try both("upload-detail-folder", size: MainView.size) { fixture.mainView() }

        fixture.context.model.detailFilter = .waiting
        try both("upload-detail-folder-waiting", size: MainView.size) { fixture.mainView() }

        try await fixture.openDetail("up-4", from: .overview, expecting: 8)
        try both("upload-detail-several", size: MainView.size) { fixture.mainView() }
    }

    /// The rows the mockups draw for a folder and for several items, alone and enlarged
    /// enough to compare the thumbnails point by point.
    func testFolderAndSeveralItemsRows() async throws {
        let fixture = await UIFixture()
        await fixture.loadMixedUploads()
        let ledger = fixture.tray.uploads.ledger
        for (name, id) in [("row-folder", "up-7"), ("row-several", "up-4"), ("row-folder-waiting", "up-5")] {
            let record = try XCTUnwrap(ledger[id])
            XCTAssertNotEqual(record.kind, .singleFile)
            try both(name, size: CGSize(width: 754, height: 72)) {
                UploadRow(record: record, line: UploadText.progressLine(record))
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.ink)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.main)
                    .environment(fixture.thumbnails)
            }
        }
    }

    // MARK: Upload actions (design/mockups/remove-upload.html)

    func testHistoryWithTheActionsButtonAndItsOpenMenu() async throws {
        let fixture = await UIFixture()
        await fixture.loadEndedUploads()
        fixture.context.model.show(.history)
        try both("actions-history", size: MainView.size) { fixture.mainView() }

        let folder = try XCTUnwrap(fixture.tray.uploads.ledger["up-2"])
        fixture.openMenu(of: .upload(id: "up-2"), actions: UploadAction.available(for: folder), highlighted: .remove)
        try both("actions-history-menu", size: MainView.size) { fixture.mainView() }

        // Overview draws the same rows; the ones still sending or waiting have no button.
        let mixed = await UIFixture()
        await mixed.loadMixedUploads()
        let failed = try XCTUnwrap(mixed.tray.uploads.ledger["up-6"])
        mixed.openMenu(of: .upload(id: "up-6"), actions: UploadAction.available(for: failed))
        try both("actions-overview-menu", size: MainView.size) { mixed.mainView() }
    }

    func testUploadDetailWithTheActionsButtonAndAFileMenu() async throws {
        let fixture = await UIFixture()
        await fixture.loadEndedUploads()
        try await fixture.openDetail("up-2", from: .history, expecting: 12)
        try both("actions-detail", size: MainView.size) { fixture.mainView() }

        let file = try XCTUnwrap(fixture.context.model.detailFiles.file(at: 1))
        fixture.openMenu(
            of: .file(uploadID: "up-2", index: 1), actions: UploadAction.available(for: file), highlighted: .remove)
        try both("actions-detail-file-menu", size: MainView.size) { fixture.mainView() }

        let folder = try XCTUnwrap(fixture.tray.uploads.ledger["up-2"])
        fixture.openMenu(of: .upload(id: "up-2"), actions: UploadAction.available(for: folder))
        try both("actions-detail-header-menu", size: MainView.size) { fixture.mainView() }

        // A failed single file: Try again lives in the menus, no longer in a link.
        fixture.context.model.openDetail(id: "up-3", from: .history)
        let failed = try XCTUnwrap(fixture.tray.uploads.ledger["up-3"])
        fixture.openMenu(of: .upload(id: "up-3"), actions: UploadAction.available(for: failed))
        try both("actions-detail-failed-menu", size: MainView.size) { fixture.mainView() }
    }

    /// The three menus the mockup lists by kind of upload, alone.
    func testTheMenuByKindOfUpload() throws {
        let kinds: [(String, [UploadAction])] = [
            ("actions-menu-finished", [.remove, .deleteFromBucket]),
            ("actions-menu-failed", [.retry, .remove]),
            ("actions-menu-failed-partly", [.retry, .remove, .deleteFromBucket]),
        ]
        for (name, actions) in kinds {
            try both(name) {
                ActionsMenuView(
                    menu: OpenActionsMenu(target: .upload(id: "a"), actions: actions), hover: { _, _ in },
                    choose: { _ in }
                )
                .padding(30)
                .background(Theme.main)
            }
        }
    }

    /// Every confirmation the mockup draws, plus the two states it describes in words:
    /// the daemon working, and the daemon's refusal shown in the sheet.
    func testRemoveAndDeleteConfirmations() async throws {
        let folder = RemovalPrompt.Subject.upload(name: "vacation-2026/", filesInBucket: 12, filesTotal: 12)
        let file = RemovalPrompt.Subject.file(name: "IMG_4402.jpg", uploadName: "vacation-2026/", inBucket: true)
        let failed = RemovalPrompt.Subject.upload(name: "armadillo.png", filesInBucket: 0, filesTotal: 1)
        let target = UploadActionTarget.upload(id: "up-2")
        func sheet(_ prompt: RemovalPrompt, perform: @escaping RemovalSheetModel.Perform = { _, _, _ in }) -> RemovalSheetModel {
            RemovalSheetModel(prompt: prompt, perform: perform, close: { _ in })
        }
        func draw(_ name: String, _ model: RemovalSheetModel) throws {
            try both(name) { RemovalSheet(model: model).clipShape(.rect(cornerRadius: RemovalSheet.cornerRadius)) }
        }

        try draw("sheet-remove", sheet(RemovalPrompt(target: target, subject: folder, intent: .remove)))
        try draw(
            "sheet-remove-checked",
            sheet(RemovalPrompt(target: target, subject: folder, intent: .remove, alsoDelete: true)))
        try draw("sheet-remove-file", sheet(RemovalPrompt(target: target, subject: file, intent: .remove)))
        try draw("sheet-remove-failed", sheet(RemovalPrompt(target: target, subject: failed, intent: .remove)))
        try draw("sheet-delete", sheet(RemovalPrompt(target: target, subject: folder, intent: .delete)))
        try draw("sheet-delete-file", sheet(RemovalPrompt(target: target, subject: file, intent: .delete)))

        // The daemon is deleting a big folder: the button shows progress, Cancel is off.
        let (gate, release) = AsyncStream<Void>.makeStream()
        let working = sheet(
            RemovalPrompt(target: target, subject: folder, intent: .delete),
            perform: { _, _, _ in for await _ in gate { break } })
        let confirming = Task { await working.confirm() }
        while !working.isWorking { await Task.yield() }
        try draw("sheet-delete-working", working)
        release.yield()
        await confirming.value

        let refused = sheet(
            RemovalPrompt(target: target, subject: folder, intent: .delete),
            perform: { _, _, _ in
                throw DaemonError.rejected("AWS denied permission to delete from the bucket (s3:DeleteObject)")
            })
        await refused.confirm()
        XCTAssertNotNil(refused.errorMessage)
        try draw("sheet-delete-error", refused)
    }

    // MARK: Pause, cancel, download and bucket (design/mockups/transfers.html)

    /// The History list of the mockup with the menu of the sending upload open, and each of
    /// its rows alone.
    func testTransferRowsInEveryNewState() async throws {
        let fixture = await UIFixture()
        await fixture.loadTransferUploads()
        fixture.context.model.show(.history)
        let sending = try XCTUnwrap(fixture.tray.uploads.ledger["up-1"])
        XCTAssertEqual(UploadAction.available(for: sending), [.pause, .cancelUpload])
        fixture.openMenu(of: .upload(id: "up-1"), actions: UploadAction.available(for: sending), highlighted: .pause)
        try both("transfers-history", size: MainView.size) { fixture.mainView() }
        fixture.context.model.actionsMenu = nil

        let rows = [
            ("transfers-row-sending", "up-1"), ("transfers-row-paused", "up-2"),
            ("transfers-row-paused-battery", "up-3"), ("transfers-row-canceled", "up-4"),
            ("transfers-row-downloading", "up-5"), ("transfers-row-downloaded", "up-6"),
        ]
        for (name, id) in rows {
            let record = try XCTUnwrap(fixture.tray.uploads.ledger[id])
            try both(name, size: CGSize(width: 754, height: 84)) {
                UploadRow(
                    record: record, line: UploadText.historyLine(record, now: Date()),
                    menus: fixture.context.model, download: fixture.context.downloads[.upload(id: id)]
                )
                .font(.system(size: 13))
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.main)
                .environment(fixture.thumbnails)
            }
        }

        // A download that failed says so where the finished one says where it went.
        fixture.tray.apply(
            DownloadSnapshot.make("dl-2", of: "up-6", .failed, error: ServiceCondition.offlineMessage))
        let failed = try XCTUnwrap(fixture.tray.uploads.ledger["up-6"])
        try both("transfers-row-download-failed", size: CGSize(width: 754, height: 84)) {
            UploadRow(
                record: failed, line: UploadText.historyLine(failed, now: Date()),
                menus: fixture.context.model, download: fixture.context.downloads[.upload(id: "up-6")]
            )
            .font(.system(size: 13))
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.main)
            .environment(fixture.thumbnails)
        }
    }

    /// The paused detail header with Resume and Cancel upload, the same upload paused on
    /// battery, a canceled one, and one that is being downloaded.
    func testTransferDetailHeaders() async throws {
        let fixture = await UIFixture()
        await fixture.loadTransferUploads()
        for (name, id) in [
            ("transfers-detail-paused", "up-2"), ("transfers-detail-paused-battery", "up-3"),
            ("transfers-detail-canceled", "up-4"), ("transfers-detail-downloading", "up-5"),
            ("transfers-detail-downloaded", "up-6"), ("transfers-detail-sending", "up-1"),
        ] {
            fixture.context.model.openDetail(id: id, from: .history)
            try both(name, size: MainView.size) { fixture.mainView() }
        }
    }

    /// The menu by state, as the mockup lists it: sending or waiting, paused by you, paused
    /// on battery, canceled, finished, being downloaded.
    func testTheMenuByState() throws {
        let states: [(String, [UploadAction])] = [
            ("transfers-menu-sending", [.pause, .cancelUpload]),
            ("transfers-menu-paused", [.resume, .cancelUpload]),
            ("transfers-menu-paused-battery", [.cancelUpload]),
            ("transfers-menu-canceled", [.retry, .download, .remove, .deleteFromBucket]),
            ("transfers-menu-finished", [.download, .remove, .deleteFromBucket]),
            ("transfers-menu-downloading", [.cancelDownload]),
        ]
        for (name, actions) in states {
            try both(name) {
                ActionsMenuView(
                    menu: OpenActionsMenu(target: .upload(id: "a"), actions: actions), hover: { _, _ in },
                    choose: { _ in }
                )
                .padding(30)
                .background(Theme.main)
            }
        }
    }

    /// A paused batch in the tray and on Overview's first card.
    func testPausedBatchInTheTrayAndOnOverview() async throws {
        let fixture = await UIFixture()
        await fixture.enqueue(1)
        fixture.tray.apply(
            .paused("up-1", "vacation-2026", in: "\(UIFixture.home)/Pictures", total: 1_900_000_000, sent: 800_000_000))
        try both("transfers-tray-paused") { fixture.trayView() }
        try both("transfers-overview-paused", size: MainView.size) { fixture.mainView() }
    }

    /// Settings › Destination and the setup's second step with the bucket selector: closed,
    /// open, loading and without permission to list.
    func testBucketSelector() async throws {
        let fixture = await UIFixture()
        fixture.client.setBuckets(UIFixture.threeBuckets)
        let buckets = fixture.context.buckets
        fixture.context.model.show(pane: .destination)
        await buckets.loadIfNeeded()
        buckets.choose(UIFixture.threeBuckets[0])
        for _ in 0..<200 where fixture.context.account.summary.destination.bucket != "carlos-backups" {
            try await Task.sleep(for: .milliseconds(10))
        }
        try both("bucket-selector", size: MainView.size) { fixture.mainView() }

        buckets.toggle()
        buckets.highlighted = .bucket("carlos-backups")
        try both("bucket-selector-open", size: MainView.size) { fixture.mainView() }
        buckets.close()

        fixture.client.failList(
            with: .rejected("AWS denied permission to list buckets: the access key needs the s3:ListAllMyBuckets permission"))
        await buckets.reload()
        try both("bucket-selector-denied", size: MainView.size) { fixture.mainView() }

        let first = await UIFixture(configured: false)
        first.client.setBuckets(UIFixture.threeBuckets)
        let setup = SetupModel(
            store: first.store, buckets: BucketService(client: first.client), onSaved: { _ in },
            onFinished: { _, _ in })
        first.context.model.setup = setup
        setup.accessKeyID = "AKIAIOSFODNN7EXAMPLE"
        setup.secret = "not-a-real-secret-value"
        setup.region = "sa-east-1"
        await setup.advance()
        await setup.buckets.loadIfNeeded()
        setup.buckets.choose(UIFixture.threeBuckets[0])
        try both("bucket-first-run", size: MainView.setupSize) { first.mainView() }
        setup.buckets.toggle()
        try both("bucket-first-run-open", size: MainView.setupSize) { first.mainView() }
    }

    /// The "Create a new bucket" window and its two failure layouts.
    func testCreateBucketWindowAndItsFailures() async throws {
        func window(failing error: DaemonError?) async -> CreateBucketModel {
            let model = CreateBucketModel(
                region: "sa-east-1",
                service: BucketService(
                    list: { _ in [] },
                    create: { _, _ in if let error { throw error } }),
                access: { AWSAccess(accessKeyID: "AKIAIOSFODNN7EXAMPLE", secretAccessKey: "not-a-real-secret", region: "sa-east-1") },
                close: { _ in })
            return model
        }
        func draw(_ name: String, _ model: CreateBucketModel) throws {
            try both(name) {
                CreateBucketSheet(model: model).clipShape(.rect(cornerRadius: RemovalSheet.cornerRadius))
            }
        }

        let plain = await window(failing: nil)
        plain.name = "carlos-backups-2026"
        try draw("bucket-create", plain)

        let taken = await window(
            failing: .alreadyExists(
                "This name is already taken by another AWS account. Bucket names are unique in all of AWS: try another one."))
        taken.name = "backups"
        await taken.confirm()
        XCTAssertNotNil(taken.nameError)
        try draw("bucket-create-name-error", taken)

        let denied = await window(
            failing: .rejected(
                "AWS denied permission to create buckets: the access key needs the s3:CreateBucket permission"))
        denied.name = "carlos-backups-2026"
        await denied.confirm()
        XCTAssertNotNil(denied.boxError)
        try draw("bucket-create-box-error", denied)
    }

    func testSettingsPanes() async throws {
        let fixture = await UIFixture()
        for pane in SettingsPane.allCases {
            fixture.context.model.show(pane: pane)
            try both("settings-\(pane.rawValue)", size: MainView.size) { fixture.mainView() }
        }
    }

    func testFirstLaunchSteps() async throws {
        let fixture = await UIFixture(configured: false)
        let setup = SetupModel(store: fixture.store, onSaved: { _ in }, onFinished: { _, _ in })
        fixture.context.model.setup = setup
        setup.accessKeyID = "AKIAIOSFODNN7EXAMPLE"
        setup.secret = "not-a-real-secret-value"
        try both("first-run-1", size: MainView.setupSize) { fixture.mainView() }
        await setup.advance()
        setup.bucket = "example-backups"
        try both("first-run-2", size: MainView.setupSize) { fixture.mainView() }
        await setup.advance()
        XCTAssertEqual(setup.step, .ready)
        try both("first-run-3", size: MainView.setupSize) { fixture.mainView() }
    }

    func testConnectionLostAndKeyRejectedBanners() async throws {
        let offline = await UIFixture()
        await offline.loadFailures(message: ServiceCondition.offlineMessage)
        try both("banner-offline", size: MainView.size) { offline.mainView() }

        let rejected = await UIFixture()
        await rejected.loadFailures(message: ServiceCondition.keyRejectedMessage)
        try both("banner-key-rejected", size: MainView.size) { rejected.mainView() }
    }

    // MARK: Small windows

    func testSmallWindows() throws {
        try both("about") { AboutView(version: "0.1.0", checkForUpdates: {}) }
        try both("passphrase-create") { CreatePassphraseView(close: {}) }
        try both("passphrase-enter") { EnterPassphraseView(close: {}) }
        try both("update-unavailable") {
            UpdateResultView(result: .unavailable, currentVersion: "0.1.0", close: {})
        }
        try both("update-up-to-date") {
            UpdateResultView(result: .upToDate, currentVersion: "0.1.0", close: {})
        }
        try both("update-available") {
            UpdateResultView(result: .available(version: "0.2.0"), currentVersion: "0.1.0", close: {})
        }
    }
}
