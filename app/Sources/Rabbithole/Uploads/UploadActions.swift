import Foundation
import Observation

/// What an actions menu, or the confirmation it leads to, is about.
enum UploadActionTarget: Hashable, Sendable {
    case upload(id: String)
    /// One file of an upload, by `FileSnapshot.index`.
    case file(uploadID: String, index: Int)

    var uploadID: String {
        switch self {
        case .upload(let id): id
        case .file(let uploadID, _): uploadID
        }
    }

    /// The file indexes a daemon call takes for this target: none means the whole upload.
    var fileIndexes: [Int] {
        switch self {
        case .upload: []
        case .file(_, let index): [index]
        }
    }
}

/// The entries of the actions menu, in the order they are listed.
enum UploadAction: Equatable, Sendable {
    case retry, remove, deleteFromBucket

    var title: String {
        switch self {
        case .retry: "Try again"
        case .remove: "Remove from history…"
        case .deleteFromBucket: "Delete from bucket…"
        }
    }

    /// What applies to an upload. One that is sending or waiting has no actions yet: Pause
    /// and Cancel upload stay in the detail. Try again needs something that failed, and
    /// Delete from bucket needs something of the upload in the bucket.
    static func available(for record: UploadRecord) -> [UploadAction] {
        guard !record.isActive else { return [] }
        return available(
            failed: record.state == .failed || record.filesFailed > 0,
            inBucket: record.filesInBucket > 0)
    }

    /// What applies to one file of an upload: nothing while the file is sent or waits.
    static func available(for file: FileSnapshot) -> [UploadAction] {
        switch file.state {
        case .queued, .uploading: []
        case .failed: available(failed: true, inBucket: false)
        case .finished: available(failed: false, inBucket: true)
        }
    }

    private static func available(failed: Bool, inBucket: Bool) -> [UploadAction] {
        var actions: [UploadAction] = failed ? [.retry] : []
        actions.append(.remove)
        if inBucket { actions.append(.deleteFromBucket) }
        return actions
    }
}

extension UploadRecord {
    /// How many files of the upload are in the bucket: the ones that were sent.
    var filesInBucket: Int {
        switch state {
        case .finished: max(filesFinished, kind == .singleFile ? 1 : 0)
        case .queued, .uploading, .failed: filesFinished
        }
    }
}

/// An actions menu that is open in the main window.
struct OpenActionsMenu: Equatable, Sendable {
    let target: UploadActionTarget
    let actions: [UploadAction]
    /// Where a right click opened it, in the main window's coordinates. Nil hangs the menu
    /// from the target's three-dot button.
    var point: CGPoint?
    /// The entry under the pointer.
    var highlighted: UploadAction?
}

/// The words of the two confirmations, "Remove from history" and "Delete from bucket", for
/// an upload or for one file of it, as the approved mockup writes them.
struct RemovalPrompt: Equatable, Sendable {
    enum Intent: Equatable, Sendable {
        /// Take it out of the history; the checkbox decides about the bucket.
        case remove
        /// Delete it from the bucket, which also takes it out of the history.
        case delete
    }

    enum Subject: Equatable, Sendable {
        /// A whole upload. `filesInBucket` of its `filesTotal` files were sent.
        case upload(name: String, filesInBucket: Int, filesTotal: Int)
        /// One file of the upload called `uploadName`.
        case file(name: String, uploadName: String, inBucket: Bool)
    }

    enum ConfirmStyle: Equatable, Sendable { case primary, destructive }

    let target: UploadActionTarget
    let subject: Subject
    let intent: Intent
    /// The checkbox of "Remove from history": also delete from the bucket.
    var alsoDelete = false

    static let warning = "Files deleted from the bucket cannot be recovered."

    /// Whether confirming deletes objects from the bucket.
    var deletesFromBucket: Bool {
        switch intent {
        case .delete: true
        case .remove: alsoDelete && hasSomethingInBucket
        }
    }

    var title: String {
        switch (intent, subject) {
        case (.remove, .upload(let name, _, _)): "Remove “\(name)” from the history?"
        case (.remove, .file(let name, _, _)): "Remove “\(name)” from this upload?"
        case (.delete, .upload(let name, _, _)), (.delete, .file(let name, _, _)):
            "Delete “\(name)” from the bucket?"
        }
    }

    var message: String {
        switch subject {
        case .upload:
            guard hasSomethingInBucket else {
                return "This upload failed, so there is nothing in the bucket to delete."
            }
            let files = bucketFiles
            switch intent {
            case .delete:
                return "\(files.capitalized) \(files.are) deleted from the bucket and it leaves the history. Nothing on this Mac is touched."
            case .remove where alsoDelete:
                return "It leaves this list and \(files.phrase) \(files.are) deleted from the bucket. Nothing on this Mac is touched."
            case .remove:
                return "It leaves this list. \(files.capitalized) \(files.stay) in the bucket, and nothing on this Mac is touched."
            }
        case .file(_, let uploadName, let inBucket):
            guard inBucket else {
                return "This file failed, so there is nothing in the bucket to delete."
            }
            switch intent {
            case .delete:
                return "The file is deleted from the bucket and leaves the list of “\(uploadName)”. Nothing on this Mac is touched."
            case .remove where alsoDelete:
                return "It leaves the list of “\(uploadName)” and the file is deleted from the bucket. Nothing on this Mac is touched."
            case .remove:
                return "It leaves the list of “\(uploadName)”. The file stays in the bucket, and nothing on this Mac is touched."
            }
        }
    }

    /// The checkbox's label; nil when there is no checkbox (deleting, or nothing to delete).
    var checkboxTitle: String? {
        guard intent == .remove, hasSomethingInBucket else { return nil }
        return "Also delete \(bucketFiles.phrase) from the bucket"
    }

    /// The red note shown whenever confirming deletes from the bucket.
    var warning: String? { deletesFromBucket ? Self.warning : nil }

    var confirmTitle: String {
        switch intent {
        case .delete: "Delete"
        case .remove: deletesFromBucket ? "Remove and delete" : "Remove"
        }
    }

    var confirmStyle: ConfirmStyle { deletesFromBucket ? .destructive : .primary }

    private var hasSomethingInBucket: Bool {
        switch subject {
        case .upload(_, let filesInBucket, _): filesInBucket > 0
        case .file(_, _, let inBucket): inBucket
        }
    }

    /// How the files in the bucket are called in a sentence, with the verbs that agree.
    private struct Files {
        let phrase: String
        let isPlural: Bool

        var capitalized: String { phrase.prefix(1).uppercased() + phrase.dropFirst() }
        var are: String { isPlural ? "are" : "is" }
        var stay: String { isPlural ? "stay" : "stays" }
    }

    /// "its 12 files" when the whole upload is in the bucket, "the file" when that is one
    /// file, and "the 5 files already sent" when only part of a failed upload got there.
    private var bucketFiles: Files {
        switch subject {
        case .file:
            return Files(phrase: "the file", isPlural: false)
        case .upload(_, let inBucket, let total):
            if inBucket >= total {
                return inBucket == 1
                    ? Files(phrase: "the file", isPlural: false)
                    : Files(phrase: "its \(inBucket) files", isPlural: true)
            }
            return inBucket == 1
                ? Files(phrase: "the 1 file already sent", isPlural: false)
                : Files(phrase: "the \(inBucket) files already sent", isPlural: true)
        }
    }
}

extension RemovalPrompt {
    /// The confirmation for a whole upload.
    init(upload record: UploadRecord, intent: Intent) {
        self.init(
            target: .upload(id: record.id),
            subject: .upload(
                name: UploadText.name(record), filesInBucket: record.filesInBucket,
                filesTotal: max(record.filesTotal, 1)),
            intent: intent)
    }

    /// The confirmation for one file of `record`.
    init(file: FileSnapshot, of record: UploadRecord, intent: Intent) {
        self.init(
            target: .file(uploadID: record.id, index: file.index),
            subject: .file(
                name: (file.relativePath as NSString).lastPathComponent, uploadName: UploadText.name(record),
                inBucket: file.state == .finished),
            intent: intent)
    }
}

/// The state of a confirmation sheet: what it asks, whether the daemon is working on it and
/// what went wrong the last time.
@MainActor
@Observable
final class RemovalSheetModel: Identifiable {
    /// Does the removal: upload id, file indexes (none for the whole upload) and whether to
    /// delete from the bucket. Returns when the daemon is done; throws what it refused.
    typealias Perform = (String, [Int], Bool) async throws -> Void

    private(set) var prompt: RemovalPrompt
    /// True from the confirmation until the daemon answers.
    private(set) var isWorking = false
    /// Why the last attempt failed, in words to show. The sheet stays open with it.
    private(set) var errorMessage: String?

    @ObservationIgnored private let perform: Perform
    @ObservationIgnored private let close: (_ removed: Bool) -> Void

    /// `close` is called with true after the daemon did the work, and with false on Cancel.
    init(prompt: RemovalPrompt, perform: @escaping Perform, close: @escaping (_ removed: Bool) -> Void) {
        self.prompt = prompt
        self.perform = perform
        self.close = close
    }

    /// The checkbox. It cannot change while the daemon is working on what was confirmed.
    var alsoDelete: Bool {
        get { prompt.alsoDelete }
        set {
            guard !isWorking else { return }
            prompt.alsoDelete = newValue
        }
    }

    func cancel() {
        guard !isWorking else { return }
        close(false)
    }

    /// Asks the daemon once: a second confirmation while it works does nothing.
    func confirm() async {
        guard !isWorking else { return }
        isWorking = true
        errorMessage = nil
        do {
            try await perform(prompt.target.uploadID, prompt.target.fileIndexes, prompt.deletesFromBucket)
            isWorking = false
            close(true)
        } catch {
            isWorking = false
            errorMessage = Self.message(for: error)
        }
    }

    /// The daemon's own words when it gave any, and plain ones otherwise.
    static func message(for error: Error) -> String {
        switch error as? DaemonError {
        case .rejected(let message) where !message.isEmpty: message
        case .invalidArgument(let message) where !message.isEmpty: message
        case .notConfigured: "Connect your AWS account first."
        case .unavailable: "Uploads are unavailable right now. Try again in a moment."
        default: "This could not be done. Try again in a moment."
        }
    }
}
