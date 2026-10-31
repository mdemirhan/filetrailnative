// Port of resolveRuntimeConflict, cancelOperation, getAllowedRuntimeResolutions, runtimeConflictScope and the
// paste's requestResolution and autoResolve (packages/core/src/fs/writeService.ts)
import FTFoundation
import Foundation

/// The answers that make sense for a conflict as it is on disk now.
public func getAllowedRuntimeResolutions(_ conflict: CopyPasteRuntimeConflict) -> [CopyPasteChoice] {
    CopyPasteChoices.runtimeConflictChoices(
        reason: conflict.reason, conflictClass: conflict.conflictClass,
        destinationExists: conflict.currentDestinationFingerprint.exists)
}

func runtimeConflictScope(_ conflict: CopyPasteRuntimeConflict) -> String {
    CopyPasteChoices.runtimeConflictScope(
        reason: conflict.reason, conflictClass: conflict.conflictClass,
        destinationExists: conflict.currentDestinationFingerprint.exists)
}

extension WriteService {
    /// Answers the question a paste is waiting on; with `applyToRemaining`, later conflicts of the same kind are
    /// answered the same way, without asking, where that answer suits them. False (the question stays open) for
    /// another question than the one open, or an answer it doesn't offer.
    @discardableResult
    public func resolveRuntimeConflict(
        _ operationId: String, conflictId: String, action: CopyPasteChoice, applyToRemaining: Bool = false
    ) -> Bool {
        let answer = state.withLock { state -> RuntimeAnswer? in
            guard let pending = state.pendingResolutions[operationId],
                pending.conflict.conflictId.unicodeScalars.elementsEqual(conflictId.unicodeScalars)
            else { return nil }
            // An answer this conflict doesn't offer is refused; the question stays open.
            guard getAllowedRuntimeResolutions(pending.conflict).contains(action) else { return nil }
            state.pendingResolutions[operationId] = nil
            if applyToRemaining {
                state.standingResolutions[operationId, default: [:]][runtimeConflictScope(pending.conflict)] = action
            }
            return pending.answer
        }
        answer?.resolve(action)
        return answer != nil
    }

    /// Stops a paste, as the Stop button does: a question still open is dropped unanswered. False when there is
    /// no such paste running.
    @discardableResult
    public func cancelOperation(_ operationId: String) -> Bool {
        let (pending, signal) = state.withLock { state in
            let pending = state.pendingResolutions.removeValue(forKey: operationId)
            return (pending, state.signals[operationId])
        }
        // Stopped before the question is dropped, so the paste waking up to it finds itself stopped.
        signal?.stop()
        pending?.answer.resolve(nil)
        return signal != nil
    }

    /// Registers the question synchronously, before the progress event announcing it goes out, so an answer
    /// given from that event is not lost.
    func registerQuestion(_ operationId: String, _ conflict: CopyPasteRuntimeConflict) -> RuntimeAnswer {
        let answer = RuntimeAnswer()
        state.withLock { $0.pendingResolutions[operationId] = PendingResolution(conflict: conflict, answer: answer) }
        return answer
    }

    /// Only an answer given for the same kind of conflict, and one that makes sense for this conflict, is reused.
    func standingAnswer(_ operationId: String, _ conflict: CopyPasteRuntimeConflict) -> CopyPasteChoice? {
        let standing = state.withLock { $0.standingResolutions[operationId]?[runtimeConflictScope(conflict)] }
        guard let standing, getAllowedRuntimeResolutions(conflict).contains(standing) else { return nil }
        return standing
    }
}
