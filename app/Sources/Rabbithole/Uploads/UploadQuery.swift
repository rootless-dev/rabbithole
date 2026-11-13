import Foundation

enum UploadStateFilter: CaseIterable, Sendable {
    case all, inProgress, waiting, paused, finished, failed, canceled

    var title: String {
        switch self {
        case .all: "All"
        case .inProgress: "In progress"
        case .waiting: "Waiting"
        case .paused: "Paused"
        case .finished: "Finished"
        case .failed: "Failed"
        case .canceled: "Canceled"
        }
    }

    /// Paused and Canceled are states an upload only gets into when the user asks, so their
    /// tabs are shown only while there is something under them.
    var isShownOnlyWhenUsed: Bool { self == .paused || self == .canceled }

    /// Whether a file in `state` belongs under this tab of an upload's file list.
    func includes(_ state: UploadState) -> Bool {
        switch self {
        case .all: true
        case .inProgress: state == .uploading
        case .waiting: state == .queued
        case .paused: state == .paused
        case .finished: state == .finished
        case .failed: state == .failed
        case .canceled: state == .canceled
        }
    }
}

/// The search text and filters of an upload list. State is one at a time, file kinds are
/// several at once, and no kind selected means every kind.
struct UploadQuery: Equatable, Sendable {
    var text = ""
    var state: UploadStateFilter = .all
    var kinds: Set<FileKind> = []
    /// Overview has no Waiting or Paused tab: there, waiting and paused uploads count as in
    /// progress, since none of them has ended.
    var waitingCountsAsInProgress = false

    var isFiltering: Bool { !trimmedText.isEmpty || state != .all || !kinds.isEmpty }

    func apply(to records: [UploadRecord]) -> [UploadRecord] {
        records.filter { matchesTextAndKind($0) && matches($0.state, filter: state) }
    }

    /// How many uploads each state tab would show with the current text and kinds.
    func count(_ filter: UploadStateFilter, in records: [UploadRecord]) -> Int {
        records.filter { matchesTextAndKind($0) && matches($0.state, filter: filter) }.count
    }

    /// The state tabs History shows: every one, except Paused and Canceled while nothing is
    /// in that state. A tab that is selected stays, so the list never loses its own filter.
    func historyTabs(in records: [UploadRecord]) -> [(filter: UploadStateFilter, count: Int)] {
        UploadStateFilter.allCases.compactMap { filter in
            if filter.isShownOnlyWhenUsed, state != filter,
                !records.contains(where: { filter.includes($0.state) })
            {
                return nil
            }
            return (filter, count(filter, in: records))
        }
    }

    /// The headline shown when the filters leave nothing: `No finished uploads match "x"`.
    var emptyTitle: String {
        let subject: String
        switch state {
        case .all: subject = "No uploads"
        case .inProgress: subject = "No uploads in progress"
        case .waiting: subject = "No waiting uploads"
        case .paused: subject = "No paused uploads"
        case .finished: subject = "No finished uploads"
        case .failed: subject = "No failed uploads"
        case .canceled: subject = "No canceled uploads"
        }
        if !trimmedText.isEmpty { return "\(subject) match \"\(trimmedText)\"" }
        if !kinds.isEmpty { return "\(subject) match these file types" }
        return subject
    }

    mutating func clear() {
        text = ""
        state = .all
        kinds = []
    }

    private var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func matchesTextAndKind(_ record: UploadRecord) -> Bool {
        if !kinds.isEmpty, !kinds.contains(FileKind.of(record)) { return false }
        let needle = trimmedText
        guard !needle.isEmpty else { return true }
        return record.fileName.localizedCaseInsensitiveContains(needle)
            || record.handedPaths.contains { $0.localizedCaseInsensitiveContains(needle) }
    }

    private func matches(_ state: UploadState, filter: UploadStateFilter) -> Bool {
        if filter == .inProgress, waitingCountsAsInProgress {
            return state == .uploading || state == .queued || state == .paused
        }
        return filter.includes(state)
    }
}
