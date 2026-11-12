import SwiftUI

/// Plain AWS settings form. The secret is never loaded into the field: when settings
/// already exist the field starts empty and an empty submission keeps the stored secret.
struct AWSSettingsView: View {
    let store: SettingsStore
    let onSaved: (AWSSettings) -> Void
    let onCancel: () -> Void

    @State private var accessKeyID = ""
    @State private var secret = ""
    @State private var region = ""
    @State private var bucket = ""
    @State private var existingSecret = false
    @State private var message: String?
    /// True while the keychain is being read on open or a save is in flight.
    @State private var isBusy = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Form {
                TextField("Access key ID", text: $accessKeyID)
                VStack(alignment: .leading, spacing: 4) {
                    SecureField(
                        "Secret access key", text: $secret,
                        prompt: Text(existingSecret ? "A secret is saved" : ""))
                    Text("Saved in the system keychain, never in a file.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                TextField("Region", text: $region)
                TextField("Bucket", text: $bucket)
            }
            if let message {
                Text(message).foregroundStyle(.red).font(.callout)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save") { Task { await save() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isBusy)
            }
        }
        .padding(20)
        .frame(width: 420)
        .task { await loadExisting() }
    }

    /// The keychain is read off the main actor; the form stays disabled until it returns.
    private func loadExisting() async {
        defer { isBusy = false }
        do {
            if let current = try await AWSSettingsForm.load(store: store) {
                accessKeyID = current.accessKeyID
                region = current.region
                bucket = current.bucket
                existingSecret = true
            }
        } catch {
            message = "Could not read the saved settings."
        }
    }

    private func save() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        message = nil
        let candidate = AWSSettings(
            accessKeyID: accessKeyID, secretAccessKey: secret, region: region, bucket: bucket)
        switch await AWSSettingsForm.save(candidate, keepStoredSecret: existingSecret, store: store) {
        case .saved(let saved): onSaved(saved)
        case .failed(let problem): message = problem
        }
    }
}
