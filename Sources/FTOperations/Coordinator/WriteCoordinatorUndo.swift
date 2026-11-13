// Undo and Redo through the write slot
import FTFileSystem
import FTFoundation
import Foundation
import os

/// What an Undo (or Redo) was looked at for.
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
    /// The looks given up on whose disk still hasn't answered.
    let stuckLooks = StuckLooks()
    /// What runs an Undo on the disk (tests make it fail as nothing else can).
    var run: @Sendable ([UndoUnit], UndoRunOptions) throws -> UndoRun = { UndoExecution.runUndo($0, $1) }
}

/// What `prepareUndo` answers: what the Undo (or Redo) would ask, or why it can't run.
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
    /// How long the disks may take to answer when an Undo looks at what it would ask, when it is chosen and again as it
    /// starts: from the last answer, so a large Undo on a slow disk is looked at in full. As it starts it holds the
    /// write slot, and a disk that doesn't answer (a network share gone away) mustn't keep every other operation
    /// waiting; when chosen, ⌘Z mustn't seem to do nothing.
    public nonisolated static let undoCheckWithinMs: Double = 10_000

    /// What undoing (or redoing) the last operation would ask, without changing anything. It doesn't
    /// take the write slot. `stop` ends the look (Stop on the card that is up while it lasts): nothing is undone then,
    /// as when there is nothing to undo.
    public func prepareUndo(_ direction: UndoDirection, stop: StopSignal? = nil) async throws -> UndoPrepared {
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
        // Each look given up on keeps its threads until its disk answers: no more are started on top of them.
        let stuckLooks = undo.stuckLooks
        if stuckLooks.tooMany {
            throw WriteCoordinatorError(Self.undoNotAnswered(direction))
        }
        let fileSystem = self.fileSystem
        let generation = history.generation
        undo.ticketCount += 1
        let ticket = "\(direction.rawValue):\(entry.id):\(generation):\(undo.ticketCount)"
        undo.preparing = true
        let units = entry.units
        // Named now, after the entry looked at: another window's operation may end while the disks are read.
        let label = direction == .undo ? history.menu().undo : history.menu().redo
        let questions = await Self.answerWithin(options.undoCheckWithinMs, stuck: stuckLooks, stop: stop) { progress in
            UndoPlan.findQuestions(fileSystem, units, progress: progress)
        }
        undo.preparing = false
        if stop?.isStopped == true {
            return .refused(.nothing)
        }
        guard let questions else {
            throw WriteCoordinatorError(Self.undoNotAnswered(direction))
        }
        if history.generation != generation {
            throw WriteCoordinatorError(Self.undoOvertaken(direction))
        }
        // Only tickets for the history as it is now can still be started.
        undo.asked = undo.asked.filter { $0.value.generation == history.generation }
        undo.asked[ticket] = UndoLook(
            direction: direction, entryId: entry.id, generation: generation, questions: questions)
        return UndoPrepared(
            ticket: ticket, refusal: nil, label: label,
            action: entry.action, nameTaken: questions.nameTaken.map(\.name),
            changed: questions.changed.map {
                UndoQuestion.ChangedItem(name: $0.name, putBack: $0.putBack, replaced: $0.replaced)
            })
    }

    /// Runs what `prepareUndo` looked at, once what would be asked now was asked then.
    @discardableResult
    public func startUndo(ticket: String, window: any WriteOperationWindow) async throws -> WriteOperationHandle {
        // A ticket is started once: what it asked is let go of here, whether or not it starts.
        let look = undo.asked.removeValue(forKey: ticket)
        let history = options.undoHistory
        // A ticket no longer known still says which command it was for.
        let chosen =
            look?.direction ?? UndoDirection(rawValue: String(ticket.prefix { $0 != ":" })) ?? .undo
        // Another operation, or another Undo, came in between: what was asked about may not be what would be done
        // now.
        func entryAsked() throws -> (history: UndoHistory, look: UndoLook, entry: UndoEntry) {
            guard let history, let look, let entry = history.top(look.direction), entry.id == look.entryId,
                history.generation == look.generation
            else {
                throw WriteCoordinatorError("Something changed since \(chosen.command) was chosen. Choose it again.")
            }
            return (history, look, entry)
        }
        // Things may have changed on disk while the questions were open: what would be asked now must have been asked
        // and agreed to (each question is all or nothing).
        let asked = try entryAsked().look.questions
        let fileSystem = self.fileSystem
        let withinMs = options.undoCheckWithinMs
        let stuckLooks = undo.stuckLooks
        return try await prepareWithReservedSlot { () async throws -> UndoQuestions? in
            let units = try entryAsked().entry.units
            // As in `prepareUndo`: not answered.
            if stuckLooks.tooMany { return nil }
            return await Self.answerWithin(withinMs, stuck: stuckLooks) { progress in
                UndoPlan.findQuestions(fileSystem, units, progress: progress)
            }
        } then: { now, reservation in
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
            return try queueLocalWriteOperation(
                action: direction == .undo ? .undo : .redo, window: window, reservation: reservation
            ) { [weak self] operation in
                await self?.executeUndo(
                    started.history, direction, entry, changedAgreed: changedAgreed, operation, fileSystem)
            }
        }
    }

    /// `forgetUndo`: the Undo (or Redo) `prepareUndo` looked at won't be started (its question was cancelled): what
    /// it asked is let go of.
    public func forgetUndo(ticket: String) {
        undo.asked[ticket] = nil
    }

    func executeUndo(
        _ history: UndoHistory, _ direction: UndoDirection, _ entry: UndoEntry, changedAgreed: Set<String>,
        _ operation: LocalWriteOperation, _ fileSystem: any UndoFileSystem
    ) async {
        let startedAt = Date()
        // Counted as the run counts what it has done: each step, and each item of a batch.
        let totalItemCount = UndoHistory.itemStepCount(entry.units)
        let homePath = homePath
        let homeDev: Int64? = await LocalOperations.onDisk {
            if case .size(let home) = LocalOperations.readItemSize(fileSystem, homePath) { return home.dev }
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

    /// `undoOvertaken`: why an Undo (or Redo) was refused when another operation changed the history while it looked at
    /// its items.
    nonisolated static func undoOvertaken(_ direction: UndoDirection) -> String {
        "Something changed while \(direction.command) looked at its items. Choose \(direction.command) again."
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

    /// `answerWithin`: what `work` gives, on a thread of its own, or nil when it takes longer than `milliseconds`
    /// without an answer. A disk that doesn't answer keeps that thread; nothing waits for it, and `stuck` counts it
    /// until it returns. What a look gives once it was given up on is never taken: it was cut short. `stop` gives up
    /// on it at once.
    nonisolated static func answerWithin<T: Sendable>(
        _ milliseconds: Double, stuck: StuckLooks? = nil, stop: StopSignal? = nil,
        _ work: @escaping @Sendable (AnswerProgress) -> T
    ) async -> T? {
        let progress = AnswerProgress()
        return await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let look = OSAllocatedUnfairLock(initialState: LookEnd.waitedFor)
            // A thread of its own, not one of the shared pool's: a disk that never answers would keep it from the
            // rest of the app's disk work.
            let thread = Thread {
                let value = work(progress)
                let was = look.withLock { end -> LookEnd in
                    defer { if end == .waitedFor { end = .answered } }
                    return end
                }
                switch was {
                case .waitedFor: continuation.resume(returning: value)
                case .givenUp: stuck?.returned()
                case .answered: break
                }
            }
            thread.qualityOfService = .userInitiated
            thread.start()
            let giveUp: @Sendable () -> Void = {
                // Given up first, then the look is told: what it gives from here on is not an answer.
                let first = look.withLock { end -> Bool in
                    guard end == .waitedFor else { return false }
                    end = .givenUp
                    stuck?.gaveUp()
                    return true
                }
                if first {
                    progress.abandon()
                    continuation.resume(returning: nil)
                }
            }
            waitForAnswers(progress, milliseconds, answered: { look.withLock { $0 != .waitedFor } }, giveUp: giveUp)
            if let stop, stop.onStop(giveUp) == nil {
                // Stopped already.
                giveUp()
            }
        }
    }

    /// How a look ended (`answerWithin`).
    private enum LookEnd: Sendable {
        case waitedFor, answered, givenUp
    }

    /// Where the wait on a look runs: a queue of its own, so that it gives up in time however many threads of the
    /// shared pool are kept by disks that don't answer.
    private nonisolated static let lookWaits = DispatchQueue(label: "filetrail.undo-look-wait", qos: .userInitiated)

    /// Gives up (`giveUp`) once `milliseconds` pass without an answer: the time runs from the last one, so a look at
    /// many items on a slow disk that answers each read is never given up on, and one that stops answering is.
    private nonisolated static func waitForAnswers(
        _ progress: AnswerProgress, _ milliseconds: Double, answered: @escaping @Sendable () -> Bool,
        giveUp: @escaping @Sendable () -> Void
    ) {
        let due = progress.lastAnswer + .nanoseconds(Int(milliseconds * 1_000_000))
        lookWaits.asyncAfter(deadline: due) {
            if answered() { return }
            if progress.lastAnswer + .nanoseconds(Int(milliseconds * 1_000_000)) <= .now() {
                giveUp()
            } else {
                waitForAnswers(progress, milliseconds, answered: answered, giveUp: giveUp)
            }
        }
    }
}

/// The looks that were given up on and haven't returned (`answerWithin`): each keeps up to 17 threads waiting for its
/// disk. Past `atMost` of them an Undo is refused at once instead of starting another.
final class StuckLooks: Sendable {
    static let atMost = 4
    private let stuck = OSAllocatedUnfairLock(initialState: 0)

    var count: Int { stuck.withLock { $0 } }
    var tooMany: Bool { count >= Self.atMost }
    func gaveUp() { stuck.withLock { $0 += 1 } }
    func returned() { stuck.withLock { $0 -= 1 } }
}

/// How a look at the disks is getting on, for the wait on it (`answerWithin`): when it last got an answer, and
/// whether the wait gave up on it, so it stops.
public final class AnswerProgress: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: (last: DispatchTime.now(), abandoned: false))

    public init() {}

    /// The look got an answer (a unit of an Undo was looked at).
    public func answered() { state.withLock { $0.last = .now() } }
    /// The wait gave up: what is left needn't be looked at.
    public var abandoned: Bool { state.withLock { $0.abandoned } }
    var lastAnswer: DispatchTime { state.withLock { $0.last } }
    func abandon() { state.withLock { $0.abandoned = true } }
}
