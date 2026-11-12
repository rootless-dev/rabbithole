import AppKit
import SwiftUI

/// Borderless panel that can become key, so keyboard shortcuts and buttons work, without
/// activating the app or stealing focus from the frontmost one.
final class TrayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Owns the menu bar icon and the window it toggles. The window closes only when the icon is
/// clicked again or the app quits; clicks elsewhere leave it open.
@MainActor
final class TrayWindowController: NSObject {
    private let statusItem: NSStatusItem
    private let panel: TrayPanel
    private var contentHeight: CGFloat = 150

    init(
        viewModel: TrayViewModel,
        openSettings: @escaping () -> Void,
        chooseFile: @escaping () -> Void,
        quit: @escaping () -> Void
    ) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        panel = TrayPanel(
            contentRect: CGRect(
                x: 0, y: 0, width: TrayPanelPositioner.width, height: 150),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        super.init()

        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]

        let hosting = NSHostingView(
            rootView: TrayView(
                viewModel: viewModel, openSettings: openSettings, chooseFile: chooseFile,
                quit: quit,
                heightChanged: { [weak self] in self?.contentHeightChanged($0) }))
        hosting.sizingOptions = []
        // NSGlassEffectView is the system glass material, available from macOS 26.
        let glass = NSGlassEffectView()
        glass.cornerRadius = 11
        glass.contentView = hosting
        panel.contentView = glass

        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "arrow.up.circle", accessibilityDescription: "Rabbithole")
            button.target = self
            button.action = #selector(toggle)
        }
    }

    @objc private func toggle() {
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            reposition()
            panel.orderFrontRegardless()
            panel.makeKey()
        }
    }

    /// Releases the status item and hides the window.
    func tearDown() {
        panel.orderOut(nil)
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    private func contentHeightChanged(_ height: CGFloat) {
        guard height > 0, height != contentHeight else { return }
        contentHeight = height
        if panel.isVisible { reposition() }
    }

    private func reposition() {
        guard let iconFrame = statusItem.button?.window?.frame else { return }
        panel.setFrame(
            TrayPanelPositioner.frame(statusItemFrame: iconFrame, contentHeight: contentHeight),
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
}
