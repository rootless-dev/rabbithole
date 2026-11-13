import SwiftUI

// MARK: - The selector

/// Where the open bucket selector is, so its menu can hang from it.
struct BucketAnchorKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

/// The select box of the approved mockup (design/mockups/transfers.html): the value, and a
/// chevron drawn 13 points from the right edge.
struct ChevronSelectLabel: View {
    let title: String
    var isPlaceholder = false

    var body: some View {
        Text(title)
            .font(.system(size: 13))
            .foregroundStyle(isPlaceholder ? Theme.muted : Theme.ink)
            .lineLimit(1)
            .truncationMode(.middle)
            // The mockup's padding excludes the 1 point border; add it back.
            .padding(.leading, 12)
            .padding(.trailing, 27)
            .padding(.vertical, 6)
            .background(Theme.main, in: .rect(cornerRadius: 7))
            .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.line, lineWidth: 1) }
            .overlay(alignment: .trailing) {
                Chevron()
                    .stroke(Theme.muted, style: StrokeStyle(lineWidth: 1.5, lineCap: .butt, lineJoin: .miter))
                    .frame(width: 8.5, height: 4.25)
                    // The mockup's rotated square sits a little above the middle.
                    .offset(y: 0.9)
                    .padding(.trailing, 9.75)
            }
            .contentShape(.rect(cornerRadius: 7))
    }

    private struct Chevron: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            return path
        }
    }
}

/// The bucket selector of Settings › Destination and of the setup's second step. With the
/// list loaded it is a select box that opens the menu of buckets; while the list cannot be
/// had (no permission to list, no connection) it is the text field it used to be, with
/// "Reload list" beside it, so the bucket can always be given by name.
struct BucketSelector: View {
    enum Style {
        /// The compact box of the Settings rows.
        case settings
        /// The full-width box of the setup's fields.
        case setup
    }

    let model: BucketListModel
    let style: Style
    /// The name while it is typed, when there is no list to choose from.
    @Binding var typedName: String
    var onCommit: () -> Void = {}

    var body: some View {
        if model.offersList {
            Button {
                model.toggle()
            } label: {
                label
            }
            .buttonStyle(.plain)
            .anchorPreference(key: BucketAnchorKey.self, value: .bounds) { model.isOpen ? $0 : nil }
            .accessibilityLabel("Bucket")
            .accessibilityValue(model.selectedName)
        } else {
            HStack(spacing: 8) {
                switch style {
                case .settings:
                    BoxTextField(
                        text: $typedName, prompt: "Bucket name", fontSize: 12.5, horizontal: 9, vertical: 3,
                        radius: 7, onCommit: onCommit
                    )
                    .frame(width: 200)
                case .setup:
                    BoxTextField(text: $typedName, prompt: "Bucket name", onCommit: onCommit)
                }
                if case .failed = model.phase {
                    Button(BucketListModel.reloadTitle) { Task { await model.reload() } }
                        .buttonStyle(
                            style == .settings
                                ? BoxButtonStyle(horizontal: 9, vertical: 3, radius: 7, fontSize: 12.5) : BoxButtonStyle()
                        )
                        .fixedSize()
                }
            }
        }
    }

    @ViewBuilder private var label: some View {
        let name = model.selectedName
        let title = name.isEmpty ? "Choose a bucket" : name
        switch style {
        case .settings:
            ChevronSelectLabel(title: title, isPlaceholder: name.isEmpty)
                .frame(maxWidth: 260, alignment: .trailing)
        case .setup:
            // The setup's select box, as its region choice draws it.
            HStack(spacing: 8) {
                Text(title)
                    .foregroundStyle(name.isEmpty ? Theme.muted : Theme.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Image(systemName: "arrowtriangle.down.fill")
                    .font(.system(size: 6.5))
                    .foregroundStyle(Theme.muted)
            }
            .font(.system(size: 13))
            .fieldBox()
            .contentShape(.rect)
        }
    }
}

// MARK: - The menu

/// The open selector's menu: the buckets with their regions and a tick on the chosen one,
/// a rule, then "Create new bucket…" and "Reload list".
struct BucketMenuView: View {
    static let minWidth: CGFloat = 250

    let model: BucketListModel
    let create: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(model.buckets, id: \.name) { bucket in
                row(.bucket(bucket.name), isTicked: bucket.name == model.selectedName) {
                    model.choose(bucket)
                } label: { color in
                    Text(bucket.name).foregroundStyle(color)
                    if !bucket.region.isEmpty {
                        Text(bucket.region)
                            .font(.system(size: 13 / 1.2))
                            .foregroundStyle(model.highlighted == .bucket(bucket.name) ? color.opacity(0.8) : Theme.muted)
                            .padding(.leading, 8)
                    }
                }
            }
            if !model.buckets.isEmpty {
                Rectangle().fill(Theme.line)
                    .frame(height: 1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
            }
            row(.create, isTicked: false, action: create) { color in
                Text(BucketListModel.createTitle).foregroundStyle(color)
            }
            row(.reload, isTicked: false) {
                model.close()
                Task { await model.reload() }
            } label: { color in
                Text(BucketListModel.reloadTitle).foregroundStyle(color)
            }
        }
        .font(.system(size: 13))
        .frame(minWidth: Self.minWidth, alignment: .leading)
        .fixedSize()
        // The mockup's 5 point padding excludes the 1 point border; add it back.
        .padding(6)
        .background(Theme.card, in: .rect(cornerRadius: 9))
        .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.line, lineWidth: 1) }
        .shadow(color: Theme.shadow, radius: 14, y: 10)
    }

    /// One entry: the tick's column, then the label, highlighted under the pointer.
    private func row<Label: View>(
        _ entry: BucketListModel.Entry, isTicked: Bool, action: @escaping () -> Void,
        @ViewBuilder label: (Color) -> Label
    ) -> some View {
        let isHot = model.highlighted == entry
        let color = isHot ? Theme.onAccent : Theme.ink
        return Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(isTicked ? "✓" : "")
                    .foregroundStyle(color)
                    // The tick starts 2 points left of the text column and takes 16.
                    .frame(width: 16, alignment: .leading)
                    .padding(.leading, -2)
                label(color)
                Spacer(minLength: 0)
            }
            .lineLimit(1)
            .padding(.leading, 10)
            .padding(.trailing, 10)
            .padding(.vertical, 5)
            .background(isHot ? Theme.accent : .clear, in: .rect(cornerRadius: 6))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { over in
            if over {
                model.highlighted = entry
            } else if model.highlighted == entry {
                model.highlighted = nil
            }
        }
    }
}

/// Draws the open bucket menu over the whole main window: 4 points under the selector with
/// their right edges aligned. A click anywhere else, or Escape, closes it.
struct BucketMenuLayer: View {
    let model: BucketListModel
    let anchor: Anchor<CGRect>?
    let create: () -> Void

    var body: some View {
        GeometryReader { proxy in
            if model.isOpen, model.offersList, let anchor {
                let spot = ActionsMenuLayer.Spot.button(proxy[anchor])
                let available = proxy.size
                ZStack(alignment: .topLeading) {
                    Color.clear
                        .contentShape(.rect)
                        .onTapGesture { model.close() }
                    Button("Close menu") { model.close() }
                        .keyboardShortcut(.cancelAction)
                        .buttonStyle(.plain)
                        .frame(width: 0, height: 0)
                        .opacity(0)
                        .accessibilityHidden(true)
                    BucketMenuView(model: model, create: create)
                        .alignmentGuide(.leading) { size in
                            -ActionsMenuLayer.left(spot, width: size.width, within: available.width)
                        }
                        .alignmentGuide(.top) { size in
                            -ActionsMenuLayer.top(spot, height: size.height, within: available.height)
                        }
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            }
        }
    }
}

// MARK: - Create a new bucket

/// The "Create a new bucket" window, shown as a sheet on the main window. When creating
/// fails it stays open: a problem with the name shows under the name, any other in a box
/// above the buttons.
struct CreateBucketSheet: View {
    let model: CreateBucketModel
    @FocusState private var nameFocused: Bool
    @Environment(\.flatMaterials) private var flat

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 0) {
            SheetText(text: "Create a new bucket", size: 15, weight: .semibold, lineHeight: 17.5, color: Theme.inkNS)
            SheetText(
                text: "It is created private: nobody outside your account can read it.", size: 12.5,
                lineHeight: 12.5 * 1.45, color: Theme.mutedNS
            )
            .padding(.top, 6)

            fieldLabel("Name").padding(.top, 12)
            TextField("", text: $model.name)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Theme.ink)
                .focused($nameFocused)
                .disabled(model.isWorking)
                .onSubmit { Task { await model.confirm() } }
                // The mockup's padding excludes the 1 point border; add it back.
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Theme.main, in: .rect(cornerRadius: 8))
                .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(nameBorder, lineWidth: 1) }
                .background {
                    if let glow = nameGlow {
                        RoundedRectangle(cornerRadius: 11).fill(glow).padding(-3)
                    }
                }
                .accessibilityLabel("Name")
            SheetText(
                text: model.nameError ?? CreateBucketModel.nameHint, size: 11.5, lineHeight: 11.5 * 1.4,
                color: model.nameError == nil ? Theme.mutedNS : Theme.badNS
            )
            .padding(.top, 4)

            fieldLabel("Region").padding(.top, 12)
            Menu {
                ForEach(AWSRegion.options(including: model.region), id: \.code) { region in
                    Button(region.longTitle) { model.region = region.code }
                }
            } label: {
                ChevronSelectLabel(
                    title: AWSRegion.options(including: model.region).first { $0.code == model.region }?.longTitle
                        ?? model.region)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(model.isWorking)

            if let error = model.boxError {
                SheetText(text: error, size: 12, lineHeight: 12 * 1.4, color: Theme.badNS)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 8)
                    .background(Theme.badTint, in: .rect(cornerRadius: 8))
                    .padding(.top, 12)
            }

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Cancel") { model.cancel() }
                    .buttonStyle(BoxButtonStyle(fill: Theme.main))
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.isWorking)
                Button("Create and use") { Task { await model.confirm() } }
                    .buttonStyle(BoxButtonStyle(kind: .primary))
                    .keyboardShortcut(.defaultAction)
                    // Still drawn at full strength while the daemon works; the model ignores
                    // a second click.
                    .allowsHitTesting(!model.isWorking)
            }
            .padding(.top, 18)
        }
        .font(.system(size: 13))
        .foregroundStyle(Theme.ink)
        .frame(width: RemovalSheet.contentWidth, alignment: .leading)
        // The mockup's padding excludes the sheet's 1 point border; add it back.
        .padding(.top, 19)
        .padding(.horizontal, 21)
        .padding(.bottom, 17)
        .background(Theme.card)
        // Offscreen there is no key window to hold the focus, so it is only drawn there.
        .onAppear { if !flat { nameFocused = true } }
    }

    /// The name field waits for typing when the window opens. In an offscreen render it is
    /// drawn that way while nothing has failed, as the mockup draws its first window.
    private var showsFocus: Bool { nameFocused || (flat && model.failure == nil) }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12.5, weight: .medium))
            .padding(.bottom, 4)
    }

    private var nameBorder: Color {
        if model.nameError != nil { return Theme.bad }
        return showsFocus ? Theme.accent : Theme.line
    }

    private var nameGlow: Color? {
        if model.nameError != nil { return Theme.badGlow }
        return showsFocus ? Theme.accentGlow : nil
    }
}
