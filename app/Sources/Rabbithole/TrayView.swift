import AppKit
import SwiftUI

/// Colors from the approved mockups. They follow the system appearance.
private enum Palette {
    static let accent = dynamic(light: 0x4A3FD0, dark: 0xA99BFF)
    static let success = dynamic(light: 0x1C8F63, dark: 0x5FD0A0)
    static let solid = dynamic(light: 0xFFFFFF, dark: 0x222638)
    static let tint = dynamic(light: 0xECEAFD, dark: 0x2F2B55)
    static let hot = dynamic(light: 0xFFFFFF, dark: 0xFFFFFF, lightAlpha: 0.55, darkAlpha: 0.13)

    private static func dynamic(
        light: UInt32, dark: UInt32, lightAlpha: Double = 1, darkAlpha: Double = 1
    ) -> Color {
        Color(
            nsColor: NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                let hex = isDark ? dark : light
                return NSColor(
                    srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                    green: CGFloat((hex >> 8) & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255,
                    alpha: isDark ? darkAlpha : lightAlpha)
            })
    }
}

/// The content of the tray window: setup block or drop area, status line and a small menu.
/// The glass material is supplied by the panel behind it.
struct TrayView: View {
    let viewModel: TrayViewModel
    let openSettings: () -> Void
    let chooseFile: () -> Void
    let quit: () -> Void
    let heightChanged: (CGFloat) -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                if viewModel.state == .notConfigured {
                    SetupBlock(openSettings: openSettings)
                } else {
                    DropArea(state: viewModel.state, feedback: viewModel.dropFeedback)
                    if let status = StatusLine(state: viewModel.state, text: viewModel.statusText) {
                        status
                    }
                }
            }
            .padding(.init(top: 7, leading: 7, bottom: 6, trailing: 7))

            Divider()

            VStack(spacing: 0) {
                MenuRow(title: "Choose file…", shortcut: "⌘O", action: chooseFile)
                    .keyboardShortcut("o", modifiers: .command)
                    .disabled(!canChooseFile)
                MenuRow(title: "Quit", shortcut: "⌘Q", action: quit)
                    .keyboardShortcut("q", modifiers: .command)
            }
            .padding(4)
            .opacity(isHovering ? 0.35 : 1)
        }
        .font(.system(size: 12.5))
        .frame(width: TrayPanelPositioner.width)
        .fixedSize(horizontal: false, vertical: true)
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .strokeBorder(Palette.accent, lineWidth: 2)
                .opacity(isHovering ? 1 : 0)
                .allowsHitTesting(false)
        }
        .dropDestination(for: URL.self) { urls, _ in
            Task { await viewModel.drop(urls) }
            return true
        } isTargeted: { over in
            viewModel.setHovering(over)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { heightChanged($0) }
    }

    /// Dragging over the setup block is not a drop target, so it gets no highlight.
    private var isHovering: Bool {
        viewModel.dropFeedback == .hovering && viewModel.state != .notConfigured
    }

    private var canChooseFile: Bool {
        switch viewModel.state {
        case .notConfigured, .unavailable, .starting: false
        default: true
        }
    }
}

private struct SetupBlock: View {
    let openSettings: () -> Void

    var body: some View {
        VStack(spacing: 2) {
            Text("Connect your AWS account").fontWeight(.semibold)
            Text("Rabbithole needs it before it can send files.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.bottom, 6)
            Button(action: openSettings) {
                Text("Set up Rabbithole")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .background(Palette.accent, in: .rect(cornerRadius: 6))
                    .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
        .padding(.init(top: 10, leading: 10, bottom: 9, trailing: 10))
        .frame(maxWidth: .infinity)
        .background(Palette.solid, in: .rect(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7).strokeBorder(.separator, lineWidth: 1.5)
        }
    }
}

private struct DropArea: View {
    let state: TrayState
    let feedback: DropFeedback

    var body: some View {
        VStack(spacing: 1) {
            Text(title).fontWeight(.semibold)
            if let subtitle {
                Text(subtitle).font(.system(size: 11)).opacity(0.8)
            }
        }
        .multilineTextAlignment(.center)
        .lineLimit(2)
        .padding(.horizontal, 6)
        .foregroundStyle(foreground)
        .frame(maxWidth: .infinity)
        .frame(height: 64)
        .background(background, in: .rect(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(
                    border,
                    style: StrokeStyle(lineWidth: 1.5, dash: dashed ? [4, 3] : []))
        }
    }

    private var title: String {
        switch feedback {
        case .hovering: "Release to upload"
        case .confirmed: "File added"
        case .refused(let message): message
        case .none:
            if case .uploading = state { "Drop more to queue" } else { "Drop a file" }
        }
    }

    private var subtitle: String? {
        feedback == .confirmed ? "Upload started" : nil
    }

    private var foreground: Color {
        switch feedback {
        case .hovering: Palette.accent
        case .confirmed: Palette.success
        default: .primary
        }
    }

    private var background: Color {
        feedback == .hovering ? Palette.tint : Palette.solid
    }

    private var border: Color {
        switch feedback {
        case .hovering: Palette.accent
        case .confirmed: Palette.success
        default: Color.secondary
        }
    }

    private var dashed: Bool {
        switch feedback {
        case .hovering, .confirmed: false
        default: true
        }
    }
}

/// Status text, percentage and the thin overall progress bar. Hidden while idle.
private struct StatusLine: View {
    let text: String
    let fraction: Double?

    init?(state: TrayState, text: String) {
        switch state {
        case .idle, .notConfigured:
            return nil
        case .uploading(_, _, let fraction):
            self.fraction = fraction
        case .unavailable, .starting, .finished, .failed:
            self.fraction = nil
        }
        self.text = text
    }

    var body: some View {
        VStack(spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(text)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Spacer(minLength: 4)
                if let fraction {
                    Text("\(Int((fraction * 100).rounded()))%")
                        .monospacedDigit()
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 2)

            if let fraction {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary)
                        Capsule().fill(Palette.accent)
                            .frame(width: proxy.size.width * min(max(fraction, 0), 1))
                    }
                }
                .frame(height: 2)
                .padding(.horizontal, 2)
            }
        }
        .padding(.top, 7)
    }
}

private struct MenuRow: View {
    let title: String
    let shortcut: String
    let action: () -> Void
    @State private var hovered = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                Text(shortcut)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(isEnabled ? .primary : .tertiary)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(hovered && isEnabled ? Palette.hot : .clear, in: .rect(cornerRadius: 5))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}
