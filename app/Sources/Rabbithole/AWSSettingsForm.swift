import Foundation

/// The keychain-touching work behind the AWS settings form. These are `nonisolated`
/// async functions, so they run off the main actor: a keychain prompt (shown after
/// every ad-hoc-signed rebuild) must never block the main thread.
enum AWSSettingsForm {
    enum SaveResult: Equatable, Sendable {
        case saved(AWSSettings)
        /// A fixed, user-facing sentence. Never carries credentials or system error text.
        case failed(String)
    }

    /// What the settings screens show about the saved account. It never carries the secret,
    /// and the key ID only in masked form.
    struct Summary: Equatable, Sendable {
        var maskedKeyID = ""
        var hasCredentials = false
        /// The keychain item exists but could not be read.
        var credentialsUnreadable = false
        var destination = SettingsStore.Destination(
            region: "", bucket: "", uploadsPrefix: AWSSettings.quickUploadsPrefix)
    }

    /// Reads the summary. The keychain read happens here, off the main actor.
    static func summary(store: SettingsStore) async -> Summary {
        var summary = Summary(destination: store.loadDestination())
        do {
            if let keyID = try store.loadAccessKeyID() {
                summary.maskedKeyID = maskedKeyID(keyID)
                summary.hasCredentials = true
            }
        } catch {
            summary.credentialsUnreadable = true
        }
        return summary
    }

    /// "AKIA••••••••••••7Q2F": the first and last four characters around twelve dots. Short
    /// values are hidden entirely.
    static func maskedKeyID(_ keyID: String) -> String {
        let dots = String(repeating: "•", count: 12)
        guard keyID.count >= 12 else { return dots }
        return keyID.prefix(4) + dots + keyID.suffix(4)
    }

    /// Changes part of the saved settings (region, bucket, folder) and saves the result. The
    /// stored credentials are read and written back here, off the main actor.
    static func update(
        store: SettingsStore, _ change: @Sendable (inout AWSSettings) -> Void
    ) async -> SaveResult {
        let current: AWSSettings
        do {
            guard let saved = try store.load() else {
                return .failed("Connect your AWS account first.")
            }
            current = saved
        } catch {
            return .failed("Could not read the saved settings.")
        }
        var candidate = current
        change(&candidate)
        if let problem = SettingsStore.validate(candidate) {
            return .failed(problem)
        }
        do {
            try store.save(candidate)
        } catch {
            return .failed("Could not save the settings.")
        }
        return .saved(candidate)
    }

    /// Reads the saved settings for the form. Throws when the keychain cannot be read.
    static func load(store: SettingsStore) async throws -> AWSSettings? {
        try store.load()
    }

    /// The saved key pair and region for the bucket calls, or nil when there is none or it
    /// cannot be read. The keychain read happens here, off the main actor.
    static func access(store: SettingsStore) async -> AWSAccess? {
        try? store.loadAccess()
    }

    /// Validates `candidate` and saves it. When `keepStoredSecret` is true and the secret
    /// field was left empty, the stored secret is kept: the pair lives in one keychain
    /// item, so it is read once and written back together with the other fields.
    static func save(
        _ candidate: AWSSettings, keepStoredSecret: Bool, store: SettingsStore
    ) async -> SaveResult {
        var candidate = candidate
        if candidate.secretAccessKey.isEmpty, keepStoredSecret {
            do {
                guard let current = try store.load() else {
                    return .failed("Enter the secret access key.")
                }
                candidate.secretAccessKey = current.secretAccessKey
            } catch {
                return .failed("Could not read the saved secret.")
            }
        }
        if let problem = SettingsStore.validate(candidate) {
            return .failed(problem)
        }
        do {
            try store.save(candidate)
        } catch {
            return .failed("Could not save the settings.")
        }
        return .saved(candidate)
    }
}
