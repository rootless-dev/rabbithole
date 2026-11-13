import AppKit
import Carbon.HIToolbox
import Observation
import ServiceManagement
@preconcurrency import UserNotifications

// MARK: - Open at login

/// Registers the app as a login item. Behind a protocol so tests never touch the system.
protocol LoginItemService: Sendable {
    func isEnabled() -> Bool
    func setEnabled(_ enabled: Bool) throws
}

struct SystemLoginItemService: LoginItemService {
    func isEnabled() -> Bool {
        SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

/// The "Open at login" switch. The system is asked off the main actor, and the switch
/// always ends up showing what the system really holds.
@MainActor
@Observable
final class LoginItemModel {
    private(set) var isOn = false
    /// Set when the system refused the change.
    private(set) var message: String?
    @ObservationIgnored private let service: LoginItemService

    init(service: LoginItemService) {
        self.service = service
    }

    func refresh() async {
        let service = service
        isOn = await Task.detached { service.isEnabled() }.value
    }

    func set(_ enabled: Bool) async {
        let service = service
        message = nil
        let result = await Task.detached { () -> (isOn: Bool, failed: Bool) in
            do {
                try service.setEnabled(enabled)
                return (service.isEnabled(), false)
            } catch {
                return (service.isEnabled(), true)
            }
        }.value
        isOn = result.isOn
        if result.failed || result.isOn != enabled {
            message = enabled
                ? "macOS did not allow Rabbithole to open at login."
                : "macOS could not remove Rabbithole from the login items."
        }
    }
}

// MARK: - Global shortcut

/// A system-wide keyboard shortcut registered through Carbon, which needs no accessibility
/// permission. One instance holds at most one shortcut.
@MainActor
final class GlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
    }

    /// Replaces the registered shortcut. Returns false when the system refused it, for
    /// example because another app already owns the combination.
    @discardableResult
    func register(_ shortcut: Shortcut) -> Bool {
        unregister()
        installHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x5242_4854), id: 1)  // "RBHT"
        let status = RegisterEventHotKey(
            shortcut.keyCode, shortcut.carbonModifiers, id, GetApplicationEventTarget(), 0, &ref)
        hotKeyRef = status == noErr ? ref : nil
        return status == noErr
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return noErr }
                // Carbon delivers hot key events on the main thread.
                MainActor.assumeIsolated {
                    Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue().action()
                }
                return noErr
            }, 1, &spec, pointer, &handlerRef)
    }

    /// Carbon modifier flags and the written form ("⌥⌘U") of a key press, or nil when the
    /// press has no Command, Option or Control and so cannot be a global shortcut.
    static func shortcut(
        keyCode: UInt16, modifiers: NSEvent.ModifierFlags, characters: String?
    ) -> Shortcut? {
        let flags = modifiers.intersection([.command, .option, .control, .shift])
        guard !flags.intersection([.command, .option, .control]).isEmpty,
            let key = characters?.uppercased(), !key.isEmpty, key != " "
        else { return nil }
        var carbon: UInt32 = 0
        var display = ""
        if flags.contains(.control) { carbon |= UInt32(controlKey); display += "⌃" }
        if flags.contains(.option) { carbon |= UInt32(optionKey); display += "⌥" }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey); display += "⇧" }
        if flags.contains(.command) { carbon |= UInt32(cmdKey); display += "⌘" }
        return Shortcut(keyCode: UInt32(keyCode), carbonModifiers: carbon, display: display + key)
    }
}

// MARK: - Notifications

/// Posts a system notification when an upload finishes or fails. Permission is asked the
/// first time one is due; a refusal simply means nothing is shown.
struct UploadNotifier: Sendable {
    /// The notification's title and text for an ended upload.
    static func content(for record: UploadRecord) -> (title: String, body: String) {
        switch record.state {
        case .failed:
            ("Upload failed", "\(UploadText.name(record)): \(record.errorMessage)")
        default:
            ("Upload finished", "\(UploadText.name(record)), \(UploadText.bytes(record.bytesTotal)) sent")
        }
    }

    func notify(_ record: UploadRecord) {
        let (title, body) = Self.content(for: record)
        let identifier = record.id
        Task.detached {
            let center = UNUserNotificationCenter.current()
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            try? await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
        }
    }
}
