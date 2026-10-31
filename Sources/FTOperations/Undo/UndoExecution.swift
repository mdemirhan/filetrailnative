// Port of apps/desktop/src/main/bootstrap/undoExecution.ts
import FTFileSystem
import FTFoundation
import Foundation
import os

// Runs an Undo (or a Redo): the reverse of each step, newest first, one at a time. Each is checked on disk just
// before it runs and skipped, never forced, when it no longer fits. Nothing is overwritten (every move refuses a
// taken name) and nothing is deleted: what an operation made goes to the Trash.
//
// What the person was asked first (see findQuestions) was all or nothing: an Undo they agreed to puts an item whose
// name is taken back with a number, and moves an item that changed since to the Trash, so it is never left half done
// by an answer.
//
// A step skipped because the disk check refused it (the item was changed, moved or removed outside the app) is
// dropped: there is nothing left to undo there. A step whose rename or Trash failed (no permission, a locked folder,
// the Trash refusing) stays to be undone, with the steps before it in its unit, so the next Undo tries it again rather
// than undoing an older operation instead.

/// What an Undo did (`UndoRun`).
public struct UndoRun: Sendable {
    public var items: [WriteOperationItem] = []
    /// What was done, unit by unit in the order it was done: what the other direction undoes.
    public var done: [UndoUnit] = []
    /// What is left to do, in the order the operation did it: what a stop didn't reach, and what failed to be
    /// written.
    public var leftover: [UndoUnit] = []
    public var removedItems: [RemovedItem] = []
    public var completedItemCount = 0
    public var cancelled = false

    public init() {}
}

/// What `runUndo` is given besides the units.
public struct UndoRunOptions: Sendable {
    public var direction: UndoDirection
    public var fileSystem: any UndoFileSystem
    public var signal: StopSignal
    /// The home folder's disk: an item from there lands in the home folder's Trash.
    public var homeDev: Int64?
    /// Whether the disk holding a path has a Trash (`makeDiskHasTrash`), to tell a Trash that failed without saying
    /// why from a disk that has none.
    public var diskHasTrash: (@Sendable (String) -> Bool)?
    /// The items the person agreed to move to the Trash though they changed since. Another that changed once the Undo
    /// started is left, and the next Undo asks about it.
    public var changedAgreed: Set<NameKeys.Exact>
    /// Where a rename of several writes down the items it moves aside (see WriteJournal).
    public var journal: (any WriteJournal)?
    /// The batch rename a batch step runs (`runBatchRename`; tests give their own).
    public var batchRename: UndoBatchRenamer
    /// Told as each step starts, with how many items are done; from the thread the run is on.
    public var onStepStart: (@Sendable (String, Int) -> Void)?

    public init(
        direction: UndoDirection, fileSystem: any UndoFileSystem, signal: StopSignal = StopSignal(),
        homeDev: Int64? = nil, diskHasTrash: (@Sendable (String) -> Bool)? = nil, changedAgreed: Set<String> = [],
        journal: (any WriteJournal)? = nil, batchRename: @escaping UndoBatchRenamer = UndoBatchRename.runBatchRename,
        onStepStart: (@Sendable (String, Int) -> Void)? = nil
    ) {
        self.direction = direction
        self.fileSystem = fileSystem
        self.signal = signal
        self.homeDev = homeDev
        self.diskHasTrash = diskHasTrash
        self.changedAgreed = Set(changedAgreed.map(NameKeys.Exact.init))
        self.journal = journal
        self.batchRename = batchRename
        self.onStepStart = onStepStart
    }
}

public enum UndoExecution {
    /// Tries at a free numbered name ("a 2.txt") when the one found free is taken just then.
    static let keepBothAttempts = 3
    static let maxAddedNumber = 10_000

    /// How one step went.
    enum StepOutcome {
        case done(produced: UndoStep?, items: [WriteOperationItem], removed: RemovedItem?)
        /// Refused by the disk check, or something outside the app got in the way.
        case skipped(items: [WriteOperationItem], missing: Bool)
        /// The write failed: what it did (a batch may have renamed some of its items), and what is left of the step to
        /// try again.
        case failed(produced: UndoStep?, items: [WriteOperationItem], leftover: UndoStep)
        /// A batch stopped part way: what it did, and what is left of the step.
        case stopped(produced: UndoStep?, items: [WriteOperationItem], leftover: UndoStep)

        var items: [WriteOperationItem] {
            switch self {
            case .done(_, let items, _), .skipped(let items, _), .failed(_, let items, _), .stopped(_, let items, _):
                items
            }
        }

        func with(items: [WriteOperationItem]) -> StepOutcome {
            switch self {
            case .done(let produced, _, let removed): .done(produced: produced, items: items, removed: removed)
            case .skipped(_, let missing): .skipped(items: items, missing: missing)
            case .failed(let produced, _, let leftover): .failed(produced: produced, items: items, leftover: leftover)
            case .stopped(let produced, _, let leftover): .stopped(produced: produced, items: items, leftover: leftover)
            }
        }
    }

    /// What each step of a run is given: the run's options, and the id of a folder an item is taken out of, read once
    /// per run.
    final class RunContext: Sendable {
        let options: UndoRunOptions
        private let folderIds = OSAllocatedUnfairLock(initialState: [NameKeys.Exact: ItemId?]())

        init(_ options: UndoRunOptions) {
            self.options = options
        }

        var fileSystem: any UndoFileSystem { options.fileSystem }

        func folderIdOf(_ path: String) -> ItemId? {
            let key = NameKeys.Exact(path)
            if let known = folderIds.withLock({ $0[key] }) {
                return known
            }
            let fileSystem = fileSystem
            let id = readFolderId({ try fileSystem.stat($0) }, path)
            folderIds.withLock { $0[key] = id }
            return id
        }
    }

    /// `runUndo`: reads and writes the disk, one step at a time; call it off the main actor.
    public static func runUndo(_ units: [UndoUnit], _ options: UndoRunOptions) -> UndoRun {
        var run = UndoRun()
        let context = RunContext(options)
        // What a stop didn't reach, and the units whose write failed, newest first.
        var notReached: [UndoUnit] = []
        var failed: [UndoUnit] = []
        eachUnit: for unitIndex in stride(from: units.count - 1, through: 0, by: -1) {
            let unit = units[unitIndex]
            var doneSteps: [UndoStep] = []
            // Once a step can't be undone, the ones before it in the unit aren't either: the old item of a Replace
            // isn't put back where the new one still is.
            var blocked = false
            // A step done that can't be done again (the Trash didn't say where it put the item): the unit's other
            // steps aren't redone either, so Redo never does only part of it (a Replace's old item moved to the Trash
            // again with no new item in its place).
            var unrecorded = false
            for stepIndex in stride(from: unit.steps.count - 1, through: 0, by: -1) {
                let step = unit.steps[stepIndex]
                let planned = PlannedStep(reversing: step)
                if blocked {
                    run.items.append(contentsOf: blockedItems(planned, options.direction))
                    continue
                }
                if options.signal.isStopped {
                    run.cancelled = true
                    notReached = Array(units[0..<unitIndex]) + [UndoUnit(steps: Array(unit.steps[0...stepIndex]))]
                    pushDone(&run, doneSteps, unrecorded)
                    break eachUnit
                }
                options.onStepStart?(firstPathOf(planned), run.completedItemCount)
                let outcome = runStep(planned, step, context)
                run.items.append(contentsOf: outcome.items)
                run.completedItemCount += outcome.items.filter { $0.status == .completed }.count
                switch outcome {
                case .done(let produced, _, _), .failed(let produced, _, _), .stopped(let produced, _, _):
                    if let produced {
                        doneSteps.append(produced)
                    } else if case .done = outcome {
                        unrecorded = true
                    }
                case .skipped:
                    break
                }
                switch outcome {
                case .stopped(_, _, let leftover):
                    run.cancelled = true
                    notReached =
                        Array(units[0..<unitIndex]) + [UndoUnit(steps: Array(unit.steps[0..<stepIndex]) + [leftover])]
                    pushDone(&run, doneSteps, unrecorded)
                    break eachUnit
                case .failed(_, _, let leftover):
                    // It and the steps before it in the unit wait for the next try.
                    failed.append(UndoUnit(steps: Array(unit.steps[0..<stepIndex]) + [leftover]))
                    pushDone(&run, doneSteps, unrecorded)
                    continue eachUnit
                case .done(_, _, let removed):
                    if let removed { run.removedItems.append(removed) }
                case .skipped(_, let missing):
                    if !missing { blocked = true }
                }
            }
            pushDone(&run, doneSteps, unrecorded)
        }
        run.leftover = notReached + failed.reversed()
        return run
    }

    /// What a unit did goes to the other list, unless part of it can't be done again.
    private static func pushDone(_ run: inout UndoRun, _ steps: [UndoStep], _ unrecorded: Bool) {
        if !steps.isEmpty && !unrecorded {
            run.done.append(UndoUnit(steps: steps))
        }
    }

    private static func firstPathOf(_ planned: PlannedStep) -> String {
        switch planned {
        case .move(let move): move.from
        case .trash(let trash): trash.path
        case .batch(let items): items.first?.from ?? ""
        }
    }

    private static func runStep(_ planned: PlannedStep, _ original: UndoStep, _ context: RunContext) -> StepOutcome {
        switch planned {
        case .move(let move): moveBack(move, original, context)
        case .trash(let trash): moveToTrash(trash, original, context)
        case .batch(let items): renameBack(items, context)
        }
    }

    // MARK: Items and reasons

    static func skippedItem(_ sourcePath: String, _ destinationPath: String?, _ reason: String) -> WriteOperationItem {
        WriteOperationItem(sourcePath: sourcePath, destinationPath: destinationPath, status: .skipped, error: reason)
    }

    static func failedItem(_ sourcePath: String, _ destinationPath: String?, _ reason: String) -> WriteOperationItem {
        WriteOperationItem(sourcePath: sourcePath, destinationPath: destinationPath, status: .failed, error: reason)
    }

    static func takenReason(_ path: String) -> String {
        "An item named \u{201C}\(NodePath.basename(path))\u{201D} is already in \u{201C}\(NodePath.basename(NodePath.dirname(path)))\u{201D}."
    }

    private static func describeFailure(_ fileSystem: some UndoFileSystem, _ error: any Error, _ paths: [String])
        -> String
    {
        findLockedRefusal({ try fileSystem.getFlags($0) }, error, paths)?.message ?? describeCopyPasteError(error)
    }

    /// How a failed write is taken (`classifyUndoWriteError`):
    /// - `outsideChange`: the item went away, or another item took the name just then. Like a change the disk check
    ///   finds, the step is skipped, and dropped from the list.
    /// - `permanent`: it would fail the same way every time (a disk with no Trash, a read-only disk, another disk).
    ///   Skipped and dropped too, and said, so older operations can still be undone.
    /// - `retry`: anything else (no permission, a lock, the Trash refusing for a reason it didn't give). The step
    ///   stays on the list, and the next Undo tries it.
    public enum WriteErrorKind: String, Sendable {
        case outsideChange = "outside_change"
        case permanent
        case retry
    }

    public static func classifyUndoWriteError(_ code: String?) -> WriteErrorKind {
        switch code {
        case "ENOENT", "ENOTDIR", "EEXIST": .outsideChange
        case CopyPasteErrors.noTrashErrorCode, "EROFS", "EXDEV": .permanent
        default: .retry
        }
    }

    /// `failureCode`: the code a failure of the write to the item at `path` counts as. "No Trash" only when the disk
    /// is known to have none: macOS said the Trash isn't supported there, or the disk is a network share; a Trash that
    /// failed without saying why may work next time.
    static func failureCode(_ code: String?, cause: (any Error)?, _ path: String, _ context: RunContext) -> String? {
        if code == CopyPasteErrors.noTrashErrorCode {
            let said = cause.flatMap(errorCode)
            let noTrash =
                said == "ENOTSUP" || said == "EOPNOTSUPP" || context.options.diskHasTrash?(path) == false
            return noTrash ? code : nil
        }
        return code
    }

    private static func causeOf(_ error: any Error) -> (any Error)? {
        (error as? OperationError)?.cause
    }

    /// Why a step can never be done, said about its item.
    static func permanentReason(_ code: String?, _ path: String) -> String {
        let name = "\u{201C}\(NodePath.basename(path))\u{201D}"
        switch code {
        case CopyPasteErrors.noTrashErrorCode:
            return "\(name) couldn't be moved to the Trash because its disk has no Trash."
        case "EROFS":
            return "\(name) is on a disk that can only be read."
        default:
            return "\(name) is on another disk now."
        }
    }

    /// `writeFailed`: a step whose write (the rename, the Trash, or unlocking the item for them) failed: skipped, or
    /// kept to be tried again, as `classifyUndoWriteError` says.
    private static func writeFailed(
        _ error: any Error, original: UndoStep, from: String, to: String?, around: [String], _ context: RunContext
    ) -> StepOutcome {
        let fileSystem = context.fileSystem
        let code = failureCode(errorCode(error), cause: causeOf(error), from, context)
        let kind = classifyUndoWriteError(code)
        if kind == .retry {
            return failedStep(original, from, to, describeFailure(fileSystem, error, [from] + around))
        }
        let reason: String
        if kind == .permanent {
            reason = permanentReason(code, from)
        } else if code == "EEXIST", let to {
            reason = takenReason(to)
        } else {
            reason = UndoPlan.missingReason(fileSystem, from)
        }
        return .skipped(items: [skippedItem(from, to, reason)], missing: false)
    }

    /// A step whose write failed: it stays to be tried again.
    private static func failedStep(
        _ original: UndoStep, _ sourcePath: String, _ destinationPath: String?, _ reason: String
    )
        -> StepOutcome
    {
        .failed(produced: nil, items: [failedItem(sourcePath, destinationPath, reason)], leftover: original)
    }

    // MARK: Moving back

    /// `moveBack`: a rename or move back, or an item put back from the Trash.
    private static func moveBack(_ planned: PlannedMove, _ original: UndoStep, _ context: RunContext) -> StepOutcome {
        let fileSystem = context.fileSystem
        let found: (nameTaken: Bool, renamesItself: Bool, isFolder: Bool, id: ItemId?, kind: ItemKind)
        switch UndoPlan.checkMove(fileSystem, planned) {
        case .refused(let refusal):
            if refusal.retry {
                return failedStep(original, planned.from, planned.to, refusal.reason)
            }
            return .skipped(
                items: [skippedItem(planned.from, planned.to, refusal.reason)], missing: refusal.missing)
        case .ok(let nameTaken, let renamesItself, let isFolder, let id, let kind):
            found = (nameTaken, renamesItself, isFolder, id, kind)
        }
        // An item put back from the Trash is the very item that went there (its id was checked). What kept the Trash
        // from taking it was taken off when an Undo moved it there (a lock, a folder that can't be written to, a rule
        // against deleting it), and is again to move it out, then put back once it is back.
        var lifted = Lifted()
        if planned.putBack && found.id != nil {
            do {
                lifted = try liftRestrictions(fileSystem, planned.from)
            } catch {
                return writeFailed(error, original: original, from: planned.from, to: planned.to, around: [], context)
            }
        }
        let renamed = renameInto(planned, found.nameTaken, found.renamesItself, found.isFolder, original, context)
        let target: String
        switch renamed {
        case .failure(let outcome):
            let restored = restoreRestrictions(fileSystem, planned.from, lifted)
            return restored ? outcome : outcome.with(items: notLockedAgain(outcome.items))
        case .success(let renamedTo):
            target = renamedTo
        }
        let restored = restoreRestrictions(fileSystem, target, lifted)
        // A rename keeps the item's id: it is the one the check just read.
        let produced = UndoStep.moved(
            UndoStep.Moved(
                from: planned.from, to: target, id: found.id, itemKind: found.kind,
                parentId: context.folderIdOf(NodePath.dirname(planned.from)),
                fromTrash: planned.putBack ? true : nil,
                stamp: planned.putBack ? readItemStamp(StampReader(fileSystem), target) : nil,
                locked: lifted.any && restored ? true : nil))
        return .done(
            produced: produced, items: [doneItem(planned.from, target, restored ? nil : lostLockNote(target))],
            removed: nil)
    }

    /// What keeps an item from being moved to the Trash or out of it, taken off an item the operation made (its id
    /// was checked) to move it, and put back after: its lock, a folder's read-only mode (renaming it into another
    /// folder needs it writable), and an access rule against deleting it (a copy of ~/Documents has one).
    struct Lifted {
        var flags: UInt32?
        var mode: UInt32?
        var acl: String?

        var any: Bool { flags != nil || mode != nil || acl != nil }
    }

    private static func liftRestrictions(_ fileSystem: some UndoFileSystem, _ path: String) throws -> Lifted {
        // A locked item's mode and access rules can't be changed: its lock comes off first.
        var lifted = Lifted(flags: try unlockForMove(fileSystem, path))
        do {
            let stats = try? fileSystem.lstat(path)
            if let chmod = fileSystem.chmod, let stats, stats.isDirectory {
                let mode = stats.mode & 0o7777
                if mode & 0o200 == 0 {
                    try chmod(path, mode | 0o200)
                    lifted.mode = mode
                }
            }
            let acl = fileSystem.getAcl.flatMap { getAcl -> String? in try? getAcl(path) }
            if let setAcl = fileSystem.setAcl, let acl, acl.contains(":deny:") {
                try setAcl(path, nil)
                lifted.acl = acl
            }
        } catch {
            // Left as it was: what was taken off goes back on.
            _ = restoreRestrictions(fileSystem, path, lifted)
            throw error
        }
        return lifted
    }

    /// Puts back on the item at `path` what `liftRestrictions` took off; whether all of it could be (said in the
    /// result).
    private static func restoreRestrictions(_ fileSystem: some UndoFileSystem, _ path: String, _ lifted: Lifted)
        -> Bool
    {
        var restored = true
        if let acl = lifted.acl {
            restored = succeeds(fileSystem.setAcl.map { setAcl in { try setAcl(path, acl) } })
        }
        if let mode = lifted.mode {
            restored = succeeds(fileSystem.chmod.map { chmod in { try chmod(path, mode) } }) && restored
        }
        if let flags = lifted.flags {
            restored = (try? fileSystem.setFlags(path, flags)) != nil && restored
        }
        return restored
    }

    /// Whether `write` was there to make, and went through.
    private static func succeeds(_ write: (() throws -> Void)?) -> Bool {
        guard let write else { return false }
        return (try? write()) != nil
    }

    /// An item an Undo moved that had its lock or permissions taken off, which couldn't be put back: said, though the
    /// move is done and nothing is left to do.
    private static func lostLockNote(_ path: String) -> String {
        "\u{201C}\(NodePath.basename(path))\u{201D} was moved, but its lock or permissions couldn't be put back. Set them in Finder's Get Info."
    }

    /// A done item, with a note when there is something to know about it.
    private static func doneItem(_ sourcePath: String, _ destinationPath: String?, _ note: String?)
        -> WriteOperationItem
    {
        WriteOperationItem(
            sourcePath: sourcePath, destinationPath: destinationPath, status: .completed, error: note,
            note: note != nil)
    }

    /// Items left where they were, now unlocked: said too.
    private static func notLockedAgain(_ items: [WriteOperationItem]) -> [WriteOperationItem] {
        items.map { item in
            guard let sourcePath = item.sourcePath else { return item }
            var said = item
            said.error =
                "\(item.error ?? "") \u{201C}\(NodePath.basename(sourcePath))\u{201D} couldn't be locked again. Lock it in Finder's Get Info."
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return said
        }
    }

    enum Renamed {
        case success(String)
        case failure(StepOutcome)
    }

    /// `renameInto`: renames the item of a move step to where it goes back, with a number when its name is taken;
    /// where it went, or why it didn't.
    private static func renameInto(
        _ planned: PlannedMove, _ nameTaken: Bool, _ renamesItself: Bool, _ isFolder: Bool, _ original: UndoStep,
        _ context: RunContext
    ) -> Renamed {
        let fileSystem = context.fileSystem
        var target = planned.to
        var numberedAsFolder: Bool?
        var attempt = 1
        while true {
            if nameTaken || attempt > 1 {
                let asFolder = numberedAsFolder ?? numbersAsFolder(fileSystem, planned.from, isFolder)
                numberedAsFolder = asFolder
                target = freeNumberedPath(fileSystem, planned.to, asFolder)
            }
            do {
                if renamesItself && sameText(target, planned.to) {
                    try fileSystem.rename(planned.from, target)
                } else {
                    try fileSystem.renameExclusive(planned.from, target)
                }
                return .success(target)
            } catch {
                // Another item took the name just then: the next number is tried, a few times.
                if errorCode(error) == "EEXIST" && attempt < keepBothAttempts {
                    attempt += 1
                    continue
                }
                return .failure(
                    writeFailed(
                        error, original: original, from: planned.from, to: target,
                        around: [NodePath.dirname(planned.from), NodePath.dirname(target)], context))
            }
        }
    }

    /// `numbersAsFolder`: whether the item at `path` takes a number at the end of its whole name ("Photos 2"): a
    /// folder does, a package ("Tool.app") takes it before its extension, as a file does.
    static func numbersAsFolder(_ fileSystem: some UndoFileSystem, _ path: String, _ isFolder: Bool) -> Bool {
        guard isFolder else { return false }
        let isPackage: Bool? = try? fileSystem.isPackage(path)
        return !(isPackage ?? CopyPasteNames.isPackageName(NodePath.basename(path)))
    }

    /// `freeNumberedPath`: "a 2.txt", "a 3.txt"… next to `path`: the first name that is free.
    private static func freeNumberedPath(_ fileSystem: some UndoFileSystem, _ path: String, _ numberedAsFolder: Bool)
        -> String
    {
        let folder = NodePath.dirname(path)
        let name = NodePath.basename(path)
        for number in 2...maxAddedNumber {
            let candidate = NodePath.join(
                folder,
                NumberedNames.addNumberToName(name, isFolder: numberedAsFolder, separator: " ", number: number).name)
            if (try? fileSystem.lstat(candidate)) == nil {
                return candidate
            }
        }
        return path
    }

    // MARK: Moving to the Trash

    /// `moveToTrash`: what an operation made (or put back) goes to the Trash; never deleted, even on a disk without
    /// one.
    private static func moveToTrash(_ planned: PlannedTrash, _ original: UndoStep, _ context: RunContext)
        -> StepOutcome
    {
        let fileSystem = context.fileSystem
        let options = context.options
        let changed: Bool
        let id: ItemId?
        switch UndoPlan.checkTrash(fileSystem, planned) {
        case .refused(let refusal):
            if refusal.retry {
                return failedStep(original, planned.path, nil, refusal.reason)
            }
            return .skipped(items: [skippedItem(planned.path, nil, refusal.reason)], missing: refusal.missing)
        case .ok(let isChanged, let itemId):
            changed = isChanged
            id = itemId
        }
        if changed && !options.changedAgreed.contains(NameKeys.Exact(planned.path)) {
            return failedStep(
                original, planned.path, nil,
                "\u{201C}\(NodePath.basename(planned.path))\u{201D} was changed after \(options.direction.command) was chosen, so it was left as it is."
            )
        }
        let parentId = context.folderIdOf(NodePath.dirname(planned.path))
        let looks = stampWithoutId(StampReader(fileSystem), planned.path, id)
        let before = fileSystem.itemSize.flatMap { itemSize in try? itemSize(planned.path) }
        // What an operation made is its own (its id was checked): a copy of a locked item is locked too, a copy of a
        // read-only folder read-only, and a copy of ~/Documents has a rule against deleting it; the Trash refuses all
        // of them. It goes there without them, without asking, and they are put back on it there. So does a copy put
        // back by a Redo.
        var lifted = Lifted()
        if planned.unlock && id != nil {
            do {
                lifted = try liftRestrictions(fileSystem, planned.path)
            } catch {
                return writeFailed(error, original: original, from: planned.path, to: nil, around: [], context)
            }
        }
        let trashPath: String?
        do {
            guard let trash = fileSystem.trash else {
                throw OperationError(
                    "\u{201C}\(NodePath.basename(planned.path))\u{201D} couldn\u{2019}t be moved to the Trash.")
            }
            trashPath = try trash(planned.path)
        } catch {
            let restored = restoreRestrictions(fileSystem, planned.path, lifted)
            let outcome = writeFailed(
                error, original: original, from: planned.path, to: nil, around: [NodePath.dirname(planned.path)],
                context)
            return restored ? outcome : outcome.with(items: notLockedAgain(outcome.items))
        }
        let restored = trashPath.map { restoreRestrictions(fileSystem, $0, lifted) } ?? true
        return .done(
            // In the Trash, but the Trash didn't say where: done, and nothing to do it again from.
            produced: trashPath.map {
                .trashed(from: planned.path, trashPath: $0, id: id, parentId: parentId, stamp: looks)
            },
            items: [doneItem(planned.path, nil, restored ? nil : lostLockNote(planned.path))],
            removed: RemovedItem(
                path: planned.path, item: before,
                intoHomeTrash: before.flatMap { before in options.homeDev.map { before.dev == $0 } }))
    }

    // MARK: Batch rename

    /// `renameBack`: the items of a batch rename get their names back, as one batch again: that handles swaps ("a"
    /// and "b" trading names) and a folder renamed with items inside it.
    ///
    /// What is recorded says exactly where each item went, so either list can always put it back: an item that moved
    /// is done from where it was to where it is now, and an item not yet back under its name is left to do from where
    /// it is now. That is so for an item that took a number only because the name it goes back to is still held by an
    /// item of the batch that wasn't renamed (two that swap names, one of them locked): it waits under the number, and
    /// is tried again with the other.
    private static func renameBack(_ plannedItems: [BatchRenamedItem], _ context: RunContext) -> StepOutcome {
        let fileSystem = context.fileSystem
        var items: [WriteOperationItem] = []
        var running: [BatchRenamedItem] = []
        var toRename: [UndoBatchRenameItem] = []
        let checks = UndoPlan.checkBatch(fileSystem, plannedItems)
        // The whole step as the operation named it (see the end of this function).
        let wholeStep = UndoStep.batchRenamed(
            items: plannedItems.map { BatchRenamedItem(from: $0.to, to: $0.from, id: $0.id, itemKind: $0.itemKind) })
        // An item that couldn't be checked leaves the whole batch to be tried again: its items may swap names with
        // each other.
        if let unreadable = checks.first(where: { $0.refusal?.retry == true }), let refusal = unreadable.refusal {
            return .failed(
                produced: nil, items: [failedItem(unreadable.item.from, unreadable.item.to, refusal.reason)],
                leftover: wholeStep)
        }
        for check in checks {
            if let refusal = check.refusal {
                items.append(skippedItem(check.item.from, check.item.to, refusal.reason))
            } else {
                running.append(check.item)
                toRename.append(
                    UndoBatchRenameItem(
                        sourcePath: check.item.from, destinationName: NodePath.basename(check.item.to),
                        isFolder: numbersAsFolder(fileSystem, check.item.from, check.isFolder)))
            }
        }
        if running.isEmpty {
            return .skipped(items: items, missing: false)
        }
        let errors = RecordingErrorsFileSystem(fileSystem)
        let batch = context.options.batchRename(toRename, errors, context.options.signal, context.options.journal)
        // Every item has a result, in the order asked for. Names are compared in the folder the item was in: a folder
        // renamed in the same batch takes its items' paths along.
        struct Outcome {
            var item: BatchRenamedItem
            var result: WriteOperationItem
            var from: String
            var wanted: String
            var at: String
            /// Left to do, though it moved: numbered while it waits for another item.
            var waits = false
        }
        var outcomes = batch.items.enumerated().map { index, result -> Outcome in
            let from = result.sourcePath ?? ""
            return Outcome(
                item: running[index], result: result, from: from,
                wanted: NodePath.join(NodePath.dirname(from), toRename[index].destinationName),
                at: result.destinationPath ?? from)
        }
        // The names still held by items that weren't renamed.
        var held: Set<NameKeys.Exact> = []
        for outcome in outcomes
        where outcome.result.status != .completed
            && sameText(NodePath.basename(outcome.at), NodePath.basename(outcome.from))
        {
            held.insert(UndoPlan.placeKey(outcome.from))
        }
        for index in outcomes.indices {
            let outcome = outcomes[index]
            if outcome.result.status != .completed
                || sameText(NodePath.basename(outcome.at), NodePath.basename(outcome.wanted))
                || !held.contains(UndoPlan.placeKey(outcome.wanted))
            {
                continue
            }
            // Under the number for now: done from where it was to there, and left to do from there.
            outcomes[index].waits = true
            items.append(
                failedItem(
                    outcome.from, outcome.at,
                    "\u{201C}\(NodePath.basename(outcome.from))\u{201D} is named \u{201C}\(NodePath.basename(outcome.at))\u{201D} for now, because \u{201C}\(NodePath.basename(outcome.wanted))\u{201D} couldn't be renamed out of its way."
                ))
        }
        var moves: [WriteOperationItem] = []
        var leftover: [BatchRenamedItem] = []
        for outcome in outcomes {
            let moved = !sameText(NodePath.basename(outcome.at), NodePath.basename(outcome.from))
            if moved {
                var move = outcome.result
                move.destinationPath = outcome.at
                moves.append(move)
            }
            if outcome.result.status == .completed && moved && !outcome.waits {
                items.append(outcome.result)
                continue
            }
            var left = outcome.item
            left.from = outcome.at
            if outcome.waits {
                // Still under the number: said so above.
                leftover.append(left)
                continue
            }
            if readItemRef({ try fileSystem.lstat($0) }, outcome.at).kind == nil {
                // Gone while it was being renamed: like an item the check finds gone.
                items.append(
                    skippedItem(outcome.from, outcome.item.to, UndoPlan.missingReason(fileSystem, outcome.from)))
                continue
            }
            if outcome.result.status == .failed {
                let code = failureCode(errors.codeOf(outcome.from), cause: nil, outcome.at, context)
                let kind = classifyUndoWriteError(code)
                if kind != .retry {
                    let reason = kind == .permanent ? permanentReason(code, outcome.from) : outcome.result.error
                    items.append(skippedItem(outcome.from, outcome.item.to, reason ?? takenReason(outcome.item.to)))
                    continue
                }
            }
            if outcome.result.status != .cancelled {
                items.append(outcome.result)
            }
            leftover.append(left)
        }
        let renamed = UndoBatchRename.movedItemsOf(fileSystem, moves)
        let produced: UndoStep? = renamed.isEmpty ? nil : .batchRenamed(items: renamed)
        // What is left of the step, as the operation named it, each item where it is now.
        let left = UndoStep.batchRenamed(
            items: leftover.map { BatchRenamedItem(from: $0.to, to: $0.from, id: $0.id, itemKind: $0.itemKind) })
        if !leftover.isEmpty {
            return batch.cancelled
                ? .stopped(produced: produced, items: items, leftover: left)
                : .failed(produced: produced, items: items, leftover: left)
        }
        if let produced {
            return .done(produced: produced, items: items, removed: nil)
        }
        return .skipped(items: items, missing: false)
    }

    /// A step not run because the one before it in the same unit couldn't be.
    private static func blockedItems(_ planned: PlannedStep, _ direction: UndoDirection) -> [WriteOperationItem] {
        let verb = direction == .undo ? "undone" : "redone"
        switch planned {
        case .move(let move):
            return [
                skippedItem(
                    move.from, move.to,
                    move.putBack
                        ? "\u{201C}\(NodePath.basename(move.to))\u{201D} was left in the Trash, because the item in its place couldn't be moved away."
                        : "\u{201C}\(NodePath.basename(move.from))\u{201D} was left as it is, because the step before it couldn't be \(verb)."
                )
            ]
        case .trash(let trash):
            return [
                skippedItem(
                    trash.path, nil,
                    "\u{201C}\(NodePath.basename(trash.path))\u{201D} was left as it is, because the step before it couldn't be \(verb)."
                )
            ]
        case .batch:
            return []
        }
    }
}

/// `recordingErrors`: the file system for a batch rename, keeping the error each item's rename failed with, by where
/// the item was before it: an item moved aside under a hidden name keeps its own. A name found taken is kept only when
/// nothing else went wrong (the batch numbers it).
final class RecordingErrorsFileSystem: UndoFileSystem, @unchecked Sendable {
    private let base: any UndoFileSystem
    private struct State {
        var startedAt: [NameKeys.Exact: String] = [:]
        var codes: [NameKeys.Exact: String?] = [:]
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(_ base: any UndoFileSystem) {
        self.base = base
    }

    func codeOf(_ path: String) -> String? {
        state.withLock { $0.codes[NameKeys.Exact(path)] ?? nil }
    }

    private func recording(_ from: String, _ to: String, _ rename: () throws -> Void) throws {
        let item = state.withLock { $0.startedAt[NameKeys.Exact(from)] } ?? from
        do {
            try rename()
            state.withLock { $0.startedAt[NameKeys.Exact(to)] = item }
        } catch {
            let code = errorCode(error)
            state.withLock { state in
                let key = NameKeys.Exact(item)
                if code != "EEXIST" || state.codes[key] == nil {
                    state.codes[key] = .some(code)
                }
            }
            throw error
        }
    }

    func rename(_ from: String, _ to: String) throws { try recording(from, to) { try base.rename(from, to) } }
    func renameExclusive(_ from: String, _ to: String) throws {
        try recording(from, to) { try base.renameExclusive(from, to) }
    }

    func lstat(_ path: String) throws -> WriteServiceStats { try base.lstat(path) }
    func stat(_ path: String) throws -> WriteServiceStats { try base.stat(path) }
    func realpath(_ path: String) throws -> String { try base.realpath(path) }
    func readdir(_ path: String) throws -> [String] { try base.readdir(path) }
    func readlink(_ path: String) throws -> String { try base.readlink(path) }
    func isCaseSensitive(_ path: String) throws -> Bool? { try base.isCaseSensitive(path) }
    func isPackage(_ path: String) throws -> Bool? { try base.isPackage(path) }
    func isAppleDouble(_ path: String) -> Bool { base.isAppleDouble(path) }
    func mkdir(_ path: String) throws { try base.mkdir(path) }
    func rm(_ path: String, recursive: Bool, force: Bool) throws {
        try base.rm(path, recursive: recursive, force: force)
    }
    func rmdir(_ path: String) throws { try base.rmdir(path) }
    func copyFile(
        _ source: String, _ destination: String, stop: StopSignal?, onProgress: (@Sendable (Int64) -> Void)?
    ) throws {
        try base.copyFile(source, destination, stop: stop, onProgress: onProgress)
    }
    func getFlags(_ path: String) throws -> UInt32 { try base.getFlags(path) }
    func setFlags(_ path: String, _ flags: UInt32) throws { try base.setFlags(path, flags) }
    var chmod: ((String, UInt32) throws -> Void)? { base.chmod }
    var utimes: ((String, Double, Double) throws -> Void)? { base.utimes }
    var copyMetadata: ((String, String) throws -> Void)? { base.copyMetadata }
    var setAcl: ((String, String?) throws -> Void)? { base.setAcl }
    var trash: ((String) throws -> String?)? { base.trash }
    var canModifyFolder: ((String) throws -> Void)? { base.canModifyFolder }
    var itemSize: ((String) throws -> ItemSize)? { base.itemSize }
    var getAcl: ((String) throws -> String?)? { base.getAcl }
}
