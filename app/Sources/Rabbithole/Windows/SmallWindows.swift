import AppKit
import SwiftUI

/// The glass body shared by the small windows of `small-windows.html`: room for the window
/// buttons on top, then the content with the mockups' padding.
private struct SmallWindowBody<Content: View>: View {
    let width: CGFloat
    var alignment: HorizontalAlignment = .leading
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: alignment, spacing: 0) { content }
            .font(.system(size: 13))
            .foregroundStyle(Theme.ink)
            .padding(.init(top: 33, leading: 24, bottom: 20, trailing: 24))
            .frame(width: width)
            .fixedSize(horizontal: false, vertical: true)
            .overlay(alignment: .topLeading) { WindowLightsStandIn().padding(12) }
            .background(GlassBackdrop(material: .popover))
            .ignoresSafeArea()
    }
}

private struct WindowTitle: View {
    let title: String
    var text: String?

    var body: some View {
        Text(title).font(.system(size: 15, weight: .semibold))
        if let text { WindowText(text) }
    }
}

private struct WindowText: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 12.5))
            .lineSpacing(2.5)
            .foregroundStyle(Theme.smallWindowMuted)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 6)
    }
}

private struct WindowButtons<Buttons: View>: View {
    @ViewBuilder var buttons: Buttons

    var body: some View {
        HStack(spacing: 8) {
            Spacer()
            buttons
        }
        .padding(.top, 18)
    }
}

// MARK: - About

struct AboutView: View {
    let version: String
    let checkForUpdates: () -> Void
    @State private var licensesNote = false

    var body: some View {
        SmallWindowBody(width: 270, alignment: .center) {
            AppIconPlaceholder()
                .padding(.top, 6)
                .padding(.bottom, 12)
            Text("Rabbithole").font(.system(size: 18, weight: .semibold))
            WindowText("Version \(version)")
            WindowText("Backs up your files to your own AWS account.").multilineTextAlignment(.center)
            HStack(spacing: 18) {
                Button("Check for updates", action: checkForUpdates).buttonStyle(LinkButtonStyle())
                Button("Licenses") { licensesNote = true }.buttonStyle(LinkButtonStyle())
            }
            .padding(.top, 10)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .top) { Rectangle().fill(Theme.glassLine).frame(height: 1) }
            .padding(.top, 14)
            if licensesNote {
                Text("The license list is not included in this version yet.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.smallWindowMuted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }
            Text("Made by Carlos, 2026")
                .font(.system(size: 11))
                .foregroundStyle(Theme.smallWindowMuted)
                .padding(.top, 12)
        }
    }
}

/// The placeholder app icon of the mockup: rings going down a hole.
struct AppIconPlaceholder: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 17)
            .fill(
                RadialGradient(
                    stops: [
                        .init(color: Theme.dynamic(0x0D0F1C, 0x0D0F1C), location: 0.15),
                        .init(color: Theme.dynamic(0x2B2A66, 0x2B2A66), location: 0.16),
                        .init(color: Theme.dynamic(0x2B2A66, 0x2B2A66), location: 0.30),
                        .init(color: Theme.dynamic(0x4A3FD0, 0x4A3FD0), location: 0.31),
                        .init(color: Theme.dynamic(0x4A3FD0, 0x4A3FD0), location: 0.46),
                        .init(color: Theme.dynamic(0x8D7BF5, 0x8D7BF5), location: 0.47),
                        .init(color: Theme.dynamic(0x8D7BF5, 0x8D7BF5), location: 0.63),
                        .init(color: Theme.dynamic(0xCFC6FF, 0xCFC6FF), location: 0.64),
                    ],
                    center: UnitPoint(x: 0.5, y: 0.54), startRadius: 0, endRadius: 53)
            )
            .overlay { RoundedRectangle(cornerRadius: 17).strokeBorder(.white.opacity(0.25), lineWidth: 1) }
            .frame(width: 72, height: 72)
            .shadow(color: .black.opacity(0.35), radius: 8, y: 6)
    }
}

// MARK: - Encryption passphrase

/// A rough, honest judgment of a passphrase from its length and variety.
enum PassphraseStrength: Equatable, Sendable {
    case empty, weak, fair, strong

    static func of(_ passphrase: String) -> PassphraseStrength {
        if passphrase.isEmpty { return .empty }
        if passphrase.count < 8 { return .weak }
        let scalars = passphrase.unicodeScalars
        let classes = [
            scalars.contains { CharacterSet.lowercaseLetters.contains($0) },
            scalars.contains { CharacterSet.uppercaseLetters.contains($0) },
            scalars.contains { CharacterSet.decimalDigits.contains($0) },
            scalars.contains { !CharacterSet.alphanumerics.contains($0) },
        ].filter { $0 }.count
        if passphrase.count >= 16 || (passphrase.count >= 12 && classes >= 3) { return .strong }
        return .fair
    }

    var hint: String? {
        switch self {
        case .empty: nil
        case .weak: "Too short"
        case .fair: "Fair passphrase"
        case .strong: "Strong passphrase"
        }
    }

    var color: Color {
        switch self {
        case .empty, .weak: Theme.bad
        case .fair: Theme.warn
        case .strong: Theme.ok
        }
    }
}

private struct PassphraseField: View {
    let label: String
    @Binding var text: String

    var body: some View {
        Text(label)
            .font(.system(size: 12.5, weight: .medium))
            .padding(.top, 12)
            .padding(.bottom, 4)
        BoxTextField(text: $text, secure: true)
    }
}

private struct KeychainCheck: View {
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(isOn ? Theme.accent : Theme.card)
                    .overlay {
                        if isOn {
                            Text("✓").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.onAccent)
                        } else {
                            RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.glassLine, lineWidth: 1)
                        }
                    }
                    .frame(width: 15, height: 15)
                Text("Save it in the system keychain").font(.system(size: 12.5))
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .padding(.top, 12)
    }
}

private struct WarnBox: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .lineSpacing(2)
            .foregroundStyle(Theme.warn)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(Theme.warnBackground, in: .rect(cornerRadius: 8))
            .padding(.top, 12)
    }
}

/// Opened by the encryption switch in Settings. Encryption is not built yet: the window is
/// complete, and its main button says so instead of turning anything on. Nothing typed here
/// is stored.
struct CreatePassphraseView: View {
    let close: () -> Void
    @State private var passphrase = ""
    @State private var repeated = ""
    @State private var saveInKeychain = true
    @State private var answer: String?

    var body: some View {
        let strength = PassphraseStrength.of(passphrase)
        SmallWindowBody(width: 340) {
            WindowTitle(
                title: "Create an encryption passphrase",
                text: "Files are locked with it before they leave this Mac. AWS only stores the locked copy.")
            PassphraseField(label: "Passphrase", text: $passphrase)
            if let hint = strength.hint {
                Text(hint).font(.system(size: 11.5)).foregroundStyle(strength.color).padding(.top, 4)
            }
            PassphraseField(label: "Repeat passphrase", text: $repeated)
            if !repeated.isEmpty, repeated != passphrase {
                Text("The passphrases do not match")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.bad).padding(.top, 4)
            }
            WarnBox(
                text: answer
                    ?? "Rabbithole cannot recover this passphrase. If you lose it, encrypted files cannot be opened.")
            KeychainCheck(isOn: $saveInKeychain)
            WindowButtons {
                Button("Cancel", action: close)
                    .buttonStyle(BoxButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Turn on encryption") {
                    answer = "Encryption is not available in this version yet. Nothing was turned on and the passphrase was not saved."
                    passphrase = ""
                    repeated = ""
                }
                .buttonStyle(BoxButtonStyle(kind: .primary))
                .disabled(passphrase.isEmpty || passphrase != repeated)
            }
        }
    }
}

/// Asks for the passphrase again, for example on a new Mac. Nothing opens it yet, because
/// nothing is encrypted; it exists so the design is complete when encryption arrives.
struct EnterPassphraseView: View {
    let close: () -> Void
    @State private var passphrase = ""
    @State private var saveInKeychain = true
    @State private var answer: String?

    var body: some View {
        SmallWindowBody(width: 340) {
            WindowTitle(
                title: "Enter your encryption passphrase",
                text: "Rabbithole needs it to encrypt new uploads and to open files you sent before.")
            PassphraseField(label: "Passphrase", text: $passphrase)
            if let answer { WarnBox(text: answer) }
            KeychainCheck(isOn: $saveInKeychain)
            WindowButtons {
                Button("Cancel", action: close)
                    .buttonStyle(BoxButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Unlock") {
                    answer = "Encryption is not available in this version yet. Nothing was unlocked."
                    passphrase = ""
                }
                .buttonStyle(BoxButtonStyle(kind: .primary))
                .disabled(passphrase.isEmpty)
            }
        }
    }
}

// MARK: - Check for updates

/// What "Check for updates" can report. The app cannot check yet, so today it only ever
/// shows `.unavailable`; the other two are the designed results, ready for a real check.
enum UpdateCheckResult: Equatable, Sendable {
    case unavailable
    case upToDate
    case available(version: String)
}

struct UpdateResultView: View {
    let result: UpdateCheckResult
    let currentVersion: String
    let close: () -> Void

    var body: some View {
        SmallWindowBody(width: 340) {
            switch result {
            case .unavailable:
                WindowTitle(
                    title: "Rabbithole cannot check for updates yet",
                    text: "You have version \(currentVersion). This version has no update check, so it cannot tell whether a newer one exists.")
                WindowButtons {
                    Button("OK", action: close).buttonStyle(BoxButtonStyle(kind: .primary))
                        .keyboardShortcut(.defaultAction)
                }
            case .upToDate:
                WindowTitle(
                    title: "Rabbithole is up to date", text: "Version \(currentVersion) is the newest one.")
                WindowButtons {
                    Button("OK", action: close).buttonStyle(BoxButtonStyle(kind: .primary))
                        .keyboardShortcut(.defaultAction)
                }
            case .available(let version):
                WindowTitle(
                    title: "Rabbithole \(version) is available",
                    text: "You have version \(currentVersion). Uploads in progress continue after the restart.")
                WindowButtons {
                    Button("Later", action: close).buttonStyle(BoxButtonStyle())
                    Button("Install and restart") {}
                        .buttonStyle(BoxButtonStyle(kind: .primary))
                        .disabled(true)
                        .help("Installing updates is not available yet")
                }
            }
        }
    }
}

// MARK: - Windows

/// Shows the small glass windows, one of each kind at a time. The app has no Dock icon, so
/// showing a window activates the app and makes the window key explicitly.
@MainActor
final class SmallWindowPresenter {
    enum Kind: Hashable { case about, createPassphrase, updates }

    private var windows: [Kind: NSWindow] = [:]

    func show<Content: View>(_ kind: Kind, title: String, content: (@escaping () -> Void) -> Content) {
        windows[kind]?.close()
        let hosting = NSHostingController(rootView: content { [weak self] in self?.close(kind) })
        let window = NSWindow(contentViewController: hosting)
        window.title = title
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isReleasedWhenClosed = false
        window.center()
        windows[kind] = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func close(_ kind: Kind) {
        windows[kind]?.close()
        windows[kind] = nil
    }

    func closeAll() {
        for kind in Array(windows.keys) { close(kind) }
    }
}
