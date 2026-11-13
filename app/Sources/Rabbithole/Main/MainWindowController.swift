import AppKit
import SwiftUI

/// Owns the main window. The app lives in the menu bar and shows its Dock icon only while
/// this window is open (minimized counts as open, since the Dock is where it sits then).
/// The window is created on first use and kept.
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    private let context: MainContext
    private let thumbnails: ThumbnailCache
    private let makeSetup: () -> SetupModel
    private let setDockIconVisible: (Bool) -> Void
    private var window: NSWindow?

    /// `setDockIconVisible` is replaced in tests; by default it switches the app between a
    /// regular app (Dock icon, menu bar) and a menu bar accessory.
    init(
        context: MainContext, thumbnails: ThumbnailCache, makeSetup: @escaping () -> SetupModel,
        setDockIconVisible: @escaping (Bool) -> Void = { visible in
            NSApp.setActivationPolicy(visible ? .regular : .accessory)
        }
    ) {
        self.context = context
        self.thumbnails = thumbnails
        self.makeSetup = makeSetup
        self.setDockIconVisible = setDockIconVisible
    }

    /// Brings the window forward on `section`, or on the first-launch setup while no AWS
    /// account is connected.
    func show(section: MainSection? = nil) {
        if context.tray.state == .notConfigured {
            startSetup()
            return
        }
        if let section { context.model.show(section) }
        present()
    }

    func show(pane: SettingsPane) {
        if context.tray.state == .notConfigured {
            startSetup()
            return
        }
        context.model.show(pane: pane)
        present()
    }

    func showUpload(id: String) {
        context.model.openDetail(id: id, from: .history)
        present()
    }

    func startSetup() {
        if context.model.setup == nil { context.model.setup = makeSetup() }
        present()
    }

    /// The setup's last step was confirmed: the regular window takes its place.
    func finishSetup() {
        context.model.setup = nil
        context.model.show(.overview)
        resize(to: MainView.size)
    }

    func close() {
        window?.close()
    }

    private func present() {
        let size = context.model.setup == nil ? MainView.size : MainView.setupSize
        if let window {
            if context.model.setup != nil || window.frame.height < MainView.size.height {
                resize(to: size)
            }
        } else {
            window = makeWindow(size: size)
        }
        context.model.windowShowing(true)
        // Before activating, so the app comes forward already as a regular app.
        setDockIconVisible(true)
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    private func makeWindow(size: CGSize) -> NSWindow {
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "Rabbithole"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // The sidebar is glass: the window itself must let the desktop through.
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isReleasedWhenClosed = false
        window.contentMinSize = CGSize(width: 820, height: 480)
        window.delegate = self
        let hosting = NSHostingView(rootView: MainView(context: context).environment(thumbnails))
        hosting.sizingOptions = []
        window.contentView = hosting
        window.setContentSize(size)
        window.center()
        return window
    }

    private func resize(to size: CGSize) {
        guard let window else { return }
        var frame = window.frameRect(forContentRect: CGRect(origin: .zero, size: size))
        // Keep the top left corner where it is.
        frame.origin = CGPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        window.setFrame(frame, display: true, animate: window.isVisible)
    }

    func windowWillClose(_ notification: Notification) {
        // A setup that is closed drops what was typed, including the secret. If it had
        // already saved the account, the regular window is what opens next.
        context.model.setup = nil
        // Nobody is looking at an upload's files any more: stop asking the daemon for them.
        context.model.windowShowing(false)
        setDockIconVisible(false)
    }
}
