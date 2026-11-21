import FTFileSystem
import FTFoundation
import Foundation

/// How making one alias went, on the disk.
private enum MadeAlias: Sendable {
    case made(String)
    case failed(String)
}

extension WriteCoordinator {
    /// What writes an alias of an item at a path: the system's bookmark file, as Finder's Make Alias writes, unless a
    /// test gives its own.
    public typealias AliasWriter = @Sendable (_ original: String, _ aliasPath: String) throws -> Void

    /// Make Alias: an alias of each item beside it, named as Finder names one ("Report.pdf alias", then "Report.pdf
    /// alias 2"); nothing is replaced and the items are left as they are. One item that can't have one doesn't keep
    /// the others from theirs; only stopping stops the rest. One Undo moves the aliases to the Trash.
    @discardableResult
    public func makeAliases(
        paths requested: [String], window: any WriteOperationWindow,
        write: @escaping AliasWriter = { original, aliasPath in try Links.writeAlias(of: original, at: aliasPath) }
    ) async throws -> WriteOperationHandle {
        let paths = requested.map(NodePath.resolve)
        guard !paths.isEmpty else { throw WriteCoordinatorError("There are no items to make aliases of.") }
        var folders: [String] = []
        for folder in paths.map(NodePath.dirname) where !folders.contains(folder) {
            try WriteGuards.assertNotIntoTrash(folder, verb: "made in", homePath: homePath)
            folders.append(folder)
        }
        // The folder the aliases are selected in once they are made, when they are all in one.
        let targetPath = folders.count == 1 ? folders[0] : nil
        return try await prepareWithReservedSlot {
        } then: { _, reservation in
            let fileSystem = self.fileSystem
            // As for a copy: undoing it would mean deleting them, on a disk without a Trash.
            let undoable: @MainActor () -> Bool = { [weak self] in
                guard let self else { return false }
                return folders.allSatisfy { self.canBeTrashed(in: $0) }
            }
            return try queueLocalWriteOperation(action: .makeAlias, window: window, reservation: reservation) {
                local in
                await Self.executeMakeAliases(
                    paths, targetPath: targetPath, local, fileSystem, write: write, undoable: undoable)
            }
        }
    }

    static func executeMakeAliases(
        _ paths: [String], targetPath: String?, _ operation: LocalWriteOperation,
        _ fileSystem: any LocalWriteFileSystem, write: @escaping AliasWriter, undoable: @MainActor () -> Bool
    ) async {
        let startedAt = Date()
        var items: [WriteOperationItem] = []
        var completedItemCount = 0
        var cancelled = false
        // One unit per alias, so one that changed since doesn't keep the others from the Trash.
        var units: [UndoUnit] = []
        for (index, path) in paths.enumerated() {
            if operation.signal.isStopped {
                cancelled = true
                items += LocalWriteResults.notStartedItems(Array(paths[index...]))
                break
            }
            operation.emit(
                operation.progress(
                    .running, completedItemCount: completedItemCount, totalItemCount: paths.count,
                    currentSourcePath: path))
            switch await LocalOperations.onDisk({ makeOne(path, fileSystem, write) }) {
            case .failed(let message):
                items.append(
                    WriteOperationItem(sourcePath: path, destinationPath: nil, status: .failed, error: message))
            case .made(let destinationPath):
                units.append(UndoUnit(steps: [await createdStep(destinationPath, fileSystem)]))
                completedItemCount += 1
                items.append(
                    WriteOperationItem(sourcePath: path, destinationPath: destinationPath, status: .completed))
            }
        }
        let failedItemCount = items.filter { $0.status == .failed }.count
        let status = LocalWriteResults.terminalStatus(
            cancelled: cancelled, completedItemCount: completedItemCount, failedItemCount: failedItemCount)
        let error: String? =
            cancelled
            ? LocalWriteResults.stoppedMessage(completedItemCount, MakeAlias.stoppedDone)
            : failedItemCount > 0 ? items.first { $0.status == .failed }?.error : nil
        let result = LocalWriteResults.result(
            operationId: operation.operationId, action: .makeAlias, targetPath: targetPath, startedAt: startedAt,
            finishedAt: Date(), totalItemCount: paths.count, completedItemCount: completedItemCount, items: items,
            status: status, error: error)
        let undoLog: UndoLog? =
            units.isEmpty ? nil : undoable() ? .undoable(units: units) : .notUndoable(reason: .noTrash)
        operation.emit(
            operation.progress(
                status, completedItemCount: completedItemCount, totalItemCount: paths.count, result: result),
            undoLog: undoLog)
    }

    /// One alias, on the disk: written under a hidden name, then given the first free one of its own, so a half
    /// written alias never shows.
    private nonisolated static func makeOne(
        _ path: String, _ fileSystem: any LocalWriteFileSystem, _ write: AliasWriter
    ) -> MadeAlias {
        let folder = NodePath.dirname(path)
        do {
            try fileSystem.canModifyFolder(folder)
        } catch {
            return .failed(LocalOperations.describeWriteError(error, missing: NodePath.basename(folder)))
        }
        let name = MakeAlias.name(for: NodePath.basename(path))
        let partial = partialFilePath(for: NodePath.join(folder, name))
        do {
            try write(path, partial)
        } catch {
            try? fileSystem.rm(partial, recursive: false, force: true)
            return .failed(LocalOperations.describeWriteError(error, missing: NodePath.basename(path)))
        }
        do {
            // Numbered after the whole name, as Finder numbers aliases: "Report.pdf alias 2".
            return .made(try place(partial, in: folder, named: name, isFolder: true, fileSystem))
        } catch {
            try? fileSystem.rm(partial, recursive: false, force: true)
            return .failed(
                LocalOperations.describeWriteError(error, missing: NodePath.basename(folder), existing: name))
        }
    }
}
