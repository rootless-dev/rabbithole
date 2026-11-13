import AppKit
import Observation

@main
enum RabbitholeMain {
    // The delegate must outlive `run()`; `NSApplication.delegate` is a weak reference.
    @MainActor private static let delegate = AppDelegate()

    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.delegate = delegate
        app.run()
    }
}

/// Composes the app: settings, daemon supervisor, view models, the tray window, the main
/// window, the small windows and the forwarder that connects the daemon to them.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var supervisor: DaemonSupervisor?
    private var forwarder: DaemonEventForwarder?
    private var tray: TrayWindowController?
    private var mainWindow: MainWindowController?
    private var viewModel: TrayViewModel?
    private var preferences: AppPreferences?
    private var loginItem: LoginItemModel?
    private var hotKey: GlobalHotKey?
    private var optionsSync: UploadOptionsSync?
    private let smallWindows = SmallWindowPresenter()
    /// Set once the app is quitting; composition that is still in progress must not start a daemon.
    private var isShutDown = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The unit tests are hosted inside this app: do not start a daemon or a menu bar icon.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }
        let store = SettingsStore(credentials: KeychainCredentialStore(), defaults: .standard)
        compose(store: store)
    }

    func applicationWillTerminate(_ notification: Notification) {
        shutDown()
    }

    /// Nothing here blocks: the keychain is read by the forwarder, off the main actor.
    private func compose(store: SettingsStore) {
        let preferences = AppPreferences(defaults: .standard)
        NSApp.appearance = preferences.theme.appearance
        NSApp.mainMenu = MainMenu.make()

        let client = GRPCDaemonClient(socketPath: Self.socketURL.path)
        let supervisor = DaemonSupervisor(
            executable: Bundle.main.url(forResource: "rabbitholed", withExtension: nil),
            socketURL: Self.socketURL,
            launcher: SystemProcessLauncher(),
            socketProbe: { await UnixSocketProbe.waitUntilAccepting(path: Self.socketURL.path) },
            makeClient: { _ in client })
        let viewModel = TrayViewModel(
            client: client,
            sleep: { try await Task.sleep(for: $0) },
            makeRequest: { preferences.enqueueRequest(for: $0) })
        // The upload options follow the preferences and the power source. The forwarder
        // sends them, in turn with the daemon's configuration; the sync says when to.
        let power = SystemPowerSource()
        let forwarder = DaemonEventForwarder(
            client: client, events: supervisor.events, viewModel: viewModel,
            loadSettings: { try store.load() },
            resumeInterrupted: { await preferences.resumeAutomatically },
            options: { await preferences.daemonOptions(onBattery: power.isOnBattery) })
        let optionsSync = UploadOptionsSync(
            preferences: preferences, power: power, changed: { forwarder.optionsChanged() })
        optionsSync.start()

        let notifier = UploadNotifier()
        viewModel.uploads.onEnded = { record in
            if preferences.notifyWhenUploadsEnd { notifier.notify(record) }
        }

        let actions = makeActions()
        let account = AccountModel(store: store, onSaved: { forwarder.settingsChanged($0) })
        let loginItem = LoginItemModel(service: SystemLoginItemService())
        let windowModel = MainWindowModel()
        windowModel.watchFiles = { client.watchFiles(uploadID: $0) }
        viewModel.uploads.onRemoved = { [weak windowModel] id in windowModel?.uploadRemoved(id) }
        let bucketService = BucketService(client: client)
        let buckets = BucketListModel(
            service: bucketService,
            access: { await AWSSettingsForm.access(store: store) },
            selection: { (account.bucket, account.region) },
            pick: { bucket in Task { await account.choose(bucket) } })
        let context = MainContext(
            model: windowModel, tray: viewModel, account: account, preferences: preferences,
            loginItem: loginItem, buckets: buckets, actions: actions)
        let mainWindow = MainWindowController(
            context: context, thumbnails: ThumbnailCache(),
            makeSetup: { [weak self] in
                SetupModel(
                    store: store,
                    buckets: bucketService,
                    onSaved: { settings in
                        forwarder.settingsChanged(settings)
                        Task { await account.reload() }
                    },
                    onFinished: { openAtLogin, notify in
                        preferences.notifyWhenUploadsEnd = notify
                        Task { await loginItem.set(openAtLogin) }
                        self?.mainWindow?.finishSetup()
                    })
            })
        let tray = TrayWindowController(viewModel: viewModel, actions: actions)
        let hotKey = GlobalHotKey(action: { [weak tray] in tray?.toggle() })
        hotKey.register(preferences.trayShortcut)

        self.supervisor = supervisor
        self.forwarder = forwarder
        self.tray = tray
        self.mainWindow = mainWindow
        self.viewModel = viewModel
        self.preferences = preferences
        self.loginItem = loginItem
        self.hotKey = hotKey
        self.optionsSync = optionsSync

        forwarder.start()
        openSetupOnFirstLaunch(viewModel)
        Task {
            // A quit that lands before this runs must not leave a daemon behind.
            guard !isShutDown else { return }
            await supervisor.start()
        }
    }

    /// The first state after "starting" tells whether an account is saved. With none, the
    /// main window opens by itself on the setup, as a first launch should.
    private func openSetupOnFirstLaunch(_ viewModel: TrayViewModel) {
        withObservationTracking {
            _ = viewModel.state
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, !self.isShutDown else { return }
                switch viewModel.state {
                case .starting: self.openSetupOnFirstLaunch(viewModel)
                case .notConfigured: self.mainWindow?.startSetup()
                default: break
                }
            }
        }
    }

    private func makeActions() -> AppActions {
        var actions = AppActions()
        actions.chooseFile = { [weak self] in
            Task {
                let urls = await FilePicker.chooseItems()
                guard !urls.isEmpty else { return }
                await self?.viewModel?.drop(urls)
            }
        }
        actions.uploadFromClipboard = { [weak self] in
            let urls = FilePicker.clipboardFiles()
            Task { await self?.viewModel?.uploadFromClipboard(urls) }
        }
        actions.openMainWindow = { [weak self] section in self?.mainWindow?.show(section: section) }
        actions.openSettingsPane = { [weak self] pane in self?.mainWindow?.show(pane: pane) }
        actions.openUpload = { [weak self] id in self?.mainWindow?.showUpload(id: id) }
        actions.startSetup = { [weak self] in self?.mainWindow?.startSetup() }
        actions.showAbout = { [weak self] in self?.showAbout() }
        actions.checkForUpdates = { [weak self] in self?.showUpdateCheck() }
        actions.showCreatePassphrase = { [weak self] in
            self?.smallWindows.show(.createPassphrase, title: "Encryption passphrase") { close in
                CreatePassphraseView(close: close)
            }
        }
        actions.retry = { [weak self] records in
            Task { await self?.viewModel?.retry(records) }
        }
        actions.retryFiles = { [weak self] uploadID, fileIndexes in
            Task { await self?.viewModel?.retry(uploadID: uploadID, fileIndexes: fileIndexes) }
        }
        actions.removeUpload = { [weak self] uploadID, fileIndexes, deleteFromBucket in
            guard let viewModel = self?.viewModel else { throw DaemonError.unavailable }
            try await viewModel.remove(
                uploadID: uploadID, fileIndexes: fileIndexes, deleteFromBucket: deleteFromBucket)
        }
        actions.pauseUpload = { [weak self] id in Task { await self?.viewModel?.pause(uploadID: id) } }
        actions.resumeUpload = { [weak self] id in Task { await self?.viewModel?.resume(uploadID: id) } }
        actions.cancelUpload = { [weak self] id in Task { await self?.viewModel?.cancel(uploadID: id) } }
        actions.download = { [weak self] target in
            Task {
                guard let folder = await FilePicker.chooseDownloadFolder() else { return }
                await self?.viewModel?.download(target, to: folder.path)
            }
        }
        actions.cancelDownload = { [weak self] target in
            Task { await self?.viewModel?.cancelDownload(target) }
        }
        actions.showInFinder = { path in
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
        actions.applyTheme = { theme in NSApp.appearance = theme.appearance }
        actions.registerShortcut = { [weak self] shortcut in self?.hotKey?.register(shortcut) ?? false }
        actions.quit = { NSApp.terminate(nil) }
        return actions
    }

    private func showAbout() {
        smallWindows.show(.about, title: "About Rabbithole") { [weak self] _ in
            AboutView(version: Self.version, checkForUpdates: { self?.showUpdateCheck() })
        }
    }

    /// The app has no update check yet, so the window says exactly that.
    private func showUpdateCheck() {
        smallWindows.show(.updates, title: "Check for updates") { close in
            UpdateResultView(result: .unavailable, currentVersion: Self.version, close: close)
        }
    }

    /// Safe to call more than once. The daemon also exits by itself when the app dies, because
    /// its standard input closes.
    private func shutDown() {
        isShutDown = true
        forwarder?.stop()
        supervisor?.stop()
        hotKey?.unregister()
        smallWindows.closeAll()
        mainWindow?.close()
        tray?.tearDown()
    }

    private static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }

    private static var socketURL: URL {
        URL.applicationSupportDirectory
            .appending(path: "Rabbithole", directoryHint: .isDirectory)
            .appending(path: "daemon.sock", directoryHint: .notDirectory)
    }
}

/// The app has no menu bar of its own (it lives in the system menu bar as an icon), but
/// text fields get Copy, Paste and the rest from the main menu's key equivalents, and
/// windows get Close. This menu is never visible; it exists for those shortcuts.
@MainActor
enum MainMenu {
    static func make() -> NSMenu {
        let main = NSMenu()

        let app = NSMenu()
        app.addItem(withTitle: "Quit Rabbithole", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        add(app, to: main, title: "Rabbithole")

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        add(edit, to: main, title: "Edit")

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        add(window, to: main, title: "Window")

        return main
    }

    private static func add(_ submenu: NSMenu, to main: NSMenu, title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        main.addItem(item)
    }
}
