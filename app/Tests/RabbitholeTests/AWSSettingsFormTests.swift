import Foundation
import Synchronization
import XCTest

@testable import Rabbithole

/// Records whether each call ran on the main thread and can fail on demand.
private final class RecordingCredentialStore: CredentialStore, Sendable {
    private struct State {
        var pair: (accessKeyID: String, secret: String)?
        var mainThreadCalls = 0
        var loadError = false
        var saveError = false
    }
    private let state = Mutex(State())

    init(pair: (accessKeyID: String, secret: String)? = nil, loadError: Bool = false, saveError: Bool = false) {
        state.withLock {
            $0.pair = pair
            $0.loadError = loadError
            $0.saveError = saveError
        }
    }

    var mainThreadCalls: Int { state.withLock { $0.mainThreadCalls } }
    var stored: (accessKeyID: String, secret: String)? { state.withLock { $0.pair } }

    func load() throws -> (accessKeyID: String, secret: String)? {
        try state.withLock {
            if Thread.isMainThread { $0.mainThreadCalls += 1 }
            if $0.loadError { throw KeychainError(reason: "simulated") }
            return $0.pair
        }
    }

    func save(accessKeyID: String, secret: String) throws {
        try state.withLock {
            if Thread.isMainThread { $0.mainThreadCalls += 1 }
            if $0.saveError { throw KeychainError(reason: "simulated") }
            $0.pair = (accessKeyID, secret)
        }
    }
}

@MainActor
final class AWSSettingsFormTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suiteName = "com.rabbithole.app.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        // Settings load only when region and bucket are present as well.
        defaults.set("us-east-1", forKey: "region")
        defaults.set("bucket", forKey: "bucket")
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
    }

    private func candidate(secret: String = "new-secret") -> AWSSettings {
        AWSSettings(accessKeyID: "AKIAEXAMPLE", secretAccessKey: secret, region: "us-east-1", bucket: "bucket")
    }

    func testLoadAndSaveNeverTouchTheKeychainOnTheMainThread() async throws {
        let credentials = RecordingCredentialStore(pair: ("AKIAOLD", "old-secret"))
        let store = SettingsStore(credentials: credentials, defaults: defaults)

        _ = try await AWSSettingsForm.load(store: store)
        _ = await AWSSettingsForm.save(candidate(secret: ""), keepStoredSecret: true, store: store)

        XCTAssertEqual(credentials.mainThreadCalls, 0)
    }

    func testSaveStoresTheForm() async {
        let credentials = RecordingCredentialStore()
        let store = SettingsStore(credentials: credentials, defaults: defaults)

        let result = await AWSSettingsForm.save(candidate(), keepStoredSecret: false, store: store)

        XCTAssertEqual(result, .saved(candidate()))
        XCTAssertEqual(credentials.stored?.secret, "new-secret")
    }

    func testEmptySecretKeepsTheStoredSecret() async {
        let credentials = RecordingCredentialStore(pair: ("AKIAOLD", "old-secret"))
        let store = SettingsStore(credentials: credentials, defaults: defaults)

        let result = await AWSSettingsForm.save(candidate(secret: ""), keepStoredSecret: true, store: store)

        XCTAssertEqual(result, .saved(candidate(secret: "old-secret")))
        XCTAssertEqual(credentials.stored?.secret, "old-secret")
        XCTAssertEqual(credentials.stored?.accessKeyID, "AKIAEXAMPLE")
    }

    func testEmptySecretWithNothingStoredAsksForTheSecret() async {
        let store = SettingsStore(credentials: RecordingCredentialStore(), defaults: defaults)

        let result = await AWSSettingsForm.save(candidate(secret: ""), keepStoredSecret: false, store: store)

        XCTAssertEqual(result, .failed("Enter the secret access key."))
    }

    func testUnreadableStoredSecretShowsAFixedMessage() async {
        let store = SettingsStore(credentials: RecordingCredentialStore(loadError: true), defaults: defaults)

        let result = await AWSSettingsForm.save(candidate(secret: ""), keepStoredSecret: true, store: store)

        XCTAssertEqual(result, .failed("Could not read the saved secret."))
    }

    func testFailedSaveShowsAFixedMessage() async {
        let store = SettingsStore(credentials: RecordingCredentialStore(saveError: true), defaults: defaults)

        let result = await AWSSettingsForm.save(candidate(), keepStoredSecret: false, store: store)

        XCTAssertEqual(result, .failed("Could not save the settings."))
    }

    func testInvalidFormReportsTheFirstProblemWithoutSaving() async {
        let credentials = RecordingCredentialStore()
        let store = SettingsStore(credentials: credentials, defaults: defaults)
        var form = candidate()
        form.region = "  "

        let result = await AWSSettingsForm.save(form, keepStoredSecret: false, store: store)

        XCTAssertEqual(result, .failed("Enter the region."))
        XCTAssertNil(credentials.stored)
    }
}
