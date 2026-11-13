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

/// The calls most fakes of the test target have nothing to say about. A fake that cares
/// about one declares it itself; the app's own client implements every one.
extension DaemonClient {
    func setOptions(_ options: DaemonOptions) async throws {}
    func pause(uploadID: String) async throws {}
    func resume(uploadID: String) async throws {}
    func cancel(uploadID: String) async throws {}
    func startDownload(uploadID: String, fileIndexes: [Int], destinationDir: String) async throws -> String { "dl" }
    func cancelDownload(downloadID: String) async throws {}
    func watchDownloads() -> AsyncThrowingStream<DownloadSnapshot, Error> {
        AsyncThrowingStream { _ in }
    }
    func listBuckets(_ access: AWSAccess) async throws -> [Bucket] { [] }
    func createBucket(_ access: AWSAccess, name: String) async throws {}
}

final class StubDaemonClient: DaemonClient, Sendable {
    /// A call about one upload or download, as the daemon would receive it.
    enum Call: Hashable {
        case pause(String)
        case resume(String)
        case cancel(String)
        case startDownload(uploadID: String, fileIndexes: [Int], destinationDir: String)
        case cancelDownload(String)
        case listBuckets(region: String)
        case createBucket(name: String, region: String)
    }

    private struct Calls {
        var log: [Call] = []
        var options: [DaemonOptions] = []
        var actionError: DaemonError?
        var buckets: [Bucket] = []
        var listError: DaemonError?
        var createError: DaemonError?
        var nextDownload = 1
        var requests: [EnqueueRequest] = []
        var nextID = 1
        var enqueueError: DaemonError?
        var files: [String: [FileSnapshot]] = [:]
        var filesError: DaemonError?
        var watchedFiles: [String] = []
        var retries: [Retry] = []
        var retryError: DaemonError?
        var removals: [Removal] = []
        var removeError: DaemonError?
        var holdRemovals = false
        var heldRemovals: [CheckedContinuation<Void, Never>] = []
    }

    struct Retry: Equatable {
        let uploadID: String
        let fileIndexes: [Int]
    }

    struct Removal: Equatable {
        let uploadID: String
        let fileIndexes: [Int]
        let deleteFromBucket: Bool
    }

    private let calls = Mutex(Calls())

    /// Every pause, resume, cancel, download and bucket call, in order, failed ones included.
    var log: [Call] { calls.withLock { $0.log } }
    /// Every SetOptions call, in order.
    var options: [DaemonOptions] { calls.withLock { $0.options } }

    /// Pause, resume, cancel and the download calls fail with `error` until it is nil.
    func failActions(with error: DaemonError?) { calls.withLock { $0.actionError = error } }
    func setBuckets(_ buckets: [Bucket]) { calls.withLock { $0.buckets = buckets } }
    func failList(with error: DaemonError?) { calls.withLock { $0.listError = error } }
    func failCreate(with error: DaemonError?) { calls.withLock { $0.createError = error } }

    private func record(_ call: Call) throws {
        try calls.withLock { state in
            state.log.append(call)
            if let error = state.actionError { throw error }
        }
    }

    func setOptions(_ options: DaemonOptions) async throws {
        calls.withLock { $0.options.append(options) }
    }

    func pause(uploadID: String) async throws { try record(.pause(uploadID)) }
    func resume(uploadID: String) async throws { try record(.resume(uploadID)) }
    func cancel(uploadID: String) async throws { try record(.cancel(uploadID)) }

    func startDownload(uploadID: String, fileIndexes: [Int], destinationDir: String) async throws -> String {
        try record(.startDownload(uploadID: uploadID, fileIndexes: fileIndexes, destinationDir: destinationDir))
        return calls.withLock { state in
            defer { state.nextDownload += 1 }
            return "dl-\(state.nextDownload)"
        }
    }

    func cancelDownload(downloadID: String) async throws { try record(.cancelDownload(downloadID)) }

    func listBuckets(_ access: AWSAccess) async throws -> [Bucket] {
        try calls.withLock { state in
            state.log.append(.listBuckets(region: access.region))
            if let error = state.listError { throw error }
            return state.buckets
        }
    }

    func createBucket(_ access: AWSAccess, name: String) async throws {
        try calls.withLock { state in
            state.log.append(.createBucket(name: name, region: access.region))
            if let error = state.createError { throw error }
            state.buckets.append(Bucket(name: name, region: access.region))
        }
    }

    /// Every RetryUpload call, in order, including the ones that were made to fail.
    var retries: [Retry] { calls.withLock { $0.retries } }
    /// Every RemoveUpload call, in order, including the ones that were made to fail.
    var removals: [Removal] { calls.withLock { $0.removals } }

    func failRetry(with error: DaemonError?) {
        calls.withLock { $0.retryError = error }
    }

    func failRemove(with error: DaemonError?) {
        calls.withLock { $0.removeError = error }
    }

    /// Remove calls do not answer until `releaseRemovals()`, like a daemon busy deleting.
    func holdRemovals() {
        calls.withLock { $0.holdRemovals = true }
    }

    func releaseRemovals() {
        let held = calls.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.holdRemovals = false
            defer { state.heldRemovals = [] }
            return state.heldRemovals
        }
        for continuation in held { continuation.resume() }
    }

    /// One request per upload, as the daemon would receive them.
    var requests: [EnqueueRequest] { calls.withLock { $0.requests } }
    /// The paths of every request, flattened.
    var enqueued: [String] { requests.flatMap(\.paths) }
    /// The upload ids whose files were asked for, in order.
    var watchedFiles: [String] { calls.withLock { $0.watchedFiles } }

    func failEnqueue(with error: DaemonError?) {
        calls.withLock { $0.enqueueError = error }
    }

    /// What the files stream of an upload delivers before it ends.
    func setFiles(_ files: [FileSnapshot], of uploadID: String) {
        calls.withLock { $0.files[uploadID] = files }
    }

    func failFiles(with error: DaemonError?) {
        calls.withLock { $0.filesError = error }
    }

    func configure(_ settings: AWSSettings) async throws {}

    func enqueue(_ request: EnqueueRequest) async throws -> String {
        try calls.withLock { state in
            if let error = state.enqueueError { throw error }
            state.requests.append(request)
            defer { state.nextID += 1 }
            return "up-\(state.nextID)"
        }
    }

    func watch() -> AsyncThrowingStream<UploadSnapshot, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func watchFiles(uploadID: String) -> AsyncThrowingStream<FileSnapshot, Error> {
        let (files, error) = calls.withLock { state in
            state.watchedFiles.append(uploadID)
            return (state.files[uploadID] ?? [], state.filesError)
        }
        return AsyncThrowingStream { continuation in
            for file in files { continuation.yield(file) }
            continuation.finish(throwing: error)
        }
    }

    func retry(uploadID: String, fileIndexes: [Int]) async throws {
        try calls.withLock { state in
            state.retries.append(Retry(uploadID: uploadID, fileIndexes: fileIndexes))
            if let error = state.retryError { throw error }
        }
    }

    func remove(uploadID: String, fileIndexes: [Int], deleteFromBucket: Bool) async throws {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let hold = calls.withLock { state -> Bool in
                state.removals.append(
                    Removal(uploadID: uploadID, fileIndexes: fileIndexes, deleteFromBucket: deleteFromBucket))
                if state.holdRemovals { state.heldRemovals.append(continuation) }
                return state.holdRemovals
            }
            if !hold { continuation.resume() }
        }
        if let error = calls.withLock({ $0.removeError }) { throw error }
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

    /// A folder handed over as one upload; `finished` and `failed` count its files.
    static func folder(
        _ id: String, _ name: String, in parent: String = "/Users/someone/Pictures",
        files: Int, finished: Int = 0, failed: Int = 0, total: Int64, sent: Int64 = 0,
        _ state: UploadState, error: String = ""
    ) -> UploadSnapshot {
        UploadSnapshot(
            id: id, fileName: name, localPath: "\(parent)/\(name)", objectKey: "quick-uploads/\(name)/",
            bytesTotal: total, bytesSent: sent, state: state, errorMessage: error, kind: .folder,
            rootPaths: ["\(parent)/\(name)"], filesTotal: files, filesFinished: finished, filesFailed: failed)
    }

    /// Several items handed over as one upload, named after the first.
    static func several(
        _ id: String, _ paths: [String], files: Int? = nil, finished: Int = 0, failed: Int = 0,
        total: Int64, sent: Int64 = 0, _ state: UploadState, error: String = ""
    ) -> UploadSnapshot {
        UploadSnapshot(
            id: id, fileName: (paths[0] as NSString).lastPathComponent, localPath: paths[0], objectKey: "",
            bytesTotal: total, bytesSent: sent, state: state, errorMessage: error, kind: .multiple,
            rootPaths: paths, filesTotal: files ?? paths.count, filesFinished: finished, filesFailed: failed)
    }
}

extension FileSnapshot {
    static func make(
        _ index: Int, _ path: String, of uploadID: String = "up-1", in folder: String = "/Users/someone/Pictures",
        total: Int64, sent: Int64 = 0, _ state: UploadState, error: String = ""
    ) -> FileSnapshot {
        FileSnapshot(
            uploadID: uploadID, index: index, relativePath: path, localPath: "\(folder)/\(path)",
            objectKey: "quick-uploads/\(path)", bytesTotal: total, bytesSent: sent, state: state,
            errorMessage: error)
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
