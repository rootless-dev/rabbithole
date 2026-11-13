import Foundation
import Observation

/// The files of one upload in the order the detail lists them: the ones being sent, then
/// failed, waiting and finished, each group in the files' own order.
///
/// A folder can hold tens of thousands of files, so nothing here sorts the whole list: each
/// state keeps its files' indexes in ascending order and a file that changes state moves
/// from one group to another by binary search.
struct UploadFileList: Sendable {
    /// The groups in the order they are listed.
    static let stateOrder: [UploadState] = [.uploading, .failed, .queued, .finished]

    private var files: [Int: FileSnapshot] = [:]
    private var groups: [UploadState: [Int]] = [:]

    var count: Int { files.count }
    var isEmpty: Bool { files.isEmpty }

    subscript(index: Int) -> FileSnapshot? { files[index] }

    /// Stores the latest state of a file. Returns true when the listing changed: the file is
    /// new, moved to another state or left the upload. Progress alone returns false.
    @discardableResult
    mutating func apply(_ file: FileSnapshot) -> Bool {
        if file.removed { return remove(file.index) }
        let previous = files.updateValue(file, forKey: file.index)
        if let previous {
            guard previous.state != file.state else { return false }
            remove(file.index, from: previous.state)
        }
        insert(file.index, into: file.state)
        return true
    }

    /// Takes a file out of the listing. Returns false when it was not there.
    @discardableResult
    mutating func remove(_ index: Int) -> Bool {
        guard let file = files.removeValue(forKey: index) else { return false }
        remove(index, from: file.state)
        return true
    }

    /// The indexes of the files a state tab shows, in listing order.
    func indexes(_ filter: UploadStateFilter) -> [Int] {
        switch filter {
        case .all: Self.stateOrder.flatMap { groups[$0] ?? [] }
        case .inProgress: groups[.uploading] ?? []
        case .waiting: groups[.queued] ?? []
        case .finished: groups[.finished] ?? []
        case .failed: groups[.failed] ?? []
        }
    }

    func count(_ state: UploadState) -> Int { groups[state]?.count ?? 0 }

    /// The daemon is gone: files that were waiting or being sent will not be sent.
    /// Returns true when any file changed.
    @discardableResult
    mutating func interrupt(message: String) -> Bool {
        let active = (groups[.uploading] ?? []) + (groups[.queued] ?? [])
        for index in active {
            guard let file = files[index] else { continue }
            apply(
                FileSnapshot(
                    uploadID: file.uploadID, index: file.index, relativePath: file.relativePath,
                    localPath: file.localPath, objectKey: file.objectKey, bytesTotal: file.bytesTotal,
                    bytesSent: file.bytesSent, state: .failed, errorMessage: message))
        }
        return !active.isEmpty
    }

    private mutating func insert(_ index: Int, into state: UploadState) {
        let position = Self.position(of: index, in: groups[state] ?? [])
        groups[state, default: []].insert(index, at: position)
    }

    private mutating func remove(_ index: Int, from state: UploadState) {
        // The group is only borrowed for the search, so removing does not copy it.
        guard let position = Self.exactPosition(of: index, in: groups[state] ?? []) else { return }
        groups[state]?.remove(at: position)
    }

    private static func exactPosition(of index: Int, in sorted: [Int]) -> Int? {
        let position = position(of: index, in: sorted)
        return position < sorted.count && sorted[position] == index ? position : nil
    }

    /// Where `index` is, or would be inserted, in an ascending array.
    private static func position(of index: Int, in sorted: [Int]) -> Int {
        var low = 0
        var high = sorted.count
        while low < high {
            let middle = (low + high) / 2
            if sorted[middle] < index { low = middle + 1 } else { high = middle }
        }
        return low
    }
}

/// The observable holder of the file list the upload detail shows. It follows the daemon's
/// files stream only while the detail asks it to, and tells the views about changes at most
/// once per `publishInterval`, however fast the files of a big folder come in.
///
/// Views depend on two separate counters, so progress redraws the visible rows without
/// rebuilding the list, and the list is rebuilt only when a file appears or changes state.
@MainActor
@Observable
final class UploadFilesModel {
    enum Phase: Equatable, Sendable {
        /// Nothing was asked for, or the files are still on their way.
        case waiting
        /// The stream delivered files.
        case loaded
        /// The daemon could not give the files of this upload.
        case unavailable
    }

    private(set) var phase: Phase = .waiting
    /// Changes when a file appears or moves to another state.
    private var orderVersion = 0
    /// Changes when anything about any file changes.
    private var contentVersion = 0

    @ObservationIgnored private(set) var uploadID: String?
    @ObservationIgnored private var list = UploadFileList()
    @ObservationIgnored private var orderChanged = false
    @ObservationIgnored private var contentChanged = false
    @ObservationIgnored private var publishTask: Task<Void, Never>?
    @ObservationIgnored private let publishInterval: Duration

    init(publishInterval: Duration = .milliseconds(100)) {
        self.publishInterval = publishInterval
    }

    /// How many files are known so far.
    var count: Int {
        _ = orderVersion
        return list.count
    }

    /// The files a state tab shows, as indexes to ask `file(at:)` for.
    func indexes(_ filter: UploadStateFilter) -> [Int] {
        _ = orderVersion
        return list.indexes(filter)
    }

    func file(at index: Int) -> FileSnapshot? {
        _ = contentVersion
        return list[index]
    }

    /// How a `follow` call ended.
    enum FollowEnd: Equatable, Sendable {
        /// The stream closed by itself, or the call was cancelled or replaced.
        case done
        /// The daemon went away while streaming: asking again later can work.
        case interrupted
        /// The daemon does not know the upload.
        case unknownUpload
    }

    /// Reads the files stream of one upload until the calling task is cancelled or the
    /// stream ends. Files already known for the same upload stay on screen meanwhile; the
    /// stream sends every file again and brings them up to date.
    @discardableResult
    func follow(uploadID: String, stream: AsyncThrowingStream<FileSnapshot, Error>) async -> FollowEnd {
        // Replaced before it started: the newer call owns the list.
        guard !Task.isCancelled else { return .done }
        var end = FollowEnd.done
        if self.uploadID != uploadID {
            self.uploadID = uploadID
            list = UploadFileList()
            phase = .waiting
            orderVersion += 1
            contentVersion += 1
        }
        do {
            for try await file in stream {
                guard !Task.isCancelled, self.uploadID == uploadID else { return .done }
                if list.apply(file) { orderChanged = true }
                contentChanged = true
                schedulePublish()
            }
        } catch {
            if !Task.isCancelled {
                // What a restarted daemon reports for these files is the same failure with
                // the same message, so marking them here does not fight its record.
                if list.interrupt(message: UploadLedger.interruptedMessage) {
                    orderChanged = true
                    contentChanged = true
                }
                if list.isEmpty { phase = .unavailable }
                end = (error as? DaemonError) == .notFound ? .unknownUpload : .interrupted
            }
        }
        guard !Task.isCancelled, self.uploadID == uploadID else { return .done }
        publishTask?.cancel()
        publishTask = nil
        publish()
        return end
    }

    /// Takes files out of the list of `uploadID` at once, without waiting for the stream to
    /// say so: the daemon confirmed their removal, or no longer knows them.
    func remove(indexes: [Int], of uploadID: String) {
        guard self.uploadID == uploadID else { return }
        var changed = false
        for index in indexes where list.remove(index) { changed = true }
        guard changed else { return }
        orderVersion += 1
        contentVersion += 1
    }

    /// Forgets the files, for when the detail closes.
    func clear() {
        publishTask?.cancel()
        publishTask = nil
        uploadID = nil
        list = UploadFileList()
        phase = .waiting
        orderChanged = false
        contentChanged = false
        orderVersion += 1
        contentVersion += 1
    }

    private func schedulePublish() {
        guard publishInterval > .zero else {
            publish()
            return
        }
        guard publishTask == nil else { return }
        publishTask = Task { [weak self, publishInterval] in
            try? await Task.sleep(for: publishInterval)
            guard !Task.isCancelled, let self else { return }
            self.publishTask = nil
            self.publish()
        }
    }

    private func publish() {
        if !list.isEmpty, phase != .loaded { phase = .loaded }
        if orderChanged {
            orderChanged = false
            orderVersion += 1
        }
        if contentChanged {
            contentChanged = false
            contentVersion += 1
        }
    }
}
