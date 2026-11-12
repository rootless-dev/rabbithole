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
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear(perform: loadExisting)
    }

    private func loadExisting() {
        do {
            if let current = try store.load() {
                accessKeyID = current.accessKeyID
                region = current.region
                bucket = current.bucket
                existingSecret = true
            }
        } catch {
            message = "Could not read the saved settings."
        }
    }

    private func save() {
        var candidate = AWSSettings(
            accessKeyID: accessKeyID, secretAccessKey: secret, region: region, bucket: bucket)
        if candidate.secretAccessKey.isEmpty, existingSecret {
            // Keep the stored secret when the field was left empty.
            do {
                guard let current = try store.load() else {
                    message = "Enter the secret access key."
                    return
                }
                candidate.secretAccessKey = current.secretAccessKey
            } catch {
                message = "Could not read the saved secret."
                return
            }
        }
        if let problem = SettingsStore.validate(candidate) {
            message = problem
            return
        }
        do {
            try store.save(candidate)
        } catch {
            message = "Could not save the settings."
            return
        }
        onSaved(candidate)
    }
}
