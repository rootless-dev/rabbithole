import Foundation
import Observation

/// The downloads the daemon reports, as the lists show them: the latest one of each upload
/// and of each file that was downloaded by itself. Downloads are not part of the history.
/// The daemon forgets them when it exits, and so does this store.
@MainActor
@Observable
final class DownloadStore {
    /// The id of an entry that never became a download: the daemon refused to start it.
    static let refusedID = ""

    private(set) var latest: [UploadActionTarget: DownloadSnapshot] = [:]
    /// What each download the app started is about. A download the app did not start is
    /// taken to be about its whole upload.
    @ObservationIgnored private var targets: [String: UploadActionTarget] = [:]

    subscript(target: UploadActionTarget) -> DownloadSnapshot? { latest[target] }

    /// The download of `target` that is waiting or running, if there is one.
    func active(_ target: UploadActionTarget) -> DownloadSnapshot? {
        latest[target].flatMap { $0.state.isActive ? $0 : nil }
    }

    /// The daemon accepted a download and gave its id. A snapshot can arrive before the
    /// call returns; it was then filed under the upload, and moves to its real target.
    func started(id: String, target: UploadActionTarget) {
        targets[id] = target
        if latest[target]?.id == Self.refusedID { latest[target] = nil }
        let guessed = UploadActionTarget.upload(id: target.uploadID)
        if guessed != target, let early = latest[guessed], early.id == id {
            latest[guessed] = nil
            latest[target] = early
        }
    }

    /// The daemon refused to start a download: the row says why, as for one that failed.
    func refused(_ target: UploadActionTarget, message: String) {
        latest[target] = DownloadSnapshot(
            id: Self.refusedID, uploadID: target.uploadID, fileIndexes: target.fileIndexes, name: "",
            destinationPath: "", bytesTotal: 0, bytesDone: 0, state: .failed, errorMessage: message)
    }

    func apply(_ snapshot: DownloadSnapshot) {
        let target = targets[snapshot.id] ?? .upload(id: snapshot.uploadID)
        let current = latest[target]
        if snapshot.state == .canceled {
            // A canceled download leaves nothing behind, on disk or on the row.
            if current?.id == snapshot.id { latest[target] = nil }
            targets[snapshot.id] = nil
            return
        }
        // An older download that ends does not hide the one that is running now.
        if let current, current.id != snapshot.id, current.state.isActive, !snapshot.state.isActive { return }
        latest[target] = snapshot
    }

    /// The upload left the history: nothing is shown about its downloads any more.
    func forget(uploadID: String) {
        latest = latest.filter { $0.key.uploadID != uploadID }
    }

    /// The daemon restarted or is gone, and its downloads with it.
    func clear() {
        latest = [:]
        targets = [:]
    }
}
