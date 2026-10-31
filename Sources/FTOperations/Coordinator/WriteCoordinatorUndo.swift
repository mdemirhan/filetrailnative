// Port of the undo:prepare and undo:start handlers, executeUndoOperation, undoNotAnswered, describeUnaskedQuestion and
// answerWithin (apps/desktop/src/main/bootstrap/writeOperations.ts): Undo and Redo through the write slot
import FTFileSystem
import FTFoundation
import Foundation
import os

/// What an Undo (or Redo) was looked at for (`undoQuestionsAsked`'s value).
struct UndoLook {
    var direction: UndoDirection
    var entryId: Int
    var generation: Int
    var questions: UndoQuestions
}

/// The coordinator's Undo state.
struct UndoState {
    /// What each Undo or Redo looked at asked, by its ticket: starting it is refused when there is something to ask
    /// now that wasn't asked then. Each look gets a ticket of its own, so two windows looking at one Undo each start
    /// it with what they were asked.
    var asked: [String: UndoLook] = [:]
    var ticketCount = 0
    /// An Undo (or Redo) being looked at: ⌘Z pressed again meanwhile does nothing more.
    var preparing = false
    /// What runs an Undo on the disk (tests make it fail as nothing else can).
    var run: @Sendable ([UndoUnit], UndoRunOptions) throws -> UndoRun = { UndoExecution.runUndo($0, $1) }
}

/// What `undo:prepare` answers.
public struct UndoPrepared: Equatable, Sendable {
    public enum Refusal: String, Sendable {
        case busy, nothing
        case cantUndo = "cant_undo"
    }

    /// What `startUndo` is given; nil when refused.
    public var ticket: String?
    public var refusal: Refusal?
    /// What the Edit menu says after "Undo " ("Move of “a.txt”").
    public var label: String?
    public var action: WriteOperationAction?
    /// The names the window asks about; their paths stay in the coordinator.
    public var nameTaken: [String]
    public var changed: [UndoQuestion.ChangedItem]

    public init(
        ticket: String?, refusal: Refusal?, label: String?, action: WriteOperationAction?, nameTaken: [String],
        changed: [UndoQuestion.ChangedItem]
    ) {
        self.ticket = ticket
        self.refusal = refusal
        self.label = label
        self.action = action
        self.nameTaken = nameTaken
        self.changed = changed
    }

    static func refused(_ refusal: Refusal) -> UndoPrepared {
        UndoPrepared(ticket: nil, refusal: refusal, label: nil, action: nil, nameTaken: [], changed: [])
    }
}

extension WriteCoordinator {
    /// `UNDO_CHECK_WITHIN_MS`: how long the disks may take to answer when an Undo looks at what it would ask, when it
    /// is chosen and again as it starts. As it starts it holds the write slot, and a disk that doesn't answer (a
    /// network share gone away) mustn't keep every other operation waiting; when chosen, ⌘Z mustn't seem to do
    /// nothing.
    public nonisolated static let undoCheckWithinMs: Double = 10_000

    /// The file system Undo writes with: the app's has the ACL calls; another local one goes without them.
    func undoFileSystem() throws -> any UndoFileSystem {
        if let fileSystem = fileSystem as? any UndoFileSystem {
            return fileSystem
        }
        return LocalAsUndoFileSystem(try localFileSystem())
    }

    /// `undo:prepare`: what undoing (or redoing) the last operation would ask, without changing anything. It doesn't
    /// take the write slot.
    public func prepareUndo(_ direction: UndoDirection) async throws -> UndoPrepared {
        let history = options.undoHistory
        if closing || slotHolder != nil {
            return .refused(.busy)
        }
        if undo.preparing {
            return .refused(.nothing)
        }
        guard let history, let entry = history.top(direction) else {
            return .refused(direction == .undo && history?.menu().cantUndo == true ? .cantUndo : .nothing)
        }
        let fileSystem = try undoFileSystem()
        let generation = history.generation
        undo.ticketCount += 1
        let ticket = "\(direction.rawValue):\(entry.id):\(generation):\(undo.ticketCount)"
        undo.preparing = true
        let units = entry.units
        let questions = await Self.answerWithin(options.undoCheckWithinMs) {
            UndoPlan.findQuestions(fileSystem, units)
        }
        undo.preparing = false
        guard let questions else {
            throw WriteCoordinatorError(Self.undoNotAnswered(direction))
        }
        // Only tickets for the history as it is now can still be started.
        undo.asked = undo.asked.filter { $0.value.generation == history.generation }
        undo.asked[ticket] = UndoLook(
            direction: direction, entryId: entry.id, generation: generation, questions: questions)
        return UndoPrepared(
            ticket: ticket, refusal: nil, label: direction == .undo ? history.menu().undo : history.menu().redo,
            action: entry.action, nameTaken: questions.nameTaken.map(\.name),
            changed: questions.changed.map {
                UndoQuestion.ChangedItem(name: $0.name, putBack: $0.putBack, replaced: $0.replaced)
            })
    }

    /// `undo:start`: runs what `prepareUndo` looked at, once what would be asked now was asked then.
    @discardableResult
    public func startUndo(ticket: String, window: any WriteOperationWindow) async throws -> WriteOperationHandle {
        let look = undo.asked[ticket]
        let history = options.undoHistory
        // Another operation, or another Undo, came in between: what was asked about may not be what would be done
        // now.
        func entryAsked() throws -> (history: UndoHistory, look: UndoLook, entry: UndoEntry) {
            guard let history, let look, let entry = history.top(look.direction), entry.id == look.entryId,
                history.generation == look.generation
            else {
                throw WriteCoordinatorError("Something changed since Undo was chosen. Choose it again.")
            }
            return (history, look, entry)
        }
        // Things may have changed on disk while the questions were open: what would be asked now must have been asked
        // and agreed to (each question is all or nothing).
        let asked = try entryAsked().look.questions
        let fileSystem = try undoFileSystem()
        let withinMs = options.undoCheckWithinMs
        let now = try await prepareWithReservedSlot { () async throws -> UndoQuestions? in
            let units = try entryAsked().entry.units
            return await Self.answerWithin(withinMs) { UndoPlan.findQuestions(fileSystem, units) }
        }
        let started = try entryAsked()
        guard let now else {
            throw WriteCoordinatorError(Self.undoNotAnswered(started.look.direction))
        }
        if let unasked = Self.describeUnaskedQuestion(asked, now, started.look.direction) {
            throw WriteCoordinatorError(unasked)
        }
        let direction = started.look.direction
        let entry = started.entry
        let changedAgreed = Set(asked.changed.map(\.path))
        return try queueLocalWriteOperation(action: direction == .undo ? .undo : .redo, window: window) {
            [weak self] operation in
            await self?.executeUndo(
                started.history, direction, entry, changedAgreed: changedAgreed, operation, fileSystem)
        }
    }

    /// `executeUndoOperation`.
    func executeUndo(
        _ history: UndoHistory, _ direction: UndoDirection, _ entry: UndoEntry, changedAgreed: Set<String>,
        _ operation: LocalWriteOperation, _ fileSystem: any UndoFileSystem
    ) async {
        let startedAt = Date()
        // Counted as the run counts what it has done: each step, and each item of a batch.
        let totalItemCount = UndoHistory.itemStepCount(entry.units)
        let homePath = homePath
        let homeDev: Int64? = await LocalOperations.onDisk {
            if case .size(let home) = LocalOperations.readItemSize(fileSystem.itemSize, homePath) { return home.dev }
            return nil
        }
        var runDiskHasTrash: (@Sendable (String) -> Bool)?
        if let hasTrash = options.diskHasTrash {
            runDiskHasTrash = { path in (try? hasTrash(path)) ?? true }
        }
        let action = operation.action
        let operationId = operation.operationId
        let runOptions = UndoRunOptions(
            direction: direction, fileSystem: fileSystem, signal: operation.signal, homeDev: homeDev,
            diskHasTrash: runDiskHasTrash,
            changedAgreed: changedAgreed, journal: options.writeJournal, batchRename: options.undoBatchRename,
            onStepStart: { [weak self] path, completedItemCount in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.emitLocalWriteOperationEvent(
                            WriteOperationEvent(
                                operationId: operationId, action: action, status: .running,
                                completedItemCount: completedItemCount, totalItemCount: totalItemCount,
                                currentSourcePath: path))
                    }
                }
            })
        let units = entry.units
        let runner = undo.run
        var run: UndoRun
        do {
            run = try await LocalOperations.onDisk { try runner(units, runOptions) }
        } catch {
            // Nothing expected gets here. What it did is unknown, so nothing can be redone; all of it stays to be
            // tried again (each step is checked on disk first, so one done already is then skipped).
            options.logError("[filetrail] an Undo stopped unexpectedly", error)
            run = UndoRun()
            run.leftover = units
            run.items = [
                WriteOperationItem(
                    sourcePath: nil, destinationPath: nil, status: .failed,
                    error: "The \(direction.command) stopped unexpectedly: \(errorMessage(error))")
            ]
        }
        // Before the write slot is freed, so the next operation is recorded after this one. A mistake in keeping the
        // history (or in the menu rebuilt from it) must not keep the end of the Undo from being sent.
        do {
            try history.finish(direction, entryId: entry.id, done: run.done, leftover: run.leftover)
        } catch {
            options.logError("[filetrail] couldn't record an Undo in the history", error)
        }
        let problems = run.items.filter { item -> Bool in
            item.status == .failed || (item.status == .skipped && item.error != nil)
        }
        let status: WriteOperationStatus =
            run.cancelled
            ? (run.completedItemCount > 0 ? .partial : .cancelled)
            : !problems.isEmpty ? (run.completedItemCount > 0 ? .partial : .failed) : .completed
        let result = LocalWriteResults.result(
            operationId: operationId, action: action, targetPath: nil, startedAt: startedAt, finishedAt: Date(),
            totalItemCount: run.items.count, completedItemCount: run.completedItemCount, items: run.items,
            status: status,
            error: run.cancelled
                ? LocalWriteResults.stoppedMessage(run.completedItemCount, direction == .undo ? "undone" : "redone")
                : problems.first?.error)
        operation.emit(
            operation.progress(
                status, completedItemCount: run.completedItemCount, totalItemCount: totalItemCount, result: result),
            removedItems: run.removedItems)
    }

    /// `undoNotAnswered`: why an Undo (or Redo) was refused when a disk didn't answer its look at the items.
    nonisolated static func undoNotAnswered(_ direction: UndoDirection) -> String {
        let command = direction.command
        return "A disk didn't answer while \(command) looked at its items. Choose \(command) again once it does."
    }

    /// `describeUnaskedQuestion`: what an Undo (or Redo) would ask now that it didn't ask when it was chosen, as the
    /// sentence that refuses to start it; nil when everything was asked.
    nonisolated static func describeUnaskedQuestion(
        _ asked: UndoQuestions, _ now: UndoQuestions, _ direction: UndoDirection
    ) -> String? {
        let command = direction.command
        let changed = now.changed.first { item in
            !asked.changed.contains {
                sameText($0.path, item.path) && $0.putBack == item.putBack && $0.replaced == item.replaced
            }
        }
        if let changed {
            return "\u{201C}\(changed.name)\u{201D} was changed after \(command) was chosen. Choose \(command) again."
        }
        let taken = now.nameTaken.first { item in !asked.nameTaken.contains { sameText($0.path, item.path) } }
        if let taken {
            return
                "Another item took the name \u{201C}\(taken.name)\u{201D} after \(command) was chosen. Choose \(command) again."
        }
        return nil
    }

    /// `answerWithin`: what `work` gives, on a disk thread of its own, or nil when it takes longer than
    /// `milliseconds`. A disk that doesn't answer keeps that thread; nothing waits for it.
    nonisolated static func answerWithin<T: Sendable>(_ milliseconds: Double, _ work: @escaping @Sendable () -> T)
        async -> T?
    {
        await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let answered = OSAllocatedUnfairLock(initialState: false)
            let answer: @Sendable (T?) -> Void = { value in
                let first = answered.withLock { done -> Bool in
                    defer { done = true }
                    return !done
                }
                if first { continuation.resume(returning: value) }
            }
            DispatchQueue.global(qos: .userInitiated).async { answer(work()) }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + milliseconds / 1000) {
                answer(nil)
            }
        }
    }
}

/// A local file system Undo writes with as it is, without the ACL calls it doesn't have.
struct LocalAsUndoFileSystem: UndoFileSystem {
    let base: any LocalWriteFileSystem

    init(_ base: any LocalWriteFileSystem) {
        self.base = base
    }

    func rename(_ from: String, _ to: String) throws { try base.rename(from, to) }
    func renameExclusive(_ from: String, _ to: String) throws { try base.renameExclusive(from, to) }
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
}
