import Foundation
import Security

/// Where the AWS access key ID and secret live. Implementations must keep both
/// out of files, preferences and logs.
protocol CredentialStore: Sendable {
    /// Returns the saved pair, or nil when nothing (or only half a pair) is saved.
    func load() throws -> (accessKeyID: String, secret: String)?
    func save(accessKeyID: String, secret: String) throws
}

/// Keychain failure. Carries only the OS status, never item contents.
struct KeychainError: Error, CustomStringConvertible {
    let status: OSStatus

    var description: String {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
        return "Keychain error \(status): \(message)"
    }
}

/// Generic password items in the login keychain, one per credential part.
struct KeychainCredentialStore: CredentialStore {
    static let accessKeyAccount = "aws-access-key-id"
    static let secretAccount = "aws-secret-access-key"

    let service: String

    init(service: String = "com.rabbithole.app") {
        self.service = service
    }

    func load() throws -> (accessKeyID: String, secret: String)? {
        guard let accessKeyID = try read(account: Self.accessKeyAccount),
            let secret = try read(account: Self.secretAccount)
        else { return nil }
        return (accessKeyID, secret)
    }

    func save(accessKeyID: String, secret: String) throws {
        try write(accessKeyID, account: Self.accessKeyAccount)
        try write(secret, account: Self.secretAccount)
    }

    /// Removes both items stored under `service`. Used for test cleanup.
    static func deleteAll(service: String) {
        for account in [accessKeyAccount, secretAccount] {
            SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
        }
    }

    private static func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private func read(account: String) throws -> String? {
        var query = Self.baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        guard let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Update-or-add: updates the existing item, adding it when it does not exist yet.
    private func write(_ value: String, account: String) throws {
        let query = Self.baseQuery(service: service, account: account)
        let data = Data(value.utf8)
        let update = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }
}
