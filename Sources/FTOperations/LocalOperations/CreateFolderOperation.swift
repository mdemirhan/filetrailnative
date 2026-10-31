// Port of the "writeOperation:createFolder" handler, prepareCreateFolderOperation, executeCreateFolderOperation and
// nextFreeFolderPath (apps/desktop/src/main/bootstrap/writeOperations.ts)
import FTFileSystem
import FTFoundation
import Foundation

extension WriteCoordinator {
    /// `writeOperation:createFolder`: makes one folder in `parentDirectoryPath`. With `nextFreeName`, the name is
    /// only a suggestion ("untitled folder"): when it is taken (by something the window hasn't listed yet), the next
    /// free one ("untitled folder 2") is used. A name the person typed is never changed: it is refused.
    @discardableResult
    public func createFolder(
        parentDirectoryPath: String, folderName: String, nextFreeName: Bool = false, window: any WriteOperationWindow
    ) async throws -> WriteOperationHandle {
        if let refusal = ItemNames.error(for: folderName) {
            throw WriteCoordinatorError(refusal)
        }
        let destinationPath = try await prepareWithReservedSlot {
            try await self.prepareCreateFolder(
                parentDirectoryPath: parentDirectoryPath, folderName: folderName, nextFreeName: nextFreeName)
        }
        let fileSystem = try localFileSystem()
        // As for a copy: undoing it would mean deleting it, on a disk without a Trash.
        let undoable: @MainActor () -> Bool = { [weak self] in
            self?.canBeTrashed(in: NodePath.dirname(destinationPath)) ?? false
        }
        return try queueLocalWriteOperation(action: .newFolder, window: window) { local in
            await Self.executeCreateFolder(destinationPath, local, fileSystem, undoable: undoable)
        }
    }

    /// `prepareCreateFolderOperation`: the folder's path.
    func prepareCreateFolder(parentDirectoryPath rawParent: String, folderName rawName: String, nextFreeName: Bool)
        async throws -> String
    {
        let parentDirectoryPath = NodePath.resolve(rawParent)
        try WriteGuards.assertNotIntoTrash(parentDirectoryPath, verb: "made in", homePath: homePath)
        let fileSystem = try localFileSystem()
        let folderName = InlineRenameRules.trimmedName(rawName)
        return try await LocalOperations.onDisk {
            let destinationPath = NodePath.join(parentDirectoryPath, folderName)
            let parentStats: WriteServiceStats
            do {
                parentStats = try fileSystem.stat(parentDirectoryPath)
            } catch {
                throw WriteCoordinatorError(
                    LocalOperations.describeWriteError(error, missing: NodePath.basename(parentDirectoryPath)))
            }
            if !parentStats.isDirectory {
                throw WriteCoordinatorError("Folder destination must be an existing directory.")
            }
            if LocalOperations.lstatOrNull(fileSystem, destinationPath) != nil {
                if nextFreeName {
                    return try Self.nextFreeFolderPath(parentDirectoryPath, folderName, fileSystem)
                }
                throw WriteCoordinatorError("An item named \u{201C}\(folderName)\u{201D} already exists.")
            }
            return destinationPath
        }
    }

    /// `nextFreeFolderPath`: "untitled folder" taken: "untitled folder 2", "untitled folder 3"… (from
    /// "untitled folder 3", the next).
    nonisolated static func nextFreeFolderPath(
        _ parentDirectoryPath: String, _ name: String, _ fileSystem: any LocalWriteFileSystem
    ) throws -> String {
        let (base, first) = numberedBase(name)
        var number = first
        while number < first + 10_000 {
            let candidate = NodePath.join(parentDirectoryPath, "\(base) \(number)")
            if LocalOperations.lstatOrNull(fileSystem, candidate) == nil {
                return candidate
            }
            number += 1
        }
        throw WriteCoordinatorError("An item named \u{201C}\(name)\u{201D} already exists.")
    }

    /// `/^(.*?) (\d+)$/u`: the name before a trailing " N", and the number after N to try first (2 without one).
    nonisolated static func numberedBase(_ name: String) -> (base: String, first: Int) {
        let scalars = Array(name.unicodeScalars)
        var digitsStart = scalars.count
        while digitsStart > 0, ("0"..."9").contains(scalars[digitsStart - 1]) {
            digitsStart -= 1
        }
        guard digitsStart < scalars.count, digitsStart > 0, scalars[digitsStart - 1] == " " else {
            return (name, 2)
        }
        // The lazy `(.*?)` leaves every digit it can to `(\d+)`.
        let base = String(String.UnicodeScalarView(scalars[..<(digitsStart - 1)]))
        let digits = String(String.UnicodeScalarView(scalars[digitsStart...]))
        guard let number = Int(digits), number < Int.max - 10_001 else { return (name, 2) }
        return (base, number + 1)
    }

    /// `executeCreateFolderOperation`.
    static func executeCreateFolder(
        _ destinationPath: String, _ operation: LocalWriteOperation, _ fileSystem: any LocalWriteFileSystem,
        undoable: @MainActor () -> Bool
    ) async {
        let startedAt = Date()
        do {
            try operation.signal.throwIfStopped()
            operation.emit(
                operation.progress(.running, totalItemCount: 1, currentDestinationPath: destinationPath))
            try operation.signal.throwIfStopped()
            try await LocalOperations.onDisk { try fileSystem.mkdir(destinationPath) }
        } catch {
            let cancelled = error is StopError || operation.signal.isStopped
            emitSingleItemResult(
                operation, startedAt: startedAt, sourcePath: nil, destinationPath: destinationPath,
                status: cancelled ? .cancelled : .failed,
                error: cancelled
                    ? "Operation cancelled."
                    : LocalOperations.describeWriteError(
                        error, missing: NodePath.basename(NodePath.dirname(destinationPath)),
                        existing: NodePath.basename(destinationPath)))
            return
        }
        // Outside the do, for the same reason as a rename's.
        let created = await LocalOperations.onDisk { () -> UndoStep in
            .created(
                path: destinationPath, id: readItemId({ try fileSystem.lstat($0) }, destinationPath),
                stamp: readItemStamp(StampReader(fileSystem), destinationPath))
        }
        emitSingleItemResult(
            operation, startedAt: startedAt, sourcePath: nil, destinationPath: destinationPath, status: .completed,
            error: nil,
            undoLog: undoable() ? .undoable(units: [UndoUnit(steps: [created])]) : .notUndoable(reason: .noTrash))
    }
}
