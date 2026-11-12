import AppKit
import Foundation
import SwiftUI
import Synchronization
import XCTest

@testable import Rabbithole

final class StubCredentialStore: CredentialStore, Sendable {
    private let stored = Mutex<(accessKeyID: String, secret: String)?>(nil)
    private let failing = Mutex(false)

    func failReads() { failing.withLock { $0 = true } }

    func load() throws -> (accessKeyID: String, secret: String)? {
        if failing.withLock({ $0 }) { throw KeychainError(reason: "simulated") }
        return stored.withLock { $0 }
    }

    func save(accessKeyID: String, secret: String) throws {
        stored.withLock { $0 = (accessKeyID, secret) }
    }
}

final class StubDaemonClient: DaemonClient, Sendable {
    private struct Calls {
        var enqueued: [String] = []
        var nextID = 1
        var enqueueError: DaemonError?
    }

    private let calls = Mutex(Calls())

    var enqueued: [String] { calls.withLock { $0.enqueued } }

    func failEnqueue(with error: DaemonError?) {
        calls.withLock { $0.enqueueError = error }
    }

    func configure(_ settings: AWSSettings) async throws {}

    func enqueue(localPath: String) async throws -> String {
        try calls.withLock { state in
            if let error = state.enqueueError { throw error }
            state.enqueued.append(localPath)
            defer { state.nextID += 1 }
            return "up-\(state.nextID)"
        }
    }

    func watch() -> AsyncThrowingStream<UploadSnapshot, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

final class StubLoginItemService: LoginItemService, Sendable {
    private let state = Mutex<(enabled: Bool, refuses: Bool)>((false, false))

    init(enabled: Bool = false, refuses: Bool = false) {
        state.withLock { $0 = (enabled, refuses) }
    }

    func isEnabled() -> Bool { state.withLock { $0.enabled } }

    func setEnabled(_ enabled: Bool) throws {
        try state.withLock { state in
            if state.refuses { throw KeychainError(reason: "refused") }
            state.enabled = enabled
        }
    }
}

/// A clock tests can move by hand.
@MainActor
final class TestClock {
    var now: Date

    init(_ now: Date = Date(timeIntervalSince1970: 1_794_500_000)) {
        self.now = now
    }

    func advance(_ seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
    }
}

extension UploadSnapshot {
    static func make(
        _ id: String, _ name: String, in folder: String = "/Users/someone/Documents",
        total: Int64, sent: Int64 = 0, _ state: UploadState, error: String = ""
    ) -> UploadSnapshot {
        UploadSnapshot(
            id: id, fileName: name, localPath: "\(folder)/\(name)",
            objectKey: state == .queued ? "" : "quick-uploads/\(name)",
            bytesTotal: total, bytesSent: sent, state: state, errorMessage: error)
    }
}

/// A preferences domain that exists only for one test.
final class ScratchDefaults {
    let name = "com.rabbithole.app.tests.\(UUID().uuidString)"
    let defaults: UserDefaults

    init() {
        defaults = UserDefaults(suiteName: name)!
    }

    deinit {
        defaults.removePersistentDomain(forName: name)
    }
}

/// Draws a SwiftUI view offscreen and writes it as a PNG under `build/ui/app`, so the app's
/// screens can be compared with the approved mockups without screen recording.
@MainActor
enum Offscreen {
    static let directory: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { url.deleteLastPathComponent() }  // repository root
        return url.appending(path: "build/ui/app", directoryHint: .isDirectory)
    }()

    /// Renders `view` in the given appearance. With `size` nil the view's own size is used.
    @discardableResult
    static func render(_ view: some View, size: CGSize? = nil, dark: Bool, name: String) throws -> NSBitmapImageRep {
        let appearance = try XCTUnwrap(NSAppearance(named: dark ? .darkAqua : .aqua))
        let hosting = NSHostingView(
            rootView: view.environment(\.flatMaterials, true).environment(\.colorScheme, dark ? .dark : .light))
        hosting.appearance = appearance
        let size = size ?? hosting.fittingSize
        // The window must keep the size asked for, not the view's ideal size.
        hosting.sizingOptions = []
        let frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.setContentSize(size)
        hosting.frame = frame
        // Let tasks started by the views (thumbnails, reloads) land before drawing.
        for _ in 0..<2 {
            hosting.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.08))
        }
        hosting.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: directory.appending(path: "\(name)-\(dark ? "dark" : "light").png"))
        window.contentView = nil
        return rep
    }
}
