// Port of attachSender, handOver, detachSender, isOperationOwner, sendProgress, broadcast, watchAnalysisOwner,
// forgetAnalysis, analysesOfOtherWindows, assertAnalysisOwner and "writeOperation:getAdopted"
// (apps/desktop/src/main/bootstrap/writeOperations.ts): each operation and analysis belongs to the window that started
// it, and is handed on or cancelled when that window closes
import FTFoundation
import Foundation

extension WriteCoordinator {
    // MARK: A window closing

    /// A window closed (the original's "destroyed", "render-process-gone" and "did-navigate"): an operation it
    /// started goes on in the window `successorOf` names, or is cancelled when there is none; an analysis it started
    /// is cancelled, as nobody can answer its review.
    public func windowClosed(_ window: any WriteOperationWindow) {
        for operationId in watchedOperations.sorted() where senders[operationId] === window {
            handOverOrCancel(operationId, from: window)
        }
        for analysisId in watchedAnalyses.sorted() where analysisOwners[analysisId] === window {
            forgetAnalysis(analysisId)
            _ = writeService.cancelCopyPasteAnalysis(analysisId)
        }
    }

    /// How many of the window's operations and analyses listen for it to close (the original's listener count).
    public func watchCount(_ window: any WriteOperationWindow) -> Int {
        watchedOperations.filter { senders[$0] === window }.count
            + watchedAnalyses.filter { analysisOwners[$0] === window }.count
    }

    // MARK: Operations and their windows

    /// `attachSender`: an operation whose window closed can never be answered or finished from the UI, so it is
    /// cancelled instead of holding the write slot forever, unless another window takes it.
    func attachSender(_ operationId: String, _ sender: any WriteOperationWindow) {
        senders[operationId] = sender
        if sender.isClosed {
            // The window closed while the start request was in flight; nothing will ever answer this operation.
            _ = cancelWriteOperation(operationId)
            return
        }
        watchedOperations.insert(operationId)
    }

    private func handOverOrCancel(_ operationId: String, from window: any WriteOperationWindow) {
        if let successor = options.successorOf?(window), successor !== window, !successor.isClosed {
            handOver(operationId, to: successor)
            return
        }
        _ = cancelWriteOperation(operationId)
    }

    /// `handOver`: makes `successor` the window an operation answers to: its progress, Stop and conflict questions
    /// go there from now on.
    private func handOver(_ operationId: String, to successor: any WriteOperationWindow) {
        if let previous = senders[operationId], pendingAdoption(of: previous)?.operationId == operationId {
            pendingAdoptions[ObjectIdentifier(previous)] = nil
        }
        watchedOperations.remove(operationId)
        attachSender(operationId, successor)
        let clearsCutClipboard = copyPasteRequests[operationId]?.clearsCutClipboard
        pendingAdoptions[ObjectIdentifier(successor)] = PendingAdoption(
            window: successor, operationId: operationId, clearsCutClipboard: clearsCutClipboard, end: nil)
        do {
            try successor.receive(
                .adopted(
                    WriteOperationAdoption(
                        operationId: operationId, event: latestProgress[operationId],
                        clearsCutClipboard: clearsCutClipboard)))
        } catch {
            // The window went away mid-send; its own close hands the operation on again.
        }
    }

    func detachSender(_ operationId: String) {
        senders[operationId] = nil
        watchedOperations.remove(operationId)
        latestProgress[operationId] = nil
    }

    /// `isOperationOwner`: cancel and conflict answers are only taken from the window that started the operation.
    func isOperationOwner(_ operationId: String, _ requester: any WriteOperationWindow) -> Bool {
        senders[operationId] === requester
    }

    func pendingAdoption(of window: any WriteOperationWindow) -> PendingAdoption? {
        guard let pending = pendingAdoptions[ObjectIdentifier(window)], pending.window === window else { return nil }
        return pending
    }

    /// `writeOperation:getAdopted`: the operation handed to the window asking, if it hasn't heard of it yet, with
    /// where it is now or how it ended. Each hand-over is told once; asking again answers nil.
    public func adoptedOperation(window: any WriteOperationWindow) -> WriteOperationAdoption? {
        let pending = pendingAdoption(of: window)
        pendingAdoptions[ObjectIdentifier(window)] = nil
        guard let pending, !(pending.end == nil && senders[pending.operationId] !== window) else { return nil }
        return WriteOperationAdoption(
            operationId: pending.operationId, event: pending.end ?? latestProgress[pending.operationId],
            clearsCutClipboard: pending.clearsCutClipboard)
    }

    /// `sendProgress`: a window can go away between the check and the send; losing a progress update for a window
    /// that's gone is fine, letting the throw skip the operation's cleanup is not.
    func sendProgress(_ sender: any WriteOperationWindow, _ payload: WriteOperationEvent) {
        let operationId = payload.operationId
        if !payload.status.isTerminal, senders[operationId] != nil {
            latestProgress[operationId] = payload
        }
        if payload.status.isTerminal, var adoption = pendingAdoption(of: sender), adoption.operationId == operationId {
            adoption.end = payload
            pendingAdoptions[ObjectIdentifier(sender)] = adoption
        }
        broadcast(payload, owner: sender)
        if sender.isClosed { return }
        do {
            try sender.receive(.progress(payload))
        } catch {
            // The window went away mid-send; there is no one left to tell.
        }
    }

    /// `broadcast`: the other windows miss this update when telling them fails; the operation, and its own window,
    /// go on.
    func broadcast(_ payload: WriteOperationEvent, owner: any WriteOperationWindow) {
        do {
            try options.broadcastProgress?(payload.forOtherWindows, owner)
        } catch {
            options.logError("[filetrail] couldn't tell the other windows about an operation", error)
        }
    }

    // MARK: Analyses and their windows

    /// `watchAnalysisOwner`: an analysis whose window closed is cancelled: nobody can answer its review, and one
    /// still running would keep every other window from setting up a copy.
    func watchAnalysisOwner(_ analysisId: String, _ owner: any WriteOperationWindow) {
        analysisOwners[analysisId] = owner
        if owner.isClosed {
            forgetAnalysis(analysisId)
            _ = writeService.cancelCopyPasteAnalysis(analysisId)
            return
        }
        watchedAnalyses.insert(analysisId)
    }

    func forgetAnalysis(_ analysisId: String) {
        watchedAnalyses.remove(analysisId)
        analysisOwners[analysisId] = nil
    }

    /// `analysesOfOtherWindows`: their reviews may still be open, so the write service keeps them when it drops
    /// finished ones.
    func analysesOfOtherWindows(_ sender: any WriteOperationWindow) -> Set<String> {
        Set(analysisOwners.filter { $0.value !== sender }.keys)
    }

    /// `assertAnalysisOwner`: an analysis is read, cancelled, and started only by the window that asked for it.
    func assertAnalysisOwner(_ analysisId: String, _ requester: any WriteOperationWindow) throws {
        guard let owner = analysisOwners[analysisId], owner === requester else {
            throw WriteCoordinatorError.analysisOfAnotherWindow
        }
    }
}
