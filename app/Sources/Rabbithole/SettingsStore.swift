import Foundation

/// Persists `AWSSettings`: key ID and secret in the credential store (keychain),
/// region and bucket in preferences.
final class SettingsStore: Sendable {
    private static let regionKey = "region"
    private static let bucketKey = "bucket"

    private let credentials: CredentialStore
    // UserDefaults is documented as thread safe.
    nonisolated(unsafe) private let defaults: UserDefaults

    init(credentials: CredentialStore, defaults: UserDefaults) {
        self.credentials = credentials
        self.defaults = defaults
    }

    /// Returns nil unless the credentials, region and bucket are all present.
    func load() throws -> AWSSettings? {
        guard let pair = try credentials.load(),
            let region = defaults.string(forKey: Self.regionKey),
            let bucket = defaults.string(forKey: Self.bucketKey)
        else { return nil }
        return AWSSettings(
            accessKeyID: pair.accessKeyID, secretAccessKey: pair.secret,
            region: region, bucket: bucket)
    }

    /// Saves trimmed values. Callers are expected to have run `validate` first.
    func save(_ s: AWSSettings) throws {
        try credentials.save(
            accessKeyID: s.accessKeyID.trimmed, secret: s.secretAccessKey.trimmed)
        defaults.set(s.region.trimmed, forKey: Self.regionKey)
        defaults.set(s.bucket.trimmed, forKey: Self.bucketKey)
    }

    /// The first problem as a one-line message, or nil when the settings are usable.
    static func validate(_ s: AWSSettings) -> String? {
        if s.accessKeyID.trimmed.isEmpty { return "Enter the access key ID." }
        if s.secretAccessKey.trimmed.isEmpty { return "Enter the secret access key." }
        if s.region.trimmed.isEmpty { return "Enter the region." }
        if s.bucket.trimmed.isEmpty { return "Enter the bucket name." }
        return nil
    }
}

extension String {
    fileprivate var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
