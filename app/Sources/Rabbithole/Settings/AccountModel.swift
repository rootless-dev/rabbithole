import Foundation
import Observation

/// An AWS region as shown in the region choice: "sa-east-1, São Paulo".
struct AWSRegion: Equatable, Sendable {
    let code: String
    let place: String

    var title: String { "\(code), \(place)" }

    static let all: [AWSRegion] = [
        .init(code: "us-east-1", place: "N. Virginia"),
        .init(code: "us-east-2", place: "Ohio"),
        .init(code: "us-west-1", place: "N. California"),
        .init(code: "us-west-2", place: "Oregon"),
        .init(code: "ca-central-1", place: "Canada"),
        .init(code: "sa-east-1", place: "São Paulo"),
        .init(code: "eu-west-1", place: "Ireland"),
        .init(code: "eu-west-2", place: "London"),
        .init(code: "eu-west-3", place: "Paris"),
        .init(code: "eu-central-1", place: "Frankfurt"),
        .init(code: "eu-north-1", place: "Stockholm"),
        .init(code: "eu-south-1", place: "Milan"),
        .init(code: "ap-south-1", place: "Mumbai"),
        .init(code: "ap-southeast-1", place: "Singapore"),
        .init(code: "ap-southeast-2", place: "Sydney"),
        .init(code: "ap-northeast-1", place: "Tokyo"),
        .init(code: "ap-northeast-2", place: "Seoul"),
        .init(code: "ap-northeast-3", place: "Osaka"),
        .init(code: "ap-east-1", place: "Hong Kong"),
        .init(code: "me-south-1", place: "Bahrain"),
        .init(code: "af-south-1", place: "Cape Town"),
    ]

    /// The list for a pop-up, with a saved region that is not in the list kept selectable.
    static func options(including code: String) -> [AWSRegion] {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !all.contains(where: { $0.code == trimmed }) else { return all }
        return all + [AWSRegion(code: trimmed, place: "custom")]
    }
}

/// The saved AWS account and destination as the Settings screen edits them. Keychain work
/// runs off the main actor through `AWSSettingsForm`; the secret is never kept here.
@MainActor
@Observable
final class AccountModel {
    private(set) var summary = AWSSettingsForm.Summary()
    private(set) var isBusy = false
    /// A one-line problem from the last save or load, shown under the controls.
    private(set) var message: String?

    // Editable copies of the saved values.
    var region = ""
    var bucket = ""
    var folder = AWSSettings.quickUploadsPrefix

    @ObservationIgnored private let store: SettingsStore
    @ObservationIgnored private let onSaved: (AWSSettings) -> Void

    init(store: SettingsStore, onSaved: @escaping (AWSSettings) -> Void) {
        self.store = store
        self.onSaved = onSaved
    }

    func reload() async {
        let loaded = await AWSSettingsForm.summary(store: store)
        summary = loaded
        region = loaded.destination.region
        bucket = loaded.destination.bucket
        folder = loaded.destination.uploadsPrefix
        if loaded.credentialsUnreadable { message = "Could not read the saved settings." }
    }

    /// Saves the edited region, bucket and folder when they differ from what is saved.
    func commitDestination() async {
        let wanted = SettingsStore.Destination(
            region: region.trimmingCharacters(in: .whitespacesAndNewlines),
            bucket: bucket.trimmingCharacters(in: .whitespacesAndNewlines),
            uploadsPrefix: AWSSettings.normalizedPrefix(folder))
        guard wanted != summary.destination, !isBusy else { return }
        let store = store
        await run {
            await AWSSettingsForm.update(store: store) { settings in
                settings.region = wanted.region
                settings.bucket = wanted.bucket
                settings.uploadsPrefix = wanted.uploadsPrefix
            }
        }
    }

    /// Replaces the saved key pair. Returns true when it was saved.
    func replaceCredentials(accessKeyID: String, secret: String) async -> Bool {
        guard !isBusy else { return false }
        let destination = summary.destination
        let store = store
        return await run {
            await AWSSettingsForm.save(
                AWSSettings(
                    accessKeyID: accessKeyID, secretAccessKey: secret, region: destination.region,
                    bucket: destination.bucket, uploadsPrefix: destination.uploadsPrefix),
                keepStoredSecret: false, store: store)
        }
    }

    @discardableResult
    private func run(_ save: @escaping @Sendable () async -> AWSSettingsForm.SaveResult) async -> Bool {
        isBusy = true
        message = nil
        let result = await save()
        isBusy = false
        switch result {
        case .saved(let settings):
            onSaved(settings)
            await reload()
            return true
        case .failed(let problem):
            await reload()
            message = problem
            return false
        }
    }
}
