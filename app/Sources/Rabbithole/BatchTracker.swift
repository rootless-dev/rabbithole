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
///
/// An upload whose failed files are sent again keeps its id and goes back to waiting. When
/// it belongs to the batch it is counted again by its next snapshot; otherwise `retried`
/// brings it in.
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
        /// True while the upload is paused, with why when the daemon said.
        var isPaused = false
        var pauseReason: PauseReason?

        /// Held by the daemon with every other upload, so cut off when the daemon goes.
        var isInFlight: Bool { !isDone && !(isPaused && pauseReason == .byUser) }

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

    /// Why nothing is being sent although the batch is not over: every upload left in it is
    /// paused. `.byUser` when the user paused them all, `.onHold` when any is held with
    /// every other upload. Nil while anything is being sent or waits, and once it is over.
    var pause: PauseReason? {
        let open = entries.values.filter { !$0.isDone }
        guard !open.isEmpty, open.allSatisfy(\.isPaused) else { return nil }
        return open.allSatisfy { $0.pauseReason == .byUser } ? .byUser : .onHold
    }

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
        // An upload the user canceled leaves the batch, like one that was removed: it is
        // neither sent nor failed, so it stops counting. Sending it again brings it back.
        if snapshot.removed || snapshot.state == .canceled { return remove(snapshot.id) }
        guard entries[snapshot.id] != nil else {
            held[snapshot.id] = snapshot
            return false
        }
        return update(snapshot.id, with: snapshot)
    }

    /// The upload left the history: it stops counting. Returns true when the batch changed.
    @discardableResult
    mutating func remove(_ id: String) -> Bool {
        held[id] = nil
        guard entries.removeValue(forKey: id) != nil else { return false }
        order.removeAll { $0 == id }
        return true
    }

    /// Call before asking the daemon to send an upload's failed files again: what is held
    /// for it is its old end, which must not be taken for the outcome of the new attempt.
    mutating func willRetry(id: String) {
        if entries[id] == nil { held[id] = nil }
    }

    /// The daemon accepted sending `files` failed files of an upload again. An upload from
    /// an earlier batch or an earlier run joins the current batch; one that is already in
    /// it is counted again by its own snapshots.
    mutating func retried(id: String, files: Int) {
        register(id: id, items: files)
    }

    /// The daemon restarted: uploads that were queued, in progress or on hold are lost.
    /// Uploads the user paused were not being sent and stay paused.
    mutating func interrupted() {
        for id in order where entries[id]?.isInFlight == true {
            entries[id]?.isDone = true
            entries[id]?.isPaused = false
            entries[id]?.errorMessage = Self.interruptedMessage
        }
        held = held.filter { $0.value.state.hasEnded || $0.value.pauseReason == .byUser }
    }

    private mutating func startNewBatch() {
        order = []
        entries = [:]
        held = held.filter { !$0.value.state.hasEnded }
    }

    @discardableResult
    private mutating func update(_ id: String, with snapshot: UploadSnapshot) -> Bool {
        guard var entry = entries[id] else { return false }
        if entry.isDone {
            // An ended upload only comes back when its failed files are sent again.
            guard !snapshot.state.hasEnded else { return false }
            if !isActive {
                // The queue was empty: this upload alone starts the next batch.
                startNewBatch()
                order = [id]
            }
            entry = Entry()
        }
        entry.bytesTotal = max(snapshot.bytesTotal, 0)
        entry.bytesSent = max(entry.bytesSent, snapshot.bytesSent)
        entry.filesTotal = max(snapshot.filesTotal, 1)
        entry.filesEnded = max(entry.filesEnded, snapshot.filesFinished + snapshot.filesFailed)
        entry.isPaused = snapshot.state == .paused
        entry.pauseReason = snapshot.pauseReason
        switch snapshot.state {
        case .queued, .uploading, .paused, .canceled:
            // Canceled never gets here: `apply` takes the upload out of the batch.
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
