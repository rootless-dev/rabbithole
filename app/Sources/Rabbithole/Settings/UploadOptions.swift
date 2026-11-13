import Foundation
import IOKit.ps
import Observation

/// Tells whether the Mac runs on battery, and when that changes. Behind a protocol so tests
/// never ask the system.
@MainActor
protocol PowerSource: AnyObject {
    var isOnBattery: Bool { get }
    /// Called on the main actor each time the power source may have changed.
    var onChange: (() -> Void)? { get set }
}

/// The system's power source, through IOKit. A Mac without a battery is never on battery.
@MainActor
final class SystemPowerSource: PowerSource {
    var onChange: (() -> Void)?
    private var runLoopSource: CFRunLoopSource?

    init() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        let source = IOPSNotificationCreateRunLoopSource(
            { context in
                guard let context else { return }
                // The source is on the main run loop, so this runs on the main thread.
                MainActor.assumeIsolated {
                    Unmanaged<SystemPowerSource>.fromOpaque(context).takeUnretainedValue().onChange?()
                }
            }, context)?.takeRetainedValue()
        if let source {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            runLoopSource = source
        }
    }

    isolated deinit {
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .defaultMode) }
    }

    var isOnBattery: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue()
        else { return false }
        return (type as String) == kIOPMBatteryPowerKey
    }
}

extension AppPreferences {
    /// The megabyte of "Limit upload speed", decimal like every size the app shows.
    static let bytesPerMegabyte: Int64 = 1_000_000

    /// The options the daemon gets for every upload, from the preferences and the power
    /// source: the speed limit when it is switched on, checking files after sending, and
    /// the hold while "Pause on battery power" is on and the Mac runs on battery.
    func daemonOptions(onBattery: Bool) -> DaemonOptions {
        DaemonOptions(
            speedLimitBytesPerSecond: limitSpeed ? Int64(speedLimitMBps) * Self.bytesPerMegabyte : 0,
            verifyUploads: checkAfterSending,
            holdUploads: pauseOnBattery && onBattery)
    }
}

/// Keeps the daemon's options in step with the preferences and the power source: it calls
/// `changed` whenever the options that should be in effect are no longer the ones last
/// reported. Sending them, in turn with the daemon's configuration, is the forwarder's job.
@MainActor
final class UploadOptionsSync {
    private let preferences: AppPreferences
    private let power: PowerSource
    private let changed: () -> Void
    private var reported: DaemonOptions?

    init(preferences: AppPreferences, power: PowerSource, changed: @escaping () -> Void) {
        self.preferences = preferences
        self.power = power
        self.changed = changed
    }

    /// The options that should be in effect right now.
    var options: DaemonOptions {
        preferences.daemonOptions(onBattery: power.isOnBattery)
    }

    /// Starts following the preferences and the power source. What is in effect when this
    /// is called is not reported: the daemon gets it when it is configured.
    func start() {
        reported = options
        power.onChange = { [weak self] in self?.check() }
        observePreferences()
    }

    private func observePreferences() {
        withObservationTracking {
            _ = preferences.daemonOptions(onBattery: false)
            _ = preferences.pauseOnBattery
        } onChange: { [weak self] in
            // The change lands after this callback returns: look at it on the next turn.
            Task { @MainActor in
                guard let self else { return }
                self.check()
                self.observePreferences()
            }
        }
    }

    private func check() {
        let current = options
        guard current != reported else { return }
        reported = current
        changed()
    }
}
