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
        XCTAssertEqual(Set(domain.keys), ["region", "bucket"])
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

    /// Talks to the real keychain under a service name unique to this run, so the
    /// user's own entries are never read or modified. Items are removed in tearDown
    /// even when an assertion fails.
    func testKeychainRoundTrip() async throws {
        let service = "com.rabbithole.app.tests.\(UUID().uuidString)"
        addTeardownBlock { KeychainCredentialStore.deleteAll(service: service) }
        let keychain = KeychainCredentialStore(service: service)

        // Bounded: a keychain permission dialog would otherwise hang the run.
        let outcome = await withTaskGroup(of: String.self) { group in
            group.addTask {
                do {
                    XCTAssertNil(try keychain.load())
                    try keychain.save(accessKeyID: "AKIATESTKEY", secret: "first-secret")
                    try keychain.save(accessKeyID: "AKIATESTKEY2", secret: "second-secret")
                    let loaded = try keychain.load()
                    XCTAssertEqual(loaded?.accessKeyID, "AKIATESTKEY2")
                    XCTAssertEqual(loaded?.secret, "second-secret")
                    return "done"
                } catch {
                    return "error: \(error)"
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(20))
                return "timeout"
            }
            let first = await group.next() ?? "none"
            group.cancelAll()
            return first
        }
        XCTAssertEqual(outcome, "done")
    }
}
