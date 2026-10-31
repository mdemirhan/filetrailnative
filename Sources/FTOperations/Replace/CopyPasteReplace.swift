// Port of executeReplace, applyStagedFolderMetadata and recordReplacement (packages/core/src/fs/copyPasteExecution.ts)
import FTFoundation
import Foundation

/// Replace, without ever leaving the person with neither item: the new item is first written (or, for a move on
/// the same volume, moved) to a hidden name next to the existing one, then the existing item goes to the Trash
/// and the new one takes its name. `destination` is what is there now, `source` the item being pasted as the
/// check just before saw it.
func executeReplace(
    _ context: ExecutionContext, _ currentNode: ResolvedCopyPasteNode, _ destination: NodeFingerprint,
    _ source: NodeFingerprint
) throws -> ExecuteNodeResult {
    let fileSystem = context.fileSystem
    let finalPath = currentNode.destinationPath
    try assertDestinationDoesNotContainSource(currentNode, destination, fileSystem)
    if destination.kind == .directory && holdsAnyOf(fileSystem, finalPath, pastedItems(context)) {
        throw OperationError(
            "Can't replace \u{201C}\(basenameOf(finalPath))\u{201D} because it contains another item being pasted.")
    }
    // Pasting "/x/a.txt" over "/d/a.txt" while "/d/a.txt" is pasted too (search results): replacing it would take
    // away an item this paste still has to paste, or just pasted.
    if isAnyOf(fileSystem, finalPath, pastedItems(context)) {
        throw OperationError(
            "Can't replace \u{201C}\(basenameOf(finalPath))\u{201D} because it is another item being pasted.")
    }
    // A locked item can't go to the Trash; found out now, before anything is written.
    if isLocked(context.getFlags, finalPath) {
        throw OperationError(lockedMessage(finalPath))
    }
    // Only the item the review, or the answer to a question, agreed to replace: one that changed since it was
    // last looked at is looked at, and asked about, again.
    if !isAsApproved(currentNode.node.destinationFingerprint, destination) {
        throw DestinationTakenError(
            original: OperationError("\u{201C}\(basenameOf(finalPath))\u{201D} changed before it could be replaced."))
    }

    // A move that copies (to another disk) removes the originals only after the swap, and the copy is staged as a
    // plain copy: everything it will have to remove is checked now, or the old item would go to the Trash for a
    // move that leaves the original in place.
    if context.mode == .cut && !canRenameForCut(context, currentNode) {
        try assertRemovableAfterCopy(context, currentNode, deep: true)
    }

    var temporaryPath = try temporarySiblingPath(fileSystem, finalPath)
    // Written down before anything is staged, so a crash can't leave the item under the hidden name: the next
    // start finishes or undoes the Replace.
    let journal = context.writeJournal
    var journalEntry = ReplaceJournalEntry(
        id: randomHex(bytes: 8), stagingPath: temporaryPath, finalPath: finalPath,
        sourcePath: currentNode.node.sourcePath, moved: false, staged: false)
    // Whether what is at the hidden name is this paste's own: only then is it ever removed. A folder is made
    // there first, under a name nothing else had; a file is its own once copied there (a copy that fails leaves
    // nothing there).
    var stagingIsOurs = false
    var movedByRename = false
    if canRenameForCut(context, currentNode) {
        var moved = journalEntry
        moved.moved = true
        moved.staged = true
        try journal?.add(.replace(moved))
        do {
            try moveExclusive(fileSystem, currentNode.node.sourcePath, temporaryPath)
            movedByRename = true
        } catch {
            if errorCode(error) != "EXDEV" {
                try? journal?.remove(journalEntry.id)
                throw error
            }
        }
    }
    if !movedByRename {
        if context.mode == .cut {
            expectCantUndo(context, .otherDiskMove)
        }
        if currentNode.node.sourceKind == .directory {
            temporaryPath = try reserveStagingFolder(fileSystem, finalPath)
            stagingIsOurs = true
            journalEntry.stagingPath = temporaryPath
        }
        do {
            try journal?.add(.replace(journalEntry))
        } catch {
            if stagingIsOurs {
                try? removeOwnStaging(fileSystem, temporaryPath)
            }
            throw error
        }
    }
    // What the swap takes off the staged item to move it (its lock, a read-only folder's mode), put back wherever
    // it ends up.
    var stagedFlags: UInt32?
    var stagedMode: UInt32?
    // Whether the record says the hidden copy is complete (see executeStagedDirectory).
    var recordedComplete = false
    // Puts things back the way they were before this item started.
    func undoStaging() throws {
        if movedByRename {
            try moveExclusive(fileSystem, temporaryPath, currentNode.node.sourcePath)
            restoreAfterMove(fileSystem, currentNode.node.sourcePath, stagedMode, stagedFlags)
        } else if stagingIsOurs {
            if !recordIncomplete(journal, journalEntry, recordedComplete) {
                throw OperationError(
                    "The copy of \u{201C}\(basenameOf(finalPath))\u{201D} couldn't be cleared away yet.")
            }
            recordedComplete = false
            try removeOwnStaging(fileSystem, temporaryPath)
        }
        try journal?.remove(journalEntry.id)
    }

    var stagedChildItems: [CopyPasteItemResult] = []
    if movedByRename {
        context.shared.completedItemCount += countExecutableSteps([currentNode])
        context.shared.completedByteCount += sumSubtreeBytes([currentNode])
    } else {
        var asCreate = currentNode
        asCreate.action = .create
        let staged = rebaseResolvedNode(asCreate, finalPath, temporaryPath)
        let stagedOutcome: ExecuteNodeResult
        do {
            // Sources stay in place until the swap is done, even for a move.
            let outerMode = context.mode
            let outerDisplay = context.displayPath
            let madeAt = stagingIsOurs ? temporaryPath : nil
            let stagingPath = temporaryPath
            let staging = context.with { staging in
                staging.mode = .copy
                staging.recordsUndo = false
                staging.stagingFor = outerMode
                staging.metadataLaterFor = stagingPath
                staging.folderMadeAt = madeAt
                staging.displayPath = { path in
                    let shown = rebasePath(path, stagingPath, finalPath)
                    return outerDisplay?(shown) ?? shown
                }
            }
            stagedOutcome = try performNode(staging, staged, source)
        } catch {
            try? undoStaging()
            if isAbortError(error) || context.signal.isStopped {
                // What was written went away with the hidden copy.
                throw CancelledWithItemsError(childItems: [])
            }
            if let taken = rootError(error) as? DestinationTakenError {
                throw taken.original
            }
            throw error
        }
        stagingIsOurs = true
        stagedChildItems = rebaseItemResults(flattenItems(stagedOutcome.childItems), temporaryPath, finalPath)
        // An item inside that changed and was skipped would be in neither the new folder nor, once the old one is
        // in the Trash, where it was: the old folder is kept instead.
        let skippedInside = stagedChildItems.first { $0.skipReason == .runtimeConflictResolution }
        if stagedOutcome.itemStatus != .failed, let skippedInside {
            try? undoStaging()
            return ExecuteNodeResult(
                itemStatus: .failed, skipReason: nil,
                error:
                    "\u{201C}\(basenameOf(finalPath))\u{201D} wasn't replaced because \u{201C}\(basenameOf(skippedInside.sourcePath))\u{201D} in it changed and was skipped.",
                destinationPath: finalPath, childItems: [])
        }
        if stagedOutcome.itemStatus != .failed {
            // Complete now: once the old item is in the Trash, this copy is the one to keep.
            do {
                recordedComplete = true
                var complete = journalEntry
                complete.staged = true
                try journal?.add(.replace(complete))
            } catch {
                try? undoStaging()
                throw error
            }
        }
        if stagedOutcome.itemStatus == .failed {
            try? undoStaging()
            return ExecuteNodeResult(
                itemStatus: .failed, skipReason: nil,
                error:
                    "\u{201C}\(basenameOf(finalPath))\u{201D} wasn't replaced because some items inside couldn't be copied.",
                destinationPath: finalPath,
                // Only the failures: everything else went away with the hidden copy.
                childItems: stagedChildItems.filter { $0.status == .failed }.map { .item($0) })
        }
    }

    var oldItemRemoved = false
    do {
        // A copy of a locked item is locked too, and a locked item can't be renamed: it is unlocked for the swap
        // and locked again after. Done before the old item goes.
        stagedFlags = try unlockForMove(fileSystem, temporaryPath)
        stagedMode = try openForMove(fileSystem, temporaryPath)
        if try removeReplacedItem(context, currentNode, destination) == .skipped {
            try undoStaging()
            return .skipped(.runtimeConflictResolution, finalPath)
        }
        oldItemRemoved = true
        do {
            try moveExclusive(fileSystem, temporaryPath, finalPath)
        } catch {
            if errorCode(error) == "EEXIST" {
                throw error
            }
            // The old item is in the Trash already: the new one must not be thrown away too. It is kept under a
            // visible name next to where it was going.
            let isDirectory = currentNode.node.sourceKind == .directory
            let visiblePath = try resolveDuplicateName(
                basenameOf(finalPath), in: dirnameOf(finalPath), fileSystem, reserved: context.shared.reservedPaths,
                options: .init(
                    isDirectory: isDirectory,
                    isPackage: isDirectory && isPackageFolder(fileSystem, currentNode.node.sourcePath),
                    caseSensitive: context.caseSensitive))
            try moveExclusive(fileSystem, temporaryPath, visiblePath)
            restoreAfterMove(fileSystem, visiblePath, stagedMode, stagedFlags)
            applyStagedFolderMetadata(context, currentNode, visiblePath, movedByRename)
            recordReplacement(context, currentNode, visiblePath, movedByRename, source)
            try? journal?.remove(journalEntry.id)
            return ExecuteNodeResult(
                itemStatus: .failed, skipReason: nil,
                error:
                    "The old \u{201C}\(basenameOf(finalPath))\u{201D} was moved to the Trash, but the new one couldn't take its name, so it was saved as \u{201C}\(basenameOf(visiblePath))\u{201D}. \(describeCopyPasteError(error))",
                destinationPath: visiblePath, childItems: stagedChildItems.map { .item($0) })
        }
        restoreAfterMove(fileSystem, finalPath, stagedMode, stagedFlags)
        applyStagedFolderMetadata(context, currentNode, finalPath, movedByRename)
        recordReplacement(context, currentNode, finalPath, movedByRename, source)
    } catch {
        if oldItemRemoved && journal != nil && errorCode(error) != "EEXIST" {
            // Neither name could be used: the journal keeps the new item, and the next start puts it in place.
            throw OperationError(
                "The old \u{201C}\(basenameOf(finalPath))\u{201D} was moved to the Trash, but the new one couldn't be put in its place. It will be put there the next time File Trail starts. \(describeCopyPasteError(error))"
            )
        }
        try? undoStaging()
        throw errorCode(error) == "EEXIST" ? DestinationTakenError(original: error) : error
    }
    try? journal?.remove(journalEntry.id)

    var ownError: String?
    var childItems = stagedChildItems
    if context.mode == .cut && !movedByRename {
        let cleanup = removeMovedSources(context, currentNode, stagedChildItems, temporaryPath, finalPath)
        ownError = cleanup.error
        childItems = cleanup.childItems
    }
    emitProgress(context, .running, currentNode, nil)
    let failed = ownError != nil || childItems.contains { $0.status == .failed }
    return ExecuteNodeResult(
        itemStatus: failed ? .failed : .completed, skipReason: nil, error: ownError, destinationPath: finalPath,
        childItems: childItems.map { .item($0) })
}

/// Where the paste's items really are, looked up once per paste. The items the review planned, as it decided
/// which items Replace can't take: one left out of the paste (moved into the folder it is in already) isn't
/// pasted.
private func pastedItems(_ context: ExecutionContext) -> PastedItems {
    if let known = context.pastedItems {
        return known
    }
    let pasted = PastedItems(realPaths: realItemPaths(context.fileSystem, context.report.nodes.map(\.sourcePath)))
    context.pastedItems = pasted
    return pasted
}

/// Refuses to replace an item that is, or contains, the item being pasted: removing it would destroy the source
/// too (pasting "foo/foo" over "foo", or the same folder reached through a symlink or a different letter case).
private func assertDestinationDoesNotContainSource(
    _ currentNode: ResolvedCopyPasteNode, _ destination: NodeFingerprint, _ fileSystem: some WriteServiceFileSystem
) throws {
    let name = basenameOf(currentNode.destinationPath)
    switch findSourceRelation(
        fileSystem, sourcePath: currentNode.node.sourcePath, destinationPath: currentNode.destinationPath,
        destination: destination)
    {
    case .same:
        throw OperationError("\u{201C}\(name)\u{201D} is the item being pasted, so it can't replace itself.")
    case .contains:
        throw OperationError("Can't replace \u{201C}\(name)\u{201D} because it contains the item being pasted.")
    case nil:
        return
    }
}

/// A folder a Replace built under a hidden name gets its own metadata once it has its name (see
/// metadataLaterFor); one moved there on its disk kept its own.
private func applyStagedFolderMetadata(
    _ context: ExecutionContext, _ node: ResolvedCopyPasteNode, _ path: String, _ movedByRename: Bool
) {
    if movedByRename || node.node.sourceKind != .directory {
        return
    }
    var placed = node
    placed.destinationPath = path
    let outerMode = context.mode
    try? applyDirectoryMetadata(context.with { $0.stagingFor = outerMode }, placed)
}

/// The new item a Replace put in place: moved there on its disk, or copied there.
private func recordReplacement(
    _ context: ExecutionContext, _ node: ResolvedCopyPasteNode, _ path: String, _ movedByRename: Bool,
    _ source: NodeFingerprint
) {
    if movedByRename {
        recordMoved(context, node, path, source)
    } else if context.mode == .copy {
        recordCreated(context, node, path)
    }
}
