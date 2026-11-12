import AppKit

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

/// Composes the app: settings, daemon supervisor, view model, tray window and the forwarder
/// that connects them.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var supervisor: DaemonSupervisor?
    private var forwarder: DaemonEventForwarder?
    private var tray: TrayWindowController?
    private var settingsWindow: AWSSettingsWindowController?
    private var viewModel: TrayViewModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The unit tests are hosted inside this app: do not start a daemon or a menu bar icon.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }
        let store = SettingsStore(credentials: KeychainCredentialStore(), defaults: .standard)
        Task { await compose(store: store) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        shutDown()
    }

    private func compose(store: SettingsStore) async {
        // The keychain read may block, so it runs off the main actor.
        let saved = await Task.detached { try? store.load() }.value

        let client = GRPCDaemonClient(socketPath: Self.socketURL.path)
        let supervisor = DaemonSupervisor(
            executable: Bundle.main.url(forResource: "rabbitholed", withExtension: nil),
            socketURL: Self.socketURL,
            launcher: SystemProcessLauncher(),
            socketProbe: { await UnixSocketProbe.waitUntilAccepting(path: Self.socketURL.path) },
            makeClient: { _ in client })
        let viewModel = TrayViewModel(
            client: client, settings: saved,
            isRegularFile: TrayViewModel.isRegularFileOnDisk,
            sleep: { try await Task.sleep(for: $0) })
        let settingsWindow = AWSSettingsWindowController(
            store: store,
            onSaved: { settings in Task { await viewModel.settingsSaved(settings) } })
        let forwarder = DaemonEventForwarder(
            client: client, events: supervisor.events, viewModel: viewModel,
            loadSettings: { try? store.load() })
        let tray = TrayWindowController(
            viewModel: viewModel,
            openSettings: { settingsWindow.show() },
            chooseFile: {
                Task {
                    if let url = await FilePicker.chooseFile() { await viewModel.drop([url]) }
                }
            },
            quit: { [weak self] in self?.quit() })

        self.supervisor = supervisor
        self.forwarder = forwarder
        self.tray = tray
        self.settingsWindow = settingsWindow
        self.viewModel = viewModel

        forwarder.start()
        await supervisor.start()
    }

    private func quit() {
        shutDown()
        NSApp.terminate(nil)
    }

    /// Safe to call more than once. The daemon also exits by itself when the app dies, because
    /// its standard input closes.
    private func shutDown() {
        forwarder?.stop()
        supervisor?.stop()
        tray?.tearDown()
    }

    private static var socketURL: URL {
        URL.applicationSupportDirectory
            .appending(path: "Rabbithole", directoryHint: .isDirectory)
            .appending(path: "daemon.sock", directoryHint: .notDirectory)
    }
}
