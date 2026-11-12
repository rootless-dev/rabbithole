import Foundation
import Security

/// Where the AWS access key ID and secret live. Implementations must keep both
/// out of files, preferences and logs.
protocol CredentialStore: Sendable {
    /// Returns the saved pair, or nil when nothing is saved.
    func load() throws -> (accessKeyID: String, secret: String)?
    func save(accessKeyID: String, secret: String) throws
}

/// Keychain failure. Carries only a status or a fixed reason, never item contents.
struct KeychainError: Error, CustomStringConvertible {
    let description: String

    init(status: OSStatus) {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
        description = "Keychain error \(status): \(message)"
    }

    init(reason: String) {
        description = "Keychain error: \(reason)"
    }
}

/// The raw Security framework calls, behind a seam so write failures can be simulated.
protocol KeychainItemAPI: Sendable {
    func copyMatching(_ query: [String: Any]) -> (status: OSStatus, data: Data?)
    func update(_ query: [String: Any], with attributes: [String: Any]) -> OSStatus
    func add(_ attributes: [String: Any]) -> OSStatus
    func delete(_ query: [String: Any]) -> OSStatus
}

struct SystemKeychainAPI: KeychainItemAPI {
    func copyMatching(_ query: [String: Any]) -> (status: OSStatus, data: Data?) {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result as? Data)
    }

    func update(_ query: [String: Any], with attributes: [String: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
        SecItemAdd(attributes as CFDictionary, nil)
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        SecItemDelete(query as CFDictionary)
    }
}

/// Both credentials live in ONE generic password item (a JSON-encoded pair), so a save
/// either replaces the whole pair or leaves the previous one untouched.
struct KeychainCredentialStore: CredentialStore {
    static let account = "aws-credentials"

    private struct Pair: Codable {
        let accessKeyID: String
        let secret: String
    }

    let service: String
    private let api: KeychainItemAPI

    init(service: String = "com.rabbithole.app", api: KeychainItemAPI = SystemKeychainAPI()) {
        self.service = service
        self.api = api
    }

    func load() throws -> (accessKeyID: String, secret: String)? {
        var query = Self.baseQuery(service: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, data) = api.copyMatching(query)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        guard let data, let pair = try? JSONDecoder().decode(Pair.self, from: data) else {
            throw KeychainError(reason: "the stored credentials could not be decoded")
        }
        return (pair.accessKeyID, pair.secret)
    }

    /// Update-or-add of the single item.
    func save(accessKeyID: String, secret: String) throws {
        let data = try JSONEncoder().encode(Pair(accessKeyID: accessKeyID, secret: secret))
        let query = Self.baseQuery(service: service)
        var status = api.update(query, with: [kSecValueData as String: data])
        if status == errSecItemNotFound {
            var attributes = query
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            status = api.add(attributes)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    /// Removes the item stored under `service`. Used for test cleanup.
    static func deleteAll(service: String) {
        _ = SystemKeychainAPI().delete(baseQuery(service: service))
    }

    private static func baseQuery(service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
