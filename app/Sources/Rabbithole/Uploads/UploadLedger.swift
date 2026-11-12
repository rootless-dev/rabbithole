import Foundation
import Observation

/// One upload as the app knows it in this run: the daemon's latest snapshot plus what only the
/// app can add (when it was first seen, when it ended, how fast it is going).
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

    var isActive: Bool { state == .queued || state == .uploading }

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

/// Every upload seen in this run, in arrival order, with the rules for merging snapshots.
/// The daemon keeps uploads only while it lives and the app keeps them only while it runs,
/// so this is the whole history the app can show.
struct UploadLedger: Equatable, Sendable {
    static let interruptedMessage = BatchTracker.interruptedMessage
    /// Minimum spacing between two speed samples.
    static let sampleInterval: TimeInterval = 0.5

    private(set) var records: [UploadRecord] = []
    private(set) var condition: ServiceCondition = .none
    private var index: [String: Int] = [:]
    private var lastSample: [String: (at: Date, bytes: Int64)] = [:]

    static func == (lhs: UploadLedger, rhs: UploadLedger) -> Bool {
        lhs.records == rhs.records && lhs.condition == rhs.condition
    }

    subscript(id: String) -> UploadRecord? {
        index[id].map { records[$0] }
    }

    /// Merges one snapshot. Returns the record when this snapshot ended the upload (it became
    /// finished or failed just now), so the caller can announce it once.
    @discardableResult
    mutating func apply(_ snapshot: UploadSnapshot, now: Date) -> UploadRecord? {
        guard let position = index[snapshot.id] else {
            var record = UploadRecord(
                id: snapshot.id, fileName: snapshot.fileName, localPath: snapshot.localPath,
                objectKey: snapshot.objectKey, bytesTotal: max(snapshot.bytesTotal, 0),
                bytesSent: max(snapshot.bytesSent, 0), state: snapshot.state,
                errorMessage: "", startedAt: now)
            let ended = finish(&record, with: snapshot, now: now)
            index[snapshot.id] = records.count
            records.append(record)
            lastSample[snapshot.id] = (now, record.bytesSent)
            return ended ? record : nil
        }
        var record = records[position]
        // A finished or failed upload never comes back: late or replayed snapshots are ignored.
        guard record.isActive else { return nil }
        record.bytesTotal = max(snapshot.bytesTotal, 0)
        record.bytesSent = max(record.bytesSent, snapshot.bytesSent)
        if !snapshot.objectKey.isEmpty { record.objectKey = snapshot.objectKey }
        if snapshot.state != .queued { record.state = snapshot.state }
        sampleSpeed(&record, now: now)
        let ended = finish(&record, with: snapshot, now: now)
        records[position] = record
        return ended ? record : nil
    }

    /// The daemon restarted or is gone: uploads that were queued or in progress are lost.
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

    /// Applies a terminal snapshot to `record`. Returns true when it ended the upload.
    private mutating func finish(
        _ record: inout UploadRecord, with snapshot: UploadSnapshot, now: Date
    ) -> Bool {
        switch snapshot.state {
        case .queued, .uploading:
            return false
        case .finished:
            record.state = .finished
            record.bytesSent = record.bytesTotal
            record.endedAt = now
            record.bytesPerSecond = nil
            condition = .none
        case .failed:
            record.state = .failed
            record.errorMessage = snapshot.errorMessage.isEmpty ? "Upload failed" : snapshot.errorMessage
            record.endedAt = now
            record.bytesPerSecond = nil
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

    /// The newest uploads first, for the tray's "Recent uploads" list.
    func recent(limit: Int) -> [UploadRecord] {
        Array(records.reversed().prefix(limit))
    }

    var finishedCount: Int { records.filter { $0.state == .finished }.count }

    var finishedBytes: Int64 {
        records.filter { $0.state == .finished }.reduce(0) { $0 + $1.bytesTotal }
    }

    var lastFinished: UploadRecord? {
        records.filter { $0.state == .finished }
            .max { ($0.endedAt ?? .distantPast) < ($1.endedAt ?? .distantPast) }
    }

    /// Failed uploads that can be sent again because of the current condition.
    var failedByCondition: [UploadRecord] {
        let message: String
        switch condition {
        case .none: return []
        case .offline: message = ServiceCondition.offlineMessage
        case .keyRejected: message = ServiceCondition.keyRejectedMessage
        }
        return records.filter { $0.state == .failed && $0.errorMessage == message }
    }
}

/// The observable holder of the ledger that views read.
@MainActor
@Observable
final class UploadStore {
    private(set) var ledger = UploadLedger()
    /// Called once for each upload that just finished or failed.
    @ObservationIgnored var onEnded: ((UploadRecord) -> Void)?
    @ObservationIgnored private let now: () -> Date

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    func apply(_ snapshot: UploadSnapshot) {
        if let ended = ledger.apply(snapshot, now: now()) {
            onEnded?(ended)
        }
    }

    func interrupt() {
        ledger.interrupt(now: now())
    }

    func clearCondition() {
        ledger.clearCondition()
    }
}
