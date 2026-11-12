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
        let client = GRPCDaemonClient(socketPath: Self.socketURL.path)
        let supervisor = DaemonSupervisor(
            executable: Bundle.main.url(forResource: "rabbitholed", withExtension: nil),
            socketURL: Self.socketURL,
            launcher: SystemProcessLauncher(),
            socketProbe: { await UnixSocketProbe.waitUntilAccepting(path: Self.socketURL.path) },
            makeClient: { _ in client })
        let viewModel = TrayViewModel(
            client: client,
            isRegularFile: TrayViewModel.isRegularFileOffMain,
            sleep: { try await Task.sleep(for: $0) })
        let forwarder = DaemonEventForwarder(
            client: client, events: supervisor.events, viewModel: viewModel,
            loadSettings: { try store.load() })
        let settingsWindow = AWSSettingsWindowController(
            store: store, onSaved: { settings in forwarder.settingsChanged(settings) })
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
        Task {
            // A quit that lands before this runs must not leave a daemon behind.
            guard !isShutDown else { return }
            await supervisor.start()
        }
    }

    private func quit() {
        shutDown()
        NSApp.terminate(nil)
    }

    /// Safe to call more than once. The daemon also exits by itself when the app dies, because
    /// its standard input closes.
    private func shutDown() {
        isShutDown = true
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
