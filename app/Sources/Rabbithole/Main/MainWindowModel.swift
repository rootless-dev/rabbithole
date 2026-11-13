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
    /// Sends every failed file of each upload again.
    var retry: ([UploadRecord]) -> Void = { _ in }
    /// Sends failed files of one upload again: the listed indexes, or all when there are none.
    var retryFiles: (_ uploadID: String, _ fileIndexes: [Int]) -> Void = { _, _ in }
    /// Takes an upload (or the listed files of it) out of the history, and out of the bucket
    /// when the last argument says so. Returns when it is done and throws what was refused.
    var removeUpload: RemovalSheetModel.Perform = { _, _, _ in }
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

    /// The actions menu that is open, if any. One at a time.
    var actionsMenu: OpenActionsMenu?
    /// The confirmation shown as a sheet on the window, if any.
    var removal: RemovalSheetModel?

    /// The files of the upload whose detail is open. The daemon's files stream is read only
    /// while a detail is open and the window is showing.
    let detailFiles: UploadFilesModel
    /// Opens the daemon's files stream of one upload; set by the app's composition.
    @ObservationIgnored var watchFiles: (String) -> AsyncThrowingStream<FileSnapshot, Error> = { _ in
        AsyncThrowingStream { $0.finish() }
    }
    @ObservationIgnored private var filesTask: Task<Void, Never>?
    @ObservationIgnored private var windowIsShowing = true
    /// The pause before asking again for the files of an upload whose stream broke.
    @ObservationIgnored private let refollowDelay: Duration

    init(detailFiles: UploadFilesModel = UploadFilesModel(), refollowDelay: Duration = .seconds(1)) {
        self.detailFiles = detailFiles
        self.refollowDelay = refollowDelay
    }

    func show(_ section: MainSection) {
        self.section = section
        detail = nil
        actionsMenu = nil
        followDetailFiles()
    }

    func show(pane: SettingsPane) {
        section = .settings
        settingsPane = pane
        detail = nil
        actionsMenu = nil
        followDetailFiles()
    }

    func openDetail(id: String, from origin: MainSection? = nil) {
        let origin = origin ?? (section == .settings ? .history : section)
        section = origin
        detailFilter = .all
        detail = (id, origin)
        actionsMenu = nil
        followDetailFiles()
    }

    func closeDetail() {
        detail = nil
        actionsMenu = nil
        followDetailFiles()
    }

    /// The window was shown or closed. A closed window stops reading the files stream; the
    /// detail stays where it was and catches up when the window comes back.
    func windowShowing(_ showing: Bool) {
        guard showing != windowIsShowing else { return }
        windowIsShowing = showing
        if !showing { actionsMenu = nil }
        followDetailFiles()
    }

    // MARK: Upload actions

    /// The three-dot button was clicked: opens its menu, or closes it when it is the one open.
    func toggleActionsMenu(for target: UploadActionTarget, actions: [UploadAction]) {
        if actionsMenu?.target == target, actionsMenu?.point == nil {
            actionsMenu = nil
        } else {
            openActionsMenu(for: target, actions: actions)
        }
    }

    /// Opens the menu of `target` under its button, or at `point` after a right click.
    /// A target with no actions has no menu.
    func openActionsMenu(for target: UploadActionTarget, actions: [UploadAction], at point: CGPoint? = nil) {
        actionsMenu = actions.isEmpty ? nil : OpenActionsMenu(target: target, actions: actions, point: point)
    }

    /// Shows a confirmation sheet. `perform` asks the daemon; once it has done the work the
    /// sheet closes, and a removed file leaves the list without waiting to be told.
    func confirm(_ prompt: RemovalPrompt, perform: @escaping RemovalSheetModel.Perform) {
        actionsMenu = nil
        let target = prompt.target
        removal = RemovalSheetModel(prompt: prompt, perform: perform) { [weak self] removed in
            guard let self else { return }
            if removed, case .file(let uploadID, let index) = target {
                detailFiles.remove(indexes: [index], of: uploadID)
            }
            if removal?.prompt.target == target { removal = nil }
        }
    }

    /// An upload left the history: nothing on screen may keep pointing at it. An open detail
    /// of it goes back to the list it was opened from.
    func uploadRemoved(_ id: String) {
        if actionsMenu?.target.uploadID == id { actionsMenu = nil }
        if let removal, removal.prompt.target.uploadID == id, !removal.isWorking { self.removal = nil }
        if detail?.id == id { closeDetail() }
    }

    /// Starts, moves or ends the files subscription to match what is on screen.
    private func followDetailFiles() {
        let wanted = windowIsShowing ? detail?.id : nil
        if wanted != nil, wanted == detailFiles.uploadID, filesTask != nil { return }
        filesTask?.cancel()
        filesTask = nil
        guard let wanted else {
            // A closed window keeps the list it had; leaving the detail drops it.
            if detail == nil { detailFiles.clear() }
            return
        }
        let stream = watchFiles(wanted)
        filesTask = Task { [weak self, detailFiles, refollowDelay] in
            var stream = stream
            // A stream that broke (the daemon restarted) is asked for again while the detail
            // stays open: the history outlives the daemon, so the files come back.
            while await detailFiles.follow(uploadID: wanted, stream: stream) == .interrupted {
                try? await Task.sleep(for: refollowDelay)
                guard !Task.isCancelled, let self else { return }
                stream = self.watchFiles(wanted)
            }
        }
    }
}
