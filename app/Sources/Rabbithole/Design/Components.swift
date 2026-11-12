import AppKit
import SwiftUI

// MARK: - Glass

/// The system blur behind a window, as an AppKit view.
private struct VisualEffect: NSViewRepresentable {
    let material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .active
        view.material = material
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}

/// A flat picture of a desktop, drawn where the blur would be when rendering offscreen.
private struct WallStandIn: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let stops: [Color] =
            scheme == .dark
            ? [Theme.dynamic(0x1D2A52, 0x1D2A52), Theme.dynamic(0x151A36, 0x151A36), Theme.dynamic(0x2A1B4D, 0x2A1B4D)]
            : [Theme.dynamic(0x9FC4F2, 0x9FC4F2), Theme.dynamic(0x6F8FE0, 0x6F8FE0), Theme.dynamic(0x8A6FD6, 0x8A6FD6)]
        LinearGradient(
            stops: [.init(color: stops[0], location: 0), .init(color: stops[1], location: 0.55),
                .init(color: stops[2], location: 1)],
            startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// Glass surface of the sidebar and the small windows: the desktop blurred behind the
/// window with the mockups' tint over it.
struct GlassBackdrop: View {
    var material: NSVisualEffectView.Material = .sidebar
    @Environment(\.flatMaterials) private var flat

    var body: some View {
        ZStack {
            if flat {
                WallStandIn()
                Theme.glass
            } else {
                VisualEffect(material: material)
                // The system material already carries a tint; a lighter layer of the
                // mockups' tint keeps the two from adding up to an opaque surface.
                Theme.glass.opacity(0.45)
            }
        }
    }
}

// MARK: - Progress

/// The 2 point progress line used in the tray, the cards and the upload detail.
struct ThinBar: View {
    let fraction: Double
    var color: Color = Theme.accent
    var track: Color = Theme.track

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Rectangle().fill(track)
                Rectangle().fill(color)
                    .frame(width: proxy.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: 2)
        .clipShape(.rect(cornerRadius: 1))
    }
}

/// A circular progress ring around some content (a thumbnail).
struct ProgressRing<Content: View>: View {
    let fraction: Double
    var color: Color = Theme.accent
    var size: CGFloat = 54
    var hole: CGFloat = 48
    var holeColor: Color = Theme.card
    @ViewBuilder var content: Content

    var body: some View {
        let width = (size - hole) / 2
        ZStack {
            Circle().fill(holeColor).frame(width: hole, height: hole)
            Circle().strokeBorder(Theme.track, lineWidth: width)
            Circle()
                .inset(by: width / 2)
                .trim(from: 0, to: min(max(fraction, 0), 1))
                .stroke(color, style: StrokeStyle(lineWidth: width, lineCap: .butt))
                .rotationEffect(.degrees(-90))
            content
                .frame(width: hole, height: hole)
                .clipShape(Circle())
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Buttons

/// The bordered buttons of the mockups: plain on a card background, primary on the accent.
struct BoxButtonStyle: ButtonStyle {
    enum Kind { case plain, primary, danger }

    var kind: Kind = .plain
    var horizontal: CGFloat = 14
    var vertical: CGFloat = 6
    var radius: CGFloat = 8
    var fontSize: CGFloat = 13
    var fill: Color = Theme.card
    var fullWidth = false

    func makeBody(configuration: Configuration) -> some View {
        Label(style: self, configuration: configuration)
    }

    private struct Label: View {
        let style: BoxButtonStyle
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: style.fontSize, weight: style.kind == .primary ? .semibold : .regular))
                .lineLimit(1)
                .foregroundStyle(foreground)
                .frame(maxWidth: style.fullWidth ? .infinity : nil)
                // The mockups' CSS padding excludes the 1 point border; add it back.
                .padding(.horizontal, style.horizontal + 1)
                .padding(.vertical, style.vertical + 1)
                .background(
                    style.kind == .primary ? Theme.accent : style.fill, in: .rect(cornerRadius: style.radius))
                .overlay {
                    if style.kind != .primary {
                        RoundedRectangle(cornerRadius: style.radius).strokeBorder(Theme.line, lineWidth: 1)
                    }
                }
                .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
                .contentShape(.rect(cornerRadius: style.radius))
        }

        private var foreground: Color {
            switch style.kind {
            case .plain: Theme.ink
            case .primary: Theme.onAccent
            case .danger: Theme.bad
            }
        }
    }
}

/// A text-only link in the accent color.
struct LinkButtonStyle: ButtonStyle {
    var fontSize: CGFloat = 12.5

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: fontSize))
            .foregroundStyle(Theme.accent)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(.rect)
    }
}

// MARK: - Controls

/// The 34 by 20 point switch of the mockups.
struct SwitchToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Switch(configuration: configuration)
    }

    private struct Switch: View {
        let configuration: ToggleStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            HStack(spacing: 8) {
                configuration.label
                Button {
                    configuration.isOn.toggle()
                } label: {
                    Capsule()
                        .fill(configuration.isOn ? Theme.accent : Theme.strongTrack)
                        .frame(width: 34, height: 20)
                        .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                            Circle().fill(.white)
                                .frame(width: 16, height: 16)
                                .shadow(color: .black.opacity(0.3), radius: 1, y: 1)
                                .padding(2)
                        }
                        .animation(.easeOut(duration: 0.12), value: configuration.isOn)
                }
                .buttonStyle(.plain)
                .opacity(isEnabled ? 1 : 0.45)
                .accessibilityAddTraits(.isToggle)
                .accessibilityValue(configuration.isOn ? "On" : "Off")
            }
        }
    }
}

/// The joined segments of the theme choice.
struct SegmentedChoice<Value: Hashable>: View {
    let options: [(value: Value, title: String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                if index > 0 { Rectangle().fill(Theme.line).frame(width: 1) }
                Button {
                    selection = option.value
                } label: {
                    Text(option.title)
                        .font(.system(size: 12.5))
                        .foregroundStyle(selection == option.value ? Theme.onAccent : Theme.ink)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 3)
                        .background(selection == option.value ? Theme.accent : Theme.card)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .fixedSize()
        .clipShape(.rect(cornerRadius: 7))
        .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.line, lineWidth: 1) }
    }
}

extension View {
    /// The bordered box behind text fields and pop-up choices.
    func fieldBox(
        horizontal: CGFloat = 11, vertical: CGFloat = 7, radius: CGFloat = 8,
        fill: Color = Theme.card, focused: Bool = false
    ) -> some View {
        // The mockups' CSS padding excludes the 1 point border; add it back.
        padding(.horizontal, horizontal + 1)
            .padding(.vertical, vertical + 1)
            .background(fill, in: .rect(cornerRadius: radius))
            .overlay {
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(focused ? Theme.accent : Theme.line, lineWidth: 1)
            }
    }
}

/// A plain text field (or secure field) inside the mockups' field box.
struct BoxTextField: View {
    @Binding var text: String
    var prompt = ""
    var secure = false
    var fontSize: CGFloat = 13
    var horizontal: CGFloat = 11
    var vertical: CGFloat = 7
    var radius: CGFloat = 8
    var fill: Color = Theme.card
    var onCommit: () -> Void = {}
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if secure {
                SecureField("", text: $text, prompt: promptText)
            } else {
                TextField("", text: $text, prompt: promptText)
            }
        }
        .textFieldStyle(.plain)
        .font(.system(size: fontSize))
        .foregroundStyle(Theme.ink)
        .focused($focused)
        .onSubmit(onCommit)
        .onChange(of: focused) { _, isFocused in
            if !isFocused { onCommit() }
        }
        .fieldBox(horizontal: horizontal, vertical: vertical, radius: radius, fill: fill, focused: focused)
    }

    private var promptText: Text? {
        prompt.isEmpty ? nil : Text(prompt).foregroundStyle(Theme.muted)
    }
}

/// A pop-up choice drawn as the mockups' select box. Options that are not available yet
/// are listed but cannot be picked.
struct BoxMenu<Value: Hashable>: View {
    struct Option {
        let value: Value
        let title: String
        var available = true
    }

    let options: [Option]
    @Binding var selection: Value
    var fontSize: CGFloat = 12.5
    var horizontal: CGFloat = 9
    var vertical: CGFloat = 3
    var radius: CGFloat = 7
    var fullWidth = false

    var body: some View {
        Menu {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                Button(option.available ? option.title : "\(option.title) (not available yet)") {
                    selection = option.value
                }
                .disabled(!option.available)
            }
        } label: {
            HStack(spacing: 8) {
                Text(options.first { $0.value == selection }?.title ?? "")
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                if fullWidth { Spacer(minLength: 0) }
                Image(systemName: "arrowtriangle.down.fill")
                    .font(.system(size: 6.5))
                    .foregroundStyle(Theme.muted)
            }
            .font(.system(size: fontSize))
            .fieldBox(horizontal: horizontal, vertical: vertical, radius: radius)
            .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: !fullWidth, vertical: true)
    }
}

// MARK: - Filters

/// One-at-a-time filter tabs, optionally with a count after each title.
struct FilterTabs<Value: Hashable>: View {
    struct Tab {
        let value: Value
        let title: String
        var count: Int?
    }

    let tabs: [Tab]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(tabs.enumerated()), id: \.offset) { _, tab in
                Button {
                    selection = tab.value
                } label: {
                    HStack(spacing: 4) {
                        Text(tab.title)
                        if let count = tab.count {
                            Text("\(count)").monospacedDigit().opacity(0.75)
                        }
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(selection == tab.value ? Theme.ink : Theme.muted)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(selection == tab.value ? Theme.track : .clear, in: .rect(cornerRadius: 6))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// A several-at-once filter chip.
struct FilterChip: View {
    let title: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: isOn ? .semibold : .regular))
                .foregroundStyle(isOn ? Theme.accent : Theme.muted)
                .padding(.horizontal, 11)
                .padding(.vertical, 3)
                .overlay { Capsule().strokeBorder(isOn ? Theme.accent : Theme.line, lineWidth: 1) }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - States

/// The colored strip across the top of the main window for a lost connection or a rejected key.
struct Banner: View {
    enum Tone { case warn, bad }

    let tone: Tone
    let lead: String
    let text: String
    var actionTitle: String?
    var action: () -> Void = {}

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Text("\(Text(lead).fontWeight(.semibold)) \(text)")
                .font(.system(size: 12.5))
                .foregroundStyle(tone == .warn ? Theme.warn : Theme.bannerBad)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let actionTitle {
                Button(actionTitle, action: action)
                    .buttonStyle(BoxButtonStyle(horizontal: 13, vertical: 5, fontSize: 12.5))
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 9)
        .background(tone == .warn ? Theme.warnBackground : Theme.bannerBadBackground)
    }
}

/// Centered title, explanation and one button, for a list with nothing to show.
struct EmptyState: View {
    let title: String
    let text: String
    let actionTitle: String
    var primary = false
    let action: () -> Void

    var body: some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .multilineTextAlignment(.center)
            Text(text)
                .font(.system(size: 13))
                .lineSpacing(3)
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
                .padding(.bottom, 10)
            Button(actionTitle, action: action)
                .buttonStyle(BoxButtonStyle(kind: primary ? .primary : .plain, horizontal: 13, vertical: 5))
        }
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
