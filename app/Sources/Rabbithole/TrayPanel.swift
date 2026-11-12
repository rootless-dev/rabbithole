import AppKit
import SwiftUI

/// Borderless panel that can become key, so keyboard shortcuts and buttons work, without
/// activating the app or stealing focus from the frontmost one.
final class TrayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// A glass panel of the tray: floating, borderless, with the content on system glass.
    @MainActor
    static func make(width: CGFloat, content: NSView) -> TrayPanel {
        let panel = TrayPanel(
            contentRect: CGRect(x: 0, y: 0, width: width, height: 150),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        // NSGlassEffectView is the system glass material, available from macOS 26.
        let glass = NSGlassEffectView()
        glass.cornerRadius = 11
        glass.contentView = content
        panel.contentView = glass
        return panel
    }
}

/// Owns the menu bar icon, the window it toggles and the "Recent uploads" list beside it. The
/// window closes when the icon is clicked again, when a menu item opens another window, or
/// when the app quits; clicks elsewhere leave it open.
@MainActor
final class TrayWindowController: NSObject {
    private let statusItem: NSStatusItem
    private let menu = TrayMenuModel()
    private var panel: TrayPanel!
    private var recentPanel: TrayPanel!
    private var contentHeight: CGFloat = 150
    private var recentHeight: CGFloat = 150

    init(viewModel: TrayViewModel, actions: AppActions) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        let actions = closingTray(actions)
        let hosting = NSHostingView(
            rootView: TrayView(
                viewModel: viewModel, menu: menu, actions: actions,
                heightChanged: { [weak self] in self?.contentHeightChanged($0) }))
        hosting.sizingOptions = []
        panel = TrayPanel.make(width: TrayPanelPositioner.width, content: hosting)

        let recentHosting = NSHostingView(
            rootView: RecentUploadsView(
                uploads: viewModel.uploads, actions: actions,
                heightChanged: { [weak self] in self?.recentHeightChanged($0) }))
        recentHosting.sizingOptions = []
        recentPanel = TrayPanel.make(width: RecentUploadsView.width, content: recentHosting)

        menu.onRecentChange = { [weak self] open in self?.showRecent(open) }

        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "arrow.up.circle", accessibilityDescription: "Rabbithole")
            button.target = self
            button.action = #selector(toggleFromIcon)
        }
    }

    @objc private func toggleFromIcon() {
        toggle()
    }

    /// Shows the window under the icon, or hides it when it is showing.
    func toggle() {
        if panel.isVisible {
            hide()
        } else {
            reposition()
            panel.orderFrontRegardless()
            panel.makeKey()
        }
    }

    func hide() {
        menu.setRecentOpen(false)
        recentPanel.orderOut(nil)
        panel.orderOut(nil)
    }

    /// Releases the status item and hides the windows.
    func tearDown() {
        hide()
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    /// Menu items that open another window close the tray first, as a menu would.
    private func closingTray(_ actions: AppActions) -> AppActions {
        var wrapped = actions
        wrapped.openMainWindow = { [weak self] section in
            self?.hide()
            actions.openMainWindow(section)
        }
        wrapped.openSettingsPane = { [weak self] pane in
            self?.hide()
            actions.openSettingsPane(pane)
        }
        wrapped.openUpload = { [weak self] id in
            self?.hide()
            actions.openUpload(id)
        }
        wrapped.startSetup = { [weak self] in
            self?.hide()
            actions.startSetup()
        }
        wrapped.showAbout = { [weak self] in
            self?.hide()
            actions.showAbout()
        }
        wrapped.checkForUpdates = { [weak self] in
            self?.hide()
            actions.checkForUpdates()
        }
        return wrapped
    }

    private func contentHeightChanged(_ height: CGFloat) {
        guard height > 0, height != contentHeight else { return }
        contentHeight = height
        if panel.isVisible { reposition() }
    }

    private func recentHeightChanged(_ height: CGFloat) {
        guard height > 0, height != recentHeight else { return }
        recentHeight = height
        if recentPanel.isVisible { repositionRecent() }
    }

    private func showRecent(_ open: Bool) {
        if open, panel.isVisible {
            repositionRecent()
            recentPanel.orderFrontRegardless()
        } else {
            recentPanel.orderOut(nil)
        }
    }

    private func reposition() {
        guard let iconFrame = statusItem.button?.window?.frame else { return }
        panel.setFrame(
            TrayPanelPositioner.frame(statusItemFrame: iconFrame, contentHeight: contentHeight),
            display: true)
        if recentPanel.isVisible { repositionRecent() }
    }

    private func repositionRecent() {
        recentPanel.setFrame(
            TrayPanelPositioner.recentFrame(
                trayFrame: panel.frame, rowTop: menu.recentRowTop,
                width: RecentUploadsView.width, contentHeight: recentHeight),
            display: true)
    }
}

enum FilePicker {
    /// Lets the user pick one regular file. Packages are selectable here and refused later by
    /// the view model's file check.
    @MainActor
    static func chooseFile() async -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a file to upload"
        NSApp.activate()
        let response = await panel.begin()
        return response == .OK ? panel.url : nil
    }

    /// The files currently copied in Finder, if any. Other clipboard contents give nothing.
    @MainActor
    static func clipboardFiles() -> [URL] {
        let objects = NSPasteboard.general.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        return (objects as? [URL]) ?? []
    }
}
