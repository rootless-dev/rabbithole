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

    /// Reads the saved settings for the form. Throws when the keychain cannot be read.
    static func load(store: SettingsStore) async throws -> AWSSettings? {
        try store.load()
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
