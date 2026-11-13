import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The content of the tray window, following `tray-popover.html`, `tray-setup.html` and
/// `tray-drag.html`: a setup or fix block or the drop area, the status line and the menu.
/// The glass material is supplied by the panel behind it.
struct TrayView: View {
    let viewModel: TrayViewModel
    let menu: TrayMenuModel
    let actions: AppActions
    let heightChanged: (CGFloat) -> Void

    nonisolated static let space = "tray"

    var body: some View {
        let look = TrayPresentation(viewModel)
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                switch look.topBlock {
                case .setup:
                    TrayCallout(
                        title: "Connect your AWS account", titleColor: Theme.ink,
                        text: "Rabbithole needs it before it can send files.",
                        actionTitle: "Set up Rabbithole", action: actions.startSetup)
                case .keyRejected:
                    TrayCallout(
                        title: "AWS rejected the access key", titleColor: Theme.bannerBad,
                        text: "Uploads are stopped until you update it.",
                        actionTitle: "Update access key", action: { actions.openSettingsPane(.aws) })
                case .drop:
                    TrayDropArea(title: look.dropTitle, subtitle: look.dropSubtitle, style: look.dropStyle)
                    if let status = look.status {
                        TrayStatusLine(status: status)
                    }
                }
            }
            .padding(.init(top: 7, leading: 7, bottom: 6, trailing: 7))
            .onHover { if $0 { menu.setRecentOpen(false) } }

            Rectangle().fill(Theme.glassLine).frame(height: 1)

            TrayMenu(look: look, menu: menu, actions: actions)
        }
        .font(.system(size: 12.5))
        .foregroundStyle(Theme.ink)
        .frame(width: TrayPanelPositioner.width)
        .fixedSize(horizontal: false, vertical: true)
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .strokeBorder(look.isDragging ? Theme.accent : Theme.glassEdge, lineWidth: look.isDragging ? 2 : 1)
                .allowsHitTesting(false)
        }
        .coordinateSpace(.named(Self.space))
        .onDrop(of: [.fileURL], delegate: TrayDropDelegate(viewModel: viewModel))
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { heightChanged($0) }
    }
}

/// Dropping anywhere on the window counts. The number of held items is known as soon as the
/// drag enters, which is what the drop area announces.
private struct TrayDropDelegate: DropDelegate {
    let viewModel: TrayViewModel

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.fileURL])
    }

    func dropEntered(info: DropInfo) {
        viewModel.setHovering(true, itemCount: info.itemProviders(for: [.fileURL]).count)
    }

    func dropExited(info: DropInfo) {
        viewModel.setHovering(false)
    }

    func performDrop(info: DropInfo) -> Bool {
        let providers = info.itemProviders(for: [.fileURL])
        Task {
            let urls = await Self.urls(from: providers)
            await viewModel.drop(urls)
        }
        return true
    }

    @MainActor
    private static func urls(from providers: [NSItemProvider]) async -> [URL] {
        var urls: [URL] = []
        for provider in providers {
            let url: URL? = await withCheckedContinuation { continuation in
                _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                    continuation.resume(returning: data.flatMap { URL(dataRepresentation: $0, relativeTo: nil) })
                }
            }
            if let url { urls.append(url) }
        }
        return urls
    }
}

// MARK: - Top blocks

/// The solid block with one button that replaces the drop area before setup and when AWS
/// rejected the access key.
private struct TrayCallout: View {
    let title: String
    let titleColor: Color
    let text: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Text(title)
                .fontWeight(.semibold)
                .foregroundStyle(titleColor)
            Text(text)
                .font(.system(size: 11.5))
                .lineSpacing(1.5)
                .foregroundStyle(Theme.glassMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
                .padding(.bottom, 8)
            Button(action: action) {
                Text(actionTitle)
                    .fontWeight(.semibold)
                    .foregroundStyle(Theme.onAccent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .background(Theme.accent, in: .rect(cornerRadius: 6))
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
        .padding(.init(top: 11.5, leading: 11.5, bottom: 10.5, trailing: 11.5))
        .frame(maxWidth: .infinity)
        .background(Theme.card, in: .rect(cornerRadius: 7))
        .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.glassLine, lineWidth: 1.5) }
    }
}

private struct TrayDropArea: View {
    let title: String
    let subtitle: String?
    let style: TrayPresentation.DropStyle

    var body: some View {
        VStack(spacing: 0) {
            Text(title).fontWeight(.semibold)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(style == .over ? Theme.accent.opacity(0.8) : Theme.glassMuted)
            }
        }
        .multilineTextAlignment(.center)
        .lineLimit(2)
        .minimumScaleFactor(0.85)
        .padding(.horizontal, 6)
        .foregroundStyle(foreground)
        .frame(maxWidth: .infinity)
        .frame(height: 67)
        .background(style == .over ? Theme.tint : Theme.card, in: .rect(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(border, style: StrokeStyle(lineWidth: 1.5, dash: style == .normal ? [4, 2.5] : []))
        }
    }

    private var foreground: Color {
        switch style {
        case .normal: Theme.ink
        case .over: Theme.accent
        case .done: Theme.ok
        }
    }

    private var border: Color {
        switch style {
        case .normal: Theme.glassMuted
        case .over: Theme.accent
        case .done: Theme.ok
        }
    }
}

/// Status text, percentage and the thin overall progress bar.
private struct TrayStatusLine: View {
    let status: TrayPresentation.Status

    var body: some View {
        VStack(spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(status.text)
                    .fontWeight(.semibold)
                    .foregroundStyle(status.tone == .warn ? Theme.warn : Theme.ink)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if let fraction = status.fraction {
                    Text("\(Int((fraction * 100).rounded()))%")
                        .monospacedDigit()
                        .foregroundStyle(Theme.glassMuted)
                }
            }
            .font(.system(size: 11))
            .padding(.horizontal, 2)

            if let fraction = status.fraction {
                ThinBar(fraction: fraction, track: Theme.glassTrack)
                    .padding(.horizontal, 2)
            }
        }
        .padding(.top, 7)
    }
}

// MARK: - Menu

private struct TrayMenu: View {
    let look: TrayPresentation
    let menu: TrayMenuModel
    let actions: AppActions

    var body: some View {
        VStack(spacing: 0) {
            TrayMenuRow(title: "Choose file…", shortcut: "⌘O", dimmed: look.isDragging, action: actions.chooseFile)
                .keyboardShortcut("o", modifiers: .command)
                .disabled(!look.uploadsEnabled)
                .onHover { if $0 { menu.setRecentOpen(false) } }
            TrayMenuRow(
                title: "Upload from clipboard", shortcut: "⌘V", dimmed: look.isDragging,
                action: actions.uploadFromClipboard
            )
            .keyboardShortcut("v", modifiers: .command)
            .disabled(!look.uploadsEnabled)
            .onHover { if $0 { menu.setRecentOpen(false) } }
            TrayMenuRow(
                title: "Recent uploads", shortcut: "›", dimmed: look.isDragging,
                highlighted: menu.recentOpen, action: { menu.setRecentOpen(!menu.recentOpen) }
            )
            .disabled(!look.recentEnabled)
            .onHover { if $0 && look.recentEnabled { menu.setRecentOpen(true) } }
            .onGeometryChange(for: CGFloat.self) {
                $0.frame(in: .named(TrayView.space)).minY
            } action: {
                menu.recentRowTop = $0
            }
            TrayMenuRule()
            Group {
                TrayMenuRow(
                    title: "Open main window", shortcut: "⌘D", dimmed: look.isDragging,
                    action: { actions.openMainWindow(nil) }
                )
                .keyboardShortcut("d", modifiers: .command)
                TrayMenuRow(
                    title: "Settings", shortcut: "⌘,", dimmed: look.isDragging,
                    action: { actions.openMainWindow(.settings) }
                )
                .keyboardShortcut(",", modifiers: .command)
                TrayMenuRule()
                TrayMenuRow(
                    title: "About Rabbithole…", shortcut: nil, dimmed: look.isDragging,
                    action: actions.showAbout)
                TrayMenuRow(
                    title: "Check for updates", shortcut: nil, dimmed: look.isDragging,
                    action: actions.checkForUpdates)
                TrayMenuRow(title: "Quit", shortcut: "⌘Q", dimmed: look.isDragging, action: actions.quit)
                    .keyboardShortcut("q", modifiers: .command)
            }
            .onHover { if $0 { menu.setRecentOpen(false) } }
        }
        .padding(4)
    }
}

/// One row of the tray's menus: a title, and a shortcut or an age on the right.
struct TrayMenuRow: View {
    let title: String
    let shortcut: String?
    var dimmed = false
    var highlighted = false
    let action: () -> Void
    @State private var hovered = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let isOff = dimmed || !isEnabled
        Button(action: action) {
            HStack(spacing: 10) {
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(isOff ? Theme.off : Theme.ink)
                Spacer(minLength: 0)
                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 11))
                        .foregroundStyle(isOff ? Theme.off : Theme.glassMuted)
                        .fixedSize()
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(
                (hovered || highlighted) && isEnabled && !dimmed ? Theme.glassHot : .clear,
                in: .rect(cornerRadius: 5)
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

struct TrayMenuRule: View {
    var body: some View {
        Rectangle().fill(Theme.glassLine)
            .frame(height: 1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
    }
}

// MARK: - Recent uploads

/// The list that opens beside the menu: the last five uploads of the history, then History.
/// Folders end with a slash.
struct RecentUploadsView: View {
    static let width: CGFloat = 196
    static let limit = 5

    let uploads: UploadStore
    let actions: AppActions
    let heightChanged: (CGFloat) -> Void

    var body: some View {
        let recent = uploads.ledger.recent(limit: Self.limit)
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            VStack(spacing: 0) {
                if recent.isEmpty {
                    TrayMenuRow(title: "No uploads yet", shortcut: nil, action: {})
                        .disabled(true)
                }
                ForEach(recent) { record in
                    TrayMenuRow(
                        title: UploadText.name(record),
                        shortcut: UploadText.shortAge(record.startedAt, now: timeline.date),
                        action: { actions.openUpload(record.id) })
                }
                TrayMenuRule()
                TrayMenuRow(title: "History", shortcut: nil, action: { actions.openMainWindow(.history) })
            }
            .padding(4)
        }
        .font(.system(size: 12.5))
        .foregroundStyle(Theme.ink)
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .strokeBorder(Theme.glassEdge, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { heightChanged($0) }
    }
}
