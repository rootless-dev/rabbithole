import AppKit
import SwiftUI

/// Settings: categories in a second column (App, Uploads, Destination, AWS account,
/// Security), each showing its current state under the name, and the options on the right.
struct SettingsView: View {
    let context: MainContext

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Settings").font(.system(size: 19, weight: .semibold))
            HStack(alignment: .top, spacing: 22) {
                VStack(spacing: 2) {
                    ForEach(SettingsPane.allCases, id: \.self) { pane in
                        CategoryButton(
                            title: pane.title, note: note(for: pane),
                            isOn: context.model.settingsPane == pane
                        ) {
                            context.model.settingsPane = pane
                        }
                    }
                }
                .frame(width: 160)

                ScrollView {
                    VStack(spacing: 0) {
                        switch context.model.settingsPane {
                        case .app: AppPane(context: context)
                        case .uploads: UploadsPane(preferences: context.preferences)
                        case .destination: DestinationPane(account: context.account, buckets: context.buckets)
                        case .aws: AccountPane(context: context)
                        case .security: SecurityPane(actions: context.actions)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.top, 14)
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task { await context.account.reload() }
        .task { await context.loginItem.refresh() }
    }

    private func note(for pane: SettingsPane) -> String {
        switch pane {
        case .app: context.preferences.theme.title
        case .uploads: "\(context.preferences.simultaneousUploads) at a time"
        case .destination:
            context.account.summary.destination.bucket.isEmpty
                ? "No bucket" : context.account.summary.destination.bucket
        case .aws: ConnectionStatus(context: context).short
        case .security: "Encryption off"
        }
    }
}

/// What the app really knows about the AWS connection. The engine has no connection test,
/// so "Connected" is only claimed after an upload finished in this run. Finished uploads of
/// the history that earlier runs left do not prove that the key still works.
struct ConnectionStatus {
    enum Level { case ok, neutral, bad }

    let short: String
    let level: Level

    @MainActor
    init(context: MainContext) {
        self.init(
            hasCredentials: context.account.summary.hasCredentials,
            unreadable: context.account.summary.credentialsUnreadable,
            condition: context.uploads.condition, finishedThisRun: context.uploads.hasFinishedLive)
    }

    init(hasCredentials: Bool, unreadable: Bool, condition: ServiceCondition, finishedThisRun: Bool) {
        if unreadable {
            (short, level) = ("Key unreadable", .bad)
        } else if !hasCredentials {
            (short, level) = ("Not connected", .neutral)
        } else if condition == .keyRejected {
            (short, level) = ("Key rejected", .bad)
        } else if condition == .offline {
            (short, level) = ("No connection", .bad)
        } else if finishedThisRun {
            (short, level) = ("Connected", .ok)
        } else {
            (short, level) = ("Key saved", .neutral)
        }
    }

    var color: Color {
        switch level {
        case .ok: Theme.ok
        case .neutral: Theme.muted
        case .bad: Theme.bad
        }
    }
}

private struct CategoryButton: View {
    let title: String
    let note: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .fontWeight(isOn ? .semibold : .regular)
                    .foregroundStyle(isOn ? Theme.ink : Theme.muted)
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 7.25)
            .background(isOn ? Theme.card : .clear, in: .rect(cornerRadius: 8))
            .overlay {
                if isOn { RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line, lineWidth: 1) }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

/// One option: its name and explanation on the left, its controls on the right.
private struct SettingRow<Controls: View>: View {
    let title: String
    var note: String?
    var isFirst = false
    var isLast = false
    @ViewBuilder var controls: Controls

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).fontWeight(.medium)
                if let note {
                    Text(note)
                        .font(.system(size: 11.5))
                        .lineSpacing(1.5)
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(minHeight: 15.5)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) { controls }
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.muted)
        }
        .padding(.top, isFirst ? 4 : 10)
        // 10 points of padding plus the 1 point rule the mockups draw below it.
        .padding(.bottom, isLast ? 10 : 11)
        .overlay(alignment: .bottom) {
            if !isLast { Rectangle().fill(Theme.line).frame(height: 1) }
        }
    }
}

private struct SmallField: View {
    @Binding var text: String
    var width: CGFloat?
    var secure = false
    var prompt = ""
    var onCommit: () -> Void = {}

    var body: some View {
        BoxTextField(
            text: $text, prompt: prompt, secure: secure, fontSize: 12.5, horizontal: 9, vertical: 3,
            radius: 7, onCommit: onCommit
        )
        .frame(width: width)
    }
}

/// A small number box. What is typed is kept inside `range`.
private struct NumberField: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    @State private var text = ""

    var body: some View {
        SmallField(text: $text, width: 44) {
            value = AppPreferences.clamp(Int(text) ?? value, range)
            text = String(value)
        }
        .multilineTextAlignment(.center)
        .monospacedDigit()
        .onAppear { text = String(value) }
    }
}

private struct PaneMessage: View {
    let text: String?
    var color: Color = Theme.bad

    var body: some View {
        if let text {
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(color)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.top, 6)
        }
    }
}

// MARK: - Panes

private struct AppPane: View {
    let context: MainContext
    @State private var shortcutProblem: String?

    var body: some View {
        @Bindable var preferences = context.preferences
        SettingRow(title: "Theme", isFirst: true) {
            SegmentedChoice(
                options: ThemeChoice.allCases.map { ($0, $0.title) }, selection: $preferences.theme)
        }
        .onChange(of: preferences.theme) { _, theme in context.actions.applyTheme(theme) }
        SettingRow(title: "Open at login") {
            Toggle(
                "",
                isOn: Binding(
                    get: { context.loginItem.isOn },
                    set: { wanted in Task { await context.loginItem.set(wanted) } })
            )
            .toggleStyle(SwitchToggleStyle())
            .labelsHidden()
        }
        SettingRow(title: "Notify when an upload finishes or fails") {
            Toggle("", isOn: $preferences.notifyWhenUploadsEnd)
                .toggleStyle(SwitchToggleStyle())
                .labelsHidden()
        }
        SettingRow(title: "Shortcut to open the tray window", isLast: true) {
            ShortcutRecorder(shortcut: preferences.trayShortcut) { shortcut in
                if context.actions.registerShortcut(shortcut) {
                    preferences.trayShortcut = shortcut
                    shortcutProblem = nil
                } else {
                    _ = context.actions.registerShortcut(preferences.trayShortcut)
                    shortcutProblem = "\(shortcut.display) is already used by the system or another app."
                }
            }
        }
        PaneMessage(text: context.loginItem.message)
        PaneMessage(text: shortcutProblem)
    }
}

/// Shows the tray shortcut; click it and type a new combination. Escape cancels.
private struct ShortcutRecorder: View {
    let shortcut: Shortcut
    let onRecord: (Shortcut) -> Void
    @State private var monitor: Any?

    var body: some View {
        Button {
            monitor == nil ? start() : stop()
        } label: {
            Text(monitor == nil ? shortcut.display : "Type shortcut")
                .font(.system(size: 12.5))
                .monospacedDigit()
                .foregroundStyle(monitor == nil ? Theme.ink : Theme.muted)
                .fieldBox(horizontal: 9, vertical: 3, radius: 7, focused: monitor != nil)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Click, then type the new shortcut")
        .onDisappear { stop() }
    }

    private func start() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let keyCode = event.keyCode
            let modifiers = event.modifierFlags
            let characters = event.charactersIgnoringModifiers
            MainActor.assumeIsolated {
                if keyCode != 53,  // Escape cancels
                    let recorded = GlobalHotKey.shortcut(
                        keyCode: keyCode, modifiers: modifiers, characters: characters)
                {
                    onRecord(recorded)
                }
                stop()
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

/// Upload behavior. "Uploads at the same time" and "Skip these files" go to the daemon with
/// every upload; resuming goes with its configuration; the speed limit, pausing on battery
/// and checking files are its options, sent again whenever one changes. Only "Retry failed
/// uploads" and its count are stored without effect: the engine has no automatic retry yet.
private struct UploadsPane: View {
    let preferences: AppPreferences

    var body: some View {
        @Bindable var preferences = preferences
        SettingRow(
            title: "Resume uploads automatically",
            note: "Picks up where it stopped after a restart or a lost connection.", isFirst: true
        ) {
            Toggle("", isOn: $preferences.resumeAutomatically).toggleStyle(SwitchToggleStyle()).labelsHidden()
        }
        SettingRow(
            title: "Retry failed uploads",
            note: "Tries again on its own before marking an upload as failed."
        ) {
            NumberField(value: $preferences.retryCount, range: 1...20)
            Text("times")
            Toggle("", isOn: $preferences.retryFailed).toggleStyle(SwitchToggleStyle()).labelsHidden()
        }
        SettingRow(title: "Uploads at the same time") {
            NumberField(value: $preferences.simultaneousUploads, range: 1...16)
        }
        SettingRow(
            title: "Limit upload speed",
            note: "Leaves room for calls and browsing while a big upload runs."
        ) {
            NumberField(value: $preferences.speedLimitMBps, range: 1...10_000)
            Text("MB/s")
            Toggle("", isOn: $preferences.limitSpeed).toggleStyle(SwitchToggleStyle()).labelsHidden()
        }
        SettingRow(title: "Pause on battery power") {
            Toggle("", isOn: $preferences.pauseOnBattery).toggleStyle(SwitchToggleStyle()).labelsHidden()
        }
        SettingRow(
            title: "Check files after sending",
            note: "Confirms the copy in the cloud matches the original."
        ) {
            Toggle("", isOn: $preferences.checkAfterSending).toggleStyle(SwitchToggleStyle()).labelsHidden()
        }
        SettingRow(title: "Skip these files", note: "Patterns ignored inside folders.", isLast: true) {
            SmallField(text: $preferences.skipPatterns, width: 230)
        }
    }
}

private struct DestinationPane: View {
    let account: AccountModel
    let buckets: BucketListModel
    @State private var storageClass = "Standard"
    @State private var whenExists = "Keep both"

    var body: some View {
        @Bindable var account = account
        SettingRow(title: "Bucket", note: buckets.note, isFirst: true) {
            BucketSelector(model: buckets, style: .settings, typedName: $account.bucket) {
                Task { await account.commitDestination() }
            }
        }
        // The saved key is read after the account is, so the list follows a replaced key.
        .task(id: account.summary) { await buckets.loadIfNeeded() }
        SettingRow(title: "Quick uploads folder", note: "Where files dropped on the tray window go.") {
            SmallField(text: $account.folder, width: 200) {
                Task { await account.commitDestination() }
            }
        }
        SettingRow(
            title: "Storage class",
            note: "Cheaper classes cost less per month but more to read back."
        ) {
            BoxMenu(
                options: [
                    .init(value: "Standard", title: "Standard"),
                    .init(value: "Infrequent access", title: "Infrequent access", available: false),
                    .init(value: "Glacier", title: "Glacier", available: false),
                ], selection: $storageClass)
        }
        SettingRow(title: "When a file already exists", isLast: true) {
            BoxMenu(
                options: [
                    .init(value: "Keep both", title: "Keep both"),
                    .init(value: "Replace", title: "Replace", available: false),
                    .init(value: "Skip", title: "Skip", available: false),
                ], selection: $whenExists)
        }
        PaneMessage(text: account.message)
    }
}

private struct AccountPane: View {
    let context: MainContext
    @State private var replacing = false
    @State private var newKeyID = ""
    @State private var newSecret = ""
    @State private var testNote: String?

    var body: some View {
        @Bindable var account = context.account
        let status = ConnectionStatus(context: context)
        SettingRow(
            title: "Access key ID",
            note: "Needs permission to write to the bucket; s3:GetObject for downloading and s3:DeleteObject for deleting from it. Optional: s3:ListAllMyBuckets and s3:CreateBucket, to list and create buckets here.",
            isFirst: true
        ) {
            if replacing {
                SmallField(text: $newKeyID, width: 200, prompt: "New access key ID")
            } else {
                Text(account.summary.hasCredentials ? account.summary.maskedKeyID : "Not set")
                    .monospacedDigit()
                    .foregroundStyle(account.summary.hasCredentials ? Theme.ink : Theme.muted)
                    .fieldBox(horizontal: 9, vertical: 3, radius: 7)
            }
        }
        SettingRow(title: "Secret access key", note: "Stored in the system keychain, never in a file.") {
            if replacing {
                SmallField(text: $newSecret, width: 200, secure: true, prompt: "New secret access key")
                Button("Save") { Task { await save() } }
                    .buttonStyle(smallButton(.primary))
                    .disabled(account.isBusy)
                Button("Cancel") { stopReplacing() }
                    .buttonStyle(smallButton(.plain))
            } else {
                Text(account.summary.hasCredentials ? "••••••••••••••••" : "Not set")
                    .foregroundStyle(account.summary.hasCredentials ? Theme.ink : Theme.muted)
                    .fieldBox(horizontal: 9, vertical: 3, radius: 7)
                Button("Replace") { replacing = true }
                    .buttonStyle(smallButton(.plain))
            }
        }
        SettingRow(title: "Region") {
            BoxMenu(
                options: AWSRegion.options(including: account.region).map {
                    .init(value: $0.code, title: $0.title)
                },
                selection: Binding(
                    get: { account.region },
                    set: { region in
                        account.region = region
                        Task { await account.commitDestination() }
                    }))
        }
        SettingRow(
            title: "Connection", note: "Checks that the keys work and the bucket accepts uploads.",
            isLast: true
        ) {
            Text(status.short).foregroundStyle(status.color)
            Button("Test connection") {
                testNote = "Testing is not available yet: the key is checked by your next upload."
            }
            .buttonStyle(smallButton(.plain))
        }
        PaneMessage(text: account.message)
        PaneMessage(text: testNote, color: Theme.muted)
    }

    private func smallButton(_ kind: BoxButtonStyle.Kind) -> BoxButtonStyle {
        BoxButtonStyle(kind: kind, horizontal: 9, vertical: 3, radius: 7, fontSize: 12.5)
    }

    private func save() async {
        if await context.account.replaceCredentials(accessKeyID: newKeyID, secret: newSecret) {
            stopReplacing()
        }
    }

    private func stopReplacing() {
        replacing = false
        newKeyID = ""
        newSecret = ""
    }
}

/// Encryption is designed but not built: the switch opens the passphrase window, which says
/// so, and stays off.
private struct SecurityPane: View {
    let actions: AppActions

    var body: some View {
        SettingRow(
            title: "Encrypt files before sending",
            note: "Files are locked on this Mac with your own passphrase; AWS only stores the locked copy.",
            isFirst: true, isLast: true
        ) {
            Toggle("", isOn: Binding(get: { false }, set: { _ in actions.showCreatePassphrase() }))
                .toggleStyle(SwitchToggleStyle())
                .labelsHidden()
        }
    }
}
