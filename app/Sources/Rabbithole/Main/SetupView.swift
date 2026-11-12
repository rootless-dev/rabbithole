import SwiftUI

/// The first-launch setup shown in the main window while no AWS account is connected:
/// the steps where the navigation will later be, and one pane per step.
struct SetupView: View {
    static let sidebarWidth: CGFloat = 210

    let model: SetupModel

    var body: some View {
        HStack(spacing: 0) {
            steps
            VStack(alignment: .leading, spacing: 0) {
                Group {
                    switch model.step {
                    case .connect: ConnectPane(model: model)
                    case .bucket: BucketPane(model: model)
                    case .ready: ReadyPane(model: model)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                HStack {
                    Button("Back") { model.back() }
                        .buttonStyle(BoxButtonStyle())
                        .opacity(model.step == .connect ? 0 : 1)
                        .disabled(!model.canGoBack)
                    Spacer()
                    Button(model.primaryTitle) { Task { await model.advance() } }
                        .buttonStyle(BoxButtonStyle(kind: .primary))
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.isBusy)
                }
                .padding(.top, 16)
                .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
            }
            .padding(.init(top: 44, leading: 44, bottom: 22, trailing: 44))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.main)
        }
        .font(.system(size: 13))
        .foregroundStyle(Theme.ink)
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Rabbithole")
                .font(.system(size: 17, weight: .semibold))
                .padding(.horizontal, 4)
                .padding(.bottom, 18)
            ForEach(SetupModel.Step.allCases, id: \.self) { step in
                StepRow(
                    number: step.rawValue + 1, title: step.title,
                    isOn: step == model.step, isDone: step.rawValue < model.step.rawValue)
            }
            Spacer(minLength: 0)
            Text("You can change all of this later in Settings.")
                .font(.system(size: 11.5))
                .lineSpacing(2)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }
        .padding(.horizontal, 12)
        .padding(.top, 51)
        .padding(.bottom, 12)
        .frame(width: Self.sidebarWidth)
        .frame(maxHeight: .infinity)
        .overlay(alignment: .topLeading) { WindowLightsStandIn().padding(.leading, 14).padding(.top, 14) }
        .background(GlassBackdrop())
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.line).frame(width: 1) }
    }
}

private struct StepRow: View {
    let number: Int
    let title: String
    let isOn: Bool
    let isDone: Bool

    var body: some View {
        let color = isDone ? Theme.ok : (isOn ? Theme.ink : Theme.muted)
        HStack(spacing: 10) {
            Text(isDone ? "✓" : "\(number)")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 20, height: 20)
                .overlay { Circle().strokeBorder(color, lineWidth: 1.5) }
            Text(title).fontWeight(isOn ? .semibold : .regular)
            Spacer(minLength: 0)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 8)
        .background(isOn ? Theme.hot : .clear, in: .rect(cornerRadius: 8))
    }
}

// MARK: - Panes

private struct PaneHeading: View {
    let title: String
    let text: String

    var body: some View {
        Text(title).font(.system(size: 22, weight: .semibold))
        Text(text)
            .lineSpacing(3.5)
            .foregroundStyle(Theme.muted)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 400, alignment: .leading)
            .padding(.top, 6)
            .padding(.bottom, 22)
    }
}

/// A label on the left and a control up to 320 points wide beside it, with an optional note
/// under the control.
private struct SetupField<Control: View>: View {
    let label: String
    var note: String?
    @ViewBuilder var control: Control

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Text(label).fontWeight(.medium).frame(width: 150, alignment: .leading)
                control.frame(maxWidth: 320)
            }
            if let note {
                Text(note)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.muted)
                    .padding(.leading, 162)
            }
        }
        .padding(.bottom, 12)
    }
}

private struct SetupMessage: View {
    let text: String?

    var body: some View {
        if let text {
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Theme.bad)
                .padding(.leading, 162)
                .padding(.top, 8)
        }
    }
}

private struct ConnectPane: View {
    let model: SetupModel

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 0) {
            PaneHeading(
                title: "Connect your AWS account",
                text: "Rabbithole sends your files to your own AWS account. Paste an access key that can write to the bucket you want to use.")
            SetupField(label: "Access key ID") {
                BoxTextField(text: $model.accessKeyID)
            }
            SetupField(label: "Secret access key", note: "Saved in the system keychain, never in a file.") {
                BoxTextField(
                    text: $model.secret, prompt: model.secretIsSaved ? "A secret is saved" : "", secure: true)
            }
            SetupField(label: "Region") {
                BoxMenu(
                    options: AWSRegion.options(including: model.region).map {
                        .init(value: $0.code, title: $0.title)
                    },
                    selection: $model.region, fontSize: 13, horizontal: 11, vertical: 7, radius: 8,
                    fullWidth: true)
            }
            HStack(spacing: 12) {
                Button("Test connection") { model.testConnection() }
                    .buttonStyle(BoxButtonStyle())
                if let note = model.testNote {
                    Text(note).foregroundStyle(Theme.muted)
                }
            }
            .padding(.leading, 162)
            .padding(.top, 6)
            SetupMessage(text: model.message)
        }
    }
}

private struct BucketPane: View {
    let model: SetupModel

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 0) {
            PaneHeading(
                title: "Choose where your files go",
                text: "Type the name of a bucket in your account. Files dropped on the menu bar window go into the quick uploads folder inside it.")
            SetupField(label: "Bucket", note: "Exactly as it is named in AWS.") {
                BoxTextField(text: $model.bucket)
            }
            SetupField(label: "Quick uploads folder") {
                BoxTextField(text: $model.folder)
            }
            SetupMessage(text: model.message)
        }
    }
}

private struct ReadyPane: View {
    let model: SetupModel

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 0) {
            PaneHeading(
                title: "Rabbithole is ready",
                text: "It lives in the menu bar. Click its icon and drop a file or folder to send it; open this window whenever you want to follow uploads or change settings.")
            TimelineView(.periodic(from: .now, by: 30)) { timeline in
                HStack(spacing: 12) {
                    Spacer()
                    RoundedRectangle(cornerRadius: 3).fill(Theme.strongTrack).frame(width: 12, height: 12)
                    RoundedRectangle(cornerRadius: 4).fill(Theme.accent).frame(width: 12, height: 12)
                        .overlay {
                            RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.strongTrack, lineWidth: 3)
                                .padding(-3)
                        }
                    RoundedRectangle(cornerRadius: 3).fill(Theme.strongTrack).frame(width: 12, height: 12)
                    Text(timeline.date.formatted(.dateTime.weekday(.abbreviated).hour().minute()))
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.muted)
                }
                .padding(.horizontal, 14)
                .frame(height: 26)
                .background(Theme.card, in: .rect(cornerRadius: 8))
                .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line, lineWidth: 1) }
            }
            .frame(maxWidth: 472)
            .padding(.bottom, 18)
            option("Open at login", isOn: $model.openAtLogin)
            option("Notify when an upload finishes or fails", isOn: $model.notify)
        }
    }

    private func option(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(title).fontWeight(.medium)
            Spacer()
            Toggle("", isOn: isOn).toggleStyle(SwitchToggleStyle()).labelsHidden()
        }
        .padding(.vertical, 10)
        .frame(maxWidth: 472)
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
    }
}
