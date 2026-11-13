import FTFoundation
import Foundation

enum ReplacedItemRemoval {
    case removed, skipped
}

/// Moves the item being replaced (`destination`, as the Replace began with it) out of the way: to the Trash, or,
/// when there is no Trash here, deleted permanently only if the person agrees.
func removeReplacedItem(
    _ context: ExecutionContext, _ node: ResolvedCopyPasteNode, _ destination: NodeFingerprint
) throws -> ReplacedItemRemoval {
    let fileSystem = context.fileSystem
    do {
        // Staging a large copy takes a while: the item replaced must still be the one that was there, never
        // one an app saved in its place meanwhile.
        let current = try assertReplacedItemUnchanged(context, node, destination)
        let records =
            context.recordsUndo && context.shared.undo.topLevelNodeIds.contains(NameKeys.Exact(node.node.id))
        let id = itemIdOf(dev: current.dev, ino: current.ino)
        let looks = records ? stampWithoutId(StampReader(fileSystem), node.destinationPath, id) : nil
        // On a disk that ignores case, "X.TXT" replaces "x.txt": an Undo puts the item back under its own name.
        let replacedPath = records ? pathAsOnDisk(node.destinationPath) : node.destinationPath
        let trashPath = try fileSystem.trash(node.destinationPath)
        noteChanged(context)
        context.shared.replacedPaths.append(node.destinationPath)
        if let trashPath {
            context.shared.trashedPaths.append(trashPath)
            if records {
                let parentId = context.shared.folderIds.id(
                    { try fileSystem.stat($0) }, dirnameOf(node.destinationPath))
                recordUndoStep(
                    context, node,
                    .step(
                        .trashed(
                            from: replacedPath, trashPath: trashPath, id: id, parentId: parentId,
                            stamp: looks)))
            }
        } else {
            // In the Trash, but the Trash didn't say where: it can't be put back.
            markCantUndo(context, .trashLocationUnknown)
        }
        return .removed
    } catch {
        // Only a disk that may have no Trash (a network or FAT volume) is asked about below; any other reason
        // stops this item, and nothing is deleted for good.
        if errorCode(error) != .noTrash {
            throw error
        }
    }
    // A folder deleted for good may hold only what it held when it was agreed to: the review's count, or (after a
    // question about it, which the review didn't count) what it holds now, before asking. One that can't be
    // counted isn't deleted for good.
    let approvedCount: Int? =
        destination.kind == .directory
        ? (node.node.destinationTotalNodeCount ?? countItemsInside(fileSystem, node.destinationPath)) : nil
    if destination.kind == .directory && approvedCount == nil {
        throw OperationError(
            "\u{201C}\(basenameOf(node.destinationPath))\u{201D} couldn't be looked through, so it wasn't deleted for good and nothing was replaced."
        )
    }
    let conflict = CopyPasteRuntimeConflict(
        conflictId: "runtime-\(node.node.id)-trash", analysisId: context.report.analysisId,
        sourcePath: node.node.sourcePath, destinationPath: node.destinationPath, sourceKind: node.node.sourceKind,
        destinationKind: destination.kind,
        conflictClass: conflictClassFor(
            fileSystem, source: (node.node.sourcePath, node.node.sourceKind),
            destination: (node.destinationPath, destination.kind)),
        reason: .trashUnavailable, sourceFingerprint: node.node.sourceFingerprint,
        destinationFingerprint: node.node.destinationFingerprint,
        currentSourceFingerprint: captureFingerprint(fileSystem, node.node.sourcePath),
        currentDestinationFingerprint: destination)
    let resolution = try answerRuntimeConflict(context, node, conflict)
    if resolution != .overwrite {
        return .skipped
    }
    // Deleting a folder for good stops at the first locked item inside, leaving it half deleted: one is looked
    // for first, and then nothing is deleted.
    if destination.kind == .directory, let locked = findLockedInside(context, node.destinationPath) {
        throw OperationError(lockedMessage(locked))
    }
    // Last, after the long look inside: the question may have been open a while, and what is deleted is what it
    // was about. A folder holds only what the review counted in it: an item added since (a cloud sync) would be
    // lost unseen, with no Trash to get it back from.
    _ = try assertReplacedItemUnchanged(context, node, destination, itemCount: approvedCount)
    markCantUndo(context, .deletedForGood)
    noteChanged(context)
    // Named before deleting: a delete that fails part way has still removed some of it.
    context.shared.replacedPaths.append(node.destinationPath)
    try fileSystem.rm(node.destinationPath, recursive: destination.kind == .directory, force: true)
    return .removed
}

/// The item a Replace is about to remove is still the one it began with (`replaced`): the same file unchanged,
/// or the same folder, holding `itemCount` items at every depth when that is given. Throws (nothing removed) when
/// another item is there or it changed; returns what is there.
private func assertReplacedItemUnchanged(
    _ context: ExecutionContext, _ node: ResolvedCopyPasteNode, _ replaced: NodeFingerprint, itemCount: Int? = nil
) throws -> NodeFingerprint {
    // Counting a large folder takes a while: it is looked at once counted.
    let counted = itemCount == nil || countItemsInside(context.fileSystem, node.destinationPath) == itemCount
    let current = captureFingerprint(context.fileSystem, node.destinationPath)
    if !counted || !isAsApproved(replaced, current) {
        throw OperationError(
            "\u{201C}\(basenameOf(node.destinationPath))\u{201D} changed while it was being replaced, so it was kept and nothing was replaced."
        )
    }
    return current
}

/// How many items a folder holds at every depth, counted as the review counted them (`countDirectoryItems`); nil
/// when some of it can't be read.
func countItemsInside(_ fileSystem: some IdentityFileSystem, _ path: String) -> Int? {
    guard let entries = try? fileSystem.readdir(path) else { return nil }
    var count = 0
    for entry in entries where !CopyPasteNames.isFolderViewFile(entry) {
        count += 1
        let entryPath = NodePath.join(path, entry)
        guard let stats = try? fileSystem.lstat(entryPath) else { return nil }
        if stats.isDirectory {
            guard let nested = countItemsInside(fileSystem, entryPath) else { return nil }
            count += nested
        }
    }
    return count
}

/// The first locked item inside a folder, at any depth, or nil.
private func findLockedInside(_ context: ExecutionContext, _ folderPath: String) -> String? {
    let fileSystem = context.fileSystem
    let names = (try? fileSystem.readdir(folderPath)) ?? []
    for name in names {
        let path = NodePath.join(folderPath, name)
        if isLocked(context.getFlags, path) {
            return path
        }
        if (try? fileSystem.lstat(path))?.isDirectory == true, let inside = findLockedInside(context, path) {
            return inside
        }
    }
    return nil
}

/// `path` with its last name as the disk keeps it, when the disk spells it otherwise only in letter case or in how
/// accents are stored; `path` itself when the name can't be read or is another name (another hard link's).
private func pathAsOnDisk(_ path: String) -> String {
    let name = basenameOf(path)
    guard let onDisk = NativeFS.nameOnDisk(path), !sameText(onDisk, name),
        onDisk.compare(name, options: .caseInsensitive) == .orderedSame
    else { return path }
    return NodePath.join(dirnameOf(path), onDisk)
}
