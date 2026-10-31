// Port of the "writeOperation:rename" handler, prepareRenameOperation, executeRenameOperation, emitSingleItemResult and
// listsSeparateEntry (apps/desktop/src/main/bootstrap/writeOperations.ts)
import FTFileSystem
import FTFoundation
import Foundation

/// A rename checked and ready to run (`PreparedRenameOperation`).
struct PreparedRename: Sendable {
    var sourcePath: String
    var destinationPath: String
    /// The new name differs from the old one only in case (or in how an accented letter is encoded), and the disk
    /// treats both as the same name.
    var renamesItself: Bool
}

extension WriteCoordinator {
    /// The file system the local operations write with; the app's always is one.
    func localFileSystem() throws -> any LocalWriteFileSystem {
        guard let fileSystem = fileSystem as? any LocalWriteFileSystem else {
            throw WriteCoordinatorError("File Trail can\u{2019}t write to the disk here.")
        }
        return fileSystem
    }

    /// `writeOperation:rename`: renames one item in its folder. What the name and the disk allow is checked while
    /// the write slot is held for it, so nothing starts meanwhile; a refusal throws with the sentence to show.
    @discardableResult
    public func rename(sourcePath: String, destinationName: String, window: any WriteOperationWindow) async throws
        -> WriteOperationHandle
    {
        // The contract's name check (`itemNameSchema`).
        if let refusal = ItemNames.error(for: destinationName) {
            throw WriteCoordinatorError(refusal)
        }
        let operation = try await prepareWithReservedSlot {
            try await self.prepareRename(sourcePath: sourcePath, destinationName: destinationName)
        }
        let fileSystem = try localFileSystem()
        return try queueLocalWriteOperation(action: .rename, window: window) { local in
            await Self.executeRename(operation, local, fileSystem)
        }
    }

    /// `prepareRenameOperation`.
    func prepareRename(sourcePath rawSourcePath: String, destinationName rawName: String) async throws
        -> PreparedRename
    {
        let sourcePath = NodePath.resolve(rawSourcePath)
        try WriteGuards.assertNotProtectedPath([sourcePath], homePath: homePath)
        try await assertNotSystemLocation([sourcePath], verb: "renamed")
        let fileSystem = try localFileSystem()
        let destinationName = InlineRenameRules.trimmedName(rawName)
        return try await LocalOperations.onDisk {
            try Self.checkRename(sourcePath: sourcePath, destinationName: destinationName, fileSystem)
        }
    }

    private nonisolated static func checkRename(
        sourcePath: String, destinationName: String, _ fileSystem: any LocalWriteFileSystem
    ) throws -> PreparedRename {
        let sourceName = NodePath.basename(sourcePath)
        let folder = NodePath.dirname(sourcePath)
        let destinationPath = NodePath.join(folder, destinationName)
        let sourceStats: WriteServiceStats
        do {
            sourceStats = try fileSystem.lstat(sourcePath)
        } catch {
            throw WriteCoordinatorError(LocalOperations.describeWriteError(error, missing: sourceName))
        }
        if sameText(destinationPath, sourcePath) {
            throw WriteCoordinatorError("Choose a different name.")
        }
        let destinationStats = LocalOperations.lstatOrNull(fileSystem, destinationPath)
        // On a disk that ignores case, "notes.txt" finds "Notes.txt": the item itself, not another one in the way.
        // On a disk that minds case they are two different items, even two hard links to one file (renaming one
        // onto the other would do nothing at all).
        var renamesItself = false
        if let destinationStats, NameKeys.namesMatchIgnoringCase(sourceName, destinationName),
            LocalOperations.isSameItem(sourceStats, destinationStats) || !LocalOperations.hasFileId(sourceStats)
                || !LocalOperations.hasFileId(destinationStats)
        {
            renamesItself = !listsSeparateEntry(fileSystem, folder, destinationName)
        }
        if destinationStats != nil, !renamesItself {
            throw WriteCoordinatorError("An item named \u{201C}\(destinationName)\u{201D} already exists.")
        }
        return PreparedRename(sourcePath: sourcePath, destinationPath: destinationPath, renamesItself: renamesItself)
    }

    /// `listsSeparateEntry`: whether the folder holds an entry spelled exactly like `name` (another item, since the
    /// item being renamed is spelled differently). Unknown (false) when the folder can't be read.
    private nonisolated static func listsSeparateEntry(
        _ fileSystem: any LocalWriteFileSystem, _ folder: String, _ name: String
    ) -> Bool {
        guard let entries = try? fileSystem.readdir(folder) else { return false }
        return entries.contains { sameText($0, name) }
    }

    /// `executeRenameOperation`.
    static func executeRename(
        _ prepared: PreparedRename, _ operation: LocalWriteOperation, _ fileSystem: any LocalWriteFileSystem
    ) async {
        let sourcePath = prepared.sourcePath
        let destinationPath = prepared.destinationPath
        let startedAt = Date()
        do {
            try operation.signal.throwIfStopped()
            operation.emit(
                operation.progress(
                    .running, totalItemCount: 1, currentSourcePath: sourcePath,
                    currentDestinationPath: destinationPath))
            try operation.signal.throwIfStopped()
            let renamesItself = prepared.renamesItself
            try await LocalOperations.onDisk {
                if renamesItself {
                    try fileSystem.rename(sourcePath, destinationPath)
                } else {
                    // The name was free when it was checked, but something may have taken it since: this fails
                    // then, instead of replacing that item.
                    try fileSystem.renameExclusive(sourcePath, destinationPath)
                }
            }
        } catch {
            let cancelled = error is StopError || operation.signal.isStopped
            let message: String
            if cancelled {
                message = "Operation cancelled."
            } else {
                let locked = await LocalOperations.onDisk {
                    findLockedRefusal(
                        { try fileSystem.getFlags($0) }, error, [sourcePath, NodePath.dirname(sourcePath)]
                    )?.message
                }
                message =
                    locked
                    ?? LocalOperations.describeWriteError(
                        error, missing: NodePath.basename(sourcePath), existing: NodePath.basename(destinationPath))
            }
            emitSingleItemResult(
                operation, startedAt: startedAt, sourcePath: sourcePath, destinationPath: destinationPath,
                status: cancelled ? .cancelled : .failed, error: message)
            return
        }
        // Outside the do: the item has been renamed, and nothing that goes wrong while reporting it may turn that
        // into a failure (reading its id never throws).
        let step = await LocalOperations.onDisk { () -> UndoStep in
            let renamed = readItemRef({ try fileSystem.lstat($0) }, destinationPath)
            return .moved(
                UndoStep.Moved(
                    from: sourcePath, to: destinationPath, id: renamed.id, itemKind: renamed.kind,
                    parentId: readFolderId({ try fileSystem.stat($0) }, NodePath.dirname(sourcePath))))
        }
        emitSingleItemResult(
            operation, startedAt: startedAt, sourcePath: sourcePath, destinationPath: destinationPath,
            status: .completed, error: nil, undoLog: .undoable(units: [UndoUnit(steps: [step])]))
    }

    /// `emitSingleItemResult`: the end of a rename or new folder, which each change a single item.
    static func emitSingleItemResult(
        _ operation: LocalWriteOperation, startedAt: Date, sourcePath: String?, destinationPath: String,
        status: WriteOperationStatus, error: String?, undoLog: UndoLog? = nil
    ) {
        let completedItemCount = status == .completed ? 1 : 0
        let item = WriteOperationItem(
            sourcePath: sourcePath, destinationPath: destinationPath, status: Self.itemStatus(status), error: error)
        let result = LocalWriteResults.result(
            operationId: operation.operationId, action: operation.action, targetPath: destinationPath,
            startedAt: startedAt, finishedAt: Date(), totalItemCount: 1, completedItemCount: completedItemCount,
            items: [item], status: status, error: error)
        operation.emit(
            operation.progress(
                status, completedItemCount: completedItemCount, totalItemCount: 1, currentSourcePath: sourcePath,
                currentDestinationPath: destinationPath, result: result),
            undoLog: undoLog)
    }

    /// An item's status for an operation's: the same words.
    static func itemStatus(_ status: WriteOperationStatus) -> CopyPasteItemResult.Status {
        switch status {
        case .completed: .completed
        case .cancelled: .cancelled
        case .partial: .completed
        default: .failed
        }
    }
}
