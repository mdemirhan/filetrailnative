// Port of the "writeOperation:batchRename" handler, prepareBatchRenameOperation and executeBatchRenameOperation
// (apps/desktop/src/main/bootstrap/writeOperations.ts)
import FTFoundation
import Foundation

/// What runs a batch rename on the disk (tests make it fail as nothing else can).
typealias BatchRenameRunner =
    @Sendable (
        _ request: BatchRenameRequest, _ fileSystem: LocalBatchRenameFileSystem, _ signal: StopSignal,
        _ journal: (any WriteJournal)?, _ onItemStart: @escaping @Sendable (String, String, Int) -> Void
    ) throws -> BatchRenameRun

extension WriteCoordinator {
    /// The batch rename, as the coordinator runs it.
    static let runBatchRename: BatchRenameRunner = { request, fileSystem, signal, journal, onItemStart in
        BatchRenameExecution.run(
            request, fileSystem: fileSystem, signal: signal, onItemStart: onItemStart, journal: journal)
    }

    /// `writeOperation:batchRename`: renames several items at once, each in its own folder. What the request asks
    /// is checked while the write slot is held for it, so nothing starts meanwhile; a refusal throws with the
    /// sentence to show.
    @discardableResult
    public func batchRename(_ payload: BatchRenameRequest, window: any WriteOperationWindow) async throws
        -> WriteOperationHandle
    {
        let request = try await prepareWithReservedSlot { try await self.prepareBatchRename(payload) }
        let fileSystem = LocalBatchRenameFileSystem(try localFileSystem())
        return try queueLocalWriteOperation(action: .batchRename, window: window) { [weak self] operation in
            await self?.executeBatchRename(request, operation, fileSystem)
        }
    }

    /// `prepareBatchRenameOperation`: what the request asks is checked before the write slot is taken: nothing
    /// protected, no item twice. An item asked to keep its own name is left out.
    func prepareBatchRename(_ payload: BatchRenameRequest) async throws -> BatchRenameRequest {
        var request = payload
        request.items =
            payload.items
            .map { item in
                var item = item
                item.sourcePath = NodePath.resolve(item.sourcePath)
                return item
            }
            .filter { !sameText(NodePath.basename($0.sourcePath), InlineRenameRules.trimmedName($0.destinationName)) }
        if request.items.isEmpty {
            throw WriteCoordinatorError("Nothing would be renamed.")
        }
        var sources = Set<NameKeys.Exact>()
        for item in request.items where !sources.insert(NameKeys.Exact(item.sourcePath)).inserted {
            throw WriteCoordinatorError("\u{201C}\(NodePath.basename(item.sourcePath))\u{201D} is in the list twice.")
        }
        let sourcePaths = request.items.map(\.sourcePath)
        try WriteGuards.assertNotProtectedPath(sourcePaths, homePath: homePath)
        try await assertNotSystemLocation(sourcePaths, verb: "renamed")
        return request
    }

    /// `executeBatchRenameOperation`.
    func executeBatchRename(
        _ request: BatchRenameRequest, _ operation: LocalWriteOperation, _ fileSystem: LocalBatchRenameFileSystem
    ) async {
        let startedAt = Date()
        let totalItemCount = request.items.count
        let operationId = operation.operationId
        let action = operation.action
        let signal = operation.signal
        let journal = options.writeJournal
        let runner = batchRenameRunner
        let onItemStart: @Sendable (String, String, Int) -> Void = {
            [weak self] sourcePath, destinationPath, completed in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.emitLocalWriteOperationEvent(
                        WriteOperationEvent(
                            operationId: operationId, action: action, status: .running,
                            completedItemCount: completed, totalItemCount: totalItemCount,
                            currentSourcePath: sourcePath, currentDestinationPath: destinationPath))
                }
            }
        }
        var run: BatchRenameRun
        do {
            run = try await LocalOperations.onDisk {
                try runner(request, fileSystem, signal, journal, onItemStart)
            }
        } catch {
            // Nothing expected gets here: every item's failure is in its result. Should something else go wrong, the
            // window still hears the end, so it isn't left waiting.
            run = BatchRenameRun(
                items: request.items.map {
                    WriteOperationItem(
                        sourcePath: NodePath.resolve($0.sourcePath), destinationPath: nil, status: .failed,
                        error: "The rename stopped unexpectedly: \(errorMessage(error))")
                },
                completedItemCount: 0, cancelled: false)
        }
        let failedItemCount = run.items.filter { $0.status == .failed }.count
        let status = LocalWriteResults.terminalStatus(
            cancelled: run.cancelled, completedItemCount: run.completedItemCount, failedItemCount: failedItemCount)
        // One folder when all the items are in it, for the window to look at.
        var seen = Set<NameKeys.Exact>()
        let folders = request.items.map { NodePath.dirname(NodePath.resolve($0.sourcePath)) }
            .filter { seen.insert(NameKeys.Exact($0)).inserted }
        let error: String? =
            run.cancelled
            ? LocalWriteResults.stoppedMessage(run.completedItemCount, "renamed")
            : failedItemCount > 0 ? (run.items.first { $0.status == .failed }?.error ?? "Rename failed.") : nil
        let result = LocalWriteResults.result(
            operationId: operationId, action: action, targetPath: folders.count == 1 ? folders[0] : nil,
            startedAt: startedAt, finishedAt: Date(), totalItemCount: totalItemCount,
            completedItemCount: run.completedItemCount, items: run.items, status: status, error: error)
        let items = run.items
        let renamedItems = await LocalOperations.onDisk { BatchRenameExecution.movedItemsOf(fileSystem, items) }
        let step = UndoStep.batchRenamed(items: renamedItems)
        operation.emit(
            operation.progress(
                status, completedItemCount: run.completedItemCount, totalItemCount: totalItemCount, result: result),
            undoLog: renamedItems.isEmpty ? nil : .undoable(units: [UndoUnit(steps: [step])]))
    }
}
