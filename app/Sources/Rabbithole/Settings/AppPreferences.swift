import Foundation
import Observation

/// A global keyboard shortcut: a virtual key code, Carbon modifier flags and how it is written.
struct Shortcut: Equatable, Sendable {
    var keyCode: UInt32
    var carbonModifiers: UInt32
    var display: String

    /// Option-Command-U, the shortcut in the approved mockup.
    static let standard = Shortcut(keyCode: 0x20, carbonModifiers: 0x0800 | 0x0100, display: "⌥⌘U")
}

/// App options kept in preferences. Nothing here is secret. The two options whose function
/// the engine does not have yet (automatic retry and its count) are still stored and
/// restored, so the choice is there when it arrives; how the others reach the engine is
/// marked below.
@MainActor
@Observable
final class AppPreferences {
    @ObservationIgnored private let defaults: UserDefaults

    // App
    var theme: ThemeChoice { didSet { defaults.set(theme.rawValue, forKey: Key.theme) } }
    var notifyWhenUploadsEnd: Bool { didSet { defaults.set(notifyWhenUploadsEnd, forKey: Key.notify) } }
    var trayShortcut: Shortcut {
        didSet {
            defaults.set(Int(trayShortcut.keyCode), forKey: Key.shortcutKey)
            defaults.set(Int(trayShortcut.carbonModifiers), forKey: Key.shortcutModifiers)
            defaults.set(trayShortcut.display, forKey: Key.shortcutDisplay)
        }
    }

    // Uploads: sent to the daemon with every upload, see `enqueueRequest(for:)`.
    /// How many files of one upload are sent at the same time.
    var simultaneousUploads: Int { didSet { defaults.set(simultaneousUploads, forKey: Key.simultaneous) } }
    /// Comma-separated name patterns left out when a folder is walked.
    var skipPatterns: String { didSet { defaults.set(skipPatterns, forKey: Key.skip) } }

    // Uploads: sent to the daemon each time it is configured, as `resume_interrupted`.
    var resumeAutomatically: Bool { didSet { defaults.set(resumeAutomatically, forKey: Key.resume) } }

    // Uploads: sent to the daemon as its options, after it is configured and whenever one
    // changes, see `daemonOptions(onBattery:)`. "Pause on battery power" becomes the hold
    // while the Mac runs on battery.
    var limitSpeed: Bool { didSet { defaults.set(limitSpeed, forKey: Key.limitSpeed) } }
    var speedLimitMBps: Int { didSet { defaults.set(speedLimitMBps, forKey: Key.speedLimit) } }
    var pauseOnBattery: Bool { didSet { defaults.set(pauseOnBattery, forKey: Key.battery) } }
    var checkAfterSending: Bool { didSet { defaults.set(checkAfterSending, forKey: Key.verify) } }

    // Uploads: stored only. The engine has no automatic retry yet, so these two are kept
    // and restored but change nothing.
    var retryFailed: Bool { didSet { defaults.set(retryFailed, forKey: Key.retry) } }
    var retryCount: Int { didSet { defaults.set(retryCount, forKey: Key.retryCount) } }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        theme = defaults.string(forKey: Key.theme).flatMap(ThemeChoice.init(rawValue:)) ?? .system
        notifyWhenUploadsEnd = defaults.object(forKey: Key.notify) as? Bool ?? true
        if let display = defaults.string(forKey: Key.shortcutDisplay),
            let key = defaults.object(forKey: Key.shortcutKey) as? Int,
            let modifiers = defaults.object(forKey: Key.shortcutModifiers) as? Int
        {
            trayShortcut = Shortcut(
                keyCode: UInt32(clamping: key), carbonModifiers: UInt32(clamping: modifiers), display: display)
        } else {
            trayShortcut = .standard
        }
        resumeAutomatically = defaults.object(forKey: Key.resume) as? Bool ?? true
        retryFailed = defaults.object(forKey: Key.retry) as? Bool ?? true
        retryCount = Self.clamp(defaults.object(forKey: Key.retryCount) as? Int ?? 3, 1...20)
        simultaneousUploads = Self.clamp(defaults.object(forKey: Key.simultaneous) as? Int ?? 4, 1...16)
        limitSpeed = defaults.object(forKey: Key.limitSpeed) as? Bool ?? false
        speedLimitMBps = Self.clamp(defaults.object(forKey: Key.speedLimit) as? Int ?? 10, 1...10_000)
        pauseOnBattery = defaults.object(forKey: Key.battery) as? Bool ?? false
        checkAfterSending = defaults.object(forKey: Key.verify) as? Bool ?? true
        skipPatterns = defaults.string(forKey: Key.skip) ?? ".DS_Store, node_modules, *.tmp"
    }

    /// The daemon request for the paths of one upload, with the upload preferences applied.
    func enqueueRequest(for paths: [String]) -> EnqueueRequest {
        EnqueueRequest(
            paths: paths, skipPatterns: Self.patterns(from: skipPatterns), parallelFiles: simultaneousUploads)
    }

    /// The patterns typed in "Skip these files": separated by commas, trimmed, empty ones dropped.
    nonisolated static func patterns(from text: String) -> [String] {
        text.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static func clamp(_ value: Int, _ range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }

    private enum Key {
        static let theme = "pref.theme"
        static let notify = "pref.notifyWhenUploadsEnd"
        static let shortcutKey = "pref.trayShortcut.keyCode"
        static let shortcutModifiers = "pref.trayShortcut.modifiers"
        static let shortcutDisplay = "pref.trayShortcut.display"
        static let resume = "pref.uploads.resumeAutomatically"
        static let retry = "pref.uploads.retryFailed"
        static let retryCount = "pref.uploads.retryCount"
        static let simultaneous = "pref.uploads.simultaneous"
        static let limitSpeed = "pref.uploads.limitSpeed"
        static let speedLimit = "pref.uploads.speedLimitMBps"
        static let battery = "pref.uploads.pauseOnBattery"
        static let verify = "pref.uploads.checkAfterSending"
        static let skip = "pref.uploads.skipPatterns"
    }
}
