// Port of the createWriteOperationCoordinator, "with several windows" and "folder listings after a write" describes of
// apps/desktop/src/main/bootstrap/writeOperations.test.ts. The rename, New Folder, Trash and delete operations the
// original drives these with are P3-06's: the slot, cancel and window cases here run a stand-in local operation
// through the same entry point (`Coordinators.heldLocalOperation`).
import FTFileSystem
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTOperations

@MainActor
@Suite struct WriteCoordinatorTests {
    // T-35a8fecf
    @Test func forgetsTheTrashWhenAReplaceMovedItemsIntoItAndTellsTheWindow() async throws {
        let service = StubWriteService()
        var forgotten: [[String]] = []
        let coordinator = WriteCoordinator(
            writeService: service,
            options: WriteCoordinatorOptions(caches: WriteCaches(forget: { changed, _ in forgotten.append(changed) })))
        let window = TestWindow()
        try await Coordinators.startPaste(coordinator, window)

        service.emit(Coordinators.event(.completed, trashedPaths: ["/Users/demo/.Trash/a.txt"]))

        // Only a trash, Undo or Redo is taken to have changed the Trash; a Replace's own trashed paths are forgotten.
        #expect(forgotten == [["/Users/demo/target", "/Users/demo/.Trash/a.txt"]])
        #expect(window.progress.last?.result?.trashedPaths == ["/Users/demo/.Trash/a.txt"])
        await coordinator.shutDown(maxWaitMs: 0)
    }

    // T-1fcc9ee2
    @Test func holdsTheBusyLockWhileLocalWriteOperationsAreInFlightAndReleasesItOnTerminalEvents() async throws {
        let coordinator = WriteCoordinator(writeService: StubWriteService())
        let window = TestWindow()
        let gate = TestGate()
        #expect(try Coordinators.heldLocalOperation(coordinator, window, gate: gate).operationId == "write-op-1")

        #expect(throws: WriteCoordinatorError.busy) {
            try Coordinators.heldLocalOperation(coordinator, TestWindow(), gate: TestGate(), action: .newFolder)
        }

        gate.open()
        _ = try await Coordinators.end(of: "write-op-1", in: window)
        let opened = TestGate()
        #expect(
            try Coordinators.heldLocalOperation(coordinator, TestWindow(), gate: opened, action: .newFolder)
                == WriteOperationHandle(operationId: "write-op-2", status: .queued))
        opened.open()
        await coordinator.shutDown(maxWaitMs: 0)
    }

    // T-761afb52
    @Test func routesLocalAndDelegatedCancellationRequestsToTheCorrectOperationOwner() async throws {
        let service = StubWriteService()
        let coordinator = WriteCoordinator(writeService: service)
        let window = TestWindow()
        let gate = TestGate()
        try Coordinators.heldLocalOperation(coordinator, window, gate: gate)

        #expect(coordinator.cancel("write-op-1", window: window))
        #expect(!service.calls.cancelOperation.contains("write-op-1"))
        gate.open()
        #expect(try await Coordinators.end(of: "write-op-1", in: window).status == .cancelled)

        try await Coordinators.startPaste(coordinator, window)
        #expect(coordinator.cancel("copy-op-1", window: window))
        #expect(service.calls.cancelOperation == ["copy-op-1"])
        await coordinator.shutDown(maxWaitMs: 0)
    }

    // T-f3e4ba0e
    @Test func cancelsAPasteWhoseWindowClosedSoWritesDontStayLocked() async throws {
        let service = StubWriteService()
        let coordinator = WriteCoordinator(writeService: service)
        let window = TestWindow()
        try await Coordinators.startPaste(coordinator, window)

        coordinator.windowClosed(window)

        #expect(service.calls.cancelOperation == ["copy-op-1"])
        await coordinator.shutDown(maxWaitMs: 0)
        #expect(coordinator.watchCount(window) == 0)
    }

    // F-529 T-75d211c0
    @Test func tellsEveryOtherWindowHowTheOperationIsDoing() async throws {
        let service = StubWriteService()
        var broadcasts: [(WriteOperationStatus, ObjectIdentifier)] = []
        let coordinator = WriteCoordinator(
            writeService: service,
            options: WriteCoordinatorOptions(broadcastProgress: { event, owner in
                broadcasts.append((event.status, ObjectIdentifier(owner)))
            }))
        let window = TestWindow()
        try await Coordinators.startPaste(coordinator, window)

        service.emit(Coordinators.event(.running))
        service.emit(Coordinators.event(.completed))

        #expect(broadcasts.map(\.0) == [.running, .completed])
        #expect(broadcasts.allSatisfy { $0.1 == ObjectIdentifier(window) })
        await coordinator.shutDown(maxWaitMs: 0)
    }

    // F-530 T-3791698e
    @Test func handsARunningOperationToAnotherWindowWhenItsOwnCloses() async throws {
        let service = StubWriteService()
        let successor = TestWindow()
        let coordinator = WriteCoordinator(
            writeService: service, options: WriteCoordinatorOptions(successorOf: { _ in successor }))
        let window = TestWindow()
        try await Coordinators.startPaste(coordinator, window)
        service.emit(Coordinators.event(.awaitingResolution, runtimeConflict: Coordinators.conflict("conflict-1")))

        window.isClosed = true
        coordinator.windowClosed(window)

        #expect(service.calls.cancelOperation.isEmpty)
        // The window taking over hears where the operation is, its question included.
        let adoption = try #require(successor.adoptions.first)
        #expect(adoption.operationId == "copy-op-1")
        #expect(adoption.event?.status == .awaitingResolution)
        #expect(adoption.event?.runtimeConflict?.conflictId == "conflict-1")
        #expect(coordinator.watchCount(window) == 0)
        // It answers and stops it now; the window that closed can't.
        #expect(!coordinator.resolveConflict("copy-op-1", conflictId: "conflict-1", resolution: .skip, window: window))
        #expect(
            coordinator.resolveConflict("copy-op-1", conflictId: "conflict-1", resolution: .skip, window: successor))
        service.emit(Coordinators.event(.completed))
        #expect(successor.progress.map(\.status) == [.completed])
        #expect(coordinator.watchCount(successor) == 0)
        await coordinator.shutDown(maxWaitMs: 0)
    }

    // F-530 T-a95bad91
    @Test func handsItOnAgainWhenTheWindowThatTookItOverClosesToo() async throws {
        let service = StubWriteService()
        let first = TestWindow()
        let second = TestWindow()
        let third = TestWindow()
        let successors: [ObjectIdentifier: TestWindow] = [
            ObjectIdentifier(first): second, ObjectIdentifier(second): third,
        ]
        let coordinator = WriteCoordinator(
            writeService: service,
            options: WriteCoordinatorOptions(successorOf: { successors[ObjectIdentifier($0)] }))
        try await Coordinators.startPaste(coordinator, first)

        coordinator.windowClosed(first)
        coordinator.windowClosed(second)

        #expect(service.calls.cancelOperation.isEmpty)
        #expect(third.adoptions == [WriteOperationAdoption(operationId: "copy-op-1", event: nil)])
        // With no window left, it stops.
        coordinator.windowClosed(third)
        #expect(service.calls.cancelOperation == ["copy-op-1"])
        await coordinator.shutDown(maxWaitMs: 0)
    }

    // T-b29571bc
    @Test func rejectsAPasteThatArrivesWhileARenameIsStillBeingPrepared() async throws {
        let coordinator = WriteCoordinator(writeService: StubWriteService())
        let window = TestWindow()
        try await Coordinators.analyze(coordinator, window)
        let gate = TestGate()
        let preparing = Task { try await coordinator.prepareWithReservedSlot { await gate.wait() } }
        _ = try await Coordinators.waitFor { gate.waiting ? true : nil }

        #expect(throws: WriteCoordinatorError.busy) {
            try coordinator.startCopyPaste(
                CopyPasteStart(analysisId: "analysis-1", policy: Coordinators.skipMerge), window: window)
        }

        gate.open()
        try await preparing.value
        await coordinator.shutDown(maxWaitMs: 0)
    }

    // T-d775d86b
    @Test func passesPerItemChoicesAndStandingRuntimeAnswersToTheWriteService() async throws {
        let service = StubWriteService()
        let coordinator = WriteCoordinator(writeService: service)
        let window = TestWindow()
        try await Coordinators.analyze(coordinator, window)
        let policy = CopyPastePolicy(file: .keepBoth, directory: .merge, mismatch: .keepBoth)
        try coordinator.startCopyPaste(
            CopyPasteStart(
                analysisId: "analysis-1", policy: policy,
                overrides: [CopyPasteNodeOverride(nodeId: "item-2", action: .overwrite)]), window: window)
        coordinator.resolveConflict(
            "copy-op-1", conflictId: "runtime-item-1-destination", resolution: .skip, applyToRemaining: true,
            window: window)

        let start = try #require(service.calls.startCopyPaste.first)
        #expect(
            start.0
                == CopyPasteExecutionRequest(
                    analysisId: "analysis-1", policy: policy,
                    overrides: [CopyPasteNodeOverride(nodeId: "item-2", action: .overwrite)]))
        #expect(start.1 == [])
        let answer = try #require(service.calls.resolveRuntimeConflict.first)
        #expect(answer.0 == "copy-op-1" && answer.1 == "runtime-item-1-destination" && answer.2 == .skip && answer.3)
        await coordinator.shutDown(maxWaitMs: 0)
    }

    // The original's reload of the window's page (a committed main-frame load) has no native meaning: a window closes.
    // A close cancels the paste and lets go of the window; an operation started afterwards listens for itself.
    // T-14f606ef
    @Test func cancelsAPasteWhenItsWindowClosesAndListensAfreshForTheNextOne() async throws {
        let service = StubWriteService()
        let coordinator = WriteCoordinator(writeService: service)
        let window = TestWindow()
        try await Coordinators.startPaste(coordinator, window)

        coordinator.windowClosed(window)
        #expect(service.calls.cancelOperation == ["copy-op-1"])
        service.emit(Coordinators.event(.cancelled))
        #expect(coordinator.watchCount(window) == 0)

        let other = TestWindow()
        try await Coordinators.analyze(coordinator, other)
        try coordinator.startCopyPaste(
            CopyPasteStart(analysisId: "analysis-1", policy: Coordinators.skipMerge), window: other)
        #expect(!service.calls.cancelOperation.contains("copy-op-2"))
        coordinator.windowClosed(other)
        #expect(service.calls.cancelOperation.contains("copy-op-2"))
        await coordinator.shutDown(maxWaitMs: 0)
    }

    // T-62b53139
    @Test func cancelsALocalWriteWhenItsWindowClosesAndFreesTheWriteSlot() async throws {
        let coordinator = WriteCoordinator(writeService: StubWriteService())
        let window = TestWindow()
        let gate = TestGate()
        try Coordinators.heldLocalOperation(coordinator, window, gate: gate, action: .deleteImmediately)
        _ = try await Coordinators.waitFor { gate.waiting ? true : nil }

        coordinator.windowClosed(window)
        gate.open()
        #expect(try await Coordinators.end(of: "write-op-1", in: window).status == .cancelled)

        let next = TestGate()
        #expect(
            try Coordinators.heldLocalOperation(coordinator, window, gate: next, action: .newFolder).operationId
                == "write-op-2")
        next.open()
        await coordinator.shutDown(maxWaitMs: 0)
    }

    // T-f6bb24f2
    @Test func freesTheWriteSlotWhenALocalOperationsWindowThrowsOnSend() async throws {
        let coordinator = WriteCoordinator(writeService: StubWriteService())
        // A window torn down mid-operation: it doesn't say it is closed yet, but sending to it already throws.
        let window = TestWindow()
        let gate = TestGate()
        try Coordinators.heldLocalOperation(coordinator, window, gate: gate)
        _ = try await Coordinators.waitFor { gate.waiting ? true : nil }
        window.throwsOnSend = true

        gate.open()
        _ = try await Coordinators.waitFor { coordinator.watchCount(window) == 0 ? true : nil }
        _ = try await Coordinators.waitFor { coordinator.activeOperation == nil ? true : nil }

        let next = TestGate()
        #expect(
            try Coordinators.heldLocalOperation(coordinator, TestWindow(), gate: next, action: .newFolder)
                .operationId == "write-op-2")
        next.open()
        await coordinator.shutDown(maxWaitMs: 0)
    }

    // T-0fc03f99
    @Test func skipsSendingToAClosedWindowAndStillFreesTheSlotForWriteServiceOperations() async throws {
        let service = StubWriteService()
        let coordinator = WriteCoordinator(writeService: service)
        let window = TestWindow()
        try await Coordinators.startPaste(coordinator, window)

        window.isClosed = true
        window.throwsOnSend = true
        coordinator.windowClosed(window)
        #expect(service.calls.cancelOperation == ["copy-op-1"])
        service.emit(Coordinators.event(.cancelled))

        #expect(window.messages.isEmpty)
        #expect(coordinator.watchCount(window) == 0)
        try await Coordinators.analyze(coordinator, TestWindow())
        await coordinator.shutDown(maxWaitMs: 0)
    }

    // T-405a9724
    @Test func freesTheSlotEvenWhenSendingAWriteServiceTerminalEventThrows() async throws {
        let service = StubWriteService()
        let coordinator = WriteCoordinator(writeService: service)
        let window = TestWindow()
        try await Coordinators.startPaste(coordinator, window)
        window.throwsOnSend = true

        service.emit(Coordinators.event(.completed))

        #expect(coordinator.watchCount(window) == 0)
        try await Coordinators.startPaste(coordinator, TestWindow())
        await coordinator.shutDown(maxWaitMs: 0)
    }

    // T-c2fe7147
    @Test func cancelsRightAwayWhenTheStartingWindowIsAlreadyClosed() async throws {
        let service = StubWriteService()
        let coordinator = WriteCoordinator(writeService: service)
        let window = TestWindow()
        try await Coordinators.analyze(coordinator, window)
        // Closed while the start request was on its way.
        window.isClosed = true

        try coordinator.startCopyPaste(
            CopyPasteStart(analysisId: "analysis-1", policy: Coordinators.skipMerge), window: window)

        #expect(service.calls.cancelOperation == ["copy-op-1"])
        await coordinator.shutDown(maxWaitMs: 0)
    }

    // T-d22043b8
    @Test func stopsListeningToTheWindowWhenAnOperationFinishesNormally() async throws {
        let coordinator = WriteCoordinator(writeService: StubWriteService())
        let window = TestWindow()
        let gate = TestGate()
        try Coordinators.heldLocalOperation(coordinator, window, gate: gate)
        #expect(coordinator.watchCount(window) > 0)

        gate.open()
        _ = try await Coordinators.end(of: "write-op-1", in: window)

        #expect(coordinator.watchCount(window) == 0)
        await coordinator.shutDown(maxWaitMs: 0)
    }

    // T-8cffec4e
    @Test func sendsTheWindowATrimmedAnalysisReportKeepsItsOwnWholeAndCopiesEverything() async throws {
        try await withTemporaryDirectory(prefix: "filetrail-trim") { root in
            let source = root.appending("source").path
            let destination = root.appending("destination").path
            let manager = FileManager.default
            // "album" is new at the destination. "shared" exists there, with one of its files.
            try manager.createDirectory(atPath: source + "/album/raw", withIntermediateDirectories: true)
            try manager.createDirectory(atPath: source + "/shared/deep", withIntermediateDirectories: true)
            try manager.createDirectory(atPath: destination + "/shared", withIntermediateDirectories: true)
            let files = [
                "album/one.jpg", "album/two.jpg", "album/raw/one.dng", "album/raw/two.dng", "shared/clash.txt",
                "shared/new.txt", "shared/deep/a.txt", "shared/deep/b.txt",
            ]
            for file in files {
                try Data(file.utf8).write(to: URL(fileURLWithPath: source + "/" + file))
            }
            try Data("already here".utf8).write(to: URL(fileURLWithPath: destination + "/shared/clash.txt"))
            let service = WriteService(WriteServiceDependencies(fileSystem: NativeWriteFileSystem()))
            let coordinator = WriteCoordinator(writeService: service)
            let window = TestWindow()
            let handle = try await coordinator.startAnalysis(
                CopyPasteAnalysisRequest(
                    mode: .copy, sourcePaths: [source + "/album", source + "/shared"],
                    destinationDirectoryPath: destination), window: window)
            let update = try await Coordinators.waitFor {
                (try? coordinator.analysisUpdate(handle.analysisId, window: window)).flatMap { $0.done ? $0 : nil }
            }
            func names(_ nodes: [CopyPasteAnalysisNode]) -> [String] {
                nodes.map { NodePath.basename($0.sourcePath) }.sorted()
            }
            let sent = try #require(update.report)

            // The window gets: nothing inside the new folder; the clashing folder's items, and nothing inside the new
            // folder within it.
            #expect(sent.nodes[0].conflictClass == nil)
            #expect(sent.nodes[0].children.isEmpty)
            #expect(sent.nodes[0].totalNodeCount == 6)
            #expect(sent.nodes[1].conflictClass == .directoryConflict)
            #expect(names(sent.nodes[1].children) == ["clash.txt", "deep", "new.txt"])
            #expect(sent.nodes[1].children.first { $0.sourcePath.hasSuffix("deep") }?.children.isEmpty == true)
            let kept = try #require(try service.getCopyPasteAnalysisUpdate(handle.analysisId).report)
            #expect(sent.summary == kept.summary)

            // The write service's own report, which the copy runs from, is untouched.
            #expect(names(kept.nodes[0].children) == ["one.jpg", "raw", "two.jpg"])
            #expect(kept.nodes[1].children.first { $0.sourcePath.hasSuffix("deep") }?.children.count == 2)

            let started = try coordinator.startCopyPaste(
                CopyPasteStart(
                    analysisId: handle.analysisId,
                    policy: CopyPastePolicy(file: .keepBoth, directory: .merge, mismatch: .keepBoth)), window: window)
            let terminal = try await Coordinators.end(of: started.operationId, in: window)

            #expect(terminal.status == .completed)
            for file in files where file != "shared/clash.txt" {
                #expect(manager.fileExists(atPath: destination + "/" + file), "\(file)")
            }
            // The clash was kept next to the existing file.
            #expect(
                try manager.contentsOfDirectory(atPath: destination + "/shared").sorted()
                    == ["clash copy.txt", "clash.txt", "deep", "new.txt"])
            await coordinator.shutDown(maxWaitMs: 0)
        }
    }

    // F-531 T-a07308c3
    @Test func sendsAtMostOnePlainProgressUpdatePerIntervalAndTheNewestAlwaysArrives() async throws {
        let service = StubWriteService()
        let time = ManualClock()
        let coordinator = WriteCoordinator(writeService: service, options: WriteCoordinatorOptions(clock: time.clock))
        let window = TestWindow()
        try await Coordinators.startPaste(coordinator, window)
        func sentCounts() -> [Int] { window.progress.map(\.completedItemCount) }

        // A folder of small files: one update per file, all within the same moment.
        for completed in 1...500 {
            service.emit(Coordinators.event(.running, completedItemCount: completed, totalItemCount: 1000))
        }
        #expect(sentCounts() == [1])

        time.advance(WriteCoordinator.progressUpdateIntervalMs)
        #expect(sentCounts() == [1, 500])

        // Nothing new: nothing more is sent.
        time.advance(WriteCoordinator.progressUpdateIntervalMs * 5)
        #expect(sentCounts() == [1, 500])

        // After a quiet spell the next update goes out at once.
        service.emit(Coordinators.event(.running, completedItemCount: 501))
        #expect(sentCounts() == [1, 500, 501])

        // A question for the user does not wait, and replaces an update that was.
        service.emit(Coordinators.event(.running, completedItemCount: 502))
        service.emit(
            Coordinators.event(
                .awaitingResolution, completedItemCount: 503, runtimeConflict: Coordinators.conflict("conflict-1")))
        #expect(sentCounts() == [1, 500, 501, 503])

        // Neither does the end, after which nothing held back is sent late.
        service.emit(Coordinators.event(.running, completedItemCount: 504))
        service.emit(Coordinators.event(.running, completedItemCount: 505))
        service.emit(Coordinators.event(.completed))
        #expect(window.progress.last?.status == .completed)
        let sentBeforeWaiting = window.messages.count
        time.advance(WriteCoordinator.progressUpdateIntervalMs * 5)
        #expect(window.messages.count == sentBeforeWaiting)
        await coordinator.shutDown(maxWaitMs: 0)
    }

    // T-e2603cef
    @Test func passesBackTheWriteServicesRejectionOfAConflictAnswer() async throws {
        let service = StubWriteService()
        let coordinator = WriteCoordinator(writeService: service)
        let window = TestWindow()
        try await Coordinators.startPaste(coordinator, window)
        service.emit(Coordinators.event(.awaitingResolution, runtimeConflict: Coordinators.conflict("conflict-1")))
        service.resolveAnswer = false

        #expect(
            !coordinator.resolveConflict("copy-op-1", conflictId: "conflict-1", resolution: .overwrite, window: window))
        let answer = try #require(service.calls.resolveRuntimeConflict.first)
        #expect(answer.0 == "copy-op-1" && answer.1 == "conflict-1" && answer.2 == .overwrite && !answer.3)
        await coordinator.shutDown(maxWaitMs: 0)
    }

    // F-529 T-25fcde45
    @Test func onlyAcceptsCancelAndConflictAnswersFromTheWindowThatStartedTheOperation() async throws {
        let service = StubWriteService()
        let coordinator = WriteCoordinator(writeService: service)
        let owner = TestWindow()
        let otherWindow = TestWindow()
        try await Coordinators.startPaste(coordinator, owner)

        #expect(
            !coordinator.resolveConflict("copy-op-1", conflictId: "conflict-1", resolution: .skip, window: otherWindow))
        #expect(!coordinator.cancel("copy-op-1", window: otherWindow))
        #expect(service.calls.resolveRuntimeConflict.isEmpty)
        #expect(service.calls.cancelOperation.isEmpty)

        #expect(coordinator.cancel("copy-op-1", window: owner))
        #expect(service.calls.cancelOperation == ["copy-op-1"])
        await coordinator.shutDown(maxWaitMs: 0)

        // Local operations follow the same rule.
        let local = WriteCoordinator(writeService: StubWriteService())
        let gate = TestGate()
        try Coordinators.heldLocalOperation(local, owner, gate: gate)
        #expect(!local.cancel("write-op-1", window: otherWindow))
        gate.open()
        #expect(try await Coordinators.end(of: "write-op-1", in: owner).status == .completed)
        await local.shutDown(maxWaitMs: 0)
    }

    // MARK: folder listings after a write

    // T-472c303e
    @Test func forgetsCachedListingsBeforeALocalOperationsEndIsSent() async throws {
        var forgets = 0
        let coordinator = WriteCoordinator(
            writeService: StubWriteService(),
            options: WriteCoordinatorOptions(caches: WriteCaches(forget: { _, _ in forgets += 1 })))
        let window = TestWindow()
        var forgetsAtEnd: [Int] = []
        window.onReceive = { message in
            if case .progress(let event) = message, event.status == .completed { forgetsAtEnd.append(forgets) }
        }
        let gate = TestGate()
        try Coordinators.heldLocalOperation(coordinator, window, gate: gate, action: .deleteImmediately)
        gate.open()
        _ = try await Coordinators.end(of: "write-op-1", in: window)

        #expect(forgetsAtEnd == [1])
        await coordinator.shutDown(maxWaitMs: 0)
    }

    // T-753b287c
    @Test func forgetsCachedListingsBeforeAPastesEndIsSent() async throws {
        let service = StubWriteService()
        var forgets = 0
        let coordinator = WriteCoordinator(
            writeService: service,
            options: WriteCoordinatorOptions(caches: WriteCaches(forget: { _, _ in forgets += 1 })))
        let window = TestWindow()
        var forgetsAtEnd: [Int] = []
        window.onReceive = { message in
            if case .progress(let event) = message, event.status == .completed { forgetsAtEnd.append(forgets) }
        }
        try await Coordinators.startPaste(coordinator, window)

        service.emit(Coordinators.event(.completed))

        #expect(forgetsAtEnd == [1])
        await coordinator.shutDown(maxWaitMs: 0)
    }
}
