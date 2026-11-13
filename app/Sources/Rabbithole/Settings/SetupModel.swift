import Foundation
import Observation

/// The three-step first-launch setup: connect AWS, choose a bucket, start uploading.
/// The settings are saved when the second step is confirmed; the secret typed here is
/// dropped from memory as soon as that save succeeds.
@MainActor
@Observable
final class SetupModel {
    enum Step: Int, CaseIterable, Sendable {
        case connect, bucket, ready

        var title: String {
            switch self {
            case .connect: "Connect AWS"
            case .bucket: "Choose a bucket"
            case .ready: "Start uploading"
            }
        }
    }

    private(set) var step: Step = .connect
    private(set) var isBusy = false
    /// A one-line problem with what was typed, or with saving it.
    private(set) var message: String?
    /// The honest answer to "Test connection", which the engine cannot run yet.
    private(set) var testNote: String?
    /// True once this setup saved the key pair, so the secret field may stay empty afterwards.
    private(set) var secretIsSaved = false

    var accessKeyID = ""
    var secret = ""
    var region = "us-east-1"
    var bucket = ""
    var folder = AWSSettings.quickUploadsPrefix
    var openAtLogin = true
    var notify = true

    /// The bucket selector of the second step, asking with the key typed in the first.
    @ObservationIgnored private(set) var buckets: BucketListModel!

    @ObservationIgnored private let store: SettingsStore
    @ObservationIgnored private let onSaved: (AWSSettings) -> Void
    @ObservationIgnored private let onFinished: (_ openAtLogin: Bool, _ notify: Bool) -> Void

    init(
        store: SettingsStore,
        buckets service: BucketService = .unavailable,
        onSaved: @escaping (AWSSettings) -> Void,
        onFinished: @escaping (_ openAtLogin: Bool, _ notify: Bool) -> Void
    ) {
        self.store = store
        self.onSaved = onSaved
        self.onFinished = onFinished
        // Region and bucket from an earlier, incomplete setup are not secret: offer them again.
        let saved = store.loadDestination()
        if !saved.region.isEmpty { region = saved.region }
        bucket = saved.bucket
        folder = saved.uploadsPrefix
        buckets = BucketListModel(
            service: service,
            access: { [weak self] in await self?.access() },
            selection: { [weak self] in (self?.bucket ?? "", self?.region ?? "") },
            pick: { [weak self] in self?.choose($0) })
    }

    /// A bucket was chosen in the selector, or created. One that lives in another region
    /// than the one picked in the first step brings its region along.
    func choose(_ chosen: Bucket) {
        bucket = chosen.name
        if !chosen.region.isEmpty { region = chosen.region }
        message = nil
    }

    /// The key typed in the first step, with the region, for listing and creating buckets.
    /// After a save in this session an empty secret field stands for the saved secret.
    private func access() async -> AWSAccess? {
        let keyID = accessKeyID.trimmingCharacters(in: .whitespacesAndNewlines)
        var secret = self.secret.trimmingCharacters(in: .whitespacesAndNewlines)
        if secret.isEmpty, secretIsSaved {
            let store = store
            secret = (try? await AWSSettingsForm.load(store: store))?.secretAccessKey ?? ""
        }
        guard !keyID.isEmpty, !secret.isEmpty else { return nil }
        return AWSAccess(accessKeyID: keyID, secretAccessKey: secret, region: region)
    }

    var primaryTitle: String { step == .ready ? "Open dashboard" : "Continue" }
    var canGoBack: Bool { step != .connect && !isBusy }

    func back() {
        guard canGoBack, let previous = Step(rawValue: step.rawValue - 1) else { return }
        message = nil
        step = previous
    }

    /// Confirms the current step.
    func advance() async {
        guard !isBusy else { return }
        message = nil
        switch step {
        case .connect:
            // After a save in this session an empty secret field means "keep the saved one".
            let candidate = AWSSettings(
                accessKeyID: accessKeyID, secretAccessKey: secretIsSaved && secret.isEmpty ? "-" : secret,
                region: region, bucket: "-")
            if let problem = SettingsStore.validate(candidate) {
                message = problem
            } else {
                step = .bucket
            }
        case .bucket:
            await save()
        case .ready:
            onFinished(openAtLogin, notify)
        }
    }

    func testConnection() {
        testNote = "Not available yet: the key is checked by your first upload."
    }

    private func save() async {
        let candidate = AWSSettings(
            accessKeyID: accessKeyID, secretAccessKey: secret, region: region, bucket: bucket,
            uploadsPrefix: AWSSettings.normalizedPrefix(folder))
        isBusy = true
        let store = store
        let result = await AWSSettingsForm.save(candidate, keepStoredSecret: secretIsSaved, store: store)
        isBusy = false
        switch result {
        case .saved(let saved):
            secret = ""
            secretIsSaved = true
            folder = saved.uploadsPrefix
            onSaved(saved)
            step = .ready
        case .failed(let problem):
            message = problem
        }
    }
}
