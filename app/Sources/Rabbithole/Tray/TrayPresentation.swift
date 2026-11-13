import Foundation
import Observation

/// What the tray window shows for a given state: which block is on top, the words in the
/// drop area, the status line and which menu items work. Pure, so it can be tested.
struct TrayPresentation: Equatable {
    enum TopBlock: Equatable { case setup, keyRejected, drop }
    enum DropStyle: Equatable { case normal, over, done }
    enum StatusTone: Equatable { case normal, warn }

    struct Status: Equatable {
        let text: String
        let tone: StatusTone
        /// Progress from 0 to 1 while uploading; nil hides the percentage and the bar.
        let fraction: Double?
        /// The uploads are paused: the bar stands still in the paused color.
        var isPaused = false
    }

    let topBlock: TopBlock
    let dropTitle: String
    let dropSubtitle: String?
    let dropStyle: DropStyle
    let status: Status?
    /// "Choose file…" and "Upload from clipboard".
    let uploadsEnabled: Bool
    let recentEnabled: Bool
    /// True while something is held over the window: the outline shows and the menu fades.
    let isDragging: Bool

    init(
        state: TrayState, statusText: String, feedback: DropFeedback, itemCount: Int,
        condition: ServiceCondition
    ) {
        let items = itemCount == 1 ? "1 item" : "\(itemCount) items"
        if state == .notConfigured {
            topBlock = .setup
        } else if condition == .keyRejected {
            topBlock = .keyRejected
        } else {
            topBlock = .drop
        }

        // A paused batch is still a queue: what is dropped now waits with it.
        let isUploading: Bool
        switch state {
        case .uploading, .paused: isUploading = true
        default: isUploading = false
        }

        switch feedback {
        case .hovering:
            dropStyle = .over
            dropTitle = "Release to upload"
            dropSubtitle = "\(items) to Quick uploads"
        case .confirmed:
            dropStyle = .done
            dropTitle = "\(items) added"
            dropSubtitle = "Upload started"
        case .refused(let message):
            dropStyle = .normal
            dropTitle = message
            dropSubtitle = nil
        case .none:
            dropStyle = .normal
            dropTitle = isUploading ? "Drop more to queue" : "Drop files or folders"
            dropSubtitle = condition == .offline && !isUploading ? "No connection: uploads may fail" : nil
        }

        switch state {
        case .uploading(_, _, let fraction):
            status = Status(text: statusText, tone: .normal, fraction: fraction)
        case .paused(_, _, let fraction, _):
            status = Status(text: statusText, tone: .normal, fraction: fraction, isPaused: true)
        case .idle, .notConfigured:
            status = condition == .offline
                ? Status(text: ServiceCondition.offlineMessage, tone: .warn, fraction: nil) : nil
        case .failed where condition == .offline:
            status = Status(text: ServiceCondition.offlineMessage, tone: .warn, fraction: nil)
        case .unavailable, .restartRequired, .settingsUnreadable, .starting, .finished, .failed:
            status = Status(text: statusText, tone: .normal, fraction: nil)
        }

        let working: Bool
        switch state {
        case .idle, .uploading, .paused, .finished, .failed: working = true
        case .notConfigured, .unavailable, .restartRequired, .settingsUnreadable, .starting: working = false
        }
        uploadsEnabled = working && condition != .keyRejected
        recentEnabled = state != .notConfigured
        isDragging = feedback == .hovering && topBlock == .drop
    }

    @MainActor
    init(_ viewModel: TrayViewModel) {
        self.init(
            state: viewModel.state, statusText: viewModel.statusText,
            feedback: viewModel.dropFeedback, itemCount: viewModel.feedbackItemCount,
            condition: viewModel.uploads.ledger.condition)
    }
}

/// Open or closed state of the "Recent uploads" list beside the tray window. The window
/// controller listens for changes and shows or hides the second panel.
@MainActor
@Observable
final class TrayMenuModel {
    private(set) var recentOpen = false
    /// Top of the "Recent uploads" row inside the tray window, so the list lines up with it.
    @ObservationIgnored var recentRowTop: CGFloat = 0
    @ObservationIgnored var onRecentChange: (Bool) -> Void = { _ in }

    func setRecentOpen(_ open: Bool) {
        guard open != recentOpen else { return }
        recentOpen = open
        onRecentChange(open)
    }
}
