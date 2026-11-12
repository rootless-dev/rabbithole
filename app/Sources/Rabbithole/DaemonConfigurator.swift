import Foundation
import Synchronization

/// Sends AWS settings to the daemon, retrying a bounded number of times. Each attempt is
/// bounded by a timeout that counts as a failure, so a daemon that accepts the connection but
/// never answers cannot hang the caller.
struct DaemonConfigurator: Sendable {
    static let attempts = 5
    static let retryDelay: Duration = .milliseconds(500)
    static let attemptTimeout: Duration = .seconds(3)

    let client: DaemonClient
    /// Used for both the pause between attempts and the attempt timeout; injected for tests.
    let sleep: @Sendable (Duration) async throws -> Void

    /// True once one attempt succeeded; false after the last attempt failed or on cancellation.
    func configure(_ settings: AWSSettings) async -> Bool {
        for attempt in 1...Self.attempts {
            if await attemptOnce(settings) { return true }
            if Task.isCancelled || attempt == Self.attempts { break }
            try? await sleep(Self.retryDelay)
        }
        return false
    }

    /// Races the call against the timeout. The call is cancelled when it loses; the caller does
    /// not wait for a call that ignores cancellation.
    private func attemptOnce(_ settings: AWSSettings) async -> Bool {
        let outcome = Outcome()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                outcome.install(continuation)
                let work = Task {
                    do {
                        try await client.configure(settings)
                        outcome.finish(true)
                    } catch {
                        outcome.finish(false)
                    }
                }
                let timer = Task {
                    try? await sleep(Self.attemptTimeout)
                    outcome.finish(false)
                }
                outcome.onFinish { work.cancel(); timer.cancel() }
            }
        } onCancel: {
            outcome.finish(false)
        }
    }
}

/// Resumes a continuation exactly once, whoever gets there first.
private final class Outcome: Sendable {
    private struct State {
        var continuation: CheckedContinuation<Bool, Never>?
        var result: Bool?
        var cleanup: (@Sendable () -> Void)?
    }

    private let state = Mutex(State())

    func install(_ continuation: CheckedContinuation<Bool, Never>) {
        let result = state.withLock { state -> Bool? in
            if state.result == nil { state.continuation = continuation }
            return state.result
        }
        // Cancelled before the continuation existed.
        if let result { continuation.resume(returning: result) }
    }

    func onFinish(_ cleanup: @escaping @Sendable () -> Void) {
        let done = state.withLock { state -> Bool in
            if state.result != nil { return true }
            state.cleanup = cleanup
            return false
        }
        if done { cleanup() }
    }

    func finish(_ value: Bool) {
        let (continuation, cleanup) = state.withLock {
            state -> (CheckedContinuation<Bool, Never>?, (@Sendable () -> Void)?) in
            guard state.result == nil else { return (nil, nil) }
            state.result = value
            defer { state.continuation = nil; state.cleanup = nil }
            return (state.continuation, state.cleanup)
        }
        continuation?.resume(returning: value)
        cleanup?()
    }
}
