import Foundation
import Observation

enum MainSection: String, CaseIterable, Sendable {
    case overview, history, settings

    var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
}

enum SettingsPane: String, CaseIterable, Sendable {
    case app, uploads, destination, aws, security

    var title: String {
        switch self {
        case .app: "App"
        case .uploads: "Uploads"
        case .destination: "Destination"
        case .aws: "AWS account"
        case .security: "Security"
        }
    }
}

/// What the app can do from any screen. Views call these and never reach for the system or
/// the daemon themselves.
@MainActor
struct AppActions {
    var chooseFile: () -> Void = {}
    var uploadFromClipboard: () -> Void = {}
    var openMainWindow: (MainSection?) -> Void = { _ in }
    var openSettingsPane: (SettingsPane) -> Void = { _ in }
    var openUpload: (String) -> Void = { _ in }
    var startSetup: () -> Void = {}
    var showAbout: () -> Void = {}
    var checkForUpdates: () -> Void = {}
    var showCreatePassphrase: () -> Void = {}
    var retry: ([UploadRecord]) -> Void = { _ in }
    /// Applies the light, dark or system appearance to the whole app.
    var applyTheme: (ThemeChoice) -> Void = { _ in }
    /// Registers the tray's global shortcut. Returns false when the system refused it.
    var registerShortcut: (Shortcut) -> Bool = { _ in true }
    var quit: () -> Void = {}
}

/// Navigation state of the main window: which section, which upload's detail, and the
/// filters of each list.
@MainActor
@Observable
final class MainWindowModel {
    var section: MainSection = .overview
    var settingsPane: SettingsPane = .app
    /// The upload whose detail is open, and the section it was opened from.
    private(set) var detail: (id: String, origin: MainSection)?
    /// The first-launch setup while it is on screen; nil shows the regular window.
    var setup: SetupModel?

    var overviewQuery = UploadQuery(waitingCountsAsInProgress: true)
    var historyQuery = UploadQuery()
    var detailFilter: UploadStateFilter = .all

    func show(_ section: MainSection) {
        self.section = section
        detail = nil
    }

    func show(pane: SettingsPane) {
        section = .settings
        settingsPane = pane
        detail = nil
    }

    func openDetail(id: String, from origin: MainSection? = nil) {
        let origin = origin ?? (section == .settings ? .history : section)
        section = origin
        detailFilter = .all
        detail = (id, origin)
    }

    func closeDetail() {
        detail = nil
    }
}
