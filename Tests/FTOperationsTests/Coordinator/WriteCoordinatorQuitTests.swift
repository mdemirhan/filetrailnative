// It is in Tests/FTOperationsTests/LocalOperations/LocalOperationsCoordinatorTests.swift.
import FTFileSystem
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTOperations

@MainActor
@Suite struct WriteCoordinatorQuitTests {
    nonisolated private static func block(_ semaphore: DispatchSemaphore) {
        semaphore.wait()
    }

    // MARK: quitting during an operation

    @Test(.localOperationHang) func stopsARunningDeleteAndWaitsForItToFinishBeforeShutdownReturns() async throws {
        // Delete Immediately itself, held on its first item.
        let firstItem = HeldCall()
        let fileSystem = TestLocalFileSystem.stub()
        fileSystem.lstatImpl = { _ in Stats.file() }
        fileSystem.rmImpl = { path, _, _ in
            if path.hasSuffix("/a.txt") { firstItem.hold() }
        }
        let coordinator = WriteCoordinator.local(fileSystem, homePath: "/Users/demo")
        let window = TestWindow()
        try await coordinator.deleteImmediately(
            paths: ["/Users/demo/.Trash/a.txt", "/Users/demo/.Trash/b.txt"], window: window)
        await firstItem.begun()
        // Let go also when the test stops early, or the delete's thread waits for good.
        defer { firstItem.release() }
        #expect(coordinator.activeOperation == ActiveWriteOperation(operationId: "write-op-1", kind: .delete))

        var shutDown = false
        let shutdown = Task {
            await coordinator.shutDown()
            shutDown = true
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        // Still on the first item: quitting waits for it.
        #expect(!shutDown)
        // Nothing new starts while the app is quitting.
        #expect(throws: WriteCoordinatorError.quitting) {
            try Coordinators.heldLocalOperation(coordinator, window, gate: TestGate(), action: .trash)
        }

        firstItem.release()
        await shutdown.value

        // It stopped after the current item, and its end was sent before shutdown finished.
        #expect(fileSystem.calls.rm.map(\.0) == ["/Users/demo/.Trash/a.txt"])
        let terminal = try #require(window.end(of: "write-op-1"))
        #expect(terminal.status == .partial)
        // Every item it never reached is counted, not only the next one.
        #expect(terminal.result?.error == "Stopped after 1 item was deleted.")
        #expect(terminal.result?.summary.completedItemCount == 1)
        #expect(terminal.result?.summary.cancelledItemCount == 1)
        #expect(terminal.result?.summary.topLevelItemCount == 2)
        #expect(coordinator.activeOperation == nil)
    }

    // A disk that stops answering (a network share gone away) mustn't keep the app from quitting. The operation here
    // never stops by itself: a quit that waited for it is caught by the time limit, and one that waited its usual 15 s
    // instead of the 50 ms asked by the clock, which is loose enough for a busy Mac.
    @Test(.timeLimit(.minutes(1))) func stopsWaitingForAnOperationThatDoesntStop() async throws {
        let coordinator = WriteCoordinator(writeService: StubWriteService())
        let window = TestWindow()
        let never = TestGate()
        try Coordinators.heldLocalOperation(coordinator, window, gate: never, action: .deleteImmediately)
        _ = try await Coordinators.waitFor { never.waiting ? true : nil }

        let started = ContinuousClock.now
        await coordinator.shutDown(maxWaitMs: 50)
        #expect(ContinuousClock.now - started < .seconds(10))

        never.open()
    }

    @Test func cancelsARunningMoveAndWaitsForTheWriteServiceToSayItStopped() async throws {
        let service = StubWriteService()
        let coordinator = WriteCoordinator(writeService: service)
        let window = TestWindow()
        try await Coordinators.startPaste(coordinator, window)
        service.emit(Coordinators.event(.running, mode: .cut))
        #expect(coordinator.activeOperation == ActiveWriteOperation(operationId: "copy-op-1", kind: .move))

        var shutDown = false
        let shutdown = Task {
            await coordinator.shutDown()
            shutDown = true
        }
        _ = try await Coordinators.waitFor { service.calls.cancelOperation == ["copy-op-1"] ? true : nil }
        try await Task.sleep(nanoseconds: 10_000_000)
        #expect(!shutDown)

        service.emit(Coordinators.event(.cancelled))
        await shutdown.value
        #expect(shutDown)
        #expect(window.progress.last?.operationId == "copy-op-1")
        #expect(window.progress.last?.status == .cancelled)
    }

    @Test func namesACopyAsACopyAndHasNothingToWaitForWhenIdle() async throws {
        let service = StubWriteService()
        let coordinator = WriteCoordinator(writeService: service)
        #expect(coordinator.activeOperation == nil)
        await coordinator.whenIdle()

        try await Coordinators.startPaste(coordinator, TestWindow())
        service.emit(Coordinators.event(.running))
        #expect(coordinator.activeOperation == ActiveWriteOperation(operationId: "copy-op-1", kind: .copy))
        let idle = Task { await coordinator.whenIdle() }
        service.emit(Coordinators.event(.completed))
        await idle.value
        #expect(coordinator.activeOperation == nil)
        await coordinator.shutDown(maxWaitMs: 0)
    }

    // MARK: starting a paste

    @Test func doesntHoldTheWriteSlotForAPasteThatEndedBeforeItsStartReturned() async throws {
        try await withTemporaryDirectory(prefix: "filetrail-early-end") { root in
            try Data("a".utf8).write(to: root.appending("a.txt"))
            try FileManager.default.createDirectory(at: root.appending("target"), withIntermediateDirectories: false)
            let service = WriteService(WriteServiceDependencies(fileSystem: NativeWriteFileSystem()))
            let coordinator = WriteCoordinator(writeService: service)
            let window = TestWindow()
            let handle = try await Coordinators.analyze(
                coordinator, window, sources: [root.appending("a.txt").path], destination: root.appending("target").path
            )
            _ = try await Coordinators.waitFor {
                (try? coordinator.analysisUpdate(handle.analysisId, window: window)).flatMap { $0.done ? $0 : nil }
            }
            // The review was dismissed after the analysis finished, then pasted from anyway: the write service fails
            // such a paste.
            coordinator.cancelAnalysis(handle.analysisId, window: window)

            let started = try coordinator.startCopyPaste(
                CopyPasteStart(analysisId: handle.analysisId, policy: Coordinators.skipMerge), window: window)

            // The window still hears how it ended, after it has the operation's id.
            #expect(try await Coordinators.end(of: started.operationId, in: window).status == .failed)
            // And the next write is not refused with "Another write operation is already running."
            _ = try await Coordinators.waitFor { coordinator.activeOperation == nil ? true : nil }
            try await Coordinators.analyze(
                coordinator, window, sources: [root.appending("a.txt").path], destination: root.appending("target").path
            )
            await coordinator.shutDown(maxWaitMs: 0)
        }
    }

    // A write service that ends the paste inside startCopyPaste: the end is sent just after the start's reply.
    @Test func sendsTheEndOfAPasteThatEndedInsideItsStartAfterTheReply() async throws {
        let service = StubWriteService()
        service.startCopyPasteImpl = { _ in
            service.emit(Coordinators.event(.queued))
            service.emit(Coordinators.event(.cancelled))
            return CopyPasteOperationHandle(operationId: "copy-op-1", status: .queued)
        }
        let coordinator = WriteCoordinator(writeService: service)
        let window = TestWindow()

        try await Coordinators.startPaste(coordinator, window)
        #expect(window.progress.isEmpty)
        #expect(coordinator.activeOperation == nil)

        #expect(try await Coordinators.end(of: "copy-op-1", in: window).status == .cancelled)
        await coordinator.shutDown(maxWaitMs: 0)
    }

    @Test func onlyLetsTheWindowThatStartedAnAnalysisReadCancelOrPasteFromIt() async throws {
        let service = StubWriteService()
        let coordinator = WriteCoordinator(writeService: service)
        let owner = TestWindow()
        let otherWindow = TestWindow()
        try await Coordinators.analyze(coordinator, owner)

        #expect(throws: WriteCoordinatorError.analysisOfAnotherWindow) {
            try coordinator.analysisUpdate("analysis-1", window: otherWindow)
        }
        #expect(!coordinator.cancelAnalysis("analysis-1", window: otherWindow))
        #expect(throws: WriteCoordinatorError.analysisOfAnotherWindow) {
            try coordinator.startCopyPaste(
                CopyPasteStart(analysisId: "analysis-1", policy: Coordinators.skipMerge), window: otherWindow)
        }
        #expect(service.calls.getCopyPasteAnalysisUpdate.isEmpty)
        #expect(service.calls.cancelCopyPasteAnalysis.isEmpty)
        #expect(service.calls.startCopyPaste.isEmpty)

        #expect(coordinator.cancelAnalysis("analysis-1", window: owner))
        await coordinator.shutDown(maxWaitMs: 0)
    }

    // MARK: writing alone (crash recovery retries)

    @Test func doesntRunWhileAnOperationHoldsTheWriteSlot() async throws {
        let coordinator = WriteCoordinator(writeService: StubWriteService())
        let window = TestWindow()
        let gate = TestGate()
        try Coordinators.heldLocalOperation(coordinator, window, gate: gate, action: .deleteImmediately)
        var ran = 0

        #expect(coordinator.runWriteAlone { ran += 1 } == nil)
        #expect(ran == 0)

        gate.open()
        _ = try await Coordinators.end(of: "write-op-1", in: window)
        #expect(
            coordinator.runWriteAlone { () -> String in
                ran += 1
                return "done"
            } == "done")
        #expect(ran == 1)
        await coordinator.shutDown(maxWaitMs: 0)
    }

    @Test func doesntRunWhileARenameIsStillBeingChecked() async throws {
        let coordinator = WriteCoordinator(writeService: StubWriteService())
        let gate = TestGate()
        let checking = Task { try await coordinator.prepareWithReservedSlot({ await gate.wait() }, then: { _, _ in }) }
        _ = try await Coordinators.waitFor { gate.waiting ? true : nil }
        var ran = false

        #expect(coordinator.runWriteAlone { ran = true } == nil)
        #expect(!ran)
        // The recovery retry, which asks whether an operation runs, isn't held up by one being checked.
        #expect(!coordinator.isBusy)

        gate.open()
        try await checking.value
        await coordinator.shutDown(maxWaitMs: 0)
    }

    // Between an operation's check and its start the slot stays held: a write alone can't start in between and
    // leave the person's operation refused as busy. What the start queues takes the slot over.
    @Test func doesntRunBetweenAnOperationsCheckAndItsStart() async throws {
        let coordinator = WriteCoordinator(writeService: StubWriteService())
        let window = TestWindow()
        let gate = TestGate()
        var ranBefore: Bool?
        let handle = try await coordinator.prepareWithReservedSlot {
        } then: { _, reservation in
            ranBefore = coordinator.runWriteAlone {} != nil
            return try coordinator.queueLocalWriteOperation(action: .rename, window: window, reservation: reservation) {
                _ in await gate.wait()
            }
        }
        #expect(ranBefore == false)
        #expect(coordinator.activeOperation?.operationId == handle.operationId)
        #expect(coordinator.runWriteAlone {} == nil)
        gate.open()
        await coordinator.whenIdle()
        #expect(coordinator.runWriteAlone {} != nil)
        await coordinator.shutDown(maxWaitMs: 0)
    }

    // A check whose start throws, or queues nothing, frees the slot.
    @Test func aStartThatThrowsFreesTheSlot() async throws {
        let coordinator = WriteCoordinator(writeService: StubWriteService())
        await #expect(throws: WriteCoordinatorError.busy) {
            try await coordinator.prepareWithReservedSlot {
            } then: { _, _ in
                throw WriteCoordinatorError.busy
            }
        }
        #expect(coordinator.runWriteAlone {} != nil)
        try await coordinator.prepareWithReservedSlot({}, then: { _, _ in })
        #expect(coordinator.runWriteAlone {} != nil)
        await coordinator.shutDown(maxWaitMs: 0)
    }

    @Test func holdsTheWriteSlotWhileItRunsSoNoOperationStartsAlongside() async throws {
        let coordinator = WriteCoordinator(writeService: StubWriteService())
        let window = TestWindow()
        let writing = DispatchSemaphore(value: 0)
        let finish = DispatchSemaphore(value: 0)
        let alone = Task.detached { [coordinator] in
            coordinator.runWriteAlone {
                writing.signal()
                finish.wait()
            } != nil
        }
        await Task.detached { Self.block(writing) }.value

        #expect(throws: WriteCoordinatorError.busy) {
            try Coordinators.heldLocalOperation(coordinator, window, gate: TestGate(), action: .trash)
        }
        let emptied = await coordinator.emptyTrash { (true, nil) }
        #expect(!emptied.ok)

        finish.signal()
        #expect(await alone.value)
        // Free again once it is done.
        _ = try await Coordinators.waitFor { coordinator.slotHolder == nil ? true : nil }
        let gate = TestGate()
        #expect(try Coordinators.heldLocalOperation(coordinator, window, gate: gate, action: .trash).status == .queued)
        gate.open()
        await coordinator.shutDown(maxWaitMs: 0)
    }

    @Test func freesTheWriteSlotWhenTheWriteFails() async throws {
        let coordinator = WriteCoordinator(writeService: StubWriteService())

        #expect(throws: OperationError.self) {
            try coordinator.runWriteAlone { () throws -> Void in throw OperationError("EIO") }
        }
        #expect(coordinator.runWriteAlone { 1 } == 1)
        await coordinator.shutDown(maxWaitMs: 0)
    }

    @Test func doesntRunOnceTheAppIsQuitting() async throws {
        let coordinator = WriteCoordinator(writeService: StubWriteService())
        await coordinator.shutDown(maxWaitMs: 0)
        var ran = false

        #expect(coordinator.runWriteAlone { ran = true } == nil)
        #expect(!ran)
        #expect(!coordinator.runWriteAloneForRecovery { ran = true })
    }

    // MARK: questions during a paste

    @Test func passesOnAQuestionAboutAnItemDatedBefore1970() async throws {
        let service = StubWriteService()
        let coordinator = WriteCoordinator(writeService: service)
        let window = TestWindow()
        try await Coordinators.startPaste(coordinator, window)
        var conflict = Coordinators.conflict("conflict-old")
        // 1 January 1950.
        conflict.currentDestinationFingerprint.mtimeMs = -631_152_000_000

        service.emit(Coordinators.event(.awaitingResolution, runtimeConflict: conflict))

        #expect(window.progress.last?.status == .awaitingResolution)
        #expect(window.progress.last?.runtimeConflict?.conflictId == "conflict-old")
        #expect(service.calls.resolveRuntimeConflict.isEmpty)
        await coordinator.shutDown(maxWaitMs: 0)
    }

    // A question the window would never see would leave the paste waiting forever.
    @Test func answersSkipToAQuestionThatCantBeSentAndGoesOn() async throws {
        let service = StubWriteService()
        let coordinator = WriteCoordinator(writeService: service)
        let window = TestWindow()
        try await Coordinators.startPaste(coordinator, window)
        var conflict = Coordinators.conflict("conflict-bad")
        conflict.currentDestinationFingerprint.size = -1

        service.emit(Coordinators.event(.awaitingResolution, runtimeConflict: conflict))

        let answer = try #require(service.calls.resolveRuntimeConflict.first)
        #expect(answer.0 == "copy-op-1" && answer.1 == "conflict-bad" && answer.2 == .skip && !answer.3)
        #expect(window.progress.last?.status == .running)
        #expect(window.progress.last?.runtimeConflict == nil)

        // Its end still reaches the window.
        service.emit(Coordinators.event(.completed))
        #expect(window.progress.map(\.status).contains(.completed))
        await coordinator.shutDown(maxWaitMs: 0)
    }
}
