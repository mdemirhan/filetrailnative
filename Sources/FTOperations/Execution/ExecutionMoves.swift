// Port of removeMovedSources, the moved-source checks and removals, and the counts and result of a paste
// (packages/core/src/fs/copyPasteExecution.ts)
import FTFoundation
import Foundation

/// The copy doesn't match its original as copied: the original grew (or shrank) while it was copied, or the copy
/// came out short (or went away).
let copyNotWholeMessage =
    "It changed while it was being moved, or its copy didn't come out whole, so the original was kept."

/// After a move to another disk was copied into place (built under `stagingPath`, now at `finalPath`), removes
/// the sources that were copied. Anything changed in the meantime stays, as in the per-file move flow, and so
/// does an original whose copy went away, changed or was cut short since it was written.
func removeMovedSources(
    _ context: ExecutionContext, _ node: ResolvedCopyPasteNode, _ childItems: [CopyPasteItemResult],
    _ stagingPath: String, _ finalPath: String
) -> (error: String?, childItems: [CopyPasteItemResult]) {
    let fileSystem = context.fileSystem
    func removeCopied(_ current: ResolvedCopyPasteNode) -> String? {
        let copied = context.shared.copiedForMove.removeValue(forKey: NameKeys.Exact(current.node.sourcePath))
        guard let copied,
            copyStillWhole(fileSystem, rebasePath(copied.path, stagingPath, finalPath), copied.source)
        else {
            return copyNotWholeMessage
        }
        return tryDeleteMovedSource(current.node.sourcePath, copied.source, fileSystem)
    }
    if node.node.sourceKind != .directory {
        return (removeCopied(node), childItems)
    }
    var itemsBySource: [NameKeys.Exact: CopyPasteItemResult] = [:]
    for item in childItems {
        itemsBySource[NameKeys.Exact(item.sourcePath)] = item
    }
    var updatedItems: [NameKeys.Exact: CopyPasteItemResult] = [:]
    var nestedFolderFailures: [CopyPasteItemResult] = []
    func removeTree(_ reviewed: ResolvedCopyPasteNode) -> String? {
        let current = asExecuted(context, reviewed)
        let key = NameKeys.Exact(current.node.sourcePath)
        if current.node.sourceKind != .directory {
            if itemsBySource[key]?.status != .completed {
                return nil
            }
            let error = removeCopied(current)
            if let error, var item = itemsBySource[key] {
                item.status = .failed
                item.error = error
                updatedItems[key] = item
            }
            return error
        }
        var keptNames = Set<NameKeys.Exact>()
        for reviewedChild in current.children {
            let child = asExecuted(context, reviewedChild)
            let name = NameKeys.Exact(NodePath.basename(child.node.sourcePath))
            // A folder skipped (or stopped) wasn't copied: it and everything in it stay.
            let childStatus = itemsBySource[NameKeys.Exact(child.node.sourcePath)]?.status
            if child.node.sourceKind == .directory && (childStatus == .skipped || childStatus == .cancelled) {
                keptNames.insert(name)
                continue
            }
            if let childError = removeTree(child) {
                keptNames.insert(name)
                if child.node.sourceKind == .directory {
                    nestedFolderFailures.append(itemResult(child, .failed, childError))
                }
            }
        }
        return metadataKeptMessage(context, current)
            ?? tryRemoveEmptySourceDirectory(current, fileSystem, keptNames)
    }
    let error = removeTree(node)
    return (
        error, childItems.map { updatedItems[NameKeys.Exact($0.sourcePath)] ?? $0 } + nestedFolderFailures
    )
}

/// Whether a move's copy is what it copied: the same kind, as large, and for a link the same target. Sizes don't
/// prove the contents, but a copy cut short or replaced is caught.
private func copyMatchesSource(_ copy: NodeFingerprint, _ source: NodeFingerprint) -> Bool {
    copy.exists && copy.kind == source.kind && (source.size == nil || copy.size == source.size)
        && sameText(copy.symlinkTarget, source.symlinkTarget)
}

/// Whether the copy at `path`, where it is now, matches its original (`source`).
func copyStillWhole(_ fileSystem: some IdentityFileSystem, _ path: String, _ source: NodeFingerprint) -> Bool {
    copyMatchesSource(captureFingerprint(fileSystem, path), source)
}

/// Deletes the source of a move once it is copied: nil when done (or gone already), else why it was kept.
func tryDeleteMovedSource(
    _ sourcePath: String, _ originalFingerprint: NodeFingerprint, _ fileSystem: some WriteServiceFileSystem
) -> String? {
    let currentFingerprint = captureFingerprint(fileSystem, sourcePath)
    if !currentFingerprint.exists {
        // Deleted by someone else meanwhile: nothing to do.
        return nil
    }
    if !fingerprintsEqual(originalFingerprint, currentFingerprint) {
        // Changed since the review: kept.
        return "It changed while it was being moved, so the original was kept."
    }
    do {
        try fileSystem.rm(sourcePath, recursive: false, force: false)
        return nil
    } catch {
        return "It was copied, but the original couldn't be removed. \(describeCopyPasteError(error))"
    }
}

/// A moved folder whose copy couldn't take all of its own metadata (its tags, say) is kept where it was, so
/// nothing of it is lost: the message saying so, or nil.
func metadataKeptMessage(_ context: ExecutionContext, _ node: ResolvedCopyPasteNode) -> String? {
    guard context.shared.metadataNotCopied.contains(NameKeys.Exact(node.node.sourcePath)) else { return nil }
    return
        "Its items were moved, but the folder's own information (such as its tags) couldn't all be copied, so the original \u{201C}\(NodePath.basename(node.node.sourcePath))\u{201D} was kept."
}

/// Removes an empty source folder once its items were moved: nil when done (or left on purpose), else why it
/// stays. `keptNames` are the planned items the move left in it; `onRemoved` is told when this removed it.
func tryRemoveEmptySourceDirectory(
    _ node: ResolvedCopyPasteNode, _ fileSystem: some WriteServiceFileSystem, _ keptNames: Set<NameKeys.Exact>,
    onRemoved: () -> Void = {}
) -> String? {
    let sourcePath = node.node.sourcePath
    let currentFingerprint = captureFingerprint(fileSystem, sourcePath)
    if !currentFingerprint.exists {
        return nil
    }
    if !canRemoveMovedSourceDirectory(node.node.sourceFingerprint, currentFingerprint) {
        // Its permissions changed, or it was swapped for another folder: it isn't removed, and "moved" mustn't
        // hide that it is still there.
        return
            "Its items were moved, but the original \u{201C}\(NodePath.basename(sourcePath))\u{201D} changed during the move, so it was kept."
    }
    do {
        // rmdir only removes an empty folder, so anything left inside (skipped items, or something added in the
        // meantime) keeps the folder in place.
        try fileSystem.rmdir(sourcePath)
        onRemoved()
        return nil
    } catch {
        let code = errorCode(error)
        if code == "ENOENT" {
            return nil
        }
        if code == "ENOTEMPTY" || code == "EEXIST" {
            return describeLeftInMovedFolder(node, fileSystem, keptNames, onRemoved)
        }
        return "Its items were moved, but the original folder couldn't be removed. \(describeCopyPasteError(error))"
    }
}

private func plannedNames(_ node: ResolvedCopyPasteNode) -> Set<NameKeys.Exact> {
    Set(node.children.map { NameKeys.Exact(NodePath.basename($0.node.sourcePath)) })
}

/// A moved folder that isn't empty afterwards: items this move left on purpose (skipped, failed) are reported on
/// their own; items added to it while it was being moved were never part of the move, and are named here so
/// "moved" doesn't hide them.
private func describeLeftInMovedFolder(
    _ node: ResolvedCopyPasteNode, _ fileSystem: some WriteServiceFileSystem, _ keptNames: Set<NameKeys.Exact>,
    _ onRemoved: () -> Void
) -> String? {
    let planned = plannedNames(node)
    let sourcePath = node.node.sourcePath
    let entries = (try? fileSystem.readdir(sourcePath)) ?? []
    // Nobody's items: what Finder wrote to show the folder, and the AppleDouble files of items that were moved,
    // on a disk that keeps attributes in them (FAT, exFAT, SMB). An item the move left on purpose is never one,
    // nor is a "._name" file that is an item of its own (on APFS, or one that isn't AppleDouble data).
    var leftovers = Set<NameKeys.Exact>()
    for entry in entries {
        let key = NameKeys.Exact(entry)
        if keptNames.contains(key) {
            continue
        }
        if CopyPasteNames.isFolderViewFile(entry)
            || (CopyPasteNames.isAppleDoubleCompanionName(entry) { planned.contains(NameKeys.Exact($0)) }
                && !planned.contains(key) && fileSystem.isAppleDouble(NodePath.join(sourcePath, entry)))
        {
            leftovers.insert(key)
        }
    }
    let isLeftover = { (entry: String) in leftovers.contains(NameKeys.Exact(entry)) }
    if !entries.isEmpty && entries.allSatisfy(isLeftover) {
        // They go with the folder. Only when nothing else keeps it: a folder that stays (skipped or failed items
        // in it) keeps its view settings too.
        for entry in entries {
            try? fileSystem.rm(NodePath.join(sourcePath, entry), recursive: false, force: true)
        }
        if (try? fileSystem.rmdir(sourcePath)) != nil {
            onRemoved()
        }
        return nil
    }
    let newItems = entries.filter { !planned.contains(NameKeys.Exact($0)) && !isLeftover($0) }
    if newItems.isEmpty {
        return nil
    }
    let folder = NodePath.basename(sourcePath)
    let named = newItems.count == 1 ? "\u{201C}\(newItems[0])\u{201D} was" : "\(newItems.count) items were"
    let left = newItems.count == 1 ? "it was" : "they were"
    return "\(named) added to \u{201C}\(folder)\u{201D} while it was being moved, so \(left) left in the original \u{201C}\(folder)\u{201D}."
}

/// Items put into a folder after the review were never part of the copy: they are named, as for a move, so
/// "copied" doesn't claim a folder whose copy lacks them.
func describeAddedDuringCopy(_ node: ResolvedCopyPasteNode, _ fileSystem: some WriteServiceFileSystem) -> String? {
    let newItems = findItemsAddedSinceReview(node, fileSystem)
    if newItems.isEmpty {
        return nil
    }
    let folder = NodePath.basename(node.node.sourcePath)
    let named = newItems.count == 1 ? "\u{201C}\(newItems[0])\u{201D} was" : "\(newItems.count) items were"
    let copied = newItems.count == 1 ? "it wasn't" : "they weren't"
    return "\(named) added to \u{201C}\(folder)\u{201D} after the copy began, so \(copied) copied."
}

private func findItemsAddedSinceReview(_ node: ResolvedCopyPasteNode, _ fileSystem: some WriteServiceFileSystem)
    -> [String]
{
    // A folder the review couldn't read has no plan to compare with.
    if node.node.issueCode == .sourceUnreadable {
        return []
    }
    let planned = plannedNames(node)
    let entries = (try? fileSystem.readdir(node.node.sourcePath)) ?? []
    var added: [String] = []
    for entry in entries {
        if planned.contains(NameKeys.Exact(entry)) || CopyPasteNames.isFolderViewFile(entry) {
            continue
        }
        // A planned item's attributes on a disk that keeps them in "._name" files went with the item; any other
        // "._name" file is an item of its own.
        if CopyPasteNames.isAppleDoubleCompanionName(entry, hasSibling: { planned.contains(NameKeys.Exact($0)) })
            && fileSystem.isAppleDouble(NodePath.join(node.node.sourcePath, entry))
        {
            continue
        }
        added.append(entry)
    }
    return added
}

private func canRemoveMovedSourceDirectory(_ original: NodeFingerprint, _ current: NodeFingerprint) -> Bool {
    current.exists && current.kind == .directory && original.kind == .directory && original.mode == current.mode
        && sameText(original.symlinkTarget, current.symlinkTarget)
        && (original.ino == nil || current.ino == nil || original.ino == current.ino)
        && (original.dev == nil || current.dev == nil || original.dev == current.dev)
}

// MARK: Counts and the result

func countExecutableSteps(_ nodes: [ResolvedCopyPasteNode]) -> Int {
    var total = 0
    var stack = nodes
    while let node = stack.popLast() {
        if node.action == .skip {
            continue
        }
        if node.node.sourceKind != .directory || node.action != .merge {
            total += 1
        }
        stack.append(contentsOf: node.children)
    }
    return total
}

func sumSubtreeBytes(_ nodes: [ResolvedCopyPasteNode]) -> Int64 {
    var total: Int64 = 0
    var stack = nodes
    while let node = stack.popLast() {
        if node.action == .skip {
            continue
        }
        if let size = node.node.sourceFingerprint.size, node.node.sourceKind != .directory {
            total += size
        }
        stack.append(contentsOf: node.children)
    }
    return total
}

func createOperationResult(
    operationId: String, report: CopyPasteAnalysisReport, mode: CopyPasteMode, startedAt: Date, finishedAt: Date,
    completedByteCount: Int64, totalBytes: Int64?, items: [CopyPasteItemResult], status: CopyPasteOperationStatus,
    error: String?
) -> CopyPasteOperationResult {
    var completed = 0
    var failed = 0
    var skipped = 0
    var cancelled = 0
    for item in items {
        switch item.status {
        case .completed: completed += 1
        case .failed: failed += 1
        case .skipped: skipped += 1
        case .cancelled: cancelled += 1
        }
    }
    // The items picked, not what is inside the folders among them ("Photos", not "Photos and 3 more" for one
    // folder holding three files).
    let pickedPaths = Set(report.nodes.map { NameKeys.Exact($0.sourcePath) })
    let topLevelItemCount = items.filter { pickedPaths.contains(NameKeys.Exact($0.sourcePath)) }.count
    return CopyPasteOperationResult(
        operationId: operationId, mode: mode, status: status, destinationDirectoryPath: report.destinationDirectoryPath,
        startedAt: startedAt, finishedAt: finishedAt,
        summary: CopyPasteOperationSummary(
            topLevelItemCount: topLevelItemCount, totalItemCount: completed + failed + skipped + cancelled,
            completedItemCount: completed, failedItemCount: failed, skippedItemCount: skipped,
            cancelledItemCount: cancelled, completedByteCount: completedByteCount, totalBytes: totalBytes),
        items: items, error: error)
}

/// `itemResults` holds the top-level items and the items surfaced from inside folders, so "nothing succeeded" also
/// covers a folder whose every item failed.
func resolveTerminalStatus(cancelled: Bool, itemResults: [CopyPasteItemResult]) -> CopyPasteOperationStatus {
    let anyCompleted = itemResults.contains { $0.status == .completed }
    if cancelled {
        return anyCompleted ? .partial : .cancelled
    }
    if itemResults.contains(where: { $0.status == .failed }) {
        return anyCompleted ? .partial : .failed
    }
    if itemResults.contains(where: { $0.status == .skipped }) {
        return .partial
    }
    return .completed
}
