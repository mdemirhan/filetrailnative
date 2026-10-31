// Port of the "writeOperation:deleteImmediately" handler, executeDeleteImmediatelyOperation, assertDeletableImmediately,
// readRealHomePath, placeInTrash and assertStillAskedItem (apps/desktop/src/main/bootstrap/writeOperations.ts)
import FTFileSystem
import FTFoundation
import Foundation

/// Where an item really is, for Delete Immediately (`placeInTrash`).
private enum PlaceInTrash {
    case inside, trashFolder, outside
}

/// How deleting one item went, read on the disk.
private struct DeletedItem: Sendable {
    var before: ItemSizeLook?
    /// Anything may be gone for good: the item was deleted, or a folder's delete failed part way.
    var began = false
    var failure: String?
}

extension WriteCoordinator {
    /// `writeOperation:deleteImmediately`: deletes the items for good. Only what is in a Trash may be, or what a
    /// Move to Trash of this window just found has no Trash to go to, and is still the item it was.
    @discardableResult
    public func deleteImmediately(paths: [String], window: any WriteOperationWindow) async throws
        -> WriteOperationHandle
    {
        try WriteGuards.assertNotProtectedPath(paths, homePath: homePath)
        try await prepareWithReservedSlot {
            try await self.assertNotSystemLocation(paths, verb: "deleted")
            try await self.assertDeletableImmediately(paths, window: window)
        }
        let fileSystem = try localFileSystem()
        return try queueLocalWriteOperation(action: .deleteImmediately, window: window) {
            [weak self, weak window] local in
            // What this window was asked about, kept for the whole operation: the window closing lets go of its
            // records.
            let asked = window.flatMap { self?.recordOfItemsWithoutTrash($0) }
            await Self.executeDeleteImmediately(paths, local, fileSystem, asked: asked)
        }
    }

    /// `assertDeletableImmediately`: the folder an item is in is looked up through any symlinks, so a link inside
    /// the Trash can't lead the deletion out of it.
    func assertDeletableImmediately(_ paths: [String], window: any WriteOperationWindow) async throws {
        let fileSystem = try localFileSystem()
        let homePath = homePath
        let asked = recordOfItemsWithoutTrash(window)?.items ?? [:]
        try await LocalOperations.onDisk {
            // `readRealHomePath`: the home folder as it really is, to compare real paths with.
            let realHomePath = (try? fileSystem.realpath(homePath)) ?? homePath
            for path in paths {
                let resolved = NodePath.resolve(path)
                if let item = asked[NameKeys.Exact(resolved)] {
                    _ = try Self.assertStillAskedItem(resolved, item, fileSystem)
                    continue
                }
                switch Self.placeInTrash(resolved, fileSystem, homePath: homePath, realHomePath: realHomePath) {
                case .trashFolder:
                    throw WriteCoordinatorError(WriteGuards.trashFolderRefusal)
                case .outside:
                    throw WriteCoordinatorError(
                        "\u{201C}\(NodePath.basename(resolved))\u{201D} isn't in the Trash, so it can't be deleted immediately."
                    )
                case .inside:
                    break
                }
            }
        }
    }

    /// `placeInTrash`: inside a Trash, a Trash folder itself (a link to one leads to the folder), or outside, its
    /// folder looked up through any symlinks. A folder that can't be looked up counts as outside.
    private nonisolated static func placeInTrash(
        _ path: String, _ fileSystem: any LocalWriteFileSystem, homePath: String, realHomePath: String
    ) -> PlaceInTrash {
        guard let folder = try? fileSystem.realpath(NodePath.dirname(path)) else { return .outside }
        let realPath = NodePath.join(folder, NodePath.basename(path))
        if Paths.isTrashFolder(realPath, homePath: realHomePath) {
            return .trashFolder
        }
        return Paths.isInsideTrash(path, homePath: homePath) && Paths.isInsideTrash(realPath, homePath: realHomePath)
            ? .inside : .outside
    }

    /// `assertStillAskedItem`: the item a no-Trash question was about is still at its path (or nothing is: there is
    /// nothing to delete then; true). Anything else there was never asked about.
    nonisolated static func assertStillAskedItem(
        _ path: String, _ asked: AskedItem, _ fileSystem: any LocalWriteFileSystem
    ) throws -> Bool {
        let now = LocalOperations.lstatUnlessMissing(fileSystem, path)
        var id: ItemId?
        switch now {
        case .missing: return true
        case .unreadable: id = nil
        case .found(let stats): id = itemIdOf(stats)
        }
        let same: Bool
        if let askedId = asked.id {
            same = sameItemId(askedId, id)
        } else if let stamp = asked.stamp, id == nil {
            same = readItemStamp(StampReader(fileSystem), path).map { LocalOperations.looksTheSame(stamp, $0) } ?? false
        } else {
            same = false
        }
        if !same {
            throw WriteCoordinatorError(
                "\u{201C}\(NodePath.basename(path))\u{201D} changed after you were asked about it, so it wasn't deleted."
            )
        }
        return false
    }

    /// `executeDeleteImmediatelyOperation`.
    static func executeDeleteImmediately(
        _ requested: [String], _ operation: LocalWriteOperation, _ fileSystem: any LocalWriteFileSystem,
        asked: ItemsWithoutTrash?
    ) async {
        // A folder and an item inside it are one item to remove (the folder takes the item).
        let paths = Paths.withoutNestedPaths(requested.map(NodePath.resolve))
        let startedAt = Date()
        var items: [WriteOperationItem] = []
        var completedItemCount = 0
        var cancelled = false
        var removedItems: [RemovedItem] = []
        // Whether anything may be gone for good: an item deleted, or a folder whose delete failed part way. One
        // refused before deleting (it changed after the question), or a file still there after its delete failed,
        // was never touched.
        var deletingBegan = false
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
            let askedItem = asked?.items[NameKeys.Exact(path)]
            let outcome = await LocalOperations.onDisk { deleteOne(path, askedItem, fileSystem) }
            if outcome.began { deletingBegan = true }
            if let failure = outcome.failure {
                items.append(
                    WriteOperationItem(sourcePath: path, destinationPath: nil, status: .failed, error: failure))
                continue
            }
            asked?.items[NameKeys.Exact(path)] = nil
            switch outcome.before {
            case nil: break
            case .missing, .unreadable:
                removedItems.append(RemovedItem(path: path, item: nil, intoHomeTrash: false))
            case .size(let before):
                removedItems.append(RemovedItem(path: path, item: before, intoHomeTrash: false))
            }
            completedItemCount += 1
            items.append(WriteOperationItem(sourcePath: path, destinationPath: nil, status: .completed))
        }
        let failedItemCount = items.filter { $0.status == .failed }.count
        // Items deleted before a stop are gone for good, so that is "partial", as for Trash.
        let status = LocalWriteResults.terminalStatus(
            cancelled: cancelled, completedItemCount: completedItemCount, failedItemCount: failedItemCount)
        let error: String? =
            cancelled
            ? LocalWriteResults.stoppedMessage(completedItemCount, "deleted")
            : failedItemCount > 0 ? (items.first { $0.status == .failed }?.error ?? "Delete failed.") : nil
        let result = LocalWriteResults.result(
            operationId: operation.operationId, action: .deleteImmediately, targetPath: nil, startedAt: startedAt,
            finishedAt: Date(), totalItemCount: paths.count, completedItemCount: completedItemCount, items: items,
            status: status, error: error)
        operation.emit(
            operation.progress(
                status, completedItemCount: completedItemCount, totalItemCount: paths.count, result: result),
            removedItems: removedItems, undoLog: deletingBegan ? .notUndoable(reason: .deletedForGood) : nil)
    }

    /// One item deleted for good, on the disk.
    private nonisolated static func deleteOne(
        _ path: String, _ asked: AskedItem?, _ fileSystem: any LocalWriteFileSystem
    ) -> DeletedItem {
        var outcome = DeletedItem()
        do {
            let before = LocalOperations.readItemSize(fileSystem.itemSize, path)
            // Checked again just before deleting: the question may have been open a while. An item gone already has
            // nothing left to delete.
            let gone: Bool
            if let asked {
                gone = try assertStillAskedItem(path, asked, fileSystem)
            } else if case .missing = LocalOperations.lstatUnlessMissing(fileSystem, path) {
                gone = true
            } else {
                gone = false
            }
            if !gone {
                do {
                    try fileSystem.rm(path, recursive: true, force: true)
                } catch {
                    switch LocalOperations.lstatUnlessMissing(fileSystem, path) {
                    case .missing, .unreadable: outcome.began = true
                    case .found(let after): if after.isDirectory { outcome.began = true }
                    }
                    throw error
                }
                outcome.began = true
            }
            outcome.before = before
        } catch {
            // What couldn't be deleted may be an item inside the folder (the error names it).
            let failedPath = (error as? NativeError)?.path
            let candidates = (failedPath.map { [$0, NodePath.dirname($0)] } ?? []) + [path, NodePath.dirname(path)]
            let locked = findLockedRefusal({ try fileSystem.getFlags($0) }, error, candidates)
            outcome.failure = locked?.message ?? describeCopyPasteError(error)
        }
        return outcome
    }
}
