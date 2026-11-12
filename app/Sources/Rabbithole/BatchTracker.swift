import Foundation

/// Counts the uploads of the current batch. A batch is every upload enqueued since the queue
/// was last empty: it ends when all of its uploads are finished or failed, and the next
/// `register` starts a new one.
///
/// Snapshots are coalesced by the daemon (only the latest state per upload is delivered), so an
/// upload may jump from queued straight to finished, and a snapshot may arrive before the
/// enqueue call has returned its id. Snapshots of ids that are not registered yet are held
/// (latest per id) and claimed by `register`; they are never counted otherwise, which also
/// ignores uploads from earlier batches and history replayed on subscription.
struct BatchTracker {
    static let interruptedMessage = "Upload interrupted"

    private struct Entry {
        var bytesTotal: Int64 = 0
        var bytesSent: Int64 = 0
        var isDone = false
        var errorMessage: String?

        var countedBytesSent: Int64 {
            isDone && errorMessage == nil ? bytesTotal : min(max(bytesSent, 0), bytesTotal)
        }
    }

    private var order: [String] = []
    private var entries: [String: Entry] = [:]
    private var held: [String: UploadSnapshot] = [:]
    private var peakFraction = 0.0

    /// Number of snapshots waiting for their id to be registered.
    var heldCount: Int { held.count }

    var total: Int { order.count }

    var remaining: Int { entries.values.filter { !$0.isDone }.count }

    var isActive: Bool { remaining > 0 }

    /// Bytes sent over total bytes for the batch, in 0...1, never decreasing within a batch.
    var fraction: Double { peakFraction }

    /// The error of the first failed upload, in registration order.
    var firstError: String? {
        order.lazy.compactMap { entries[$0]?.errorMessage }.first
    }

    mutating func register(id: String) {
        guard entries[id] == nil else { return }
        // Claim first: a coalesced snapshot may already be final, and starting a new batch
        // drops held final snapshots.
        let claimed = held.removeValue(forKey: id)
        if !isActive {
            startNewBatch()
        }
        order.append(id)
        entries[id] = Entry()
        if let snapshot = claimed {
            update(id, with: snapshot)
        }
        updatePeak()
    }

    /// Returns true when the snapshot changed the current batch.
    @discardableResult
    mutating func apply(_ snapshot: UploadSnapshot) -> Bool {
        guard entries[snapshot.id] != nil else {
            held[snapshot.id] = snapshot
            return false
        }
        let changed = update(snapshot.id, with: snapshot)
        updatePeak()
        return changed
    }

    /// The daemon restarted: uploads that were queued or in progress are lost.
    mutating func interrupted() {
        for id in order where entries[id]?.isDone == false {
            entries[id]?.isDone = true
            entries[id]?.errorMessage = Self.interruptedMessage
        }
        held = held.filter { $0.value.state == .finished || $0.value.state == .failed }
        updatePeak()
    }

    private mutating func startNewBatch() {
        order = []
        entries = [:]
        peakFraction = 0
        held = held.filter { $0.value.state != .finished && $0.value.state != .failed }
    }

    @discardableResult
    private mutating func update(_ id: String, with snapshot: UploadSnapshot) -> Bool {
        guard var entry = entries[id], !entry.isDone else { return false }
        entry.bytesTotal = max(snapshot.bytesTotal, 0)
        entry.bytesSent = snapshot.bytesSent
        switch snapshot.state {
        case .queued, .uploading:
            break
        case .finished:
            entry.isDone = true
        case .failed:
            entry.isDone = true
            entry.errorMessage = snapshot.errorMessage.isEmpty ? "Upload failed" : snapshot.errorMessage
        }
        entries[id] = entry
        return true
    }

    private mutating func updatePeak() {
        let totalBytes = entries.values.reduce(Int64(0)) { $0 + $1.bytesTotal }
        guard totalBytes > 0 else { return }
        let sent = entries.values.reduce(Int64(0)) { $0 + $1.countedBytesSent }
        peakFraction = max(peakFraction, min(Double(sent) / Double(totalBytes), 1))
    }
}
