// Port of createWriteOperationCoordinator (apps/desktop/src/main/bootstrap/writeOperations.ts): the app's one write slot,
// the write service's events as the windows hear them, the copy analyses and pastes, and quitting. The windows are in
// WriteCoordinatorWindows.swift, the progress throttle in WriteCoordinatorProgress.swift, the local operations' entry
// point in WriteCoordinatorLocal.swift.
import FTFileSystem
import FTFoundation
import Foundation
import os

/// One write at a time for the whole app: pastes, Copy To, Move To and Duplicate (through the write service), the
/// local operations (rename, New Folder, Trash, delete, Undo and Redo, batch rename), Empty Trash, and crash-recovery
/// retries. It tells every window how the running operation is doing, hands it to another window when its own closes,
/// and stops it when the app quits.
///
/// It runs on the main actor, as the original's main process runs on its one thread; the write service's events come
/// to it there. The slot itself can also be taken from any thread, by `runWriteAlone`.
@MainActor
public final class WriteCoordinator {
    /// `PROGRESS_UPDATE_INTERVAL_MS`: progress is reported once per item, which for a folder of small files is
    /// thousands of messages a second; plain "running" updates go out at most this often.
    public static let progressUpdateIntervalMs: Double = 100
    /// `SHUTDOWN_WAIT_LIMIT_MS`: how long quitting waits for a stopped operation to finish cleaning up.
    public static let shutdownWaitLimitMs: Double = 15_000
    /// `PREPARING_WRITE_OPERATION_ID`: holds the slot while a write is still being prepared, or written alone.
    nonisolated static let preparingOperationId = "preparing-write-operation"

    struct Slot {
        var active: String?
        /// Set once the app starts quitting; no new operation may begin after that.
        var closing = false
    }

    /// `activeWriteOperationId` and `closing`, which `runWriteAlone` reads from any thread.
    nonisolated let slot = OSAllocatedUnfairLock(initialState: Slot())

    let writeService: any CoordinatorWriteService
    /// What the guards ask of the disk (the system's folders, whole disks), and what local operations write with.
    public let fileSystem: (any WriteServiceFileSystem)?
    public let options: WriteCoordinatorOptions
    public var homePath: String { options.homePath }

    // The window each running operation answers to, and the operations that listen for it to close.
    var senders: [String: any WriteOperationWindow] = [:]
    var watchedOperations: Set<String> = []
    // The last progress sent for each running operation, for a window that takes it over.
    var latestProgress: [String: WriteOperationEvent] = [:]
    // The operation handed to each window, until the window asks for it (see `adoptedOperation`).
    var pendingAdoptions: [ObjectIdentifier: PendingAdoption] = [:]
    var copyPasteRequests: [String: CopyPasteStart] = [:]
    // Whether each running copy-paste copies or moves, from the write service's own events.
    var copyPasteModes: [String: CopyPasteMode] = [:]
    var localStops: [String: StopSignal] = [:]
    var localActions: [String: WriteOperationAction] = [:]
    // The window that started each copy analysis: only it may read, cancel, or start it. Each window has at most
    // one, its newest, kept until it pastes from it or goes away.
    var analysisOwners: [String: any WriteOperationWindow] = [:]
    var watchedAnalyses: Set<String> = []
    var throttles: [String: ProgressThrottle] = [:]
    // Callers waiting for the write slot to be free (see `whenIdle`).
    var idleWaiters: [@MainActor () -> Void] = []
    // While a copy-paste is being started: the latest event of an operation the start request hasn't recorded yet.
    var eventsBeforeStart: [String: CopyPasteProgressEvent]?
    // The Empty Trash running now, if any: Finder does it, so there is nothing to stop.
    var emptyTrashOperationId: String?
    var localSequence = 0
    private var unsubscribe: (@Sendable () -> Void)?

    struct PendingAdoption {
        weak var window: (any WriteOperationWindow)?
        var operationId: String
        var clearsCutClipboard: String?
        var end: WriteOperationEvent?
    }

    public init(
        writeService: any CoordinatorWriteService, fileSystem: (any WriteServiceFileSystem)? = nil,
        options: WriteCoordinatorOptions = WriteCoordinatorOptions()
    ) {
        self.writeService = writeService
        self.fileSystem = fileSystem
        self.options = options
        // The write service tells from the thread its paste runs on; the coordinator hears it on the main actor, in
        // the order it was told. What it tells on the main thread (a paste's "queued", as it starts) is heard at once.
        unsubscribe = writeService.subscribe { [weak self] event in
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.writeServiceEvent(event) }
            } else {
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.writeServiceEvent(event) } }
            }
        }
    }

    var clock: CoordinatorClock { options.clock }

    // MARK: The write slot

    /// The slot's holder, the "preparing" stand-in included.
    nonisolated var slotHolder: String? { slot.withLock { $0.active } }

    var closing: Bool { slot.withLock { $0.closing } }

    /// `ensureNoWriteOperationInFlight`.
    func ensureNoWriteOperationInFlight() throws {
        try slot.withLock { slot in
            if slot.closing { throw WriteCoordinatorError.quitting }
            if slot.active != nil { throw WriteCoordinatorError.busy }
        }
    }

    /// Takes the slot for `operationId`, refused as `ensureNoWriteOperationInFlight` refuses.
    func claimSlot(_ operationId: String) throws {
        try slot.withLock { slot in
            if slot.closing { throw WriteCoordinatorError.quitting }
            if slot.active != nil { throw WriteCoordinatorError.busy }
            slot.active = operationId
        }
    }

    /// `freeWriteSlot`.
    func freeWriteSlot(_ operationId: String) {
        let freed = slot.withLock { slot -> Bool in
            guard slot.active == operationId else { return false }
            slot.active = nil
            return true
        }
        if freed { resumeIdleWaiters() }
    }

    nonisolated private func freeSlotFromAnyThread(_ operationId: String) {
        let freed = slot.withLock { slot -> Bool in
            guard slot.active == operationId else { return false }
            slot.active = nil
            return true
        }
        guard freed else { return }
        if Thread.isMainThread {
            MainActor.assumeIsolated { resumeIdleWaiters() }
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated { self.resumeIdleWaiters() } }
        }
    }

    private func resumeIdleWaiters() {
        guard slotHolder == nil else { return }
        let waiters = idleWaiters
        idleWaiters = []
        for waiter in waiters { waiter() }
    }

    /// `whenIdle`: returns once no operation holds the write slot: at once if none does, otherwise when the running
    /// one has finished (it has sent its last event by then).
    public func whenIdle() async {
        if slotHolder == nil { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            idleWaiters.append { continuation.resume() }
        }
    }

    /// `getActiveOperation`: the operation holding the slot. A rename or new folder still being checked has changed
    /// nothing yet: it isn't one.
    public var activeOperation: ActiveWriteOperation? {
        guard let operationId = slotHolder, operationId != Self.preparingOperationId else { return nil }
        if operationId == emptyTrashOperationId {
            return ActiveWriteOperation(operationId: operationId, kind: .emptyTrash)
        }
        if let action = localActions[operationId] {
            return ActiveWriteOperation(operationId: operationId, kind: WriteOperationKind(action))
        }
        return ActiveWriteOperation(
            operationId: operationId, kind: copyPasteModes[operationId] == .cut ? .move : .copy)
    }

    /// Whether an operation holds the slot (`getActiveOperation() !== null`), from any thread: the recovery retry
    /// waits while one does.
    nonisolated public var isBusy: Bool {
        guard let holder = slotHolder else { return false }
        return holder != Self.preparingOperationId
    }

    /// `prepareWithReservedSlot`: claims the write slot before async preparation so a second request arriving
    /// meanwhile is refused instead of running alongside this one.
    public func prepareWithReservedSlot<T>(_ prepare: () async throws -> T) async throws -> T {
        try claimSlot(Self.preparingOperationId)
        do {
            let value = try await prepare()
            freeWriteSlot(Self.preparingOperationId)
            return value
        } catch {
            freeWriteSlot(Self.preparingOperationId)
            throw error
        }
    }

    /// `runWriteAlone`: runs a write that isn't one of the person's operations (finishing a Replace a crash cut
    /// short) only when the slot is free, holding it meanwhile, so the two never write at the same time. When the
    /// slot is taken, or the app is quitting, it doesn't run at all (nil). `write` runs on the calling thread, which
    /// may be any.
    nonisolated public func runWriteAlone<T>(_ write: () throws -> T) rethrows -> T? {
        let claimed = slot.withLock { slot -> Bool in
            if slot.closing || slot.active != nil { return false }
            slot.active = Self.preparingOperationId
            return true
        }
        guard claimed else { return nil }
        defer { freeSlotFromAnyThread(Self.preparingOperationId) }
        return try write()
    }

    /// `runWriteAlone` as the journal recovery takes it.
    nonisolated public var runWriteAloneForRecovery: RunWriteAlone {
        { [weak self] write in self?.runWriteAlone(write) != nil }
    }

    // MARK: Caches and Undo

    /// `forgetCachedResponses`: forgetting reads nothing from disk, but it tells the folder sizes, and a mistake there
    /// must never keep the write slot from being freed or the end from being sent.
    func forgetCachedResponses(_ changedPaths: [String], _ removedItems: [RemovedItem] = []) {
        do {
            try options.caches.forget(changedPaths, removedItems)
        } catch {
            options.logError("[filetrail] couldn't forget what an operation changed", error)
        }
    }

    /// `recordFinishedWrite`: a mistake in keeping the history must never keep the write slot from being freed.
    func recordFinishedWrite(_ finished: FinishedWrite) {
        do {
            try options.recordUndo?(finished)
        } catch {
            options.logError("[filetrail] couldn't record an operation for Undo", error)
        }
    }

    /// `pasteUndoLog`: a paste's own log, except that copies onto a disk without a Trash can't be undone.
    func pasteUndoLog(_ event: CopyPasteProgressEvent) -> UndoLog? {
        guard let log = event.result?.undoLog else { return nil }
        guard case .undoable(let units) = log else { return log }
        if units.isEmpty { return nil }
        // Asked once per folder: each answer reads the mount table, and a paste's copies are all in one folder or
        // a few.
        var answers: [String: Bool] = [:]
        func hasTrash(_ folder: String) -> Bool {
            if let known = answers[folder] { return known }
            let answer = canBeTrashed(in: folder)
            answers[folder] = answer
            return answer
        }
        let copiedOntoDiskWithoutTrash = units.contains { unit in
            unit.steps.contains { step in
                if case .created(let path, _, _) = step { return !hasTrash(NodePath.dirname(path)) }
                return false
            }
        }
        return copiedOntoDiskWithoutTrash ? .notUndoable(reason: .noTrash) : log
    }

    /// `canBeTrashedIn`: not knowing (the mount table couldn't be read) counts as no.
    public func canBeTrashed(in folder: String) -> Bool {
        do {
            return try options.diskHasTrash?(folder) ?? true
        } catch {
            options.logError("[filetrail] couldn't tell whether a disk has a Trash", error)
            return false
        }
    }

    // MARK: The write service's events

    private func writeServiceEvent(_ event: CopyPasteProgressEvent) {
        let operationId = event.operationId
        let action = copyPasteRequests[operationId]?.action ?? .paste
        copyPasteModes[operationId] = event.mode
        if event.status.isTerminal {
            copyPasteRequests[operationId] = nil
            copyPasteModes[operationId] = nil
            // Folder listings read before the operation finished may show the old contents.
            let changed =
                event.result.map { result in
                    WriteEffects.pathsChangedByWrite(
                        destinationDirectoryPath: result.destinationDirectoryPath,
                        items: result.items.map { ($0.sourcePath, $0.destinationPath) },
                        trashedPaths: result.trashedPaths ?? [])
                } ?? []
            forgetCachedResponses(changed)
            options.caches.writeEnded()
            if let undoLog = pasteUndoLog(event) {
                recordFinishedWrite(
                    FinishedWrite(
                        action: .write(action), log: undoLog,
                        items: event.result?.items.map(WriteOperationItem.init) ?? []))
            }
            // Nothing above may keep the slot held, or the end from the window.
            freeWriteSlot(operationId)
        }
        guard let sender = senders[operationId] else {
            eventsBeforeStart?[operationId] = event
            forgetProgress(operationId)
            return
        }
        let progress = deliverableProgressEvent(event, action: action)
        deliverProgress(operationId, status: event.status, asksUser: event.runtimeConflict != nil) { [weak self] in
            self?.sendProgress(sender, progress)
        }
        if event.status.isTerminal {
            detachSender(operationId)
        }
    }

    /// `toDeliverableProgressEvent`: the window's view of an event, even when part of it can't be sent. A question
    /// the window would never see is answered "skip", which changes nothing; the end of the operation always goes out.
    func deliverableProgressEvent(_ event: CopyPasteProgressEvent, action: WriteOperationAction)
        -> WriteOperationEvent
    {
        do {
            return try WriteOperationEvent.of(event, action: action)
        } catch {
            options.logError("[filetrail] couldn't send an operation update to the window", error)
            if event.status == .awaitingResolution, let conflict = event.runtimeConflict {
                _ = writeService.resolveRuntimeConflict(
                    event.operationId, conflictId: conflict.conflictId, action: .skip, applyToRemaining: false)
            }
            var stripped = event
            stripped.status = event.status == .awaitingResolution ? .running : event.status
            stripped.runtimeConflict = nil
            stripped.result = nil
            return (try? WriteOperationEvent.of(stripped, action: action))
                ?? WriteOperationEvent(operationId: event.operationId, action: action, status: stripped.status)
        }
    }

    // MARK: Copy analyses

    /// `copyPaste:analyzeStart`: starts reviewing a paste for `window`. The window's earlier analysis goes: only
    /// the newest can be pasted from.
    public func startAnalysis(_ request: CopyPasteAnalysisRequest, window: any WriteOperationWindow) async throws
        -> CopyPasteAnalysisStartHandle
    {
        try WriteGuards.assertNotIntoTrash(request.destinationDirectoryPath, verb: "pasted into", homePath: homePath)
        if request.mode == .cut {
            try WriteGuards.assertNotProtectedPath(request.sourcePaths, homePath: homePath)
            // Moving to another disk copies, then deletes the originals: as final as deleting.
            try await assertNotSystemLocation(request.sourcePaths, verb: "moved")
        }
        try ensureNoWriteOperationInFlight()
        let handle = try writeService.startCopyPasteAnalysis(request, keep: analysesOfOtherWindows(window))
        for (analysisId, owner) in analysisOwners where owner === window {
            forgetAnalysis(analysisId)
        }
        watchAnalysisOwner(handle.analysisId, window)
        return handle
    }

    /// `copyPaste:analyzeGetUpdate`: the analysis as the window is sent it, its report trimmed.
    public func analysisUpdate(_ analysisId: String, window: any WriteOperationWindow) throws
        -> CopyPasteAnalysisUpdate
    {
        try assertAnalysisOwner(analysisId, window)
        var update = try writeService.getCopyPasteAnalysisUpdate(analysisId)
        update.report = update.report.map(WriteGuards.trimAnalysisReportForWindow)
        return update
    }

    /// `copyPaste:analyzeCancel`; false for an analysis another window started.
    @discardableResult
    public func cancelAnalysis(_ analysisId: String, window: any WriteOperationWindow) -> Bool {
        analysisOwners[analysisId] === window ? writeService.cancelCopyPasteAnalysis(analysisId) : false
    }

    /// `copyPaste:start`: pastes from an analysis `window` started.
    @discardableResult
    public func startCopyPaste(_ start: CopyPasteStart, window: any WriteOperationWindow) throws
        -> CopyPasteOperationHandle
    {
        try ensureNoWriteOperationInFlight()
        try assertAnalysisOwner(start.analysisId, window)
        // The write service can finish an operation before startCopyPaste returns (an analysis that is no longer
        // usable fails at once). Its end is caught here, so the write slot isn't claimed for an operation that is
        // already over. The slot is held meanwhile, so a write alone can't start in between.
        options.caches.writeStarting()
        try claimSlot(Self.preparingOperationId)
        eventsBeforeStart = [:]
        let handle: CopyPasteOperationHandle
        let early: CopyPasteProgressEvent?
        do {
            handle = try writeService.startCopyPaste(
                CopyPasteExecutionRequest(analysisId: start.analysisId, policy: start.policy, overrides: start.overrides),
                keep: analysesOfOtherWindows(window))
            early = eventsBeforeStart?[handle.operationId]
            eventsBeforeStart = nil
        } catch {
            eventsBeforeStart = nil
            freeWriteSlot(Self.preparingOperationId)
            // Nothing started, so no end will come to stop noting the folder sizes stored.
            options.caches.writeEnded()
            throw error
        }
        // The paste has it now; the window going away stops the paste instead.
        forgetAnalysis(start.analysisId)
        if let early, early.status.isTerminal {
            freeWriteSlot(Self.preparingOperationId)
            // The window learns the operation id from this reply, so its end is sent just after it.
            let progress = deliverableProgressEvent(early, action: start.action)
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.sendProgress(window, progress) }
            }
            return handle
        }
        slot.withLock { slot in
            if slot.active == Self.preparingOperationId { slot.active = handle.operationId }
        }
        copyPasteRequests[handle.operationId] = start
        attachSender(handle.operationId, window)
        // Its "queued" came before it had a window. The window that started it knows from this reply; the others are
        // told now, so they know one runs, and it is kept for a window that takes it over.
        if let early {
            let progress = deliverableProgressEvent(early, action: start.action)
            latestProgress[handle.operationId] = progress
            broadcast(progress, owner: window)
        }
        return handle
    }

    /// `copyPaste:resolveConflict`: answers the question a paste waits on; only from the operation's own window.
    @discardableResult
    public func resolveConflict(
        _ operationId: String, conflictId: String, resolution: CopyPasteChoice, applyToRemaining: Bool = false,
        window: any WriteOperationWindow
    ) -> Bool {
        guard isOperationOwner(operationId, window) else { return false }
        let answered = writeService.resolveRuntimeConflict(
            operationId, conflictId: conflictId, action: resolution, applyToRemaining: applyToRemaining)
        // The question is answered: a window taking the operation over before its next update must not be shown it
        // again.
        if answered, var latest = latestProgress[operationId], latest.runtimeConflict != nil {
            latest.status = .running
            latest.runtimeConflict = nil
            latestProgress[operationId] = latest
        }
        return answered
    }

    /// `copyPaste:cancel` and `writeOperation:cancel`: only from the operation's own window.
    @discardableResult
    public func cancel(_ operationId: String, window: any WriteOperationWindow) -> Bool {
        isOperationOwner(operationId, window) ? cancelWriteOperation(operationId) : false
    }

    /// `writeOperation:getActive`: a window that missed the end of another window's operation asks before it refuses
    /// to start one.
    public var activeOperationId: String? { activeOperation?.operationId }

    func cancelWriteOperation(_ operationId: String) -> Bool {
        if let stop = localStops[operationId] {
            stop.stop()
            return true
        }
        return writeService.cancelOperation(operationId)
    }

    /// `assertNotSystemLocation`, with the disk read off the main actor.
    public func assertNotSystemLocation(_ paths: [String], verb: String) async throws {
        let fileSystem = fileSystem
        let homePath = homePath
        try await Task.detached {
            try WriteGuards.assertNotSystemLocation(paths, verb: verb, fileSystem: fileSystem, homePath: homePath)
        }.value
    }

    // MARK: Empty Trash

    /// `emptyTrash`: emptying the Trash while a paste is replacing items would delete the replaced items for good as
    /// they arrive there, so it waits its turn like any other write. It holds the write slot as an operation of its
    /// own, which the other windows and quitting see.
    public func emptyTrash(_ empty: () async -> (ok: Bool, error: String?)) async -> (ok: Bool, error: String?) {
        let operationId = "write-op-\(localSequence + 1)"
        do {
            try claimSlot(operationId)
        } catch {
            return (
                false,
                closing
                    ? "File Trail is quitting."
                    : "The Trash can't be emptied while another operation is running. Try again when it has finished."
            )
        }
        localSequence += 1
        emptyTrashOperationId = operationId
        options.caches.writeStarting()
        let outcome = await empty()
        // Whatever it managed to empty is gone for good, even when it then failed: Undo can't put back what was in the
        // Trash. Only a refusal before Finder began leaves the history as it was.
        if outcome.ok || !Self.trashLeftAsItWas(outcome.error) {
            recordFinishedWrite(
                FinishedWrite(action: .emptyTrash, log: .notUndoable(reason: .deletedForGood), items: []))
        }
        // The Trash's listing (and anything shown from it) is out of date now.
        forgetCachedResponses([NodePath.join(NodePath.resolve(homePath), ".Trash")])
        options.caches.writeEnded()
        emptyTrashOperationId = nil
        freeWriteSlot(operationId)
        options.onTrashEmptied?()
        return outcome
    }

    /// `trashLeftAsItWas`: Finder said no before it began, so nothing was emptied: macOS doesn't let File Trail
    /// control it (-1743, or -1744 when it would first have to ask the person), or it isn't running (-600).
    public nonisolated static func trashLeftAsItWas(_ error: String?) -> Bool {
        guard let error else { return false }
        return ["(-1743)", "(-1744)", "(-600)"].contains { error.contains($0) }
    }

    // MARK: Quitting

    /// `shutdown`: stops the running operation, if any, and waits until it has finished (up to `maxWaitMs`): an
    /// operation stops after the item it is on and removes any partly copied file. No new operation can start
    /// afterwards. Finder empties the Trash and goes on after File Trail quits: there is nothing to stop or wait for.
    public func shutDown(maxWaitMs: Double = WriteCoordinator.shutdownWaitLimitMs) async {
        slot.withLock { $0.closing = true }
        // The operation is being stopped anyway; a window closing now has nothing to add. Its final event is still
        // sent to the window if it is open.
        watchedOperations.removeAll()
        let operationId = slotHolder
        let emptyingTrash = operationId != nil && operationId == emptyTrashOperationId
        if let operationId, operationId != Self.preparingOperationId, !emptyingTrash {
            _ = cancelWriteOperation(operationId)
        }
        // A stopped copy ends within moments; only a disk that stops answering (a network share gone away) could hold
        // quitting up, and then it goes ahead anyway.
        if !emptyingTrash, await idleOrTimedOut(maxWaitMs) {
            options.logError("[filetrail] quitting without waiting longer for an operation to stop (\(operationId ?? ""))", nil)
        }
        unsubscribe?()
        unsubscribe = nil
        for progressOperationId in Array(throttles.keys) {
            forgetProgress(progressOperationId)
        }
        senders.removeAll()
        copyPasteRequests.removeAll()
        copyPasteModes.removeAll()
        for analysisId in Array(analysisOwners.keys) {
            forgetAnalysis(analysisId)
        }
        localStops.removeAll()
        localActions.removeAll()
    }

    /// Waits for the slot to be free; true when `milliseconds` went by first.
    private func idleOrTimedOut(_ milliseconds: Double) async -> Bool {
        if slotHolder == nil { return false }
        final class Once {
            var done = false
            var cancelTimer: (() -> Void)?
        }
        let once = Once()
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            idleWaiters.append {
                guard !once.done else { return }
                once.done = true
                once.cancelTimer?()
                continuation.resume(returning: false)
            }
            once.cancelTimer = clock.schedule(milliseconds) {
                guard !once.done else { return }
                once.done = true
                continuation.resume(returning: true)
            }
        }
    }
}
