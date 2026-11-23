import FTFileSystem
import FTFoundation
import Foundation

/// How a file whose name is taken gets its number.
enum TakenNameNumbering: Sendable {
    /// A name the app gave counts on from a number it ends in: "Pasted Image 3.png" taken gives
    /// "Pasted Image 4.png".
    case countingOn
    /// A person's own name is numbered whole, whatever it ends in, as `PasteAsFile.freeName` numbers one:
    /// "Scan 3.png" taken gives "Scan 3 2.png". "Scan 4.png" would read as the next scan.
    case wholeName
}

extension WriteCoordinator {
    /// Makes one file holding `contents` in `parentDirectoryPath`: Paste as File, or New File (`action`). With
    /// `nextFreeName`, the name is only a suggestion ("Pasted Image.png"): when it is taken (by something the window
    /// hasn't listed yet), the next free one ("Pasted Image 2.png") is used. The file is filled under a hidden name
    /// first and then given its own, so a file half written never shows, and nothing already there is replaced.
    @discardableResult
    public func createFile(
        parentDirectoryPath: String, fileName: String, contents: Data, nextFreeName: Bool = false,
        action: WriteOperationAction = .pasteAsFile, window: any WriteOperationWindow
    ) async throws -> WriteOperationHandle {
        if let refusal = ItemNames.error(for: fileName) {
            throw WriteCoordinatorError(refusal)
        }
        return try await prepareWithReservedSlot {
            try await self.prepareNewItem(
                parentDirectoryPath: parentDirectoryPath, name: fileName, nextFreeName: nextFreeName,
                nextFree: Self.nextFreeFilePath)
        } then: { destinationPath, reservation in
            let fileSystem = self.fileSystem
            // As for a copy: undoing it would mean deleting it, on a disk without a Trash.
            let undoable: @MainActor () -> Bool = { [weak self] in
                self?.canBeTrashed(in: NodePath.dirname(destinationPath)) ?? false
            }
            return try queueLocalWriteOperation(action: action, window: window, reservation: reservation) {
                local in
                await Self.executeCreateFile(destinationPath, contents, local, fileSystem, undoable: undoable)
            }
        }
    }

    /// "Pasted Image.png" taken: "Pasted Image 2.png", "Pasted Image 3.png"… (from "Pasted Image 3.png", the next).
    nonisolated static func nextFreeFilePath(
        _ parentDirectoryPath: String, _ name: String, _ fileSystem: any LocalWriteFileSystem
    ) throws -> String {
        try nextFreeFilePath(parentDirectoryPath, name, numbering: .countingOn, fileSystem)
    }

    /// The first free name for a file whose name is taken, numbered as `numbering` says.
    nonisolated static func nextFreeFilePath(
        _ parentDirectoryPath: String, _ name: String, numbering: TakenNameNumbering,
        _ fileSystem: any LocalWriteFileSystem
    ) throws -> String {
        let split = NumberedNames.splitItemName(name, isFolder: false)
        let (stem, first) = numbering == .countingOn ? numberedBase(split.stem) : (split.stem, 2)
        let unnumbered = stem + (split.extension.map { ".\($0)" } ?? "")
        var number = first
        while number < first + 10_000 {
            let candidate = NodePath.join(
                parentDirectoryPath,
                NumberedNames.addNumberToName(unnumbered, isFolder: false, separator: " ", number: number).name)
            if LocalOperations.lstatOrNull(fileSystem, candidate) == nil {
                return candidate
            }
            number += 1
        }
        throw WriteCoordinatorError("An item named \u{201C}\(name)\u{201D} already exists.")
    }

    /// The hidden name a file is filled under, next to where it goes.
    nonisolated static func partialFilePath(for destinationPath: String) -> String {
        NodePath.join(NodePath.dirname(destinationPath), ".\(UUID().uuidString).filetrail-partial")
    }

    static func executeCreateFile(
        _ destinationPath: String, _ contents: Data, _ operation: LocalWriteOperation,
        _ fileSystem: any LocalWriteFileSystem, undoable: @MainActor () -> Bool
    ) async {
        let startedAt = Date()
        do {
            try operation.signal.throwIfStopped()
            operation.emit(
                operation.progress(.running, totalItemCount: 1, currentDestinationPath: destinationPath))
            try operation.signal.throwIfStopped()
            try await LocalOperations.onDisk {
                let partial = partialFilePath(for: destinationPath)
                try fileSystem.writeNewFile(partial, contents)
                do {
                    try fileSystem.renameExclusive(partial, destinationPath)
                } catch {
                    try? fileSystem.rm(partial, recursive: false, force: true)
                    throw error
                }
            }
        } catch {
            let cancelled = error is StopError || operation.signal.isStopped
            emitSingleItemResult(
                operation, startedAt: startedAt, sourcePath: nil, destinationPath: destinationPath,
                status: cancelled ? .cancelled : .failed,
                error: cancelled
                    ? "Stopped before anything was changed."
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
