import Foundation

/// Persists `AWSSettings`: key ID and secret in the credential store (keychain),
/// region, bucket and the quick uploads folder in preferences.
final class SettingsStore: Sendable {
    private static let regionKey = "region"
    private static let bucketKey = "bucket"
    private static let prefixKey = "quickUploadsPrefix"

    /// The part of the settings that is not secret and lives in preferences.
    struct Destination: Equatable, Sendable {
        var region: String
        var bucket: String
        var uploadsPrefix: String
    }

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
            region: region, bucket: bucket, uploadsPrefix: storedPrefix)
    }

    /// Region, bucket and folder as saved, without touching the keychain. Missing values
    /// come back empty (the folder falls back to its default).
    func loadDestination() -> Destination {
        Destination(
            region: defaults.string(forKey: Self.regionKey) ?? "",
            bucket: defaults.string(forKey: Self.bucketKey) ?? "",
            uploadsPrefix: storedPrefix)
    }

    /// The saved access key ID alone, or nil when no credentials are saved. Reads the keychain.
    func loadAccessKeyID() throws -> String? {
        try credentials.load()?.accessKeyID
    }

    /// The saved key pair with the saved region, for the calls that list and create buckets.
    /// Nil when no credentials are saved. Reads the keychain.
    func loadAccess() throws -> AWSAccess? {
        guard let pair = try credentials.load() else { return nil }
        let region = defaults.string(forKey: Self.regionKey) ?? ""
        return AWSAccess(
            accessKeyID: pair.accessKeyID, secretAccessKey: pair.secret,
            region: region.isEmpty ? "us-east-1" : region)
    }

    /// Saves trimmed values. Callers are expected to have run `validate` first.
    func save(_ s: AWSSettings) throws {
        try credentials.save(
            accessKeyID: s.accessKeyID.trimmed, secret: s.secretAccessKey.trimmed)
        defaults.set(s.region.trimmed, forKey: Self.regionKey)
        defaults.set(s.bucket.trimmed, forKey: Self.bucketKey)
        defaults.set(AWSSettings.normalizedPrefix(s.uploadsPrefix), forKey: Self.prefixKey)
    }

    /// The first problem as a one-line message, or nil when the settings are usable.
    static func validate(_ s: AWSSettings) -> String? {
        if s.accessKeyID.trimmed.isEmpty { return "Enter the access key ID." }
        if s.secretAccessKey.trimmed.isEmpty { return "Enter the secret access key." }
        if s.region.trimmed.isEmpty { return "Enter the region." }
        if s.bucket.trimmed.isEmpty { return "Enter the bucket name." }
        return nil
    }

    private var storedPrefix: String {
        AWSSettings.normalizedPrefix(defaults.string(forKey: Self.prefixKey) ?? "")
    }
}

extension String {
    fileprivate var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
