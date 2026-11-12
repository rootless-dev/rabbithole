import Foundation
import Security
import Synchronization
import XCTest

@testable import Rabbithole

private final class InMemoryCredentialStore: CredentialStore, Sendable {
    private let stored = Mutex<(accessKeyID: String, secret: String)?>(nil)

    func load() throws -> (accessKeyID: String, secret: String)? {
        stored.withLock { $0 }
    }

    func save(accessKeyID: String, secret: String) throws {
        stored.withLock { $0 = (accessKeyID, secret) }
    }
}

final class SettingsStoreTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "com.rabbithole.app.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private let sample = AWSSettings(
        accessKeyID: "AKIAEXAMPLEKEYID",
        secretAccessKey: "example-secret-value-123",
        region: "us-east-1",
        bucket: "my-backup-bucket"
    )

    func testLoadReturnsNilWhenNothingSaved() throws {
        let store = SettingsStore(credentials: InMemoryCredentialStore(), defaults: defaults)
        XCTAssertNil(try store.load())
    }

    func testSaveThenLoadRoundTrips() throws {
        let store = SettingsStore(credentials: InMemoryCredentialStore(), defaults: defaults)
        try store.save(sample)
        XCTAssertEqual(try store.load(), sample)
    }

    func testSecretNeverWrittenToDefaults() throws {
        let store = SettingsStore(credentials: InMemoryCredentialStore(), defaults: defaults)
        try store.save(sample)
        let domain = defaults.persistentDomain(forName: suiteName) ?? [:]
        XCTAssertFalse(domain.isEmpty)
        for value in domain.values {
            XCTAssertNotEqual(value as? String, sample.accessKeyID)
            XCTAssertNotEqual(value as? String, sample.secretAccessKey)
        }
        // The quick uploads folder became a setting; it is not secret and lives here too.
        XCTAssertEqual(Set(domain.keys), ["region", "bucket", "quickUploadsPrefix"])
    }

    func testQuickUploadsFolderIsSavedNormalizedAndDefaultsWhenMissing() throws {
        let store = SettingsStore(credentials: InMemoryCredentialStore(), defaults: defaults)
        var settings = sample
        settings.uploadsPrefix = " /inbox/2026// "
        try store.save(settings)
        XCTAssertEqual(try store.load()?.uploadsPrefix, "inbox/2026/")
        XCTAssertEqual(store.loadDestination().uploadsPrefix, "inbox/2026/")

        defaults.removeObject(forKey: "quickUploadsPrefix")
        XCTAssertEqual(try store.load()?.uploadsPrefix, "quick-uploads/")
        XCTAssertEqual(AWSSettings.normalizedPrefix("  "), "quick-uploads/")
    }

    func testDestinationIsReadWithoutCredentials() {
        defaults.set("eu-west-1", forKey: "region")
        let store = SettingsStore(credentials: InMemoryCredentialStore(), defaults: defaults)
        XCTAssertEqual(
            store.loadDestination(),
            SettingsStore.Destination(region: "eu-west-1", bucket: "", uploadsPrefix: "quick-uploads/"))
    }

    func testLoadReturnsNilWhenKeychainMissing() throws {
        defaults.set("us-east-1", forKey: "region")
        defaults.set("my-backup-bucket", forKey: "bucket")
        let store = SettingsStore(credentials: InMemoryCredentialStore(), defaults: defaults)
        XCTAssertNil(try store.load())
    }

    func testValidateRejectsEmptyFields() {
        XCTAssertNil(SettingsStore.validate(sample))
        var s = sample
        s.accessKeyID = ""
        XCTAssertNotNil(SettingsStore.validate(s))
        s = sample
        s.secretAccessKey = ""
        XCTAssertNotNil(SettingsStore.validate(s))
        s = sample
        s.region = ""
        XCTAssertNotNil(SettingsStore.validate(s))
        s = sample
        s.bucket = ""
        XCTAssertNotNil(SettingsStore.validate(s))
    }

    func testValidateTrimsWhitespace() {
        var s = sample
        s.bucket = "   \n"
        XCTAssertNotNil(SettingsStore.validate(s))
        s = sample
        s.region = " us-east-1 "
        XCTAssertNil(SettingsStore.validate(s))
    }

    // MARK: - Real keychain (unique service per test, removed in teardown)

    private func makeServiceName() -> String {
        let service = "com.rabbithole.app.tests.\(UUID().uuidString)"
        // Registered before the first keychain call so it runs even if an assertion fails.
        addTeardownBlock { KeychainCredentialStore.deleteAll(service: service) }
        return service
    }

    /// Runs synchronous keychain work on a background thread and gives up waiting after
    /// `timeout` seconds. A call blocked by a permission dialog is abandoned, not
    /// cancelled; the test fails instead of hanging.
    private func runBounded<T: Sendable>(
        timeout: TimeInterval = 20, _ work: @escaping @Sendable () throws -> T
    ) throws -> T {
        let result = Mutex<Result<T, Error>?>(nil)
        let finished = expectation(description: "keychain work finished")
        DispatchQueue.global().async {
            result.withLock { $0 = Result { try work() } }
            finished.fulfill()
        }
        wait(for: [finished], timeout: timeout)
        guard let outcome = result.withLock({ $0 }) else {
            throw XCTSkip("unreachable")
        }
        return try outcome.get()
    }

    func testKeychainSaveTwiceLoadsSecondPairExactly() throws {
        let keychain = KeychainCredentialStore(service: makeServiceName())
        let loaded = try runBounded { () -> (String, String)? in
            XCTAssertNil(try keychain.load())
            try keychain.save(accessKeyID: "AKIATESTKEY", secret: "first-secret")
            try keychain.save(accessKeyID: "AKIATESTKEY2", secret: "second-secret")
            return try keychain.load().map { ($0.accessKeyID, $0.secret) }
        }
        XCTAssertEqual(loaded?.0, "AKIATESTKEY2")
        XCTAssertEqual(loaded?.1, "second-secret")
    }

    func testFailedKeychainSaveKeepsPreviousPair() throws {
        let service = makeServiceName()
        let good = KeychainCredentialStore(service: service)
        let failing = KeychainCredentialStore(
            service: service, api: UpdateFailingKeychainAPI(base: SystemKeychainAPI()))
        let loaded = try runBounded { () -> (String, String)? in
            try good.save(accessKeyID: "AKIAOLD", secret: "old-secret")
            XCTAssertThrowsError(try failing.save(accessKeyID: "AKIANEW", secret: "new-secret"))
            return try good.load().map { ($0.accessKeyID, $0.secret) }
        }
        XCTAssertEqual(loaded?.0, "AKIAOLD")
        XCTAssertEqual(loaded?.1, "old-secret")
    }

    func testUndecodableKeychainItemMakesLoadThrow() throws {
        let service = makeServiceName()
        let keychain = KeychainCredentialStore(service: service)
        let status = try runBounded { () -> OSStatus in
            SecItemAdd(
                [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service,
                    kSecAttrAccount as String: KeychainCredentialStore.account,
                    kSecValueData as String: Data("not json".utf8),
                ] as CFDictionary, nil)
        }
        XCTAssertEqual(status, errSecSuccess)
        XCTAssertThrowsError(try runBounded { try keychain.load() }) { error in
            XCTAssertTrue(error is KeychainError)
            XCTAssertFalse("\(error)".contains("not json"))
        }
    }
}

/// Delegates to the real keychain but fails every update, simulating a write error.
private struct UpdateFailingKeychainAPI: KeychainItemAPI {
    let base: KeychainItemAPI

    func copyMatching(_ query: [String: Any]) -> (status: OSStatus, data: Data?) {
        base.copyMatching(query)
    }
    func update(_ query: [String: Any], with attributes: [String: Any]) -> OSStatus {
        errSecInteractionNotAllowed
    }
    func add(_ attributes: [String: Any]) -> OSStatus { base.add(attributes) }
    func delete(_ query: [String: Any]) -> OSStatus { base.delete(query) }
}
