// Port of executeCopyPasteFromAnalysis and its runtime conflicts (packages/core/src/fs/copyPasteExecution.ts):
// the paste loop, the undo recording, progress, and what changed since the review
import Darwin
import FTFoundation
import Foundation
import os

/// Pastes what a review planned (`resolvedNodes`), on a thread with room for deep folders, and returns once
/// its last event (the one with the result) has gone out. Stopping it (`signal`) leaves nothing half done.
public func executeCopyPasteFromAnalysis(_ run: CopyPasteRun) async {
    try? await WriteService.withRoomForDepth(name: "FileTrail paste") {
        executeCopyPasteFromAnalysisHere(run)
    }
}

/// `executeCopyPasteFromAnalysis`, on this thread.
func executeCopyPasteFromAnalysisHere(_ run: CopyPasteRun) {
    let startedAt = run.now()
    let destinationFingerprint = captureFolderFingerprint(run.fileSystem, run.report.destinationDirectoryPath)
    var reserved = Set<NameKeys.Exact>()
    collectDestinationPathKeys(run.resolvedNodes, caseSensitive: run.report.destinationCaseSensitive, into: &reserved)
    let shared = ExecutionShared(
        reservedPaths: reserved,
        undo: UndoRecorder(topLevelNodeIds: Set(run.resolvedNodes.map { NameKeys.Exact($0.node.id) })))
    let context = ExecutionContext(
        run, destinationDev: destinationFingerprint.dev, totalItemCount: countExecutableSteps(run.resolvedNodes),
        // What will be written: items skipped (an Add Missing merge's existing ones) don't count. Unknown when a
        // folder is renamed whole: what it holds wasn't read.
        totalBytes: run.resolvedNodes.contains { $0.node.renameOnly } ? nil : sumSubtreeBytes(run.resolvedNodes),
        shared: shared)
    var itemResults: [CopyPasteItemResult] = []
    var encounteredError: (any Error)?
    var cancelled = false

    emitProgress(context, .running, nil, nil)

    func recordNotStarted(_ nodes: ArraySlice<ResolvedCopyPasteNode>) {
        for node in nodes {
            itemResults.append(
                node.action == .skip
                    ? itemResult(node, .skipped, nil, .plannedConflictPolicy)
                    : itemResult(node, .cancelled, notStartedMessage))
        }
    }

    for (nodeIndex, node) in run.resolvedNodes.enumerated() {
        if run.signal.isStopped {
            cancelled = true
            recordNotStarted(run.resolvedNodes[nodeIndex...])
            break
        }
        shared.undo.unit = []
        defer {
            // What was done for this item counts, even when it then failed or was stopped.
            closeUndoUnit(context)
        }
        do {
            let outcome = try executeResolvedNode(context, node)
            itemResults.append(outcomeItemResult(asExecuted(context, node), outcome))
            // Surface children (files, and folders that failed) in the result.
            appendItems(&itemResults, outcome.childItems)
        } catch {
            if isAbortError(error) || run.signal.isStopped {
                cancelled = true
                itemResults.append(itemResult(asExecuted(context, node), .cancelled, cancelledMessage))
                if let stopped = rootError(error) as? CancelledWithItemsError {
                    appendItems(&itemResults, stopped.childItems)
                }
                recordNotStarted(run.resolvedNodes[(nodeIndex + 1)...])
                break
            }
            let message = describeCopyPasteError(error)
            if encounteredError == nil {
                encounteredError = error
            }
            itemResults.append(failedItemResult(asExecuted(context, node), error, message))
            // Keep going: one failed item must not stop the rest of the operation.
        }
    }

    let status = resolveTerminalStatus(cancelled: cancelled, itemResults: itemResults)
    let undoLog: UndoLog =
        if let reason = shared.undo.cantUndo {
            .notUndoable(reason: reason)
        } else {
            .undoable(units: shared.undo.units)
        }
    var result = createOperationResult(
        operationId: run.operationId, report: run.report, mode: run.mode, startedAt: startedAt,
        finishedAt: run.now(), completedByteCount: shared.completedByteCount, totalBytes: context.totalBytes,
        items: itemResults, status: status,
        error: encounteredError.map(describeCopyPasteError) ?? (cancelled ? cancelledMessage : nil))
    result.trashedPaths = shared.trashedPaths.isEmpty ? nil : shared.trashedPaths
    result.replacedPaths = shared.replacedPaths.isEmpty ? nil : shared.replacedPaths
    result.undoLog = undoLog
    run.emit(
        CopyPasteProgressEvent(
            operationId: run.operationId, analysisId: run.report.analysisId, mode: run.mode, status: status,
            completedItemCount: shared.completedItemCount, totalItemCount: context.totalItemCount,
            completedByteCount: shared.completedByteCount, totalBytes: context.totalBytes, currentSourcePath: nil,
            currentDestinationPath: nil, runtimeConflict: nil, result: result))
}

// MARK: Undo

/// Ends the steps of the picked item just worked on. What it made is looked at now, once all of it is in place
/// (a folder's date is set last), for Undo to tell if it changes.
func closeUndoUnit(_ context: ExecutionContext) {
    let shared = context.shared
    let steps = shared.undo.unit
    shared.undo.unit = nil
    shared.undo.pendingCantUndo = nil
    guard let steps, !steps.isEmpty else { return }
    let reader = StampReader(context.fileSystem)
    var stamped: [UndoStep] = []
    for step in steps {
        switch step {
        case .step(.created(let path, let id, _)):
            let now = readItemIdAndStamp(reader, path)
            stamped.append(.created(path: path, id: id, stamp: now.stamp))
        case .createdFile(let path):
            let now = readItemIdAndStamp(reader, path)
            stamped.append(.created(path: path, id: now.id, stamp: now.stamp))
        case .step(let step):
            stamped.append(step)
        }
    }
    shared.undo.units.append(UndoUnit(steps: stamped))
}

func markCantUndo(_ context: ExecutionContext, _ reason: CantUndoReason) {
    if context.shared.undo.cantUndo == nil {
        context.shared.undo.cantUndo = reason
    }
}

/// The picked item can't be undone if it goes on to change anything (see noteChanged).
func expectCantUndo(_ context: ExecutionContext, _ reason: CantUndoReason) {
    if context.shared.undo.pendingCantUndo == nil {
        context.shared.undo.pendingCantUndo = reason
    }
}

/// Something was written or removed for the picked item. Not while a Replace builds its new item under a hidden
/// name: that is taken away again if the Replace doesn't happen.
func noteChanged(_ context: ExecutionContext) {
    if context.recordsUndo, let pending = context.shared.undo.pendingCantUndo {
        markCantUndo(context, pending)
    }
}

private func recordsUndo(_ context: ExecutionContext, _ node: ResolvedCopyPasteNode) -> Bool {
    context.recordsUndo && context.shared.undo.topLevelNodeIds.contains(NameKeys.Exact(node.node.id))
}

/// Adds a step to the picked item's steps. Steps inside it (a file in a copied folder) are left out: undoing the
/// item undoes them.
func recordUndoStep(_ context: ExecutionContext, _ node: ResolvedCopyPasteNode, _ step: RecordingStep) {
    if recordsUndo(context, node), context.shared.undo.unit != nil {
        context.shared.undo.unit?.append(step)
    }
}

func recordCreated(_ context: ExecutionContext, _ node: ResolvedCopyPasteNode, _ path: String) {
    guard recordsUndo(context, node) else { return }
    let fileSystem = context.fileSystem
    // A folder's id is read now: filling it can take long, and what is at its path once it is done may by then
    // be another item. A file is done right away.
    recordUndoStep(
        context, node,
        node.node.sourceKind == .directory
            ? .step(.created(path: path, id: readItemId({ try fileSystem.lstat($0) }, path), stamp: nil))
            : .createdFile(path: path))
}

/// `moved` is the item as the check just before the move saw it: a move on one disk keeps the item's id, so it
/// isn't read again at its new place.
func recordMoved(_ context: ExecutionContext, _ node: ResolvedCopyPasteNode, _ to: String, _ moved: NodeFingerprint) {
    guard recordsUndo(context, node) else { return }
    let from = node.node.sourcePath
    let fileSystem = context.fileSystem
    let parentId = context.shared.folderIds.id({ try fileSystem.stat($0) }, dirnameOf(from))
    recordUndoStep(
        context, node,
        .step(
            .moved(
                .init(
                    from: from, to: to, id: fingerprintId(moved), itemKind: fingerprintItemKind(moved),
                    parentId: parentId))))
}

func fingerprintId(_ fingerprint: NodeFingerprint) -> ItemId? {
    guard let dev = fingerprint.dev, let ino = fingerprint.ino else { return nil }
    return ItemId(dev: dev, ino: ino)
}

/// The kind as kindOfStats reads it: a fingerprint takes anything that isn't a folder or a link (a FIFO, a
/// socket) for a file; its mode says what it really is.
func fingerprintItemKind(_ fingerprint: NodeFingerprint) -> ItemKind? {
    let type = (fingerprint.mode ?? 0) & UInt32(S_IFMT)
    switch fingerprint.kind {
    case .missing: return nil
    case .file: return type != 0 && type != UInt32(S_IFREG) ? .other : .file
    case .directory: return .directory
    case .symlink: return .symlink
    }
}

// MARK: Results and progress

func itemResult(
    _ node: ResolvedCopyPasteNode, _ status: CopyPasteItemResult.Status, _ error: String?,
    _ skipReason: CopyPasteItemResult.SkipReason? = nil, _ destinationPath: String? = nil
) -> CopyPasteItemResult {
    CopyPasteItemResult(
        sourcePath: node.node.sourcePath, destinationPath: destinationPath ?? node.destinationPath,
        sourceKind: node.node.sourceKind, status: status, error: error, skipReason: skipReason)
}

/// The item as it was copied: the one the person went on with when its original changed after the review,
/// otherwise the one the review saw.
func asExecuted(_ context: ExecutionContext, _ node: ResolvedCopyPasteNode) -> ResolvedCopyPasteNode {
    context.shared.acceptedNodes[NameKeys.Exact(node.node.sourcePath)] ?? node
}

func outcomeItemResult(_ node: ResolvedCopyPasteNode, _ outcome: ExecuteNodeResult) -> CopyPasteItemResult {
    var result = itemResult(
        node, outcome.itemResultStatus, outcome.itemStatus == .skipped ? nil : outcome.error, outcome.skipReason,
        outcome.destinationPath)
    let childFailureCount = countFailedItems(outcome.childItems)
    if node.node.sourceKind == .directory && childFailureCount > 0 {
        result.childFailureCount = childFailureCount
    }
    return result
}

func failedItemResult(_ node: ResolvedCopyPasteNode, _ error: any Error, _ message: String) -> CopyPasteItemResult {
    itemResult(node, .failed, message, nil, failedDestination(error) ?? node.destinationPath)
}

/// `copyingBytes`: bytes of the file being copied that are written so far, not yet counted as done.
func emitProgress(
    _ context: ExecutionContext, _ status: CopyPasteOperationStatus, _ node: ResolvedCopyPasteNode?,
    _ runtimeConflict: CopyPasteRuntimeConflict?, copyingBytes: Int64 = 0
) {
    let display = context.displayPath ?? { $0 }
    var conflict = runtimeConflict
    if let destinationPath = conflict?.destinationPath {
        conflict?.destinationPath = display(destinationPath)
    }
    context.emit(
        CopyPasteProgressEvent(
            operationId: context.operationId, analysisId: context.report.analysisId, mode: context.mode,
            status: status, completedItemCount: context.shared.completedItemCount,
            totalItemCount: context.totalItemCount,
            completedByteCount: context.shared.completedByteCount + copyingBytes, totalBytes: context.totalBytes,
            currentSourcePath: node?.node.sourcePath, currentDestinationPath: node.map { display($0.destinationPath) },
            runtimeConflict: conflict, result: nil))
}

// MARK: One item, with what changed since the review

func executeResolvedNode(_ context: ExecutionContext, _ resolvedNode: ResolvedCopyPasteNode) throws
    -> ExecuteNodeResult
{
    var currentNode = resolvedNode
    if currentNode.action == .skip {
        return .skipped(.plannedConflictPolicy, currentNode.destinationPath)
    }
    let fileSystem = context.fileSystem
    var check = detectRuntimeConflict(currentNode, context.report.analysisId, fileSystem)
    var attempt = 1
    while true {
        var question = 1
        while let runtimeConflict = check.conflict {
            if question > maxRuntimeAttempts {
                throw OperationError(
                    "\u{201C}\(basenameOf(currentNode.node.sourcePath))\u{201D} kept changing, so it was left.")
            }
            try assertNotWrittenByThisPaste(context, currentNode, runtimeConflict)
            // Whatever the answer, it would copy or merge a folder whose items weren't read.
            if currentNode.node.renameOnly && !isSourceSideConflict(runtimeConflict) {
                throw OperationError(renameOnlyMessage(currentNode))
            }
            let resolution = try answerRuntimeConflict(context, currentNode, runtimeConflict)
            // An answer about the item being pasted changing says nothing about the destination: if that changed
            // too, it is asked about on its own, never replaced unseen. An answer about the destination is about
            // the item the question showed: one that changed again while it was open is asked about again.
            let aboutSource = isSourceSideConflict(runtimeConflict)
            currentNode = try resolveWithRuntimeAnswer(
                context, currentNode, runtimeConflict, resolution, keepPlannedDestination: aboutSource)
            if currentNode.action == .skip {
                return .skipped(.runtimeConflictResolution, currentNode.destinationPath)
            }
            if aboutSource {
                context.shared.acceptedNodes[NameKeys.Exact(currentNode.node.sourcePath)] = currentNode
            }
            check = detectRuntimeConflict(currentNode, context.report.analysisId, fileSystem)
            question += 1
        }
        do {
            let outcome = try performNode(context, currentNode, check.source)
            if outcome.itemStatus != .skipped {
                context.shared.writtenPaths.insert(
                    NameKeys.exactDestinationKey(outcome.destinationPath, caseSensitive: context.caseSensitive))
                context.shared.writtenByFolder[NameKeys.Exact(dirnameOf(outcome.destinationPath)), default: []]
                    .append(outcome.destinationPath)
            }
            return outcome
        } catch {
            guard let taken = rootError(error) as? DestinationTakenError else {
                // "You don't have permission" is the wrong reason when an item is locked.
                let explained: any Error =
                    findLockedRefusal(
                        context.getFlags, rootError(error),
                        [
                            currentNode.node.sourcePath, currentNode.destinationPath,
                            dirnameOf(currentNode.destinationPath),
                            dirnameOf(currentNode.node.sourcePath),
                        ]) ?? error
                throw PlacedError.placed(explained, at: currentNode.destinationPath)
            }
            if attempt >= maxRuntimeAttempts {
                throw taken.original
            }
            // Something took the name while this item was being written: decide again from what is there now.
            check = detectRuntimeConflict(currentNode, context.report.analysisId, fileSystem)
            attempt += 1
        }
    }
}

/// Every question asked gets an id of its own, even one asked again about the same item: an answer to an earlier
/// question never answers a later one, and the window, which remembers by id which question it has answered,
/// shows the new one ready to answer.
private let questionsAsked = OSAllocatedUnfairLock(initialState: 0)

/// Asks about a conflict, unless an earlier "apply to the rest" answer covers it.
func answerRuntimeConflict(
    _ context: ExecutionContext, _ node: ResolvedCopyPasteNode, _ conflict: CopyPasteRuntimeConflict
) throws -> CopyPasteChoice {
    if let standing = context.autoResolve(conflict) {
        return standing
    }
    let number = questionsAsked.withLock { count in
        count += 1
        return count
    }
    var question = conflict
    question.conflictId = "\(conflict.conflictId)-\(number)"
    // Asked for before the question goes out, so an answer given right away isn't lost.
    let answer = context.requestResolution(question)
    emitProgress(context, .awaitingResolution, node, question)
    let resolution = answer.wait()
    try context.signal.throwIfStopped()
    guard let resolution else {
        throw OperationError("Runtime conflict was not resolved.")
    }
    return resolution
}

func isSourceSideConflict(_ conflict: CopyPasteRuntimeConflict) -> Bool {
    conflict.reason == .sourceChanged || conflict.reason == .sourceDeleted
}

/// On a disk that doesn't tell "A.txt" from "a.txt", two items from a disk that does would land on one name: the
/// second is never allowed to replace the first, which this same paste just wrote (its original may already be
/// gone, after a move). A disk may take other names for one too ("Strasse" for "Straße" on some servers): the
/// item there is then known as one this paste wrote by its id, looked up only now, as a question is rare.
private func assertNotWrittenByThisPaste(
    _ context: ExecutionContext, _ node: ResolvedCopyPasteNode, _ conflict: CopyPasteRuntimeConflict
) throws {
    if isSourceSideConflict(conflict) || conflict.reason == .trashUnavailable {
        return
    }
    if context.shared.writtenPaths.contains(
        NameKeys.exactDestinationKey(node.destinationPath, caseSensitive: context.caseSensitive))
    {
        throw OperationError(sameNameMessage(node))
    }
    let there = conflict.currentDestinationFingerprint
    guard there.ino != nil else { return }
    for path in context.shared.writtenByFolder[NameKeys.Exact(dirnameOf(node.destinationPath))] ?? [] {
        let written = captureFingerprint(context.fileSystem, path)
        if written.ino == there.ino && written.dev == there.dev {
            throw OperationError(sameNameMessage(node))
        }
    }
}

private func sameNameMessage(_ node: ResolvedCopyPasteNode) -> String {
    "\u{201C}\(basenameOf(node.node.sourcePath))\u{201D} wasn't pasted because another item of this paste has the same name on this disk, which doesn't tell upper and lower case apart."
}

/// Continues from what is on disk now, which is what the person just decided on. After a question about the
/// item being pasted, the destination stays as planned, so a change there is still noticed and asked about.
private func resolveWithRuntimeAnswer(
    _ context: ExecutionContext, _ node: ResolvedCopyPasteNode, _ conflict: CopyPasteRuntimeConflict,
    _ resolution: CopyPasteChoice, keepPlannedDestination: Bool
) throws -> ResolvedCopyPasteNode {
    let fileSystem = context.fileSystem
    let currentDestination =
        keepPlannedDestination ? node.node.destinationFingerprint : conflict.currentDestinationFingerprint
    // The review counted the folder it saw: one a question showed since is another item.
    let destinationTotalNodeCount = keepPlannedDestination ? node.node.destinationTotalNodeCount : nil
    var source: CopyPasteAnalysisNode
    if resolution != .skip && keepPlannedDestination && conflict.currentSourceFingerprint.exists {
        source = try readChangedSourceAgain(context, node, conflict.currentSourceFingerprint)
    } else {
        source = node.node
        if conflict.currentSourceFingerprint.exists {
            source.sourceFingerprint = conflict.currentSourceFingerprint
        }
    }
    let conflictClass: ConflictClass? =
        currentDestination.exists
        ? conflictClassFor(
            fileSystem, source: (source.sourcePath, source.sourceKind),
            destination: (node.destinationPath, currentDestination.kind))
        : nil
    if resolution == .merge && conflictClass != .directoryConflict {
        throw OperationError(
            "\u{201C}\(basenameOf(node.node.sourcePath))\u{201D} is no longer a folder, so it can't be merged and was left."
        )
    }
    source.destinationPath = node.destinationPath
    source.destinationFingerprint = currentDestination
    source.destinationKind = currentDestination.kind
    source.destinationTotalNodeCount = destinationTotalNodeCount
    source.conflictClass = conflictClass
    return try resolveSingleNodeWithAction(
        node: source, action: resolution, policy: context.policy, overrides: context.overrides,
        fileSystem: fileSystem, caseSensitive: context.caseSensitive, reservedPaths: &context.shared.reservedPaths)
}

/// The item being pasted changed after the review. A file whose contents changed is still the same file;
/// anything else (a file saved as a package, a package saved anew under a new identity, a folder turned into a
/// file) is read again, or the paste would write what the review saw: an empty folder for a new package, or a
/// package missing its new files.
private func readChangedSourceAgain(
    _ context: ExecutionContext, _ node: ResolvedCopyPasteNode, _ current: NodeFingerprint
) throws -> CopyPasteAnalysisNode {
    var planned = node.node
    if current.kind == planned.sourceKind && current.kind != .directory {
        planned.sourceFingerprint = current
        return planned
    }
    let fresh = try analyzeItemAgain(
        id: planned.id, sourcePath: planned.sourcePath, destinationPath: node.destinationPath,
        fileSystem: context.fileSystem, caseSensitive: context.caseSensitive, signal: context.signal)
    var withPlannedDestinations = keepPlannedDestinations(context, fresh, planned)
    context.totalItemCount += max(0, fresh.totalNodeCount - planned.totalNodeCount)
    withPlannedDestinations.keepBothDestinationPath = planned.keepBothDestinationPath
    withPlannedDestinations.replaceBlockedReason = planned.replaceBlockedReason
    return withPlannedDestinations
}

/// Items inside a re-read folder that the review also saw keep the destination it saw: one that changed there
/// since is then still asked about, never replaced unseen.
private func keepPlannedDestinations(
    _ context: ExecutionContext, _ fresh: CopyPasteAnalysisNode, _ planned: CopyPasteAnalysisNode
) -> CopyPasteAnalysisNode {
    var plannedChildren: [NameKeys.Exact: CopyPasteAnalysisNode] = [:]
    for child in planned.children {
        // A Map keeps the last item of a name.
        plannedChildren[NameKeys.Exact(basenameOf(child.sourcePath))] = child
    }
    var node = fresh
    node.children = fresh.children.map { child in
        guard let plannedChild = plannedChildren[NameKeys.Exact(basenameOf(child.sourcePath))] else {
            return child
        }
        return keepPlannedDestinations(context, child, plannedChild)
    }
    node.destinationFingerprint = planned.destinationFingerprint
    node.destinationKind = planned.destinationKind
    node.destinationTotalNodeCount = planned.destinationTotalNodeCount
    node.destinationOnly = planned.destinationOnly
    node.conflictClass =
        planned.destinationFingerprint.exists
        ? conflictClassFor(
            context.fileSystem, source: (fresh.sourcePath, fresh.sourceKind),
            destination: (fresh.destinationPath, planned.destinationKind))
        : nil
    node.disposition = planned.destinationFingerprint.exists ? .conflict : .new
    return node
}

/// The clash an item has with what is at its destination, as the review would classify it (two packages are
/// replaced whole, never merged).
func conflictClassFor(
    _ fileSystem: some AnalysisFileSystem, source: (path: String, kind: CopyPasteNodeKind),
    destination: (path: String, kind: CopyPasteNodeKind)
) -> ConflictClass {
    classifyConflict(fileSystem, source: source, destination: destination) ?? .typeMismatch
}

/// What changed since the review, if anything, along with the item being pasted as it is now.
func detectRuntimeConflict(
    _ resolvedNode: ResolvedCopyPasteNode, _ analysisId: String, _ fileSystem: some AnalysisFileSystem
) -> (conflict: CopyPasteRuntimeConflict?, source: NodeFingerprint) {
    let source = captureFingerprint(fileSystem, resolvedNode.node.sourcePath)
    return (findRuntimeConflict(resolvedNode, analysisId, fileSystem, source), source)
}

private func findRuntimeConflict(
    _ resolvedNode: ResolvedCopyPasteNode, _ analysisId: String, _ fileSystem: some AnalysisFileSystem,
    _ currentSourceFingerprint: NodeFingerprint
) -> CopyPasteRuntimeConflict? {
    let node = resolvedNode.node
    let currentDestinationFingerprint = captureFingerprint(fileSystem, resolvedNode.destinationPath)
    func conflict(_ reason: RuntimeConflictReason, _ conflictClass: ConflictClass, source side: Bool)
        -> CopyPasteRuntimeConflict
    {
        CopyPasteRuntimeConflict(
            conflictId: "runtime-\(node.id)-\(side ? "source" : "destination")", analysisId: analysisId,
            sourcePath: node.sourcePath, destinationPath: resolvedNode.destinationPath, sourceKind: node.sourceKind,
            destinationKind: side ? node.destinationKind : currentDestinationFingerprint.kind,
            conflictClass: conflictClass, reason: reason, sourceFingerprint: node.sourceFingerprint,
            destinationFingerprint: node.destinationFingerprint, currentSourceFingerprint: currentSourceFingerprint,
            currentDestinationFingerprint: currentDestinationFingerprint)
    }
    func classOfWhatIsThere() -> ConflictClass {
        conflictClassFor(
            fileSystem, source: (node.sourcePath, node.sourceKind),
            destination: (resolvedNode.destinationPath, currentDestinationFingerprint.kind))
    }

    // A folder's own timestamps change whenever anything inside it changes; its items are checked one by one,
    // so only its identity matters here.
    let sourceChanged =
        node.sourceKind == .directory
        ? !sameItemIdentity(node.sourceFingerprint, currentSourceFingerprint)
        : !fingerprintsEqual(node.sourceFingerprint, currentSourceFingerprint)
    if sourceChanged {
        return conflict(
            currentSourceFingerprint.exists ? .sourceChanged : .sourceDeleted,
            node.conflictClass ?? (node.sourceKind == .directory ? .directoryConflict : .fileConflict), source: true)
    }

    let destinationExists = currentDestinationFingerprint.exists && currentDestinationFingerprint.kind != .missing
    switch resolvedNode.action {
    case .create, .keepBoth:
        return destinationExists ? conflict(.destinationCreated, classOfWhatIsThere(), source: false) : nil
    case .overwrite:
        // Gone already: nothing is left to replace, so this simply becomes a copy.
        guard destinationExists else { return nil }
        let planned = node.destinationFingerprint
        return isAsApproved(planned, currentDestinationFingerprint)
            ? nil
            : conflict(planned.exists ? .destinationChanged : .destinationCreated, classOfWhatIsThere(), source: false)
    case .merge:
        if !destinationExists {
            // The folder to merge into was removed: recreating it silently would bring back a folder someone just
            // deleted.
            return conflict(.destinationDeleted, .directoryConflict, source: false)
        }
        return currentDestinationFingerprint.kind != .directory
            ? conflict(.destinationChanged, .typeMismatch, source: false) : nil
    case .skip:
        return nil
    }
}

/// Whether the item now at a destination (`current`) is the one the review, or the answer to a question, agreed
/// to replace (`planned`). A folder's timestamps change whenever anything inside it does (Finder writes
/// .DS_Store just by showing it), so for folders only their identity counts: an item added to one since goes to
/// the Trash with it, where it can be got back (a folder deleted for good is counted first).
func isAsApproved(_ planned: NodeFingerprint, _ current: NodeFingerprint) -> Bool {
    if planned.kind == .directory && current.kind == .directory {
        return sameItemIdentity(planned, current)
    }
    return current.exists && fingerprintsEqual(planned, current)
}

func sameItemIdentity(_ planned: NodeFingerprint, _ current: NodeFingerprint) -> Bool {
    planned.exists == current.exists && planned.kind == current.kind
        && (planned.ino == nil || current.ino == nil || planned.ino == current.ino)
        && (planned.dev == nil || current.dev == nil || planned.dev == current.dev)
}
