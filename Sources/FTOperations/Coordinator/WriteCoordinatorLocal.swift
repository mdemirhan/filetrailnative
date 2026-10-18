// Port of queueLocalWriteOperation, emitUnexpectedEnd, releaseLocalWriteOperation, emitLocalWriteOperationEvent,
// createLocalWriteOperationResult, resolveLocalTerminalStatus, stoppedMessage and notStartedItems
// (apps/desktop/src/main/bootstrap/writeOperations.ts): the one entry point through which rename, New Folder, Trash,
// Delete Immediately (P3-06), Undo and Redo (P3-07) and batch rename (P3-08) take the write slot
import FTFileSystem
import FTFoundation
import Foundation

/// A local operation running in the write slot, as its work sees it: its id, its Stop, and where its progress goes.
@MainActor
public struct LocalWriteOperation {
    public let operationId: String
    public let action: WriteOperationAction
    /// Stop pressed, its window closed with no other to take it, or the app quitting.
    public let signal: StopSignal
    weak var coordinator: WriteCoordinator?

    /// `emitLocalWriteOperationEvent`: tells the window how the operation is doing. A terminal event first forgets
    /// what the operation changed (`removedItems`: what a delete removed, read just before, taken off the measured
    /// folders' sizes), records `undoLog` for Undo (left out when it changed nothing), and frees the slot.
    public func emit(_ event: WriteOperationEvent, removedItems: [RemovedItem] = [], undoLog: UndoLog? = nil) {
        coordinator?.emitLocalWriteOperationEvent(event, removedItems: removedItems, undoLog: undoLog)
    }

    /// The event of this operation with `status` and the given counts (`queued`, `running`).
    public func progress(
        _ status: WriteOperationStatus, completedItemCount: Int = 0, totalItemCount: Int = 0,
        currentSourcePath: String? = nil, currentDestinationPath: String? = nil, result: WriteOperationResult? = nil
    ) -> WriteOperationEvent {
        WriteOperationEvent(
            operationId: operationId, action: action, status: status, completedItemCount: completedItemCount,
            totalItemCount: totalItemCount, currentSourcePath: currentSourcePath,
            currentDestinationPath: currentDestinationPath, result: result)
    }
}

extension WriteCoordinator {
    /// `queueLocalWriteOperation`: takes the slot for a local operation of `window` and starts `execute`. Refused
    /// while another operation runs, or once the app is quitting. A throw from `execute` ends the operation as
    /// failed ("The operation stopped unexpectedly: …"); the slot is freed whatever happens.
    @discardableResult
    public func queueLocalWriteOperation(
        action: WriteOperationAction, window: any WriteOperationWindow,
        execute: @escaping @MainActor (LocalWriteOperation) async throws -> Void
    ) throws -> WriteOperationHandle {
        let operationId = "write-op-\(localSequence + 1)"
        // The app may have started quitting while a rename was being checked.
        try claimSlot(operationId)
        localSequence += 1
        options.caches.writeStarting()
        let signal = StopSignal()
        localStops[operationId] = signal
        localActions[operationId] = action
        attachSender(operationId, window)
        let operation = LocalWriteOperation(
            operationId: operationId, action: action, signal: signal, coordinator: self)
        emitLocalWriteOperationEvent(operation.progress(.queued))
        Task { [weak self] in
            do {
                try await execute(operation)
            } catch {
                self?.options.logError("[filetrail] local write operation failed unexpectedly", error)
                // Normally the operation's end was sent already. Should it have stopped before, every window is told
                // it failed: each would otherwise wait for it, refusing to start anything else.
                if self?.localActions[operationId] != nil {
                    self?.emitUnexpectedEnd(operationId, action: action, error: error)
                }
            }
            // Normally the terminal event already released everything; this only matters if the operation stopped
            // without reaching one, which would otherwise lock writes.
            self?.releaseLocalWriteOperation(operationId)
        }
        return WriteOperationHandle(operationId: operationId)
    }

    private func emitUnexpectedEnd(_ operationId: String, action: WriteOperationAction, error: any Error) {
        let now = Date()
        let message = "The operation stopped unexpectedly: \(errorMessage(error))"
        emitLocalWriteOperationEvent(
            WriteOperationEvent(
                operationId: operationId, action: action, status: .failed,
                result: LocalWriteResults.result(
                    operationId: operationId, action: action, targetPath: nil, startedAt: now, finishedAt: now,
                    totalItemCount: 0, completedItemCount: 0, items: [], status: .failed, error: message)))
    }

    private func releaseLocalWriteOperation(_ operationId: String) {
        detachSender(operationId)
        localStops[operationId] = nil
        localActions[operationId] = nil
        freeWriteSlot(operationId)
    }

    func emitLocalWriteOperationEvent(
        _ event: WriteOperationEvent, removedItems: [RemovedItem] = [], undoLog: UndoLog? = nil
    ) {
        let operationId = event.operationId
        let sender = senders[operationId]
        // Release the operation before telling the window, so a failed send can't leave the write slot held and a
        // window reacting to the final event can start the next write.
        if event.status.isTerminal {
            let removedPaths = Set(removedItems.map { Array($0.path.utf8) })
            forgetCachedResponses(
                event.result?.changedPaths.filter { !removedPaths.contains(Array($0.utf8)) } ?? [], removedItems)
            options.caches.writeEnded()
            if let undoLog {
                recordFinishedWrite(
                    FinishedWrite(action: .write(event.action), log: undoLog, items: event.result?.items ?? []))
            }
            releaseLocalWriteOperation(operationId)
        }
        if let sender {
            deliverProgress(operationId, status: event.status, asksUser: false) { [weak self] in
                self?.sendProgress(sender, event)
            }
        } else {
            forgetProgress(operationId)
        }
    }
}

/// How a local operation's result is put together (`createLocalWriteOperationResult` and its helpers).
public enum LocalWriteResults {
    /// `createLocalWriteOperationResult`.
    public static func result(
        operationId: String, action: WriteOperationAction, targetPath: String?, startedAt: Date, finishedAt: Date,
        totalItemCount: Int, completedItemCount: Int, items: [WriteOperationItem], status: WriteOperationStatus,
        error: String?
    ) -> WriteOperationResult {
        WriteOperationResult(
            operationId: operationId, action: action, status: status, targetPath: targetPath, startedAt: startedAt,
            finishedAt: finishedAt,
            summary: CopyPasteOperationSummary(
                topLevelItemCount: items.count, totalItemCount: totalItemCount, completedItemCount: completedItemCount,
                failedItemCount: items.filter { $0.status == .failed }.count,
                skippedItemCount: items.filter { $0.status == .skipped }.count,
                cancelledItemCount: items.filter { $0.status == .cancelled }.count, completedByteCount: 0,
                totalBytes: nil),
            items: items, error: error)
    }

    /// `resolveLocalTerminalStatus`.
    public static func terminalStatus(cancelled: Bool, completedItemCount: Int, failedItemCount: Int)
        -> WriteOperationStatus
    {
        if cancelled {
            return completedItemCount > 0 ? .partial : .cancelled
        }
        if failedItemCount > 0 {
            return completedItemCount > 0 ? .partial : .failed
        }
        return .completed
    }

    /// `stoppedMessage`: "Stopped after 2 items were moved to the Trash." (`done` is "moved to the Trash",
    /// "deleted", "renamed"…).
    public static func stoppedMessage(_ doneCount: Int, _ done: String) -> String {
        if doneCount == 0 {
            return "Operation cancelled."
        }
        return "Stopped after \(doneCount == 1 ? "1 item was" : "\(doneCount) items were") \(done)."
    }

    /// `notStartedItems`: the items a stopped Trash or delete never reached, each listed, so the result counts
    /// everything that was left alone.
    public static func notStartedItems(_ paths: [String]) -> [WriteOperationItem] {
        paths.map {
            WriteOperationItem(
                sourcePath: $0, destinationPath: nil, status: .cancelled,
                error: "Not started because the operation was stopped.")
        }
    }
}
