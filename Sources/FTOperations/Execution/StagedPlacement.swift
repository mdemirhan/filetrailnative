// An item built under a hidden name beside its place, then given its name
import Darwin
import FTFoundation
import Foundation

/// What a folder copied or moved to another disk and a Replace do differently as each is built under a hidden name
/// and then put in place (`stageThenPlace`).
struct StagedPlacement {
    enum StopOnceBuilt { case clearsAway, goesOn }

    /// The item now at the place, as the Replace began with it: it goes to the Trash once the new one is whole,
    /// just before the new one takes its name. nil when nothing is there to remove.
    var replacing: NodeFingerprint?
    /// A move on one disk: the item itself is moved under the hidden name, never copied.
    var movesOnItsDisk = false
    /// A Stop that came as the last of the hidden copy was written. The two differ here, and each is kept as it
    /// was: a folder copied or moved is cleared away, as one stopped part way is; a Replace, whose new item is whole
    /// by then, goes on and replaces.
    var stopOnceBuilt: StopOnceBuilt
    /// Whether the first item that fails ends the copying (see ExecutionContext.endsAtFirstFailure).
    var endsAtFirstFailure: Bool
    /// Looks at the hidden copy once built (`built`, with its items as the result lists them): the result to end
    /// with when it mustn't be put in place, and is cleared away, or nil to put it in place.
    var givenUp: (_ built: ExecuteNodeResult, _ items: [CopyPasteItemResult]) -> ExecuteNodeResult?
}

/// Builds `currentNode` whole under a hidden name next to where it goes, written down first so a crash can't leave
/// it there (the next start finishes it or clears it away), then gives it its name with a rename that replaces
/// nothing. Stopped, or failed, it leaves nothing half done: the hidden copy is cleared away and the count of what
/// was done taken back, or, for an item that was moved there, the item is put back where it was. A move to
/// another disk removes its originals only once the copy has its name. `source` is the item being pasted as the
/// check just before saw it.
func stageThenPlace(
    _ context: ExecutionContext, _ currentNode: ResolvedCopyPasteNode, _ source: NodeFingerprint,
    _ placement: StagedPlacement
) throws -> ExecuteNodeResult {
    let fileSystem = context.fileSystem
    let finalPath = currentNode.destinationPath
    let isDirectory = currentNode.node.sourceKind == .directory
    let appMovedByCopy = movesAppByCopy(context, currentNode)
    // Before the source is moved under a hidden name there, or anything is copied there under one.
    try assertItemsCanLeave(context, dirnameOf(finalPath))
    // A folder that is copied gets a name of its own below, made for it.
    var temporaryPath =
        placement.movesOnItsDisk || !isDirectory ? try temporarySiblingPath(fileSystem, finalPath) : finalPath
    // Written down before anything is staged, so a crash can't leave the item under the hidden name: the next
    // start finishes or undoes it.
    let journal = context.writeJournal
    var journalEntry = ReplaceJournalEntry(
        id: randomHex(bytes: 8), stagingPath: temporaryPath, finalPath: finalPath,
        sourcePath: currentNode.node.sourcePath, moved: false, staged: false)
    // Whether what is at the hidden name is this paste's own: only then is it ever removed. A folder is made
    // there first, under a name nothing else had; a file is its own once copied there.
    var stagingIsOurs = false
    var movedByRename = false
    var movedFrom: String?
    if placement.movesOnItsDisk {
        var moved = journalEntry
        moved.moved = true
        moved.staged = true
        // The moved item's only copy will be under the hidden name: its record is flushed to the drive first, so not
        // even a power cut loses track of it.
        try journal?.addFlushed(.replace(moved))
        let from = ownSourcePath(context, currentNode)
        do {
            try moveExclusive(fileSystem, currentNode.node.sourcePath, temporaryPath)
            movedByRename = true
            movedFrom = from
        } catch {
            if errorCode(error) != .errno(EXDEV) {
                try? journal?.remove(journalEntry.id)
                throw error
            }
        }
    }
    if !movedByRename {
        if context.mode == .cut && !appMovedByCopy {
            expectCantUndo(context, .otherDiskMove)
        }
        if isDirectory {
            // Made now, under a hidden name nothing else had: what is there is this paste's own.
            temporaryPath = try reserveStagingFolder(fileSystem, finalPath)
            stagingIsOurs = true
            journalEntry.stagingPath = temporaryPath
            // A folder moved by copying keeps its record until the originals are gone: a crash in between leaves
            // it in both places, and the next start says so.
            journalEntry.movingCopy = context.mode == .cut
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
    // What placing takes off the staged item to move it (its lock, a read-only folder's mode), put back wherever
    // it ends up.
    var stagedFlags: UInt32?
    var stagedMode: UInt32?
    // Whether the record says the hidden copy is complete, which the next start puts in place.
    var recordedComplete = false
    // What the progress counted as done before this item: what its hidden copy adds goes when the copy does, or an
    // item asked again would be counted twice.
    let countedItems = context.shared.completedItemCount
    let countedBytes = context.shared.completedByteCount
    // Puts things back the way they were before this item started. A hidden copy's record goes only once the copy is
    // gone: one that can't be removed now (its disk went away) is removed at the next start.
    func undoStaging() throws {
        context.shared.completedItemCount = countedItems
        context.shared.completedByteCount = countedBytes
        if movedByRename {
            try moveExclusive(fileSystem, temporaryPath, currentNode.node.sourcePath)
            restoreAfterMove(fileSystem, currentNode.node.sourcePath, stagedMode, stagedFlags)
        } else if stagingIsOurs {
            if !recordIncomplete(journal, journalEntry, recordedComplete) {
                throw OperationError(
                    "The copy of \u{201C}\(basenameOf(finalPath))\u{201D} couldn\u{2019}t be cleared away yet.")
            }
            recordedComplete = false
            try removeOwnStaging(fileSystem, temporaryPath)
        }
        try journal?.remove(journalEntry.id)
    }

    var stagedChildItems: [CopyPasteItemResult] = []
    var builtError: String?
    if movedByRename {
        context.shared.completedItemCount += countExecutableSteps([currentNode])
        context.shared.completedByteCount += sumSubtreeBytes([currentNode])
    } else {
        var asCreate = currentNode
        asCreate.action = .create
        let staged = rebaseResolvedNode(asCreate, finalPath, temporaryPath)
        let built: ExecuteNodeResult
        do {
            // Sources stay in place until the item has its name, even for a move.
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
                staging.endsAtFirstFailure = placement.endsAtFirstFailure
                staging.displayPath = { path in
                    let shown = rebasePath(path, stagingPath, finalPath)
                    return outerDisplay?(shown) ?? shown
                }
            }
            built = try performNode(staging, staged, source)
        } catch {
            // A file cut short that couldn't be cleared away is this paste's own (nothing was there when its copy
            // began): it is tried again here, and stays written down for the next start if it can't be.
            if !isDirectory && !(rootError(error) is DestinationTakenError) && !isGone(fileSystem, temporaryPath) {
                stagingIsOurs = true
            }
            try? undoStaging()
            if isAbortError(error) || context.signal.isStopped {
                // What was written went away with the hidden copy; the originals are where they were.
                throw CancelledWithItemsError(childItems: [])
            }
            if let taken = rootError(error) as? DestinationTakenError {
                throw taken.original
            }
            throw error
        }
        stagingIsOurs = true
        // Stopped as the last of it was written (see StagedPlacement.stopOnceBuilt).
        if placement.stopOnceBuilt == .clearsAway && context.signal.isStopped {
            try? undoStaging()
            throw CancelledWithItemsError(childItems: [])
        }
        stagedChildItems = rebaseItemResults(flattenItems(built.childItems), temporaryPath, finalPath)
        if let givenUp = placement.givenUp(built, stagedChildItems) {
            try? undoStaging()
            return givenUp
        }
        // Complete now: a crash from here on puts it in place at the next start (once the old item is in the
        // Trash, this copy is the one to keep). Counted as written before it is: a write that failed may still have
        // reached the disk.
        do {
            recordedComplete = true
            var complete = journalEntry
            complete.staged = true
            try journal?.add(.replace(complete))
        } catch {
            try? undoStaging()
            throw error
        }
        builtError = built.error
    }

    var oldItemRemoved = false
    do {
        // A copy of a locked item is locked too, and a locked item can't be renamed; a read-only folder can't
        // always be: it is opened for the move and closed again after. Done before the old item goes.
        stagedFlags = try unlockForMove(fileSystem, temporaryPath)
        stagedMode = try openForMove(fileSystem, temporaryPath)
        if let replaced = placement.replacing {
            if try removeReplacedItem(context, currentNode, replaced) == .skipped {
                try undoStaging()
                return .skipped(.runtimeConflictResolution, finalPath)
            }
            oldItemRemoved = true
        }
        do {
            try moveExclusive(fileSystem, temporaryPath, finalPath)
        } catch {
            if !oldItemRemoved || errorCode(error) == .errno(EEXIST) {
                throw error
            }
            // The old item is in the Trash already: the new one must not be thrown away too. It is kept under a
            // visible name next to where it was going.
            let visiblePath = try resolveDuplicateName(
                basenameOf(finalPath), in: dirnameOf(finalPath), fileSystem, reserved: context.shared.reservedPaths,
                options: .init(
                    isDirectory: isDirectory,
                    isPackage: isDirectory && isPackageFolder(fileSystem, currentNode.node.sourcePath),
                    caseSensitive: context.caseSensitive))
            try moveExclusive(fileSystem, temporaryPath, visiblePath)
            restoreAfterMove(fileSystem, visiblePath, stagedMode, stagedFlags)
            applyStagedFolderMetadata(context, currentNode, visiblePath, movedByRename)
            recordPlaced(context, currentNode, visiblePath, movedByRename, source, movedFrom)
            if appMovedByCopy {
                recordAppMovedByCopy(context, currentNode, visiblePath)
            }
            try? journal?.remove(journalEntry.id)
            return ExecuteNodeResult(
                itemStatus: .failed, skipReason: nil,
                error:
                    "The old \u{201C}\(basenameOf(finalPath))\u{201D} was moved to the Trash, but the new one couldn\u{2019}t take its name, so it was saved as \u{201C}\(basenameOf(visiblePath))\u{201D}. \(describeCopyPasteError(error))",
                destinationPath: visiblePath, childItems: stagedChildItems.map { .item($0) })
        }
        restoreAfterMove(fileSystem, finalPath, stagedMode, stagedFlags)
        applyStagedFolderMetadata(context, currentNode, finalPath, movedByRename)
        noteChanged(context)
        recordPlaced(context, currentNode, finalPath, movedByRename, source, movedFrom)
    } catch {
        if oldItemRemoved && journal != nil && errorCode(error) != .errno(EEXIST) {
            // Neither name could be used: the journal keeps the new item, and the next start puts it in place. It gets
            // back its lock and mode first, which the next start then carries over.
            restoreAfterMove(fileSystem, temporaryPath, stagedMode, stagedFlags)
            throw OperationError(
                "The old \u{201C}\(basenameOf(finalPath))\u{201D} was moved to the Trash, but the new one couldn\u{2019}t be put in its place. It will be put there the next time File Trail starts. \(describeCopyPasteError(error))"
            )
        }
        do {
            try undoStaging()
        } catch let undoError where movedByRename && !isGone(fileSystem, temporaryPath) {
            // The moved item couldn't go back where it was: it waits under its hidden name, written down, until the
            // next start puts it somewhere it can be seen. So too when it can't be looked at just now (its disk went
            // away): only one known to be gone isn't there. It gets back its lock and mode first, which the next
            // start carries over.
            restoreAfterMove(fileSystem, temporaryPath, stagedMode, stagedFlags)
            let oldTrashed =
                oldItemRemoved
                ? " The old \u{201C}\(basenameOf(finalPath))\u{201D} was moved to the Trash." : ""
            throw OperationError(
                "\u{201C}\(basenameOf(currentNode.node.sourcePath))\u{201D} wasn\u{2019}t replaced, and couldn\u{2019}t be put back where it was, so it is under the hidden name \u{201C}\(basenameOf(temporaryPath))\u{201D} in \u{201C}\(dirnameOf(temporaryPath))\u{201D} until File Trail starts again.\(oldTrashed) \(describeCopyPasteError(undoError))",
                cause: undoError)
        } catch {
            // A copy this paste made that can't be cleared away now is written down, and cleared at the next start.
        }
        throw errorCode(error) == .errno(EEXIST) ? DestinationTakenError(original: error) : error
    }
    var ownError = builtError
    var childItems = stagedChildItems
    if context.mode == .cut && !movedByRename {
        let cleanup = removeMovedSources(context, currentNode, stagedChildItems, temporaryPath, finalPath)
        ownError = cleanup.error
        childItems = cleanup.childItems
    }
    // Its record goes only once a move's originals are gone: a crash before that leaves the folder in both places,
    // and the next start says so (see journalEntry.movingCopy).
    try? journal?.remove(journalEntry.id)
    if appMovedByCopy {
        recordAppMovedByCopy(context, currentNode, finalPath)
    }
    if placement.replacing != nil {
        // (The items of a folder copied to a free name each said so as they were written.)
        emitProgress(context, .running, currentNode, nil)
    }
    let failed = ownError != nil || childItems.contains { $0.status == .failed }
    return ExecuteNodeResult(
        itemStatus: failed ? .failed : .completed, skipReason: nil, error: ownError, destinationPath: finalPath,
        childItems: childItems.map { .item($0) })
}

/// A folder built under a hidden name gets its own metadata once it has its name (see metadataLaterFor); one
/// moved there on its disk kept its own.
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

/// The new item now in place, for Undo: moved there on its disk (from `movedFrom`, its own name), or copied there.
private func recordPlaced(
    _ context: ExecutionContext, _ node: ResolvedCopyPasteNode, _ path: String, _ movedByRename: Bool,
    _ source: NodeFingerprint, _ movedFrom: String?
) {
    if movedByRename {
        recordMoved(context, node, path, source, from: movedFrom)
    } else if context.mode == .copy {
        recordCreated(context, node, path)
    }
}
