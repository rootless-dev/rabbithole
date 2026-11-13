import SwiftUI

/// Everything the main window's screens read. One value is passed down instead of six.
@MainActor
struct MainContext {
    let model: MainWindowModel
    let tray: TrayViewModel
    let account: AccountModel
    let preferences: AppPreferences
    let loginItem: LoginItemModel
    let actions: AppActions

    var uploads: UploadLedger { tray.uploads.ledger }
}

/// The main window: the first-launch setup until an account is connected, then the glass
/// sidebar with Overview, History and Settings.
struct MainView: View {
    static let size = CGSize(width: 988, height: 640)
    static let setupSize = CGSize(width: 988, height: 500)
    static let sidebarWidth: CGFloat = 190

    let context: MainContext

    var body: some View {
        Group {
            if let setup = context.model.setup {
                SetupView(model: setup)
            } else {
                HStack(spacing: 0) {
                    Sidebar(model: context.model)
                    VStack(spacing: 0) {
                        ServiceBanner(context: context)
                        content
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .background(Theme.main)
                }
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(Theme.ink)
        .ignoresSafeArea()
    }

    @ViewBuilder private var content: some View {
        if let detail = context.model.detail, let record = context.uploads[detail.id] {
            UploadDetailView(context: context, record: record, origin: detail.origin)
        } else {
            switch context.model.section {
            case .overview: OverviewView(context: context)
            case .history: HistoryView(context: context)
            case .settings: SettingsView(context: context)
            }
        }
    }
}

/// The traffic lights of the mockups, drawn only in offscreen renders where the real window
/// buttons do not exist.
struct WindowLightsStandIn: View {
    /// Small windows can only be closed: their other two buttons are grey.
    var closeOnly = false
    @Environment(\.flatMaterials) private var flat

    var body: some View {
        if flat {
            HStack(spacing: 7) {
                ForEach(Array(([0xF2605A, 0xF5BD3F, 0x5CC74B] as [UInt32]).enumerated()), id: \.offset) { index, hex in
                    Circle()
                        .fill(closeOnly && index > 0 ? Theme.glassLine : Theme.dynamic(hex, hex))
                        .frame(width: 11, height: 11)
                }
            }
        }
    }
}

private struct Sidebar: View {
    let model: MainWindowModel

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(MainSection.allCases, id: \.self) { section in
                let isOn = model.section == section
                Button {
                    model.show(section)
                } label: {
                    Text(section.title)
                        .fontWeight(isOn ? .semibold : .regular)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(isOn ? Theme.hot : .clear, in: .rect(cornerRadius: 7))
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.top, 47)
        .padding(.bottom, 12)
        .frame(width: MainView.sidebarWidth)
        .frame(maxHeight: .infinity)
        .overlay(alignment: .topLeading) { WindowLightsStandIn().padding(.leading, 14).padding(.top, 14) }
        .background(GlassBackdrop())
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.line).frame(width: 1) }
    }
}

/// The strip across the top for a lost connection, a rejected key, or a daemon that is not
/// usable. It shows only what the app has really detected.
private struct ServiceBanner: View {
    let context: MainContext

    var body: some View {
        switch context.tray.state {
        case .restartRequired, .unavailable:
            Banner(tone: .bad, lead: "Uploads are unavailable.", text: unavailableText)
        case .settingsUnreadable:
            Banner(
                tone: .bad, lead: "Saved AWS settings could not be read.",
                text: "Uploads are stopped until you enter the access key again.",
                actionTitle: "Update access key", action: { context.actions.openSettingsPane(.aws) })
        default:
            switch context.uploads.condition {
            case .none:
                EmptyView()
            case .offline:
                let failed = context.uploads.failedByCondition
                Banner(
                    tone: .warn, lead: "No internet connection.",
                    text: "Uploads have stopped. Use Try now to send them again when it comes back.",
                    actionTitle: failed.isEmpty ? nil : "Try now",
                    action: { context.actions.retry(failed) })
            case .keyRejected:
                Banner(
                    tone: .bad, lead: "AWS rejected the access key.",
                    text: "Uploads are stopped until you update it; nothing already sent was lost.",
                    actionTitle: "Update access key", action: { context.actions.openSettingsPane(.aws) })
            }
        }
    }

    private var unavailableText: String {
        context.tray.state == .restartRequired
            ? "Quit and reopen Rabbithole." : "The upload service could not be configured."
    }
}

// MARK: - Overview

struct OverviewView: View {
    let context: MainContext

    var body: some View {
        let ledger = context.uploads
        VStack(spacing: 0) {
            TimelineView(.periodic(from: .now, by: 30)) { timeline in
                SummaryCards(state: context.tray.state, ledger: ledger, now: timeline.date)
            }
            if ledger.records.isEmpty {
                EmptyState(
                    title: "No uploads yet",
                    text: "Drop a file or folder on the Rabbithole icon in the menu bar, or pick one here.",
                    actionTitle: "Choose file", primary: true, action: context.actions.chooseFile
                )
                .disabled(!context.tray.acceptsUploads)
            } else {
                @Bindable var model = context.model
                // Uploads that failed for the reason the banner is announcing.
                let stopped = Set(ledger.failedByCondition.map(\.id))
                ListBand(title: "Uploads") {
                    FilterTabs(
                        tabs: [.all, .inProgress, .finished, .failed].map { .init(value: $0, title: $0.title) },
                        selection: $model.overviewQuery.state)
                }
                UploadList(
                    records: model.overviewQuery.apply(to: ledger.ordered), topPadding: 10,
                    stopped: stopped,
                    line: {
                        stopped.contains($0.id)
                            ? UploadText.stoppedLine($0, condition: ledger.condition)
                            : UploadText.progressLine($0)
                    },
                    open: { model.openDetail(id: $0.id, from: .overview) },
                    empty: {
                        EmptyState(
                            title: model.overviewQuery.emptyTitle,
                            text: "Nothing is in this state right now.",
                            actionTitle: "Show all uploads", action: { model.overviewQuery.clear() })
                    })
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
    }
}

/// The three cards on top of Overview. The middle card counts what this run of the app
/// sent: the engine does not know the bucket's total yet.
struct SummaryCards: View {
    let state: TrayState
    let ledger: UploadLedger
    let now: Date

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if case .uploading(let remaining, let total, let fraction) = state {
                SummaryCard(label: "Uploading now", value: "\(remaining) of \(total) files left") {
                    ThinBar(fraction: fraction).padding(.top, 6)
                }
            } else {
                SummaryCard(label: "Uploading now", value: "Nothing", isNone: true) { EmptyView() }
            }
            if ledger.finishedCount > 0 {
                SummaryCard(label: "Stored in the cloud", value: UploadText.bytes(ledger.finishedBytes)) {
                    Text(storedNote).cardNote()
                }
            } else {
                SummaryCard(label: "Stored in the cloud", value: "0 files", isNone: true) {
                    Text("since Rabbithole was opened").cardNote()
                }
            }
            if let last = ledger.lastFinished, let endedAt = last.endedAt {
                SummaryCard(label: "Last upload finished", value: UploadText.longAge(endedAt, now: now)) {
                    Text(UploadText.name(last)).cardNote()
                }
            } else {
                SummaryCard(label: "Last upload finished", value: "Not yet", isNone: true) { EmptyView() }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var storedNote: String {
        let count = ledger.finishedFileCount
        return "\(count.formatted(.number.locale(Locale(identifier: "en_US")))) \(count == 1 ? "file" : "files") since Rabbithole was opened"
    }
}

extension Text {
    fileprivate func cardNote() -> some View {
        font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
    }
}

private struct SummaryCard<Footer: View>: View {
    let label: String
    let value: String
    var isNone = false
    @ViewBuilder var footer: Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label).font(.system(size: 12)).foregroundStyle(Theme.muted)
            Text(value)
                .font(.system(size: 20, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(isNone ? Theme.off : Theme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.top, 4)
                .padding(.bottom, 2)
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 15)
        .padding(.vertical, 13)
        .background(Theme.card, in: .rect(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line, lineWidth: 1) }
    }
}

// MARK: - Shared list pieces

/// A list heading with filter tabs on the right and a rule under it.
struct ListBand<Trailing: View>: View {
    let title: String
    var topPadding: CGFloat = 24
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .bottom) {
            Text(title).font(.system(size: 15, weight: .semibold))
            Spacer()
            trailing
        }
        .padding(.top, topPadding)
        .padding(.bottom, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }
}

/// The scrolling list of upload rows shared by Overview and History.
struct UploadList<Empty: View>: View {
    let records: [UploadRecord]
    var topPadding: CGFloat = 10
    /// Ids of uploads drawn as stopped where they were, instead of as failed.
    var stopped: Set<String> = []
    let line: (UploadRecord) -> UploadText.Line
    let open: (UploadRecord) -> Void
    @ViewBuilder var empty: Empty

    var body: some View {
        if records.isEmpty {
            empty
        } else {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(records) { record in
                        Button {
                            open(record)
                        } label: {
                            UploadRow(
                                record: record, line: line(record), isStopped: stopped.contains(record.id))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, topPadding)
                .padding(.bottom, 12)
                .padding(.trailing, 14)
            }
        }
    }
}

/// One upload: its thumbnail inside the progress ring, the name, the local path and a
/// progress line.
struct UploadRow: View {
    let record: UploadRecord
    let line: UploadText.Line
    /// Stopped by a lost connection or a rejected key: the ring keeps how far it got.
    var isStopped = false

    var body: some View {
        HStack(spacing: 12) {
            ProgressRing(
                fraction: isStopped ? record.fraction : record.ringFraction,
                color: isStopped ? Theme.muted : record.ringColor
            ) {
                UploadThumbnail(record: record, side: 30)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    Text(UploadText.name(record))
                        .fontWeight(.semibold)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(1)
                    Spacer(minLength: 0)
                    Text(UploadText.location(record))
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Text(line.text)
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(line.tone.color)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .background(Theme.card, in: .rect(cornerRadius: 9))
        .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.line, lineWidth: 1) }
        .contentShape(.rect(cornerRadius: 9))
    }
}

extension UploadText.Tone {
    var color: Color {
        switch self {
        case .normal: Theme.muted
        case .ok: Theme.ok
        case .warn: Theme.warn
        case .bad: Theme.bad
        }
    }
}

extension UploadRecord {
    /// A failed upload shows a full ring in the failure color, as History draws it.
    var ringFraction: Double { state == .failed ? 1 : fraction }

    var ringColor: Color { state.color }
}

extension UploadState {
    /// The color of a ring or progress line in this state.
    var color: Color {
        switch self {
        case .queued, .uploading: Theme.accent
        case .finished: Theme.ok
        case .failed: Theme.bad
        }
    }
}
