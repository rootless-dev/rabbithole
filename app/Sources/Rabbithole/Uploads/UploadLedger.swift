import Foundation
import Observation

/// One upload of the history: the daemon's latest snapshot plus what only the app can add
/// (how fast it is going). The times are the daemon's; the app's clock stands in only when a
/// snapshot does not carry them.
struct UploadRecord: Identifiable, Equatable, Sendable {
    let id: String
    var fileName: String
    var localPath: String
    var objectKey: String
    var bytesTotal: Int64
    var bytesSent: Int64
    var state: UploadState
    var errorMessage: String
    var startedAt: Date
    var endedAt: Date?
    /// Smoothed transfer speed while uploading; nil before two samples exist.
    var bytesPerSecond: Double?
    var kind: UploadKind = .singleFile
    /// Every path the upload was handed, in order; see `handedPaths`.
    var rootPaths: [String] = []
    var filesTotal = 1
    var filesFinished = 0
    var filesFailed = 0

    var isActive: Bool { state == .queued || state == .uploading }

    /// The files and folders this upload was made of.
    var handedPaths: [String] { rootPaths.isEmpty ? [localPath] : rootPaths }

    /// How long an ended upload took, from being handed over to its end.
    var duration: TimeInterval? {
        endedAt.map { max($0.timeIntervalSince(startedAt), 0) }
    }

    /// Progress from 0 to 1. A finished upload is always 1, including an empty file.
    var fraction: Double {
        if state == .finished { return 1 }
        guard bytesTotal > 0 else { return 0 }
        return min(max(Double(bytesSent) / Double(bytesTotal), 0), 1)
    }

    var bytesLeft: Int64 { max(bytesTotal - bytesSent, 0) }

    /// Seconds until done at the current speed, or nil when the speed is unknown.
    var secondsLeft: Double? {
        guard state == .uploading, let speed = bytesPerSecond, speed > 0 else { return nil }
        return Double(bytesLeft) / speed
    }
}

/// Something wrong with the service as a whole, learned from how uploads fail.
enum ServiceCondition: Equatable, Sendable {
    case none
    /// The last upload failed because there is no internet connection.
    case offline
    /// The last upload failed because AWS rejected the access key.
    case keyRejected

    /// The daemon's failure messages these conditions are recognized by.
    static let offlineMessage = "No internet connection"
    static let keyRejectedMessage = "AWS rejected the access key"
}

/// The upload history as the daemon tells it, in arrival order, with the rules for merging
/// snapshots. The daemon stores the history and replays all of it on every subscription, so
/// the ledger holds uploads of earlier runs too; `liveSince` tells those apart from what
/// ended while this run was watching.
struct UploadLedger: Equatable, Sendable {
    static let interruptedMessage = BatchTracker.interruptedMessage
    /// Minimum spacing between two speed samples.
    static let sampleInterval: TimeInterval = 0.5

    private(set) var records: [UploadRecord] = []
    private(set) var condition: ServiceCondition = .none
    /// When this run began. An upload first seen already ended, with an end before this, is
    /// history: it is listed, but it is not announced and says nothing about the service now.
    var liveSince: Date = .distantPast
    private var index: [String: Int] = [:]
    private var lastSample: [String: (at: Date, bytes: Int64)] = [:]

    static func == (lhs: UploadLedger, rhs: UploadLedger) -> Bool {
        lhs.records == rhs.records && lhs.condition == rhs.condition
    }

    subscript(id: String) -> UploadRecord? {
        index[id].map { records[$0] }
    }

    /// Merges one snapshot. Returns the record when this snapshot ended the upload (it became
    /// finished or failed just now), so the caller can announce it once. A snapshot marked
    /// removed takes the upload out; see `remove(_:)`.
    @discardableResult
    mutating func apply(_ snapshot: UploadSnapshot, now: Date) -> UploadRecord? {
        if snapshot.removed {
            remove(snapshot.id)
            return nil
        }
        guard let position = index[snapshot.id] else {
            var record = UploadRecord(
                id: snapshot.id, fileName: snapshot.fileName, localPath: snapshot.localPath,
                objectKey: snapshot.objectKey, bytesTotal: max(snapshot.bytesTotal, 0),
                bytesSent: max(snapshot.bytesSent, 0), state: snapshot.state,
                errorMessage: "", startedAt: snapshot.createdAt ?? now, kind: snapshot.kind,
                rootPaths: snapshot.rootPaths)
            countFiles(&record, from: snapshot)
            // Ended before this run began: an upload of the history, not news.
            let isHistory = (snapshot.endedAt ?? now) < liveSince
            let ended = finish(&record, with: snapshot, now: now, isNews: !isHistory)
            index[snapshot.id] = records.count
            records.append(record)
            lastSample[snapshot.id] = (now, record.bytesSent)
            return ended && !isHistory ? record : nil
        }
        var record = records[position]
        let wasActive = record.isActive
        let previousState = record.state
        if let createdAt = snapshot.createdAt { record.startedAt = createdAt }
        if !snapshot.objectKey.isEmpty { record.objectKey = snapshot.objectKey }
        record.bytesTotal = max(snapshot.bytesTotal, 0)
        countFiles(&record, from: snapshot)
        if wasActive {
            // While an upload runs, what was sent and how far it got do not go back.
            record.bytesSent = max(record.bytesSent, snapshot.bytesSent)
            if snapshot.state != .queued { record.state = snapshot.state }
            sampleSpeed(&record, now: now)
        } else {
            // An ended upload changes when its failed files are sent again (it goes back to
            // waiting, under the same id) or when some of its files are removed.
            record.bytesSent = max(snapshot.bytesSent, 0)
            record.state = snapshot.state
            if record.isActive {
                record.errorMessage = ""
                record.endedAt = nil
                lastSample[record.id] = (now, record.bytesSent)
            }
        }
        // Coalesced snapshots can take a retried upload from failed straight to finished.
        let isNews = wasActive || snapshot.state != previousState
        let ended = finish(&record, with: snapshot, now: now, isNews: isNews)
        records[position] = record
        return ended && isNews ? record : nil
    }

    /// Takes an upload out of the history: the user removed it, it is no longer in the
    /// bucket, or the bucket changed. Returns false when it was not there.
    @discardableResult
    mutating func remove(_ id: String) -> Bool {
        guard let position = index.removeValue(forKey: id) else { return false }
        records.remove(at: position)
        lastSample[id] = nil
        for later in position..<records.count { index[records[later].id] = later }
        return true
    }

    /// The daemon restarted or is gone: uploads that were queued or in progress are lost.
    /// A restarted daemon reports the same uploads as failed with the same message, which
    /// then only brings its own time of the end.
    mutating func interrupt(now: Date) {
        for position in records.indices where records[position].isActive {
            records[position].state = .failed
            records[position].errorMessage = Self.interruptedMessage
            records[position].endedAt = now
            records[position].bytesPerSecond = nil
        }
    }

    /// Forgets the current service condition, for example after new settings were saved.
    mutating func clearCondition() {
        condition = .none
    }

    /// Takes the file counters of a snapshot as the daemon gives them: they go down when a
    /// failed file is sent again or a file is removed.
    private func countFiles(_ record: inout UploadRecord, from snapshot: UploadSnapshot) {
        record.filesTotal = max(snapshot.filesTotal, 0)
        record.filesFinished = max(snapshot.filesFinished, 0)
        record.filesFailed = max(snapshot.filesFailed, 0)
    }

    /// Applies a terminal snapshot to `record`. Returns true when the snapshot is terminal.
    /// Only news (an upload that ended while this run was watching) changes the service
    /// condition; history and repeated reports of the same end do not.
    private mutating func finish(
        _ record: inout UploadRecord, with snapshot: UploadSnapshot, now: Date, isNews: Bool
    ) -> Bool {
        switch snapshot.state {
        case .queued, .uploading:
            return false
        case .finished:
            record.state = .finished
            record.errorMessage = ""
            record.bytesSent = record.bytesTotal
            record.endedAt = snapshot.endedAt ?? (isNews ? now : record.endedAt ?? now)
            record.bytesPerSecond = nil
            if isNews { condition = .none }
        case .failed:
            record.state = .failed
            record.errorMessage = snapshot.errorMessage.isEmpty ? "Upload failed" : snapshot.errorMessage
            record.endedAt = snapshot.endedAt ?? (isNews ? now : record.endedAt ?? now)
            record.bytesPerSecond = nil
            guard isNews else { break }
            switch record.errorMessage {
            case ServiceCondition.offlineMessage: condition = .offline
            case ServiceCondition.keyRejectedMessage: condition = .keyRejected
            default: condition = .none
            }
        }
        return true
    }

    private mutating func sampleSpeed(_ record: inout UploadRecord, now: Date) {
        guard record.state == .uploading else { return }
        guard let last = lastSample[record.id] else {
            lastSample[record.id] = (now, record.bytesSent)
            return
        }
        let elapsed = now.timeIntervalSince(last.at)
        guard elapsed >= Self.sampleInterval else { return }
        let instant = Double(record.bytesSent - last.bytes) / elapsed
        record.bytesPerSecond = record.bytesPerSecond.map { $0 * 0.7 + instant * 0.3 } ?? instant
        lastSample[record.id] = (now, record.bytesSent)
    }
}

// MARK: - Views over the ledger

extension UploadLedger {
    /// Uploads in progress first, then waiting ones, then ended ones with the newest first.
    var ordered: [UploadRecord] {
        let uploading = records.filter { $0.state == .uploading }
        let queued = records.filter { $0.state == .queued }
        let ended = records.filter { !$0.isActive }
            .sorted { ($0.endedAt ?? .distantPast) > ($1.endedAt ?? .distantPast) }
        return uploading + queued + ended
    }

    /// The newest uploads first, for the tray's "Recent uploads" list: by when they were
    /// handed over, and by arrival among uploads of the same moment.
    func recent(limit: Int) -> [UploadRecord] {
        let newestFirst = records.enumerated().sorted { one, other in
            one.element.startedAt != other.element.startedAt
                ? one.element.startedAt > other.element.startedAt : one.offset > other.offset
        }
        return newestFirst.prefix(limit).map(\.element)
    }

    var finishedCount: Int { records.filter { $0.state == .finished }.count }

    /// True once an upload finished while this run was watching, which is the only proof
    /// the app has that the saved key works right now.
    var hasFinishedLive: Bool {
        records.contains { $0.state == .finished && ($0.endedAt ?? .distantPast) >= liveSince }
    }

    /// How many files the finished uploads hold.
    var finishedFileCount: Int {
        records.filter { $0.state == .finished }.reduce(0) { $0 + $1.filesTotal }
    }

    var finishedBytes: Int64 {
        records.filter { $0.state == .finished }.reduce(0) { $0 + $1.bytesTotal }
    }

    var lastFinished: UploadRecord? {
        records.filter { $0.state == .finished }
            .max { ($0.endedAt ?? .distantPast) < ($1.endedAt ?? .distantPast) }
    }

    /// Failed uploads that can be sent again because of the current condition: the ones
    /// that failed for it in this run, not every old failure with the same words.
    var failedByCondition: [UploadRecord] {
        let message: String
        switch condition {
        case .none: return []
        case .offline: message = ServiceCondition.offlineMessage
        case .keyRejected: message = ServiceCondition.keyRejectedMessage
        }
        return records.filter {
            $0.state == .failed && $0.errorMessage == message && ($0.endedAt ?? .distantPast) >= liveSince
        }
    }
}

/// The observable holder of the ledger that views read.
@MainActor
@Observable
final class UploadStore {
    private(set) var ledger = UploadLedger()
    /// Called once for each upload that just finished or failed. Uploads of the history that
    /// the daemon replays are not announced.
    @ObservationIgnored var onEnded: ((UploadRecord) -> Void)?
    /// Called with the id of each upload that left the history.
    @ObservationIgnored var onRemoved: ((String) -> Void)?
    @ObservationIgnored private let now: () -> Date

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
        ledger.liveSince = now()
    }

    func apply(_ snapshot: UploadSnapshot) {
        if snapshot.removed {
            remove(snapshot.id)
        } else if let ended = ledger.apply(snapshot, now: now()) {
            onEnded?(ended)
        }
    }

    /// Takes an upload out of the history, because the daemon said so or answered that it
    /// no longer knows it.
    func remove(_ id: String) {
        if ledger.remove(id) { onRemoved?(id) }
    }

    func interrupt() {
        ledger.interrupt(now: now())
    }

    func clearCondition() {
        ledger.clearCondition()
    }
}
