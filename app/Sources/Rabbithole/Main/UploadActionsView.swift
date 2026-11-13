import AppKit
import SwiftUI

// MARK: - Choosing an action

extension MainContext {
    /// The target the daemon is asked about: the only file of a single-file upload stands
    /// for the upload.
    func resolved(_ target: UploadActionTarget) -> UploadActionTarget {
        uploads[target.uploadID]?.kind == .singleFile ? .upload(id: target.uploadID) : target
    }

    /// The download shown for a target: the latest one of the upload or of the file.
    func download(of target: UploadActionTarget) -> DownloadSnapshot? {
        downloads[resolved(target)]
    }

    /// A menu entry was chosen. Removing and deleting open their confirmation first, and
    /// Download… asks for a folder; everything else asks the daemon at once.
    func choose(_ action: UploadAction, for target: UploadActionTarget) {
        model.actionsMenu = nil
        guard let record = uploads[target.uploadID] else { return }
        let target = resolved(target)

        let intent: RemovalPrompt.Intent
        switch action {
        case .retry:
            actions.retryFiles(target.uploadID, target.fileIndexes)
            return
        case .pause:
            actions.pauseUpload(record.id)
            return
        case .resume:
            actions.resumeUpload(record.id)
            return
        case .cancelUpload:
            actions.cancelUpload(record.id)
            return
        case .download:
            actions.download(target)
            return
        case .cancelDownload:
            actions.cancelDownload(target)
            return
        case .remove: intent = .remove
        case .deleteFromBucket: intent = .delete
        }
        switch target {
        case .upload:
            model.confirm(RemovalPrompt(upload: record, intent: intent), perform: actions.removeUpload)
        case .file(_, let index):
            guard model.detailFiles.uploadID == record.id, let file = model.detailFiles.file(at: index)
            else { return }
            model.confirm(RemovalPrompt(file: file, of: record, intent: intent), perform: actions.removeUpload)
        }
    }
}

// MARK: - The three dots

/// Where each open menu's button is, so the menu can hang from it.
struct ActionsAnchorKey: PreferenceKey {
    static let defaultValue: [UploadActionTarget: Anchor<CGRect>] = [:]

    static func reduce(
        value: inout [UploadActionTarget: Anchor<CGRect>],
        nextValue: () -> [UploadActionTarget: Anchor<CGRect>]
    ) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// The button with three vertical dots that opens the actions of an upload or of a file.
/// Without actions (a file that is being sent, waits or is paused) it draws nothing and
/// keeps its place, so the rows of a list stay aligned.
struct MoreButton: View {
    static let side: CGFloat = 26

    let target: UploadActionTarget
    let actions: [UploadAction]
    let menus: MainWindowModel
    /// The bordered variant in the header of the upload detail.
    var boxed = false
    @State private var hovered = false

    var body: some View {
        if actions.isEmpty {
            Color.clear.frame(width: boxed ? 0 : Self.side, height: boxed ? 0 : Self.side)
        } else {
            // A menu opened by a right click hangs from the pointer, not from the button.
            let isOpen = menus.actionsMenu?.target == target && menus.actionsMenu?.point == nil
            Button {
                menus.toggleActionsMenu(for: target, actions: actions)
            } label: {
                VStack(spacing: 3) {
                    ForEach(0..<3, id: \.self) { _ in
                        Circle().fill(isOpen ? Theme.ink : Theme.muted).frame(width: 3.5, height: 3.5)
                    }
                }
                // The boxed button's CSS size excludes its 1 point border; add it back.
                .frame(width: boxed ? 32 : Self.side, height: boxed ? 30 : Self.side)
                .background(background(isOpen: isOpen), in: .rect(cornerRadius: 7))
                .overlay {
                    if boxed { RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.line, lineWidth: 1) }
                }
                .contentShape(.rect(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 }
            .anchorPreference(key: ActionsAnchorKey.self, value: .bounds) { isOpen ? [target: $0] : [:] }
            .help("Actions")
            .accessibilityLabel("Actions")
        }
    }

    private func background(isOpen: Bool) -> Color {
        if boxed { return Theme.card }
        if isOpen { return Theme.track }
        return hovered ? Theme.hover : .clear
    }
}

// MARK: - The menu

/// The menu's card: one row per action, a rule between what is done with the upload (Try
/// again, Download…) and what takes it away (Remove from history…, Delete from bucket…),
/// and Cancel upload and Delete from bucket in red.
struct ActionsMenuView: View {
    let menu: OpenActionsMenu
    let hover: (UploadAction, Bool) -> Void
    let choose: (UploadAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(menu.actions.enumerated()), id: \.offset) { index, action in
                let isHot = menu.highlighted == action
                if action == .remove, index > 0 {
                    Rectangle().fill(Theme.line)
                        .frame(height: 1)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                }
                Button {
                    choose(action)
                } label: {
                    Text(action.title)
                        .lineLimit(1)
                        .foregroundStyle(
                            isHot ? Theme.onAccent : action.isDestructive ? Theme.bad : Theme.ink
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(isHot ? Theme.accent : .clear, in: .rect(cornerRadius: 6))
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .onHover { hover(action, $0) }
            }
        }
        .font(.system(size: 13))
        .frame(minWidth: 186)
        .fixedSize()
        // The mockup's 5 point padding excludes the 1 point border; add it back.
        .padding(6)
        .background(Theme.card, in: .rect(cornerRadius: 9))
        .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.line, lineWidth: 1) }
        .shadow(color: Theme.shadow, radius: 14, y: 10)
    }
}

/// Draws the open menu over the whole main window: 4 points under its button with their
/// right edges aligned, or at the pointer after a right click. A click anywhere else, or
/// Escape, closes it.
struct ActionsMenuLayer: View {
    /// The menu keeps this far from the window's edges.
    nonisolated static let margin: CGFloat = 8

    let context: MainContext
    let anchors: [UploadActionTarget: Anchor<CGRect>]

    var body: some View {
        GeometryReader { proxy in
            if let menu = context.model.actionsMenu {
                ZStack(alignment: .topLeading) {
                    Color.clear
                        .contentShape(.rect)
                        .onTapGesture { context.model.actionsMenu = nil }
                    Button("Close menu") { context.model.actionsMenu = nil }
                        .keyboardShortcut(.cancelAction)
                        .buttonStyle(.plain)
                        .frame(width: 0, height: 0)
                        .opacity(0)
                        .accessibilityHidden(true)
                    let available = proxy.size
                    if let spot = spot(of: menu, in: proxy) {
                        ActionsMenuView(
                            menu: menu,
                            hover: { action, isOver in
                                if isOver {
                                    context.model.actionsMenu?.highlighted = action
                                } else if context.model.actionsMenu?.highlighted == action {
                                    context.model.actionsMenu?.highlighted = nil
                                }
                            },
                            choose: { context.choose($0, for: menu.target) }
                        )
                        // The stack lines its children up by these guides, so the menu's
                        // place follows from its own size without measuring it first.
                        .alignmentGuide(.leading) { size in
                            -Self.left(spot, width: size.width, within: available.width)
                        }
                        .alignmentGuide(.top) { size in
                            -Self.top(spot, height: size.height, within: available.height)
                        }
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            }
        }
    }

    /// What the menu hangs from: a button's frame, or the point of a right click.
    enum Spot: Equatable, Sendable {
        case button(CGRect)
        case pointer(CGPoint)
    }

    private func spot(of menu: OpenActionsMenu, in proxy: GeometryProxy) -> Spot? {
        if let point = menu.point { return .pointer(point) }
        return anchors[menu.target].map { .button(proxy[$0]) }
    }

    /// The menu's left edge: its right edge on the button's, or its left edge on the
    /// pointer, moved to the other side or inwards when the window ends first.
    nonisolated static func left(_ spot: Spot, width: CGFloat, within available: CGFloat) -> CGFloat {
        let wanted: CGFloat
        switch spot {
        case .button(let frame): wanted = frame.maxX - width
        case .pointer(let point): wanted = point.x + width > available - margin ? point.x - width : point.x
        }
        return max(min(wanted, available - margin - width), margin)
    }

    /// The menu's top edge: 4 points under the button or at the pointer, and above them
    /// when there is no room below.
    nonisolated static func top(_ spot: Spot, height: CGFloat, within available: CGFloat) -> CGFloat {
        let below: CGFloat
        let above: CGFloat
        switch spot {
        case .button(let frame): (below, above) = (frame.maxY + 4, frame.minY - 4 - height)
        case .pointer(let point): (below, above) = (point.y, point.y - height)
        }
        return below + height > available - margin && above >= margin ? above : below
    }
}

// MARK: - The confirmations

/// The sheet that confirms "Remove from history" or "Delete from bucket".
struct RemovalSheet: View {
    static let cornerRadius: CGFloat = 12
    static let contentWidth: CGFloat = 300

    let model: RemovalSheetModel

    var body: some View {
        let prompt = model.prompt
        VStack(alignment: .leading, spacing: 0) {
            SheetText(text: prompt.title, size: 15, weight: .semibold, lineHeight: 17.5, color: Theme.inkNS)
            SheetText(text: prompt.message, size: 12.5, lineHeight: 12.5 * 1.45, color: Theme.mutedNS)
                .padding(.top, 6)
            if let title = prompt.checkboxTitle {
                Button {
                    model.alsoDelete.toggle()
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        CheckBox(isOn: prompt.alsoDelete).padding(.top, 1)
                        SheetText(text: title, size: 12.5, lineHeight: 12.5 * 1.35, color: Theme.inkNS)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(model.isWorking)
                .accessibilityLabel(title)
                .accessibilityAddTraits(.isToggle)
                .accessibilityValue(prompt.alsoDelete ? "On" : "Off")
                .padding(.top, 14)
            }
            if let warning = prompt.warning {
                Note(text: warning)
            }
            if let error = model.errorMessage {
                Note(text: error)
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Cancel") { model.cancel() }
                    .buttonStyle(BoxButtonStyle(fill: Theme.main))
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.isWorking)
                Button {
                    Task { await model.confirm() }
                } label: {
                    HStack(spacing: 7) {
                        if model.isWorking { Spinner() }
                        Text(prompt.confirmTitle)
                    }
                }
                .buttonStyle(BoxButtonStyle(kind: prompt.confirmStyle == .destructive ? .destructive : .primary))
                // Still drawn at full strength while the daemon works; the model ignores
                // a second confirmation.
                .allowsHitTesting(!model.isWorking)
            }
            .padding(.top, 18)
        }
        .font(.system(size: 13))
        .foregroundStyle(Theme.ink)
        .frame(width: Self.contentWidth, alignment: .leading)
        // The mockup's padding excludes the sheet's 1 point border; add it back.
        .padding(.top, 19)
        .padding(.horizontal, 21)
        .padding(.bottom, 17)
        .background(Theme.card)
    }

    /// The 15 point checkbox of the mockup: an outline, and red with a check when on.
    private struct CheckBox: View {
        let isOn: Bool

        var body: some View {
            ZStack {
                if isOn {
                    RoundedRectangle(cornerRadius: 4).fill(Theme.bad)
                    Text("✓").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.onAccent)
                } else {
                    RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.muted, lineWidth: 1)
                }
            }
            .frame(width: 15, height: 15)
        }
    }

    /// The red note: the warning that deleting cannot be undone, or why the daemon refused.
    private struct Note: View {
        let text: String

        var body: some View {
            SheetText(text: text, size: 12, lineHeight: 12 * 1.4, color: Theme.badNS)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .background(Theme.badSoft, in: .rect(cornerRadius: 8))
                .padding(.top, 10)
        }
    }

    /// A small turning arc in the button's text color, shown while the daemon works.
    private struct Spinner: View {
        @State private var turning = false

        var body: some View {
            Circle()
                .trim(from: 0, to: 0.7)
                .stroke(Theme.onAccent, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                .frame(width: 11, height: 11)
                .rotationEffect(.degrees(turning ? 360 : 0))
                .animation(.linear(duration: 0.8).repeatForever(autoreverses: false), value: turning)
                .onAppear { turning = true }
                .accessibilityLabel("Working")
        }
    }
}

/// A paragraph of a confirmation sheet, laid out as the mockup's browser lays it out: lines
/// of an exact height with the text centered in them, each filled before the next begins.
/// SwiftUI's `Text` moves words down to avoid a short last line, which breaks the sheets'
/// titles and the warning at other words than the approved ones.
struct SheetText: NSViewRepresentable {
    let text: String
    let size: CGFloat
    var weight: NSFont.Weight = .regular
    let lineHeight: CGFloat
    let color: NSColor

    func makeNSView(context: Context) -> ParagraphView {
        let view = ParagraphView()
        view.setContentHuggingPriority(.required, for: .vertical)
        return view
    }

    func updateNSView(_ view: ParagraphView, context: Context) {
        view.paragraph = attributed
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ParagraphView, context: Context) -> CGSize? {
        ParagraphView.size(of: attributed, width: proposal.width ?? RemovalSheet.contentWidth)
    }

    private var attributed: NSAttributedString {
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = lineHeight
        style.maximumLineHeight = lineHeight
        style.lineBreakMode = .byWordWrapping
        style.lineBreakStrategy = []
        // The extra height of a line goes above its text; half of it belongs below.
        let natural = font.ascender - font.descender + font.leading
        return NSAttributedString(
            string: text,
            attributes: [
                .font: font, .foregroundColor: color, .paragraphStyle: style,
                .baselineOffset: max((lineHeight - natural) / 2, 0),
            ])
    }

    final class ParagraphView: NSView {
        var paragraph = NSAttributedString() {
            didSet {
                setAccessibilityLabel(paragraph.string)
                needsDisplay = true
            }
        }

        override var isFlipped: Bool { true }

        override init(frame: NSRect) {
            super.init(frame: frame)
            setAccessibilityElement(true)
            setAccessibilityRole(.staticText)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used") }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func draw(_ dirtyRect: NSRect) {
            paragraph.draw(with: bounds, options: [.usesLineFragmentOrigin])
        }

        static func size(of paragraph: NSAttributedString, width: CGFloat) -> CGSize {
            let bounds = paragraph.boundingRect(
                with: CGSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin])
            return CGSize(width: min(ceil(bounds.width), width), height: ceil(bounds.height))
        }
    }
}

// MARK: - Right click

/// Placed behind a row, reports right clicks (and control-clicks) that land on it, with the
/// pointer's place in the window's top-left coordinates, which are the main view's own.
/// It never takes a click itself: an app-wide monitor asks the areas in the window.
struct SecondaryClickArea: NSViewRepresentable {
    let action: (CGPoint) -> Void

    func makeNSView(context: Context) -> SecondaryClickView {
        let view = SecondaryClickView()
        view.action = action
        return view
    }

    func updateNSView(_ view: SecondaryClickView, context: Context) {
        view.action = action
    }
}

final class SecondaryClickView: NSView {
    var action: ((CGPoint) -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { SecondaryClickRouter.shared.add(self) }
    }

    /// Reports the click when it landed on the visible part of this view.
    func handle(_ event: NSEvent) -> Bool {
        guard let window, event.window === window, !isHiddenOrHasHiddenAncestor,
            visibleRect.contains(convert(event.locationInWindow, from: nil)),
            let content = window.contentView
        else { return false }
        let point = content.convert(event.locationInWindow, from: nil)
        action?(CGPoint(x: point.x, y: content.isFlipped ? point.y : content.bounds.height - point.y))
        return true
    }
}

/// Hands each right click of the app to the area under it, if there is one.
@MainActor
final class SecondaryClickRouter {
    static let shared = SecondaryClickRouter()

    private let views = NSHashTable<SecondaryClickView>.weakObjects()
    private var monitor: Any?

    func add(_ view: SecondaryClickView) {
        views.add(view)
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { event in
            SecondaryClickRouter.shared.route(event) ? nil : event
        }
    }

    /// Returns true when an area took the click, which then goes no further.
    func route(_ event: NSEvent) -> Bool {
        let isSecondary =
            event.type == .rightMouseDown
            || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
        guard isSecondary else { return false }
        return views.allObjects.contains { $0.handle(event) }
    }
}
