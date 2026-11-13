// Operations and reviews of pastes with several windows open. An operation belongs to the window that started it, and
// is handed on or cancelled when that window goes away; a review is stopped. A stand-in local operation runs through the rename's entry point. The
// no-Trash delete cases are in Tests/FTOperationsTests/LocalOperations/LocalOperationsCoordinatorTests.swift.
import Darwin
import FTFileSystem
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTOperations

/// A folder on a network disk that stopped answering: every look at an item waits until the test lets it go.
private struct StuckFileSystem: ReadOnlyWriteFileSystem {
    let release: DispatchSemaphore

    func lstat(_ path: String) throws -> WriteServiceStats {
        release.wait()
        release.signal()
        throw NativeError.errno(ENOENT, syscall: "lstat", path: path)
    }
    func stat(_ path: String) throws -> WriteServiceStats { try lstat(path) }
    func realpath(_ path: String) throws -> String { path }
    func readdir(_ path: String) throws -> [String] { [] }
    func readlink(_ path: String) throws -> String { throw NativeError.errno(EINVAL, syscall: "readlink", path: path) }
}

@MainActor
@Suite(.localOperationHang) struct WriteCoordinatorWindowsTests {
    // MARK: a paste starting

    // The write service says "queued" before startCopyPaste returns, when the paste has no window yet.
    @Test func tellsTheOtherWindowsItIsQueued() async throws {
        let service = StubWriteService()
        service.startCopyPasteImpl = { _ in
            service.emit(Coordinators.event(.queued))
            return CopyPasteOperationHandle(operationId: "copy-op-1", status: .queued)
        }
        var broadcasts: [(WriteOperationEvent, ObjectIdentifier)] = []
        let successor = TestWindow()
        let coordinator = WriteCoordinator(
            writeService: service, fileSystem: TestLocalFileSystem.stub(),
            options: WriteCoordinatorOptions(
                broadcastProgress: { broadcasts.append(($0, ObjectIdentifier($1))) }, successorOf: { _ in successor }))
        let owner = TestWindow()

        try await Coordinators.startPaste(coordinator, owner)

        let queued = try #require(broadcasts.first)
        #expect(queued.0.operationId == "copy-op-1" && queued.0.status == .queued && queued.0.action == .paste)
        #expect(queued.1 == ObjectIdentifier(owner))
        // The window that started it knows from the reply.
        #expect(owner.progress.isEmpty)
        // A window taking it over before anything else is heard knows it is queued.
        owner.isClosed = true
        coordinator.windowClosed(owner)
        #expect(successor.adoptions.first?.operationId == "copy-op-1")
        #expect(successor.adoptions.first?.event?.status == .queued)
        #expect(successor.adoptions.first?.clearsCutClipboard == nil)
        service.emit(Coordinators.event(.cancelled))
        await coordinator.shutDown(maxWaitMs: 0)
    }

    // MARK: a paste ending

    // The window follows what a paste after Cut moved, as it follows a Move To.
    @Test func tellsTheWindowWhetherItCopiedOrMovedTheItems() async throws {
        let service = StubWriteService()
        let coordinator = WriteCoordinator(writeService: service, fileSystem: TestLocalFileSystem.stub())
        let window = TestWindow()
        try await Coordinators.startPaste(coordinator, window)

        service.emit(Coordinators.copied(.cut))

        let result = try #require(try await Coordinators.end(of: "copy-op-1", in: window).result)
        #expect(result.action == .paste)
        #expect(result.mode == .cut)
        await coordinator.shutDown(maxWaitMs: 0)
    }

    // MARK: the other windows

    // A paste of a large folder lists every file in it: each other window used to be sent them all.
    @Test func areToldOfTheItemsAPasteWorkedOnButNotOfEveryItemInsideThem() async throws {
        let service = StubWriteService()
        var broadcasts: [WriteOperationEvent] = []
        let coordinator = WriteCoordinator(
            writeService: service, fileSystem: TestLocalFileSystem.stub(),
            options: WriteCoordinatorOptions(broadcastProgress: { event, _ in broadcasts.append(event) }))
        let owner = TestWindow()
        try await Coordinators.startPaste(coordinator, owner)
        func item(_ path: String, _ kind: CopyPasteNodeKind) -> CopyPasteItemResult {
            CopyPasteItemResult(
                sourcePath: "/Users/demo/\(path)", destinationPath: "/Users/demo/b/\(path)", sourceKind: kind,
                status: .completed, error: nil)
        }
        let items = [item("Folder", .directory)] + ["a", "b", "c"].map { item("Folder/\($0).txt", .file) }

        service.emit(Coordinators.event(.completed, items: items, destination: "/Users/demo/b"))

        let ownView = items.map(WriteOperationItem.init)
        #expect(try await Coordinators.end(of: "copy-op-1", in: owner).result?.items == ownView)
        let toOthers = try #require(broadcasts.first { $0.status == .completed }?.result)
        // The folder, and one item in it, so the folder is seen to hold what changed.
        #expect(toOthers.targetPath == "/Users/demo/b")
        #expect(toOthers.items == Array(ownView.prefix(2)))
        await coordinator.shutDown(maxWaitMs: 0)
    }

    // MARK: a window taking over an operation

    @Test func isToldTheCutAPasteClearsFromTheClipboardWhenItIsDone() async throws {
        let service = StubWriteService()
        let successor = TestWindow()
        let coordinator = WriteCoordinator(
            writeService: service, fileSystem: TestLocalFileSystem.stub(),
            options: WriteCoordinatorOptions(successorOf: { _ in successor }))
        let owner = TestWindow()
        try await Coordinators.startPaste(coordinator, owner, clearsCutClipboard: "2026-10-07T10:00:00.000Z")

        coordinator.windowClosed(owner)

        #expect(
            successor.adoptions == [
                WriteOperationAdoption(
                    operationId: "copy-op-1", event: nil, clearsCutClipboard: "2026-10-07T10:00:00.000Z")
            ])
        service.emit(Coordinators.event(.cancelled))
        await coordinator.shutDown(maxWaitMs: 0)
    }

    @Test func isntShownAQuestionTheWindowThatClosedAlreadyAnswered() async throws {
        let service = StubWriteService()
        let successor = TestWindow()
        let coordinator = WriteCoordinator(
            writeService: service, fileSystem: TestLocalFileSystem.stub(),
            options: WriteCoordinatorOptions(successorOf: { _ in successor }))
        let owner = TestWindow()
        try await Coordinators.startPaste(coordinator, owner)
        service.emit(Coordinators.event(.awaitingResolution, runtimeConflict: Coordinators.conflict("conflict-1")))

        #expect(coordinator.resolveConflict("copy-op-1", conflictId: "conflict-1", resolution: .skip, window: owner))
        // The engine hasn't said anything since when the window closes.
        coordinator.windowClosed(owner)

        let event = try #require(successor.adoptions.first?.event)
        #expect(event.status == .running)
        #expect(event.runtimeConflict == nil)
        service.emit(Coordinators.event(.cancelled))
        await coordinator.shutDown(maxWaitMs: 0)
    }

    @Test func isStillShownAQuestionThatWasntAnswered() async throws {
        let service = StubWriteService()
        service.resolveAnswer = false
        let successor = TestWindow()
        let coordinator = WriteCoordinator(
            writeService: service, fileSystem: TestLocalFileSystem.stub(),
            options: WriteCoordinatorOptions(successorOf: { _ in successor }))
        let owner = TestWindow()
        try await Coordinators.startPaste(coordinator, owner)
        service.emit(Coordinators.event(.awaitingResolution, runtimeConflict: Coordinators.conflict("conflict-1")))

        // An answer the write service refused (a question asked since) leaves it open.
        coordinator.resolveConflict("copy-op-1", conflictId: "conflict-old", resolution: .skip, window: owner)
        coordinator.windowClosed(owner)

        let event = try #require(successor.adoptions.first?.event)
        #expect(event.status == .awaitingResolution)
        #expect(event.runtimeConflict?.conflictId == "conflict-1")
        service.emit(Coordinators.event(.cancelled))
        await coordinator.shutDown(maxWaitMs: 0)
    }

    // MARK: a window asking for the operation handed to it

    // A window opened just before the one running an operation closed may miss the message that hands it over. It
    // asks once it listens.
    private func handedOver(clearsCutClipboard: String? = nil) async throws
        -> (WriteCoordinator, StubWriteService, TestWindow, TestWindow)
    {
        let service = StubWriteService()
        let successor = TestWindow()
        let coordinator = WriteCoordinator(
            writeService: service, fileSystem: TestLocalFileSystem.stub(),
            options: WriteCoordinatorOptions(successorOf: { _ in successor }))
        let owner = TestWindow()
        try await Coordinators.startPaste(coordinator, owner, clearsCutClipboard: clearsCutClipboard)
        return (coordinator, service, owner, successor)
    }

    @Test func isToldItWithTheQuestionItWaitsOnOnce() async throws {
        let (coordinator, service, owner, successor) = try await handedOver(
            clearsCutClipboard: "2026-10-08T10:00:00.000Z")
        service.emit(Coordinators.event(.awaitingResolution, runtimeConflict: Coordinators.conflict("conflict-1")))
        coordinator.windowClosed(owner)

        let adoption = try #require(coordinator.adoptedOperation(window: successor))
        #expect(adoption.operationId == "copy-op-1")
        #expect(adoption.event?.status == .awaitingResolution)
        #expect(adoption.event?.runtimeConflict?.conflictId == "conflict-1")
        #expect(adoption.clearsCutClipboard == "2026-10-08T10:00:00.000Z")
        #expect(coordinator.adoptedOperation(window: successor) == nil)
        // It is the operation's window now: it answers the question.
        #expect(
            coordinator.resolveConflict("copy-op-1", conflictId: "conflict-1", resolution: .skip, window: successor))
        service.emit(Coordinators.event(.cancelled))
        await coordinator.shutDown(maxWaitMs: 0)
    }

    @Test func isToldHowItEndedWhenItEndedBeforeTheWindowAsked() async throws {
        let (coordinator, service, owner, successor) = try await handedOver()
        coordinator.windowClosed(owner)
        service.emit(Coordinators.copied())

        #expect(coordinator.activeOperation == nil)
        let adoption = try #require(coordinator.adoptedOperation(window: successor))
        #expect(adoption.operationId == "copy-op-1")
        #expect(adoption.event?.status == .completed)
        #expect(adoption.event?.result?.status == .completed)
        #expect(adoption.clearsCutClipboard == nil)
        await coordinator.shutDown(maxWaitMs: 0)
    }

    @Test func isToldNothingWhenNothingWasHandedToItOrItWasHandedOnAgain() async throws {
        let service = StubWriteService()
        let second = TestWindow()
        let third = TestWindow()
        var successor = second
        let coordinator = WriteCoordinator(
            writeService: service, fileSystem: TestLocalFileSystem.stub(),
            options: WriteCoordinatorOptions(successorOf: { _ in successor }))
        let owner = TestWindow()
        try await Coordinators.startPaste(coordinator, owner)
        #expect(coordinator.adoptedOperation(window: second) == nil)

        coordinator.windowClosed(owner)
        successor = third
        coordinator.windowClosed(second)

        #expect(coordinator.adoptedOperation(window: second) == nil)
        #expect(
            coordinator.adoptedOperation(window: third) == WriteOperationAdoption(operationId: "copy-op-1", event: nil))
        service.emit(Coordinators.event(.cancelled))
        await coordinator.shutDown(maxWaitMs: 0)
    }

    // MARK: telling every window

    // A window that missed the end of another window's operation asks.
    @Test func saysWhichOperationRunsIfAny() async throws {
        let service = StubWriteService()
        let coordinator = WriteCoordinator(writeService: service, fileSystem: TestLocalFileSystem.stub())
        let window = TestWindow()
        #expect(coordinator.activeOperationId == nil)

        try await Coordinators.startPaste(coordinator, window)
        #expect(coordinator.activeOperationId == "copy-op-1")

        service.emit(Coordinators.event(.cancelled))
        #expect(coordinator.activeOperationId == nil)
        await coordinator.shutDown(maxWaitMs: 0)
    }

    // MARK: reviews of pastes and their windows

    @Test func stopsAReviewWhenItsWindowCloses() async throws {
        let service = StubWriteService()
        service.holdsReviews = true
        let coordinator = WriteCoordinator(writeService: service, fileSystem: TestLocalFileSystem.stub())
        let window = TestWindow()
        let signal = StopSignal()
        let review = Task { try await Coordinators.analyze(coordinator, window, signal: signal) }
        _ = try await Coordinators.waitFor { service.calls.analyze.isEmpty ? nil : true }
        #expect(coordinator.watchCount(window) == 1)

        window.isClosed = true
        coordinator.windowClosed(window)

        #expect(signal.isStopped)
        #expect(coordinator.watchCount(window) == 0)
        await #expect(throws: StopError.self) { try await review.value }
        await coordinator.shutDown(maxWaitMs: 0)
    }

    @Test func stopsAReviewWhenTheAppQuits() async throws {
        let service = StubWriteService()
        service.holdsReviews = true
        let coordinator = WriteCoordinator(writeService: service, fileSystem: TestLocalFileSystem.stub())
        let window = TestWindow()
        let signal = StopSignal()
        let review = Task { try await Coordinators.analyze(coordinator, window, signal: signal) }
        _ = try await Coordinators.waitFor { service.calls.analyze.isEmpty ? nil : true }

        await coordinator.shutDown(maxWaitMs: 0)

        #expect(signal.isStopped)
        await #expect(throws: StopError.self) { try await review.value }
        await #expect(throws: WriteCoordinatorError.quitting) { try await Coordinators.analyze(coordinator, window) }
    }

    // Only one review runs at a time, in any window. Closing the window of one held by a disk that doesn't answer
    // ends it at once, and lets another window set up a copy.
    @Test func letsAnotherWindowSetUpACopyOnceTheWindowOfAStuckReviewCloses() async throws {
        try await withTemporaryDirectory(prefix: "filetrail-windows") { root in
            let release = DispatchSemaphore(value: 0)
            defer { release.signal() }
            let coordinator = WriteCoordinator(
                writeService: WriteService(WriteServiceDependencies(fileSystem: StuckFileSystem(release: release))),
                fileSystem: TestLocalFileSystem.stub())
            let first = TestWindow()
            let second = TestWindow()
            let source = root.appending("a.txt").path
            let firstReview = Task {
                try await Coordinators.analyze(coordinator, first, sources: [source], destination: root.path)
            }
            _ = try await Coordinators.waitFor { coordinator.watchCount(first) == 1 ? true : nil }
            let busy = await #expect(throws: WriteCoordinatorError.self) {
                try await Coordinators.analyze(coordinator, second, sources: [source], destination: root.path)
            }
            #expect(
                busy?.message
                    == "Another window is checking items to copy or move. Try again when it has finished.")

            coordinator.windowClosed(first)

            await #expect(throws: StopError.self) { try await firstReview.value }
            let secondReview = Task {
                try await Coordinators.analyze(coordinator, second, sources: [source], destination: root.path)
            }
            _ = try await Coordinators.waitFor { coordinator.watchCount(second) == 1 ? true : nil }
            coordinator.windowClosed(second)
            await #expect(throws: StopError.self) { try await secondReview.value }
            await coordinator.shutDown(maxWaitMs: 0)
        }
    }

    // No review starts while a write runs, from any window: a paste, or a write still being checked.
    @Test func refusesAReviewWhileAWriteRuns() async throws {
        let service = StubWriteService()
        let coordinator = WriteCoordinator(writeService: service, fileSystem: TestLocalFileSystem.stub())
        let pasting = TestWindow()
        try await Coordinators.startPaste(coordinator, pasting)

        for window in [pasting, TestWindow()] {
            await #expect(throws: WriteCoordinatorError.busy) { try await Coordinators.analyze(coordinator, window) }
        }
        service.emit(Coordinators.event(.completed))
        _ = try await Coordinators.waitFor { coordinator.activeOperation == nil ? true : nil }
        let gate = TestGate()
        let checking = Task { try await coordinator.prepareWithReservedSlot({ await gate.wait() }, then: { _, _ in }) }
        _ = try await Coordinators.waitFor { gate.waiting ? true : nil }

        await #expect(throws: WriteCoordinatorError.busy) { try await Coordinators.analyze(coordinator, TestWindow()) }
        #expect(service.calls.analyze.count == 1)
        gate.open()
        try await checking.value
        try await Coordinators.analyze(coordinator, TestWindow())
        await coordinator.shutDown(maxWaitMs: 0)
    }

    // A review that ended leaves nothing listening for its window; the paste from its report listens for itself.
    @Test func listensToAWindowOnlyWhileItsReviewOrItsPasteRuns() async throws {
        let service = StubWriteService()
        let coordinator = WriteCoordinator(writeService: service, fileSystem: TestLocalFileSystem.stub())
        let window = TestWindow()

        let report = try await Coordinators.analyze(coordinator, window)
        #expect(coordinator.watchCount(window) == 0)

        try coordinator.startCopyPaste(CopyPasteStart(report: report, policy: Coordinators.skipMerge), window: window)
        #expect(coordinator.watchCount(window) == 1)
        service.emit(Coordinators.event(.cancelled))
        #expect(coordinator.watchCount(window) == 0)
        await coordinator.shutDown(maxWaitMs: 0)
    }

    @Test func keepsAWindowsFinishedReviewWhenAnotherWindowSetsUpACopy() async throws {
        try await withTemporaryDirectory(prefix: "filetrail-windows") { root in
            let manager = FileManager.default
            for folder in ["src", "one", "two"] {
                try manager.createDirectory(at: root.appending(folder), withIntermediateDirectories: false)
            }
            let source = root.appending("src/a.txt").path
            try Data("a".utf8).write(to: URL(fileURLWithPath: source))
            let coordinator = WriteCoordinator(
                writeService: WriteService(WriteServiceDependencies(fileSystem: NativeWriteFileSystem())),
                fileSystem: TestLocalFileSystem.stub())
            let first = TestWindow()
            let second = TestWindow()
            @MainActor func paste(_ window: TestWindow, _ report: CopyPasteAnalysisReport) throws
                -> CopyPasteOperationHandle
            {
                try coordinator.startCopyPaste(
                    CopyPasteStart(report: report, policy: Coordinators.skipMerge), window: window)
            }
            let firstReport = try await Coordinators.analyze(
                coordinator, first, sources: [source], destination: root.appending("one").path)

            // The second window sets up its copy, and pastes, while the first one's review is open.
            let secondReport = try await Coordinators.analyze(
                coordinator, second, sources: [source], destination: root.appending("two").path)
            let secondPaste = try paste(second, secondReport)
            #expect(try await Coordinators.end(of: secondPaste.operationId, in: second).status == .completed)
            _ = try await Coordinators.waitFor { coordinator.activeOperation == nil ? true : nil }

            // The first window's review can still be pasted from.
            let firstPaste = try paste(first, firstReport)
            #expect(try await Coordinators.end(of: firstPaste.operationId, in: first).status == .completed)
            #expect(try String(contentsOfFile: root.appending("one/a.txt").path, encoding: .utf8) == "a")
            #expect(try String(contentsOfFile: root.appending("two/a.txt").path, encoding: .utf8) == "a")
            await coordinator.shutDown(maxWaitMs: 0)
        }
    }

    // MARK: an operation that stops unexpectedly

    // Every window refuses to start an operation while one runs, until it hears the end.
    @Test func tellsEveryWindowItFailedWhenItStoppedWithoutSayingSo() async throws {
        let log = LogRecorder()
        var broadcasts: [(WriteOperationEvent, ObjectIdentifier)] = []
        let coordinator = WriteCoordinator(
            writeService: StubWriteService(), fileSystem: TestLocalFileSystem.stub(),
            options: WriteCoordinatorOptions(
                broadcastProgress: { broadcasts.append(($0, ObjectIdentifier($1))) }, logError: log.log))
        let window = TestWindow()

        let handle = try coordinator.queueLocalWriteOperation(action: .newFolder, window: window) { _ in
            // Reading the new folder back goes wrong in a way nothing expects.
            throw OperationError("The disk went away.")
        }
        let end = try await Coordinators.end(of: handle.operationId, in: window)

        #expect(end.status == .failed)
        #expect(end.result?.error == "The operation stopped unexpectedly: The disk went away.")
        #expect(
            broadcasts.contains {
                $0.0.operationId == handle.operationId && $0.0.status == .failed && $0.1 == ObjectIdentifier(window)
            })
        #expect(coordinator.activeOperation == nil)
        await coordinator.shutDown(maxWaitMs: 0)
    }

    @Test func endsAPasteWhoseDiskCantBeToldToHaveATrashAndCantUndoIt() async throws {
        let service = StubWriteService()
        let log = LogRecorder()
        var broadcasts: [WriteOperationEvent] = []
        var finished: [FinishedWrite] = []
        let coordinator = WriteCoordinator(
            writeService: service, fileSystem: TestLocalFileSystem.stub(),
            options: WriteCoordinatorOptions(
                recordUndo: { finished.append($0) },
                // Reading the mount table goes wrong.
                diskHasTrash: { _ in throw OperationError("The mount table couldn't be read.") },
                broadcastProgress: { event, _ in broadcasts.append(event) }, logError: log.log))
        let window = TestWindow()
        try await Coordinators.startPaste(coordinator, window)

        service.emit(Coordinators.copied())

        #expect(try await Coordinators.end(of: "copy-op-1", in: window).status == .completed)
        #expect(broadcasts.contains { $0.operationId == "copy-op-1" && $0.status == .completed })
        #expect(coordinator.activeOperation == nil)
        // Whether its copy could go to the Trash isn't known, so it isn't offered to Undo.
        #expect(finished.map(\.log) == [.notUndoable(reason: .noTrash)])
        // The next operation can start.
        let gate = TestGate()
        gate.open()
        let next = try Coordinators.heldLocalOperation(coordinator, window, gate: gate)
        #expect(try await Coordinators.end(of: next.operationId, in: window).status == .completed)
        await coordinator.shutDown(maxWaitMs: 0)
    }

    // A paste the write service refuses to start never ends: the folder sizes stop noting what is stored, as they
    // would at its end.
    @Test func tellsTheFolderSizesAPasteThatCouldntStartIsOver() async throws {
        let service = StubWriteService()
        var starting = 0
        var ended = 0
        let coordinator = WriteCoordinator(
            writeService: service, fileSystem: TestLocalFileSystem.stub(),
            options: WriteCoordinatorOptions(
                caches: WriteCaches(writeStarting: { starting += 1 }, writeEnded: { ended += 1 })))
        let window = TestWindow()
        let report = try await Coordinators.analyze(coordinator, window)
        service.startCopyPasteImpl = { _ in throw OperationError("The analysis broke.") }

        let refused = #expect(throws: OperationError.self) {
            try coordinator.startCopyPaste(
                CopyPasteStart(report: report, policy: Coordinators.skipMerge), window: window)
        }
        #expect(refused?.message == "The analysis broke.")

        #expect(starting == 1)
        #expect(ended == 1)
        #expect(coordinator.activeOperation == nil)
        await coordinator.shutDown(maxWaitMs: 0)
    }

    @Test func sendsTheEndOfAnUndoWhenKeepingTheHistoryGoesWrong() async throws {
        try await withUndoFolder { root, trashDir in
            try UndoDisk.write("\(root)/a.txt", "a")
            let held = HeldCall()
            let t = UndoTest(root: root, trashDir: trashDir) { fileSystem in
                fileSystem.renameExclusiveImpl = { from, to in
                    if to == "\(root)/a.txt" { held.hold() }
                    try UndoDisk.move(from, to)
                }
            }
            try await t.rename("\(root)/a.txt", "b.txt")
            let prepared = try await t.prepare()
            let undo = try await t.coordinator.startUndo(ticket: prepared.ticket ?? "", window: t.window)
            _ = try await Coordinators.waitFor { held.hasBegun ? true : nil }
            // The history changes under the Undo: it can't be told what the Undo did.
            t.history.record(
                FinishedWrite(
                    action: .write(.newFolder),
                    log: .undoable(units: [UndoUnit(steps: [.created(path: "/elsewhere", id: nil, stamp: nil)])]),
                    items: []))
            held.release()
            #expect(try await t.finish(undo).status == .completed)
            #expect(try UndoDisk.read("\(root)/a.txt") == "a")
            #expect(t.coordinator.activeOperation == nil)
            #expect(t.log.messages.contains("[filetrail] couldn't record an Undo in the history"))
            await t.shutDown()
        }
    }

    @Test func refusesWhenADiskDoesntAnswerAndDoesNothingMoreForAPressMeanwhile() async throws {
        // A share that stops answering: ⌘Z is refused in time, and pressing it again while it looks does nothing
        // more.
        try await withUndoFolder { root, trashDir in
            try UndoDisk.write("\(root)/a.txt", "a")
            let hanging = UndoFlag()
            let gate = DiskGate()
            defer { gate.open() }
            let t = UndoTest(
                root: root, trashDir: trashDir,
                configure: { fileSystem in
                    let base = fileSystem.base
                    fileSystem.lstatImpl = { path in
                        if hanging.isSet && path.hasSuffix("b.txt") { gate.wait() }
                        return try base.lstat(path)
                    }
                }, undoCheckWithinMs: 50)
            try await t.rename("\(root)/a.txt", "b.txt")
            hanging.set(true)
            let coordinator = t.coordinator
            // The second press comes while the first still looks, in the same turn: the first starts here and
            // now, up to where it waits for the disk. Had the second waited for the disk call instead, the first could
            // give up (after its 50 ms) before the second came when the main actor or the disk thread was kept waiting
            // by other suites, and the second would then look again rather than do nothing.
            let first = Task.immediate { @MainActor in try await coordinator.prepareUndo(.undo) }
            let meanwhile = try await t.coordinator.prepareUndo(.undo)
            #expect(meanwhile.ticket == nil)
            #expect(meanwhile.refusal == .nothing)
            await #expect(
                throws: WriteCoordinatorError(
                    "A disk didn't answer while Undo looked at its items. Choose Undo again once it does.")
            ) {
                _ = try await first.value
            }
            hanging.set(false)
            let again = try await t.coordinator.prepareUndo(.undo)
            #expect(again.ticket != nil)
            #expect(again.refusal == nil)
            await t.shutDown()
        }
    }
}
