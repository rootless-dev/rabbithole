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
        tray = TrayViewModel(
            client: client, isRegularFile: { _ in true }, sleep: sleep,
            uploads: UploadStore(now: { clock.now }))
        tray.configured(with: configured ? settings : nil)
        let account = AccountModel(store: store, onSaved: { _ in })
        context = MainContext(
            model: MainWindowModel(), tray: tray, account: account,
            preferences: AppPreferences(defaults: scratch.defaults),
            loginItem: LoginItemModel(service: StubLoginItemService(enabled: true)),
            actions: AppActions())
        await account.reload()
        await context.loginItem.refresh()
    }

    /// Enqueues `names` through the view model, as drops would, and returns their ids.
    func enqueue(_ count: Int) async {
        for index in 1...count {
            await tray.drop([URL(fileURLWithPath: "/tmp/file-\(index)")])
        }
    }

    /// Six uploads in every state, like the list in the dashboard mockup.
    func loadMixedUploads() async {
        await enqueue(6)
        let documents = "\(Self.home)/Documents"
        clock.advance(-3600 * 26)
        tray.apply(.make("up-6", "armadillo.png", in: "\(Self.home)/Downloads", total: 900_000, sent: 300_000, .failed, error: "No internet connection"))
        clock.advance(3600 * 26 - 900)
        tray.apply(.make("up-2", "contract-signed.pdf", in: "\(documents)/legal", total: 2_100_000, sent: 2_100_000, .finished))
        clock.advance(600)
        tray.apply(.make("up-1", "invoice-october.pdf", in: "\(documents)/finance", total: 184_000, sent: 184_000, .finished))
        clock.advance(170)
        tray.apply(.make("up-3", "db-dump.sql.gz", in: "\(Self.home)/Work/backups", total: 4_200_000_000, sent: 1_240_000_000, .uploading))
        tray.apply(.make("up-4", "report-q3.pdf", in: "\(Self.home)/Downloads", total: 480_000_000, sent: 280_000_000, .uploading))
        clock.advance(10)
        tray.apply(.make("up-3", "db-dump.sql.gz", in: "\(Self.home)/Work/backups", total: 4_200_000_000, sent: 1_300_000_000, .uploading))
        tray.apply(.make("up-4", "report-q3.pdf", in: "\(Self.home)/Downloads", total: 480_000_000, sent: 310_000_000, .uploading))
        tray.apply(.make("up-5", "design-assets.zip", in: "\(Self.home)/Work/client", total: 640_000_000, .queued))
        clock.advance(120)
        await warmThumbnails()
    }

    /// Generates the stand-in previews before drawing, as they would be on a second look.
    private func warmThumbnails() async {
        let sides: [CGFloat] = [26, 30, 50]
        for _ in 0..<50 {
            var missing = false
            for record in tray.uploads.ledger.records where ["png", "jpg"].contains((record.fileName as NSString).pathExtension) {
                for side in sides where thumbnails.image(for: record.localPath, side: side, scale: 2) == nil {
                    missing = true
                }
            }
            if !missing { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
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
        over.tray.setHovering(true, itemCount: 1)
        try both("tray-drag-over") { over.trayView() }

        // The confirmation lasts as long as the injected sleep: hold it while drawing.
        let dropped = await UIFixture(sleep: { _ in try await Task.sleep(for: .seconds(600)) })
        let drop = Task { await dropped.tray.drop([URL(fileURLWithPath: "/tmp/file-1")]) }
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
