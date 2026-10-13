// Timers the clock and the visit tracker ask for, behind a seam so tests run them on a virtual clock.
// (The original calls setTimeout/clearTimeout, or the timers a test passes in.)
import Foundation

/// A timer that has been scheduled; `cancel()` stops it if it has not fired.
public final class TimerToken: @unchecked Sendable {
    private let onCancel: @Sendable () -> Void

    public init(onCancel: @escaping @Sendable () -> Void) {
        self.onCancel = onCancel
    }

    public func cancel() {
        onCancel()
    }
}

@MainActor
public protocol TimerScheduling {
    /// Runs `action` once, on the main actor, after `delay` seconds.
    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> TimerToken
}

/// Timers on the main actor, from Swift concurrency's clock.
@MainActor
public struct TaskTimerScheduler: TimerScheduling {
    public init() {}

    public func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> TimerToken {
        let task = Task { @MainActor in
            try? await Task.sleep(for: .seconds(max(0, delay)))
            if !Task.isCancelled {
                action()
            }
        }
        return TimerToken { task.cancel() }
    }
}
