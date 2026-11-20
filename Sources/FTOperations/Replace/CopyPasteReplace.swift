import FTFoundation
import Foundation

/// Replace, without ever leaving the person with neither item: the new item is first written (or, for a move on
/// the same volume, moved) to a hidden name next to the existing one, then the existing item goes to the Trash
/// and the new one takes its name (`stageThenPlace`, after the checks made here). `destination` is what is there
/// now, `source` the item being pasted as the check just before saw it.
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
    // A folder a disk is mounted on, perhaps only since the review: what would go to the Trash, or be deleted for
    // good where there is no Trash, is everything on that disk. Refused before the pasted item is moved aside. The
    // folder holding it is looked at through a link to it, as pasting into a link pastes into its folder.
    if destination.kind == .directory,
        isMountPoint(destination, holderDev: (try? fileSystem.stat(dirnameOf(finalPath)))?.dev)
    {
        throw OperationError(
            "Can't replace \u{201C}\(basenameOf(finalPath))\u{201D} because it is a disk mounted here.")
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

    return try stageThenPlace(
        context, currentNode, source,
        StagedPlacement(
            replacing: destination, movesOnItsDisk: canRenameForCut(context, currentNode), stopOnceBuilt: .goesOn,
            // A new folder that couldn't be copied whole replaces nothing: nothing more is copied once an item
            // failed.
            endsAtFirstFailure: true,
            givenUp: { built, items in
                if built.itemStatus == .failed {
                    return ExecuteNodeResult(
                        itemStatus: .failed, skipReason: nil,
                        error:
                            "\u{201C}\(basenameOf(finalPath))\u{201D} wasn't replaced because some items inside couldn't be copied.",
                        destinationPath: finalPath,
                        // Only the failures: everything else went away with the hidden copy.
                        childItems: items.filter { $0.status == .failed }.map { .item($0) })
                }
                // An item inside that changed and was skipped would be in neither the new folder nor, once the old
                // one is in the Trash, where it was: the old folder is kept instead.
                guard let skippedInside = items.first(where: { $0.skipReason == .runtimeConflictResolution }) else {
                    return nil
                }
                return ExecuteNodeResult(
                    itemStatus: .failed, skipReason: nil,
                    error:
                        "\u{201C}\(basenameOf(finalPath))\u{201D} wasn't replaced because \u{201C}\(basenameOf(skippedInside.sourcePath))\u{201D} in it changed and was skipped.",
                    destinationPath: finalPath, childItems: [])
            }))
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
