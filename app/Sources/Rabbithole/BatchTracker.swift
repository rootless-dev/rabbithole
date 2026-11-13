import Foundation

/// Counts the files of the current batch. A batch is every upload enqueued since the queue
/// was last empty: it ends when all of its uploads are finished or failed, and the next
/// `register` starts a new one. One upload holds one file, a folder's files or several items,
/// so `total` and `remaining` add up the file counters of the batch's uploads.
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
        /// How many files the upload holds: the number of items handed over until the first
        /// snapshot brings the daemon's count.
        var filesTotal = 1
        /// Files that are finished or failed.
        var filesEnded = 0
        var isDone = false
        var errorMessage: String?

        var countedBytesSent: Int64 {
            isDone && errorMessage == nil ? bytesTotal : min(max(bytesSent, 0), bytesTotal)
        }

        /// Files still to go. An upload that is not done always has at least one: its
        /// counters may run ahead of its state.
        var filesLeft: Int {
            isDone ? 0 : max(filesTotal - filesEnded, 1)
        }
    }

    private var order: [String] = []
    private var entries: [String: Entry] = [:]
    private var held: [String: UploadSnapshot] = [:]

    /// Number of snapshots waiting for their id to be registered.
    var heldCount: Int { held.count }

    /// Files in the batch.
    var total: Int { entries.values.reduce(0) { $0 + $1.filesTotal } }

    /// Files of the batch that are neither finished nor failed.
    var remaining: Int { entries.values.reduce(0) { $0 + $1.filesLeft } }

    var isActive: Bool { entries.values.contains { !$0.isDone } }

    /// Bytes sent over total bytes for the batch, clamped to 0...1. It may drop when a file joins
    /// the batch; per-upload bytes sent never decrease, so it is otherwise monotonic.
    var fraction: Double {
        let totalBytes = entries.values.reduce(Int64(0)) { $0 + $1.bytesTotal }
        guard totalBytes > 0 else { return 0 }
        let sent = entries.values.reduce(Int64(0)) { $0 + $1.countedBytesSent }
        return min(Double(sent) / Double(totalBytes), 1)
    }

    /// The error of the first failed upload, in registration order.
    var firstError: String? {
        order.lazy.compactMap { entries[$0]?.errorMessage }.first
    }

    /// Adds an upload to the batch. `items` is how many files and folders were handed over,
    /// which stands for its file count until a snapshot arrives.
    mutating func register(id: String, items: Int = 1) {
        guard entries[id] == nil else { return }
        // Claim first: a coalesced snapshot may already be final, and starting a new batch
        // drops held final snapshots.
        let claimed = held.removeValue(forKey: id)
        if !isActive {
            startNewBatch()
        }
        order.append(id)
        entries[id] = Entry(filesTotal: max(items, 1))
        if let snapshot = claimed {
            update(id, with: snapshot)
        }
    }

    /// Returns true when the snapshot changed the current batch.
    @discardableResult
    mutating func apply(_ snapshot: UploadSnapshot) -> Bool {
        guard entries[snapshot.id] != nil else {
            held[snapshot.id] = snapshot
            return false
        }
        return update(snapshot.id, with: snapshot)
    }

    /// The daemon restarted: uploads that were queued or in progress are lost.
    mutating func interrupted() {
        for id in order where entries[id]?.isDone == false {
            entries[id]?.isDone = true
            entries[id]?.errorMessage = Self.interruptedMessage
        }
        held = held.filter { $0.value.state == .finished || $0.value.state == .failed }
    }

    private mutating func startNewBatch() {
        order = []
        entries = [:]
        held = held.filter { $0.value.state != .finished && $0.value.state != .failed }
    }

    @discardableResult
    private mutating func update(_ id: String, with snapshot: UploadSnapshot) -> Bool {
        guard var entry = entries[id], !entry.isDone else { return false }
        entry.bytesTotal = max(snapshot.bytesTotal, 0)
        entry.bytesSent = max(entry.bytesSent, snapshot.bytesSent)
        entry.filesTotal = max(snapshot.filesTotal, 1)
        entry.filesEnded = max(entry.filesEnded, snapshot.filesFinished + snapshot.filesFailed)
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
}
