import FTFileSystem
import FTFoundation
import Foundation

/// A New Folder with Selection checked and ready to run: the folder to make and the items to move into it, all in
/// the folder that holds them.
struct PreparedFolderWithSelection: Sendable {
    var folderPath: String
    var itemPaths: [String]
}

extension WriteCoordinator {
    /// Makes a folder in `parentDirectoryPath` ("untitled folder", or the next free name) and moves `itemPaths`, items
    /// of that folder, into it. One Undo moves them back out and takes the folder away.
    @discardableResult
    public func newFolderWithSelection(
        parentDirectoryPath: String, itemPaths: [String], folderName: String, window: any WriteOperationWindow
    ) async throws -> WriteOperationHandle {
        if let refusal = ItemNames.error(for: folderName) {
            throw WriteCoordinatorError(refusal)
        }
        let parent = NodePath.resolve(parentDirectoryPath)
        let items = Paths.withoutNestedPaths(itemPaths.map(NodePath.resolve))
        guard !items.isEmpty else { throw WriteCoordinatorError("Select the items to put in the new folder.") }
        // Each a rename in the one folder, so one disk: never a copy.
        guard items.allSatisfy({ sameText(NodePath.dirname($0), parent) }) else {
            throw WriteCoordinatorError("The items have to be in the folder the new folder is made in.")
        }
        try WriteGuards.assertNotProtectedPath(items, homePath: homePath)
        try WriteGuards.assertNotAlreadyInTrash(items, homePath: homePath)
        return try await prepareWithReservedSlot {
            try await self.assertNotSystemLocation(items, verb: "moved")
            let folderPath = try await self.prepareNewItem(
                parentDirectoryPath: parent, name: folderName, nextFreeName: true, nextFree: Self.nextFreeFolderPath)
            return PreparedFolderWithSelection(folderPath: folderPath, itemPaths: items)
        } then: { prepared, reservation in
            let fileSystem = self.fileSystem
            // As for New Folder: undoing it puts the folder in the Trash.
            let undoable: @MainActor () -> Bool = { [weak self] in
                self?.canBeTrashed(in: NodePath.dirname(prepared.folderPath)) ?? false
            }
            return try queueLocalWriteOperation(
                action: .newFolderWithSelection, window: window, reservation: reservation
            ) { local in
                await Self.executeNewFolderWithSelection(prepared, local, fileSystem, undoable: undoable)
            }
        }
    }

    static func executeNewFolderWithSelection(
        _ prepared: PreparedFolderWithSelection, _ operation: LocalWriteOperation,
        _ fileSystem: any LocalWriteFileSystem, undoable: @MainActor () -> Bool
    ) async {
        let folderPath = prepared.folderPath
        let paths = prepared.itemPaths
        let startedAt = Date()
        let totalItemCount = paths.count
        do {
            try operation.signal.throwIfStopped()
            operation.emit(
                operation.progress(.running, totalItemCount: totalItemCount, currentDestinationPath: folderPath))
            try await LocalOperations.onDisk { try fileSystem.mkdir(folderPath) }
        } catch {
            let cancelled = error is StopError || operation.signal.isStopped
            finish(
                operation, startedAt: startedAt, folderPath: folderPath, paths: paths,
                items: LocalWriteResults.notStartedItems(paths), completedItemCount: 0, cancelled: cancelled,
                error: cancelled
                    ? "Operation cancelled."
                    : LocalOperations.describeWriteError(
                        error, missing: NodePath.basename(NodePath.dirname(folderPath)),
                        existing: NodePath.basename(folderPath)),
                undoLog: nil)
            return
        }
        // How the folder looked empty: Undo takes it away once the items are back out of it, and asks first when
        // something else was put in it since.
        let created = await LocalOperations.onDisk { () -> UndoStep in
            .created(
                path: folderPath, id: readItemId({ try fileSystem.lstat($0) }, folderPath),
                stamp: readItemStamp(StampReader(fileSystem), folderPath))
        }
        let parentId = await LocalOperations.onDisk {
            readFolderId({ try fileSystem.stat($0) }, NodePath.dirname(folderPath))
        }
        var steps: [UndoStep] = [created]
        var items: [WriteOperationItem] = []
        var completedItemCount = 0
        var cancelled = false
        // One item that can't be moved doesn't keep the others out; only stopping stops the rest.
        for (index, path) in paths.enumerated() {
            if operation.signal.isStopped {
                cancelled = true
                items += LocalWriteResults.notStartedItems(Array(paths[index...]))
                break
            }
            operation.emit(
                operation.progress(
                    .running, completedItemCount: completedItemCount, totalItemCount: totalItemCount,
                    currentSourcePath: path, currentDestinationPath: folderPath))
            let destinationPath = NodePath.join(folderPath, NodePath.basename(path))
            let moved = await LocalOperations.onDisk { () -> Result<UndoStep, WriteCoordinatorError> in
                // Read before the move: Undo puts it back under its own name, however it was spelled when chosen.
                let ownPath = pathAsOnDisk(path)
                do {
                    try fileSystem.renameExclusive(path, destinationPath)
                } catch {
                    let locked = findLockedRefusal(
                        { try fileSystem.getFlags($0) }, error, [path, NodePath.dirname(path)])?.message
                    return .failure(
                        WriteCoordinatorError(
                            locked
                                ?? LocalOperations.describeWriteError(
                                    error, missing: NodePath.basename(path),
                                    existing: NodePath.basename(destinationPath))))
                }
                let item = readItemRef({ try fileSystem.lstat($0) }, destinationPath)
                return .success(
                    .moved(
                        UndoStep.Moved(
                            from: ownPath, to: destinationPath, id: item.id, itemKind: item.kind,
                            parentId: parentId)))
            }
            switch moved {
            case .success(let step):
                steps.append(step)
                completedItemCount += 1
                items.append(
                    WriteOperationItem(sourcePath: path, destinationPath: destinationPath, status: .completed))
            case .failure(let failure):
                items.append(
                    WriteOperationItem(
                        sourcePath: path, destinationPath: destinationPath, status: .failed, error: failure.message))
            }
        }
        // Nothing went in: the empty folder goes too, so nothing has changed.
        if completedItemCount == 0 {
            let removed = await LocalOperations.onDisk { (try? fileSystem.rmdir(folderPath)) != nil }
            if removed {
                let error = cancelled ? "Operation cancelled." : (items.first { $0.status == .failed }?.error)
                finish(
                    operation, startedAt: startedAt, folderPath: folderPath, paths: paths, items: items,
                    completedItemCount: 0, cancelled: cancelled, error: error, undoLog: nil)
                return
            }
        }
        let failedItemCount = items.filter { $0.status == .failed }.count
        let error: String? =
            cancelled
            ? LocalWriteResults.stoppedMessage(completedItemCount, "moved into the new folder")
            : failedItemCount > 0 ? items.first { $0.status == .failed }?.error : nil
        finish(
            operation, startedAt: startedAt, folderPath: folderPath, paths: paths, items: items,
            completedItemCount: completedItemCount, cancelled: cancelled, error: error,
            undoLog: undoable() ? .undoable(units: [UndoUnit(steps: steps)]) : .notUndoable(reason: .noTrash))
    }

    private static func finish(
        _ operation: LocalWriteOperation, startedAt: Date, folderPath: String, paths: [String],
        items: [WriteOperationItem], completedItemCount: Int, cancelled: Bool, error: String?, undoLog: UndoLog?
    ) {
        let failedItemCount = items.filter { $0.status == .failed }.count
        let status = LocalWriteResults.terminalStatus(
            cancelled: cancelled, completedItemCount: completedItemCount, failedItemCount: failedItemCount)
        let result = LocalWriteResults.result(
            operationId: operation.operationId, action: operation.action, targetPath: folderPath,
            startedAt: startedAt, finishedAt: Date(), totalItemCount: paths.count,
            completedItemCount: completedItemCount, items: items, status: status, error: error)
        operation.emit(
            operation.progress(
                status, completedItemCount: completedItemCount, totalItemCount: paths.count,
                currentDestinationPath: folderPath, result: result),
            undoLog: undoLog)
    }
}
