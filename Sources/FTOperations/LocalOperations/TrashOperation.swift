// Port of the "writeOperation:trash" handler, executeTrashOperation and rememberItemsWithoutTrash
// (apps/desktop/src/main/bootstrap/writeOperations.ts)
import FTFileSystem
import FTFoundation
import Foundation

/// What one window's Move to Trash found has no Trash to go to (`itemsWithoutTrash`'s map for a sender): by path,
/// the item that was there, by its id (or, on a disk without usable ids, how it looked). Another item put at its
/// path while the question was open was never asked about.
@MainActor
final class ItemsWithoutTrash {
    weak var window: (any WriteOperationWindow)?
    var items: [NameKeys.Exact: AskedItem] = [:]

    init(window: any WriteOperationWindow) {
        self.window = window
    }
}

/// How moving one item to the Trash went, read on the disk.
private struct TrashedItem: Sendable {
    var before: ItemSizeLook?
    /// The Trash said where it went; nil when the item was gone already, or the Trash didn't say.
    var unit: UndoUnit?
    var locationUnknown = false
    var failure: (message: String, noTrash: Bool)?
    var tried: AskedItem?
}

extension WriteCoordinator {
    /// `writeOperation:trash`: moves the items to the Trash, one by one, going on past one that can't go. The
    /// Trash folders, what is already in the Trash, and the system's and the home folder's own folders are refused
    /// before anything starts.
    @discardableResult
    public func trash(paths: [String], window: any WriteOperationWindow) async throws -> WriteOperationHandle {
        try WriteGuards.assertNotProtectedPath(paths, homePath: homePath)
        try WriteGuards.assertNotAlreadyInTrash(paths, homePath: homePath)
        try await prepareWithReservedSlot {
            try await self.assertNotSystemLocation(paths, verb: "moved to the Trash")
        }
        let fileSystem = try localFileSystem()
        let homePath = homePath
        return try queueLocalWriteOperation(action: .trash, window: window) { [weak self, weak window] local in
            // Only what this Trash finds without a Trash may be deleted next.
            let withoutTrash = window.flatMap { self?.rememberItemsWithoutTrash($0) }
            await Self.executeTrash(paths, local, fileSystem, homePath: homePath, withoutTrash: withoutTrash)
        }
    }

    /// `rememberItemsWithoutTrash`: a new, empty record of `window`'s, in place of what it had.
    func rememberItemsWithoutTrash(_ window: any WriteOperationWindow) -> ItemsWithoutTrash {
        let record = ItemsWithoutTrash(window: window)
        itemsWithoutTrash[ObjectIdentifier(window)] = record
        return record
    }

    /// `itemsWithoutTrash.get(sender)`.
    func recordOfItemsWithoutTrash(_ window: any WriteOperationWindow) -> ItemsWithoutTrash? {
        guard let record = itemsWithoutTrash[ObjectIdentifier(window)], record.window === window else { return nil }
        return record
    }

    func forgetItemsWithoutTrash(of window: any WriteOperationWindow) {
        if recordOfItemsWithoutTrash(window) != nil {
            itemsWithoutTrash[ObjectIdentifier(window)] = nil
        }
    }

    /// `executeTrashOperation`.
    static func executeTrash(
        _ requested: [String], _ operation: LocalWriteOperation, _ fileSystem: any LocalWriteFileSystem,
        homePath: String, withoutTrash: ItemsWithoutTrash?
    ) async {
        // A folder and an item inside it are one item to remove (the folder takes the item).
        let paths = Paths.withoutNestedPaths(requested.map(NodePath.resolve))
        let startedAt = Date()
        var items: [WriteOperationItem] = []
        var completedItemCount = 0
        var cancelled = false
        var removedItems: [RemovedItem] = []
        // One unit per item, so an item put back from the Trash doesn't depend on the others.
        var trashedUnits: [UndoUnit] = []
        var folderIds = FolderIds()
        // Set when an item went to the Trash where it can't be found again: the operation can't be undone then, as
        // undoing only part of it would.
        var trashLocationUnknown = false
        // What's on the home folder's disk goes to the home folder's Trash.
        let homeDev: Int64? = await LocalOperations.onDisk {
            if case .size(let home) = LocalOperations.readItemSize(fileSystem.itemSize, homePath) { return home.dev }
            return nil
        }
        // One item that can't go to the Trash doesn't keep the others from going; only stopping stops the rest.
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
            let ids = folderIds
            let (outcome, knownIds) = await LocalOperations.onDisk { () -> (TrashedItem, FolderIds) in
                var ids = ids
                return (trashOne(path, fileSystem, &ids), ids)
            }
            folderIds = knownIds
            if let failure = outcome.failure {
                // An item that can't be told apart from another (no id, and how it looked unknown) is never
                // offered for deletion.
                let noTrash = failure.noTrash && outcome.tried?.canBeToldApart == true
                if noTrash, let tried = outcome.tried {
                    withoutTrash?.items[NameKeys.Exact(path)] = tried
                }
                items.append(
                    WriteOperationItem(
                        sourcePath: path, destinationPath: nil, status: .failed, error: failure.message,
                        noTrash: noTrash))
                continue
            }
            if outcome.locationUnknown { trashLocationUnknown = true }
            if let unit = outcome.unit { trashedUnits.append(unit) }
            switch outcome.before {
            case nil: break
            case .missing:
                removedItems.append(RemovedItem(path: path, item: nil, intoHomeTrash: false))
            case .unreadable:
                removedItems.append(RemovedItem(path: path, item: nil, intoHomeTrash: nil))
            case .size(let before):
                removedItems.append(
                    RemovedItem(path: path, item: before, intoHomeTrash: homeDev.map { before.dev == $0 }))
            }
            completedItemCount += 1
            items.append(WriteOperationItem(sourcePath: path, destinationPath: nil, status: .completed))
        }
        let failedItemCount = items.filter { $0.status == .failed }.count
        let status = LocalWriteResults.terminalStatus(
            cancelled: cancelled, completedItemCount: completedItemCount, failedItemCount: failedItemCount)
        // Stopped part way is said as such, never as a success.
        let error: String? =
            cancelled
            ? LocalWriteResults.stoppedMessage(completedItemCount, "moved to the Trash")
            : failedItemCount > 0 ? (items.first { $0.status == .failed }?.error ?? "Trash failed.") : nil
        let result = LocalWriteResults.result(
            operationId: operation.operationId, action: .trash, targetPath: nil, startedAt: startedAt,
            finishedAt: Date(), totalItemCount: paths.count, completedItemCount: completedItemCount, items: items,
            status: status, error: error)
        let undoLog: UndoLog? =
            trashLocationUnknown
            ? .notUndoable(reason: .trashLocationUnknown)
            : trashedUnits.isEmpty ? nil : .undoable(units: trashedUnits)
        operation.emit(
            operation.progress(
                status, completedItemCount: completedItemCount, totalItemCount: paths.count, result: result),
            removedItems: removedItems, undoLog: undoLog)
    }

    /// One item to the Trash, on the disk.
    private nonisolated static func trashOne(
        _ path: String, _ fileSystem: any LocalWriteFileSystem, _ folderIds: inout FolderIds
    ) -> TrashedItem {
        var outcome = TrashedItem()
        // The item the Trash is asked to take, for a no-Trash question about it.
        var tried: AskedItem?
        do {
            let before = LocalOperations.readItemSize(fileSystem.itemSize, path)
            // An item that is already gone (deleted or moved since it was chosen) has nothing left to move: that
            // counts as done, not as a failure.
            let stats = LocalOperations.lstatUnlessMissing(fileSystem, path)
            if case .missing = stats {
            } else {
                var id: ItemId?
                if case .found(let found) = stats { id = itemIdOf(found) }
                let parentId = folderIds.id({ try fileSystem.stat($0) }, NodePath.dirname(path))
                let looks = stampWithoutId(StampReader(fileSystem), path, id)
                tried = AskedItem(id: id, stamp: looks)
                guard let trash = fileSystem.trash else {
                    throw OperationError(
                        "\u{201C}\(NodePath.basename(path))\u{201D} couldn\u{2019}t be moved to the Trash.")
                }
                if let trashPath = try trash(path) {
                    outcome.unit = UndoUnit(steps: [
                        .trashed(from: path, trashPath: trashPath, id: id, parentId: parentId, stamp: looks)
                    ])
                } else {
                    // In the Trash, but the Trash didn't say where: it can't be put back.
                    outcome.locationUnknown = true
                }
            }
            outcome.before = before
        } catch {
            outcome.tried = tried
            outcome.failure = (
                LocalOperations.describeTrashError(error, path),
                errorCode(error) == CopyPasteErrors.noTrashErrorCode && tried != nil
            )
        }
        return outcome
    }
}
