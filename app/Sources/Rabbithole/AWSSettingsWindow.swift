import AppKit
import SwiftUI

/// Owns the AWS settings window. The app has no Dock icon, so showing the window
/// activates the app and makes the window key explicitly.
@MainActor
final class AWSSettingsWindowController {
    private let store: SettingsStore
    private let onSaved: (AWSSettings) -> Void
    private var window: NSWindow?

    init(store: SettingsStore, onSaved: @escaping (AWSSettings) -> Void) {
        self.store = store
        self.onSaved = onSaved
    }

    func show() {
        // Rebuild each time so the form reflects what is currently stored.
        window?.close()
        let view = AWSSettingsView(
            store: store,
            onSaved: { [weak self] settings in
                self?.close()
                self?.onSaved(settings)
            },
            onCancel: { [weak self] in self?.close() })
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "AWS settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
        window = nil
    }
}
