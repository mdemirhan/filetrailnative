// Port of performNode, executeStagedDirectory, executeLeafNode, executeDirectoryNode and their helpers
// (packages/core/src/fs/copyPasteExecution.ts)
import Darwin
import FTFoundation
import Foundation

/// `source` is the item being pasted as the check just before saw it.
func performNode(_ context: ExecutionContext, _ resolvedNode: ResolvedCopyPasteNode, _ source: NodeFingerprint)
    throws -> ExecuteNodeResult
{
    // A folder whose items weren't read can only be renamed into place: on another disk now (EXDEV), or with
    // anything to replace, it is left where it is.
    if resolvedNode.node.renameOnly {
        let renamed =
            resolvedNode.action != .overwrite && canRenameForCut(context, resolvedNode)
            ? try tryRenameForCut(context, resolvedNode, source) : nil
        guard let renamed else {
            throw OperationError(renameOnlyMessage(resolvedNode))
        }
        return renamed
    }
    var currentNode = resolvedNode
    if currentNode.action == .overwrite {
        let destination = captureFingerprint(context.fileSystem, currentNode.destinationPath)
        if destination.exists {
            return try executeReplace(context, currentNode, destination, source)
        }
        // Gone already: nothing is left to replace, so this simply becomes a copy (or a move), made the way any
        // other is.
        currentNode.action = .create
    }

    // Same-filesystem rename fast path: rename(2) for a move when source and destination are on the same device.
    // Not for a merge (a folder can't be renamed into an existing one).
    if canRenameForCut(context, currentNode), let renamed = try tryRenameForCut(context, currentNode, source) {
        return renamed
    }
    // EXDEV: on to copying, then removing.

    // A move copies, then removes the original. An original that can't be removed isn't copied either: that
    // would leave it in both places.
    if context.mode == .cut {
        try assertRemovableAfterCopy(context, currentNode, deep: false)
        // A folder merged into isn't copied itself: its items are, each moved as its own disk allows.
        if currentNode.action != .merge {
            expectCantUndo(context, .otherDiskMove)
        }
    }

    if currentNode.node.sourceKind == .directory {
        // A folder whose contents couldn't be read is left where it is; the rest goes on.
        if currentNode.node.issueCode == .sourceUnreadable {
            throw OperationError(unreadableFolderMessage(context.mode, currentNode.node.issueMessage))
        }
        if context.stagingFor == nil && (currentNode.action == .create || currentNode.action == .keepBoth) {
            return try executeStagedDirectory(context, currentNode)
        }
        return try executeDirectoryNode(context, currentNode)
    }
    return try executeLeafNode(context, currentNode)
}

/// A folder copied, or moved to another disk, is built whole under a hidden name next to where it goes (written
/// down, for a crash), then given its name: stopped, or a move that couldn't copy everything, leaves nothing half
/// done in either place, and a move removes the originals only once the folder is in place. A copy of an ordinary
/// folder that couldn't copy everything is put in place with what it has, its failures named; a package (a
/// Keynote document, an app) is put in place whole or not at all.
private func executeStagedDirectory(_ context: ExecutionContext, _ currentNode: ResolvedCopyPasteNode) throws
    -> ExecuteNodeResult
{
    let fileSystem = context.fileSystem
    let finalPath = currentNode.destinationPath
    let name = NodePath.basename(finalPath)
    // Everything it will remove is checked before anything is copied: a move that couldn't remove its originals
    // would leave them in both places.
    if context.mode == .cut {
        try assertRemovableAfterCopy(context, currentNode, deep: true)
    }
    // Made now, under a hidden name nothing else had: what is there is this paste's own.
    let temporaryPath = try reserveStagingFolder(fileSystem, finalPath)
    let journal = context.writeJournal
    let journalEntry = ReplaceJournalEntry(
        id: randomHex(bytes: 8), stagingPath: temporaryPath, finalPath: finalPath,
        sourcePath: currentNode.node.sourcePath, moved: false, staged: false, movingCopy: context.mode == .cut)
    do {
        try journal?.add(.replace(journalEntry))
    } catch {
        try? removeOwnStaging(fileSystem, temporaryPath)
        throw error
    }
    // Whether the record says the hidden copy is complete, which the next start puts in place.
    var recordedComplete = false
    // Its record goes only once it is gone: one that can't be removed now (its disk went away) is removed at the
    // next start.
    func discard() {
        guard recordIncomplete(journal, journalEntry, recordedComplete) else { return }
        recordedComplete = false
        do {
            try removeOwnStaging(fileSystem, temporaryPath)
        } catch {
            return
        }
        try? journal?.remove(journalEntry.id)
    }

    let outerMode = context.mode
    let outerDisplay = context.displayPath
    let outcome: ExecuteNodeResult
    do {
        let staging = context.with { staging in
            staging.mode = .copy
            staging.recordsUndo = false
            staging.stagingFor = outerMode
            staging.metadataLaterFor = temporaryPath
            staging.folderMadeAt = temporaryPath
            staging.displayPath = { path in
                let shown = rebasePath(path, temporaryPath, finalPath)
                return outerDisplay?(shown) ?? shown
            }
        }
        outcome = try executeDirectoryNode(staging, rebaseResolvedNode(currentNode, finalPath, temporaryPath))
    } catch {
        discard()
        if isAbortError(error) || context.signal.isStopped {
            // What was copied went away with the hidden copy; the originals are where they were.
            throw CancelledWithItemsError(childItems: [])
        }
        if let taken = rootError(error) as? DestinationTakenError {
            throw taken.original
        }
        throw error
    }
    // Stopped as the last of it was written: it goes, like any stopped part way.
    if context.signal.isStopped {
        discard()
        throw CancelledWithItemsError(childItems: [])
    }
    let childItems = rebaseItemResults(flattenItems(outcome.childItems), temporaryPath, finalPath)
    let failedItems = childItems.filter { $0.status == .failed }
    let incompleteItems = childItems.filter { $0.status != .completed }
    let isPackage = !incompleteItems.isEmpty && isPackageFolder(fileSystem, currentNode.node.sourcePath)
    if (context.mode == .cut && !failedItems.isEmpty) || isPackage {
        discard()
        return ExecuteNodeResult(
            itemStatus: .failed, skipReason: nil,
            error: isPackage
                ? incompletePackageMessage(currentNode, context.mode)
                : "\u{201C}\(name)\u{201D} wasn't moved because some items in it couldn't be copied. Nothing in it was moved.",
            destinationPath: finalPath,
            // Only what wasn't done: everything else went away with the hidden copy.
            childItems: incompleteItems.map { .item($0) })
    }

    do {
        // Complete now: a crash from here on puts it in place at the next start. Counted as written before it
        // is: a write that failed may still have reached the disk.
        recordedComplete = true
        var complete = journalEntry
        complete.staged = true
        try journal?.add(.replace(complete))
        // A copy of a locked or read-only folder is locked or read-only too, and can't always be renamed: it is
        // opened for the move and closed again after.
        let flags = try unlockForMove(fileSystem, temporaryPath)
        let mode = try openForMove(fileSystem, temporaryPath)
        try moveExclusive(fileSystem, temporaryPath, finalPath)
        restoreAfterMove(fileSystem, finalPath, mode, flags)
    } catch {
        discard()
        throw errorCode(error) == "EEXIST" ? DestinationTakenError(original: error) : error
    }
    // Its own metadata now that it has its name (see metadataLaterFor).
    try? applyDirectoryMetadata(context.with { $0.stagingFor = outerMode }, currentNode)
    try? journal?.remove(journalEntry.id)
    noteChanged(context)
    if context.mode == .copy {
        recordCreated(context, currentNode, finalPath)
    }

    var error = outcome.error
    var items = childItems
    if context.mode == .cut {
        let cleanup = removeMovedSources(context, currentNode, childItems, temporaryPath, finalPath)
        error = cleanup.error
        items = cleanup.childItems
    }
    return ExecuteNodeResult(
        itemStatus: error != nil || items.contains { $0.status == .failed } ? .failed : .completed, skipReason: nil,
        error: error, destinationPath: finalPath, childItems: items.map { .item($0) })
}

/// What a move to another disk will have to remove after copying: the item, and for a folder what is inside it.
/// Refused before anything is copied when it can't be: an item that is locked or in a locked folder, or a folder
/// that doesn't let items be removed from it. `deep` checks everything inside a folder now (a folder is staged
/// whole before anything is removed); otherwise each item is checked when its turn comes.
func assertRemovableAfterCopy(_ context: ExecutionContext, _ node: ResolvedCopyPasteNode, deep: Bool) throws {
    let fileSystem = context.fileSystem
    let sourcePath = node.node.sourcePath
    let parentPath = NodePath.dirname(sourcePath)
    for path in [sourcePath, parentPath] where isLocked(context.getFlags, path) {
        throw OperationError(lockedMessage(path))
    }
    try assertCanRemoveFrom(fileSystem, parentPath, sourcePath)
    guard node.node.sourceKind == .directory else { return }
    try assertCanRemoveFrom(fileSystem, sourcePath, sourcePath)
    if deep {
        for child in node.children where child.action != .skip {
            try assertRemovableAfterCopy(context, child, deep: deep)
        }
    }
}

private func assertCanRemoveFrom(_ fileSystem: some WriteServiceFileSystem, _ folderPath: String, _ itemPath: String)
    throws
{
    guard let canModifyFolder = fileSystem.canModifyFolder else { return }
    do {
        try canModifyFolder(folderPath)
    } catch {
        let code = errorCode(error)
        let item = NodePath.basename(itemPath)
        if code == "EROFS" {
            throw OperationError("\u{201C}\(item)\u{201D} wasn't moved, because its disk is read-only.")
        }
        if code == "EACCES" || code == "EPERM" {
            let what =
                sameText(folderPath, itemPath)
                ? "what is inside it" : "it from \u{201C}\(NodePath.basename(folderPath))\u{201D}"
            throw OperationError(
                "\u{201C}\(item)\u{201D} wasn't moved, because you don't have permission to remove \(what).")
        }
        // Anything else (the folder just went away) is left for the move itself to report.
    }
}

func renameOnlyMessage(_ node: ResolvedCopyPasteNode) -> String {
    "\u{201C}\(NodePath.basename(node.node.sourcePath))\u{201D} wasn't moved because its destination changed after the move began. Try moving it again."
}

private func unreadableFolderMessage(_ mode: CopyPasteMode, _ reason: String?) -> String {
    let done = mode == .cut ? "moved" : "copied"
    let detail = reason.map { $0.isEmpty ? "" : " \($0)" } ?? ""
    return "This folder couldn't be read, so it wasn't \(done).\(detail)"
}

func canRenameForCut(_ context: ExecutionContext, _ node: ResolvedCopyPasteNode) -> Bool {
    context.mode == .cut && context.destinationDev != nil && node.node.sourceFingerprint.dev == context.destinationDev
        && node.action != .merge
}

/// A file or symlink written to its destination.
private func executeLeafNode(_ context: ExecutionContext, _ currentNode: ResolvedCopyPasteNode) throws
    -> ExecuteNodeResult
{
    try writeLeaf(context, currentNode, currentNode.destinationPath)
    noteChanged(context)
    if context.mode == .copy {
        recordCreated(context, currentNode, currentNode.destinationPath)
    }
    countLeafProgress(context, currentNode)
    var deleteError: String?
    let source = currentNode.node.sourceFingerprint
    if context.stagingFor == .cut {
        context.shared.copiedForMove[NameKeys.Exact(currentNode.node.sourcePath)] = CopiedItem(
            path: currentNode.destinationPath, source: source)
    }
    if context.mode == .cut {
        deleteError =
            copyStillWhole(context.fileSystem, currentNode.destinationPath, source)
            ? tryDeleteMovedSource(currentNode.node.sourcePath, source, context.fileSystem) : copyNotWholeMessage
    }
    emitProgress(context, .running, currentNode, nil)
    return ExecuteNodeResult(
        itemStatus: deleteError != nil ? .failed : .completed, skipReason: nil, error: deleteError,
        destinationPath: currentNode.destinationPath, childItems: [])
}

private func countLeafProgress(_ context: ExecutionContext, _ node: ResolvedCopyPasteNode) {
    context.shared.completedItemCount += 1
    if let size = node.node.sourceFingerprint.size {
        context.shared.completedByteCount += size
    }
}

/// Writes the file or link `node` at `targetPath`.
private func writeLeaf(_ context: ExecutionContext, _ node: ResolvedCopyPasteNode, _ targetPath: String) throws {
    let fileSystem = context.fileSystem
    if node.node.sourceKind == .symlink {
        // copyfile(3) makes the link itself (never what it points to), with its tags, flags and dates: a link
        // made anew would have none of them, and a move would lose them.
        do {
            try fileSystem.copyFile(node.node.sourcePath, targetPath, stop: context.signal, onProgress: nil)
        } catch {
            throw errorCode(error) == "EEXIST"
                ? DestinationTakenError(original: error) : explainMissingFolder(fileSystem, targetPath, error)
        }
        return
    }
    // A large file shows its progress as it is copied, not only once it is done.
    try copyFileContents(context, node.node.sourcePath, targetPath) { copiedBytes in
        emitProgress(context, .running, node, nil, copyingBytes: copiedBytes)
    }
    restoreDroppedFileMetadata(fileSystem, targetPath, node.node.sourceFingerprint)
}

/// The native copy (copyfile(3) COPYFILE_ALL) carries the mode, flags and dates, but some volumes drop them: only
/// what didn't arrive is set again. Setting it when it did arrive would fail on a locked file (its copy is locked
/// too), and a copy that worked is never reported as failed over its metadata.
private func restoreDroppedFileMetadata(
    _ fileSystem: some WriteServiceFileSystem, _ targetPath: String, _ source: NodeFingerprint
) {
    let copied = captureFingerprint(fileSystem, targetPath)
    if let mode = source.mode, copied.mode != mode {
        try? preserveModeIfSupported(fileSystem, targetPath, mode)
    }
    if let mtimeMs = source.mtimeMs, copied.mtimeMs != mtimeMs {
        try? preserveTimestampsIfSupported(fileSystem, targetPath, mtimeMs)
    }
}

func executeDirectoryNode(_ context: ExecutionContext, _ currentNode: ResolvedCopyPasteNode) throws
    -> ExecuteNodeResult
{
    let fileSystem = context.fileSystem
    let createsDirectory =
        currentNode.action == .create || currentNode.action == .keepBoth || currentNode.action == .overwrite
    if createsDirectory {
        do {
            // Not recursive: a folder that appeared in the meantime must not be merged into without asking, and
            // one that was deleted (the folder pasted into) isn't made again.
            if !sameText(currentNode.destinationPath, context.folderMadeAt) {
                try fileSystem.mkdir(currentNode.destinationPath)
            }
        } catch {
            throw errorCode(error) == "EEXIST"
                ? DestinationTakenError(original: error)
                : explainMissingFolder(fileSystem, currentNode.destinationPath, error)
        }
        noteChanged(context)
        if context.mode == .copy {
            recordCreated(context, currentNode, currentNode.destinationPath)
        }
        // The folder's own mode and flags come last (see below): a read-only or locked folder couldn't be filled
        // in otherwise.
        context.shared.completedItemCount += 1
        emitProgress(context, .running, currentNode, nil)
    }
    if currentNode.action == .merge {
        expectCantUndo(context, .merge)
    }
    var hasChildFailure = false
    // Anything inside not done (failed, skipped): a package is then not put in place at all.
    var hasIncomplete = false
    var bubbledChildItems: ItemList = []
    // Items this folder's move leaves where they are (skipped, failed): never cleared away with the folder,
    // whatever their names.
    var keptNames = Set<NameKeys.Exact>()
    for child in currentNode.children {
        if context.signal.isStopped {
            // Keep what was already done inside this folder in the result.
            throw CancelledWithItemsError(childItems: bubbledChildItems)
        }
        var childResult: ExecuteNodeResult
        do {
            childResult = try executeResolvedNode(context, child)
        } catch {
            let root = rootError(error)
            // An incomplete package that couldn't be cleared away: nothing around it is put in place either.
            if root is StagingCleanupError {
                throw error
            }
            if isAbortError(error) || context.signal.isStopped {
                let nested = root as? CancelledWithItemsError
                let stopped = asExecuted(context, child)
                let inProgress: ItemList =
                    stopped.node.sourceKind != .directory && nested == nil
                    ? [.item(itemResult(stopped, .cancelled, cancelledMessage))] : []
                throw CancelledWithItemsError(
                    childItems: [.list(bubbledChildItems), .list(inProgress), .list(nested?.childItems ?? [])])
            }
            // A failed item inside a folder is recorded and the rest of the folder continues.
            childResult = ExecuteNodeResult(
                itemStatus: .failed, skipReason: nil, error: describeCopyPasteError(error),
                destinationPath: failedDestination(error) ?? child.destinationPath, childItems: [])
        }
        // An item saved anew as another kind (a folder now a file) is reported as it was copied.
        let executedChild = asExecuted(context, child)
        if childResult.itemStatus == .failed {
            hasChildFailure = true
        }
        if childResult.itemStatus != .completed {
            hasIncomplete = true
            keptNames.insert(NameKeys.Exact(NodePath.basename(child.node.sourcePath)))
        } else if hasItemNotDone(childResult.childItems) {
            // A folder inside done, with something deeper in it not done (skipped).
            hasIncomplete = true
        }
        // Bubble up file items, and folders that failed themselves or were skipped (a move leaves those where they
        // are), into the result.
        if executedChild.node.sourceKind != .directory || childResult.error != nil
            || childResult.itemStatus == .skipped
        {
            bubbledChildItems.append(.item(outcomeItemResult(executedChild, childResult)))
        }
        if !childResult.childItems.isEmpty {
            bubbledChildItems.append(.list(childResult.childItems))
        }
    }
    // The folder's metadata goes on once its items are in: writing them changes its dates, and a read-only or
    // locked folder can't take new items. As for a file, a folder whose items were written isn't reported as
    // failed over its dates or permissions (some network volumes refuse them), and what was done inside it is
    // never dropped. A package (an app, a Keynote document) inside a folder built under a hidden name is whole or
    // not at all: an incomplete copy of one would look whole, and not open.
    if hasIncomplete && context.stagingFor != nil && createsDirectory
        && !sameText(currentNode.destinationPath, context.folderMadeAt)
        && isPackageFolder(fileSystem, currentNode.node.sourcePath)
    {
        // Should it stay (the disk refused), the folder it is in isn't put in place either: the error goes up and
        // the whole hidden copy goes.
        do {
            try removeStagedItem(fileSystem, currentNode.destinationPath)
        } catch {
            throw StagingCleanupError(original: error)
        }
        return ExecuteNodeResult(
            itemStatus: .failed, skipReason: nil, error: incompletePackageMessage(currentNode),
            destinationPath: currentNode.destinationPath,
            childItems: flattenItems(bubbledChildItems).filter { $0.status != .completed }.map { .item($0) })
    }
    if createsDirectory && !sameText(currentNode.destinationPath, context.metadataLaterFor) {
        try? applyDirectoryMetadata(context, currentNode)
    }
    var dirDeleteError: String?
    if context.mode == .cut {
        dirDeleteError =
            metadataKeptMessage(context, currentNode)
            ?? tryRemoveEmptySourceDirectory(currentNode, fileSystem, keptNames) { noteChanged(context) }
    } else if context.stagingFor != .cut {
        // (Built aside for a move, what was added meanwhile is named once the originals go.)
        dirDeleteError = describeAddedDuringCopy(currentNode, fileSystem)
    }
    return ExecuteNodeResult(
        itemStatus: dirDeleteError != nil || hasChildFailure ? .failed : .completed, skipReason: nil,
        error: dirDeleteError, destinationPath: currentNode.destinationPath, childItems: bubbledChildItems)
}

func applyDirectoryMetadata(_ context: ExecutionContext, _ node: ResolvedCopyPasteNode) throws {
    let fileSystem = context.fileSystem
    let sourcePath = node.node.sourcePath
    let sourceFingerprint = node.node.sourceFingerprint
    // A move, or a copy built for a move to take the originals' place with.
    let moving = context.mode == .cut || context.stagingFor == .cut
    if let copyMetadata = fileSystem.copyMetadata {
        do {
            // Tags, the custom-icon flag, ACLs and flags along with the mode and dates.
            try copyMetadata(sourcePath, node.destinationPath)
            if moving {
                // Moving the items out (or anything written into it meanwhile, as Finder's view settings) changed
                // the source folder's dates; put back the ones it had before. Only the date is lost if this fails
                // (a locked folder refuses it).
                try? preserveTimestampsIfSupported(fileSystem, node.destinationPath, sourceFingerprint.mtimeMs)
            }
            return
        } catch {
            // For example a volume that refuses some attribute: carry over what can be. A move keeps the original
            // folder then, with what its copy couldn't take.
            if moving {
                context.shared.metadataNotCopied.insert(NameKeys.Exact(sourcePath))
            }
        }
    }
    try preserveModeIfSupported(fileSystem, node.destinationPath, sourceFingerprint.mode)
    try preserveTimestampsIfSupported(fileSystem, node.destinationPath, sourceFingerprint.mtimeMs)
}

/// `preserveModeIfSupported`.
func preserveModeIfSupported(_ fileSystem: some WriteServiceFileSystem, _ destinationPath: String, _ mode: UInt32?)
    throws
{
    guard let chmod = fileSystem.chmod, let mode else { return }
    try FolderMetadata.preserveMode(destinationPath, mode, chmod)
}

/// `preserveTimestampsIfSupported`.
func preserveTimestampsIfSupported(
    _ fileSystem: some WriteServiceFileSystem, _ destinationPath: String, _ mtimeMs: Double?
) throws {
    guard let utimes = fileSystem.utimes, let mtimeMs else { return }
    try FolderMetadata.preserveTimestamps(destinationPath, mtimeMs, utimes)
}

func incompletePackageMessage(_ node: ResolvedCopyPasteNode, _ mode: CopyPasteMode = .copy) -> String {
    let name = NodePath.basename(node.node.sourcePath)
    return mode == .cut
        ? "\u{201C}\(name)\u{201D} wasn't moved because some items in it were skipped or couldn't be copied. Nothing in it was moved."
        : "\u{201C}\(name)\u{201D} wasn't copied because some items in it were skipped or couldn't be copied."
}

func tryRenameForCut(_ context: ExecutionContext, _ currentNode: ResolvedCopyPasteNode, _ source: NodeFingerprint)
    throws -> ExecuteNodeResult?
{
    do {
        // Exclusive: an item that appeared at the destination is asked about, never replaced.
        try moveExclusive(context.fileSystem, currentNode.node.sourcePath, currentNode.destinationPath)
    } catch {
        let code = errorCode(error)
        if code == "EXDEV" {
            return nil
        }
        throw code == "EEXIST"
            ? DestinationTakenError(original: error)
            : explainMissingFolder(context.fileSystem, currentNode.destinationPath, error)
    }
    noteChanged(context)
    recordMoved(context, currentNode, currentNode.destinationPath, source)
    // Renamed: everything in it counts as done.
    context.shared.completedItemCount += countExecutableSteps([currentNode])
    context.shared.completedByteCount += sumSubtreeBytes([currentNode])
    emitProgress(context, .running, currentNode, nil)
    return ExecuteNodeResult(
        itemStatus: .completed, skipReason: nil, error: nil, destinationPath: currentNode.destinationPath,
        childItems: [])
}

/// ENOENT while writing an item can mean the item being pasted is gone, or the folder it was going into is
/// (deleted while the paste ran; it is never made again). The second is said as such, naming the folder.
func explainMissingFolder(_ fileSystem: some IdentityFileSystem, _ targetPath: String, _ error: any Error) -> any Error
{
    guard errorCode(error) == "ENOENT" else { return error }
    let folder = captureFingerprint(fileSystem, NodePath.dirname(targetPath))
    return folder.exists
        ? error
        : OperationError(
            "The folder \u{201C}\(NodePath.basename(NodePath.dirname(targetPath)))\u{201D} no longer exists.")
}

/// rename(2) that never replaces anything at `to`: fails with EEXIST instead.
func moveExclusive(_ fileSystem: some WriteServiceFileSystem, _ from: String, _ to: String) throws {
    try fileSystem.renameExclusive(from, to)
}
