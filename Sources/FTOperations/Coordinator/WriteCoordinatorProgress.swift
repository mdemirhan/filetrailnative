// Port of deliverProgress and forgetProgress (apps/desktop/src/main/bootstrap/writeOperations.ts): plain "running"
// updates at most every 100 ms, the newest always arriving; questions and ends at once
import FTFoundation
import Foundation

/// One running operation's throttle: when its last update went out, and the newest one held back.
@MainActor
final class ProgressThrottle {
    var lastSentAt: Double
    var pending: (@MainActor () -> Void)?
    var cancelTimer: (() -> Void)?

    init(lastSentAt: Double) {
        self.lastSentAt = lastSentAt
    }
}

extension WriteCoordinator {
    /// `deliverProgress`: sends a progress update now, or holds it back if one went out a moment ago. Only plain
    /// "running" updates wait: a question for the user and the end of the operation go out at once, ahead of anything
    /// held back (which is dropped).
    func deliverProgress(
        _ operationId: String, status: WriteOperationStatus, asksUser: Bool, send: @escaping @MainActor () -> Void
    ) {
        if status != .running || asksUser {
            forgetProgress(operationId)
            if !status.isTerminal {
                throttles[operationId] = ProgressThrottle(lastSentAt: clock.now())
            }
            send()
            return
        }
        let throttle = throttles[operationId] ?? ProgressThrottle(lastSentAt: -.infinity)
        throttles[operationId] = throttle
        let now = clock.now()
        let waitMs = throttle.lastSentAt + Self.progressUpdateIntervalMs - now
        if waitMs <= 0 && throttle.cancelTimer == nil {
            throttle.lastSentAt = now
            send()
            return
        }
        throttle.pending = send
        if throttle.cancelTimer == nil {
            throttle.cancelTimer = clock.schedule(max(waitMs, 0)) { [weak self, throttle] in
                throttle.cancelTimer = nil
                let pending = throttle.pending
                throttle.pending = nil
                throttle.lastSentAt = self?.clock.now() ?? throttle.lastSentAt
                pending?()
            }
        }
    }

    /// `forgetProgress`.
    func forgetProgress(_ operationId: String) {
        throttles[operationId]?.cancelTimer?()
        throttles[operationId] = nil
    }
}
