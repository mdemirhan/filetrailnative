// Port by feature of the "an operation another window runs" cases of apps/desktop/src/renderer/App.windows.test.tsx and
// of T-00a2c789 of App.tabs.test.tsx: one explorer window's side of the file operations, driven as the coordinator
// drives it (its own operations' progress, other windows' broadcasts, hand-overs)
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit
@testable import FTOperations

/// A write service whose events the test sends.
private final class StubWriteService: CoordinatorWriteService, @unchecked Sendable {
    private var subscribers: [@Sendable (CopyPasteProgressEvent) -> Void] = []
    private var sequence = 0

    func emit(_ event: CopyPasteProgressEvent) {
        for subscriber in subscribers { subscriber(event) }
    }

    func subscribe(_ listener: @escaping @Sendable (CopyPasteProgressEvent) -> Void) -> @Sendable () -> Void {
        subscribers.append(listener)
        return {}
    }

    func startCopyPasteAnalysis(_ request: CopyPasteAnalysisRequest, keep: Set<String>) throws
        -> CopyPasteAnalysisStartHandle
    {
        CopyPasteAnalysisStartHandle(analysisId: "analysis-1", status: .queued)
    }

    func getCopyPasteAnalysisUpdate(_ analysisId: String) throws -> CopyPasteAnalysisUpdate {
        CopyPasteAnalysisUpdate(analysisId: analysisId, status: .complete, done: true, report: nil, error: nil)
    }

    func cancelCopyPasteAnalysis(_ analysisId: String) -> Bool { true }

    func startCopyPaste(_ start: CopyPasteExecutionRequest, keep: Set<String>) throws -> CopyPasteOperationHandle {
        sequence += 1
        return CopyPasteOperationHandle(operationId: "copy-op-\(sequence)", status: .queued)
    }

    func resolveRuntimeConflict(
        _ operationId: String, conflictId: String, action: CopyPasteChoice, applyToRemaining: Bool
    ) -> Bool { true }

    func cancelOperation(_ operationId: String) -> Bool { true }
}

/// An explorer window as the session sees it.
@MainActor
private final class FakeHost: WriteSessionHost {
    var isClosed = false
    var activeTabID: Int? = 1
    var currentPath = "/Users/demo/Folder"
    var selectedPaths: [String] = []
    var isSearching = false
    var selectedTreePath: String?
    private(set) var refreshes: [WriteEndRefresh] = []
    private(set) var followed: [[PathMove]] = []

    func applyWriteEnd(_ refresh: WriteEndRefresh) { refreshes.append(refresh) }
    func followMovesOnScreen(_ moves: [PathMove]) { followed.append(moves) }
    func writeLockChanged() {}
}

@MainActor
private struct Fixture {
    let service = StubWriteService()
    let coordinator: WriteCoordinator
    let host = FakeHost()
    let session: ExplorerWriteSession
    let clipboard = SharedClipboard()
    var shown: [(String, String)] { shownBox.value }
    private let shownBox = Box()
    var events: [WindowWriteEvent] { eventsBox.events }
    private let eventsBox: Events
    let observation: ExplorerWindowObservation

    final class Box {
        var value: [(String, String)] = []
    }

    final class Events {
        var events: [WindowWriteEvent] = []
    }

    /// Keeps the other windows open (a session holds its window weakly).
    final class Hosts {
        var hosts: [FakeHost] = []
    }

    private let otherHosts = Hosts()

    final class SessionBox {
        weak var session: ExplorerWriteSession?
    }

    init(successor: (@MainActor () -> (any WriteOperationWindow)?)? = nil) {
        let boxed = Events()
        let listener = SessionBox()
        coordinator = WriteCoordinator(
            writeService: service,
            options: WriteCoordinatorOptions(
                // This window hears every other window's operation.
                broadcastProgress: { event, owner in
                    if let session = listener.session, owner !== session { session.otherWindowProgress(event) }
                }, successorOf: { _ in successor?() }))
        session = ExplorerWriteSession(coordinator: coordinator, host: host, clipboard: clipboard)
        listener.session = session
        observation = session.observe { boxed.events.append($0) }
        eventsBox = boxed
    }

    /// Another window starts a paste, which runs in the coordinator; this window hears it is running.
    func otherWindowPastes() async throws -> (ExplorerWriteSession, String) {
        let otherHost = FakeHost()
        otherHosts.hosts.append(otherHost)
        let other = ExplorerWriteSession(coordinator: coordinator, host: otherHost, clipboard: nil)
        _ = try await coordinator.startAnalysis(
            CopyPasteAnalysisRequest(mode: .copy, sourcePaths: ["/Users/demo/a.txt"], destinationDirectoryPath: "/x"),
            window: other)
        let handle = try coordinator.startCopyPaste(
            CopyPasteStart(analysisId: "analysis-1", policy: WindowWriteActions.safePolicy), window: other)
        service.emit(pasteEvent(handle.operationId, .running))
        return (other, handle.operationId)
    }

    var actions: WindowWriteActions {
        var dialogs = WriteDialogs()
        let box = shownBox
        dialogs.show = { title, message, _ in box.value.append((title, message)) }
        return WindowWriteActions(session: session, tab: nil, dialogs: dialogs)
    }
}

/// Another window's copy (`otherWindowsCopy`).
private func otherWindowsCopy(_ status: WriteOperationStatus, items: [WriteOperationItem] = []) -> WriteOperationEvent {
    WriteOperationEvent(
        operationId: "other-op", action: .copyTo, status: status, totalItemCount: 1,
        currentSourcePath: "/Users/demo/elsewhere.txt",
        result: status.isTerminal
            ? LocalWriteResults.result(
                operationId: "other-op", action: .paste, targetPath: "/Users/demo/Folder",
                startedAt: Date(timeIntervalSince1970: 0), finishedAt: Date(timeIntervalSince1970: 1),
                totalItemCount: items.count, completedItemCount: items.filter { $0.status == .completed }.count,
                items: items, status: status, error: nil) : nil)
}

private func pasteEvent(_ operationId: String, _ status: CopyPasteOperationStatus) -> CopyPasteProgressEvent {
    CopyPasteProgressEvent(
        operationId: operationId, analysisId: "analysis-1", mode: .copy, status: status, completedItemCount: 0,
        totalItemCount: 1, completedByteCount: 0, totalBytes: nil, currentSourcePath: nil, currentDestinationPath: nil,
        runtimeConflict: nil,
        result: status.isTerminal
            ? CopyPasteOperationResult(
                operationId: operationId, mode: .copy, status: status, destinationDirectoryPath: "/x",
                startedAt: Date(), finishedAt: Date(),
                summary: CopyPasteOperationSummary(
                    topLevelItemCount: 1, totalItemCount: 1, completedItemCount: 0, failedItemCount: 0,
                    skippedItemCount: 0, cancelledItemCount: 0, completedByteCount: 0, totalBytes: nil),
                items: [], error: nil) : nil)
}

private let arrived = WriteOperationItem(
    sourcePath: "/Users/demo/elsewhere.txt", destinationPath: "/Users/demo/Folder/elsewhere.txt", status: .completed)

@MainActor
@Suite struct ExplorerWriteSessionTests {
    // F-247 F-244 T-b1bf94e1
    @Test func keepsThisWindowFromStartingAnotherUntilItEnds() async throws {
        let fixture = Fixture()
        let (_, operationId) = try await fixture.otherWindowPastes()
        // Its card is in the window that started it, not here.
        #expect(fixture.session.card == nil)
        #expect(fixture.session.foreign?.operationId == operationId)

        #expect(fixture.actions.refuseWhileBusy(.operation(.trash)))
        #expect(fixture.shown.map(\.0) == ["Couldn\u{2019}t Move to Trash"])
        #expect(fixture.shown.map(\.1) == ["Another file operation is running. Try again when it has finished."])
        #expect(fixture.session.isWriteLocked)

        fixture.service.emit(pasteEvent(operationId, .completed))
        #expect(!fixture.session.isWriteLocked)
        #expect(!fixture.actions.refuseWhileBusy(.operation(.trash)))
        await fixture.coordinator.shutDown(maxWaitMs: 0)
    }

    // F-244 T-3ddcdaa4
    @Test func letsGoOfItWhenItMissedItsEndAndSaysNothingRan() {
        let fixture = Fixture()
        fixture.session.otherWindowProgress(otherWindowsCopy(.running))
        // It ended, but the message saying so never reached this window: the coordinator runs nothing.
        #expect(fixture.coordinator.activeOperationId == nil)

        // The press lets go of it, and starts nothing; no notice is shown.
        #expect(fixture.actions.refuseWhileBusy(.operation(.trash)))
        #expect(fixture.shown.isEmpty)
        #expect(!fixture.session.isWriteLocked)

        // The next press goes ahead.
        #expect(!fixture.actions.refuseWhileBusy(.operation(.trash)))
    }

    // F-244 T-65a1aee0
    @Test func letsGoOfItWhenItMissedItsEndAsItComesToTheFront() {
        let fixture = Fixture()
        fixture.session.otherWindowProgress(otherWindowsCopy(.running))
        #expect(fixture.session.isWriteLocked)

        fixture.session.cameToFront()

        #expect(!fixture.session.isWriteLocked)
    }

    // F-247 F-244 T-bfd5ac7b
    @Test func keepsRefusingWhileTheCoordinatorSaysItStillRuns() async throws {
        let fixture = Fixture()
        _ = try await fixture.otherWindowPastes()
        fixture.session.cameToFront()

        #expect(fixture.actions.refuseWhileBusy(.operation(.trash)))
        #expect(fixture.shown.map(\.0) == ["Couldn\u{2019}t Move to Trash"])
        #expect(fixture.session.isWriteLocked)
        await fixture.coordinator.shutDown(maxWaitMs: 0)
    }

    // F-240 F-307 T-70c3fa89
    @Test func takesItOverWhenItWasHandedOver() async throws {
        let successor = Fixture.SessionBox()
        let fixture = Fixture(successor: { successor.session })
        successor.session = fixture.session
        let (owner, _) = try await fixture.otherWindowPastes()
        #expect(fixture.session.isWriteLocked)

        fixture.coordinator.windowClosed(owner)

        #expect(fixture.session.activeOperationId == "copy-op-1")
        #expect(fixture.session.card?.stage == .running)
        // It is this window's now: it may stop it.
        #expect(fixture.actions.cancel())
        await fixture.coordinator.shutDown(maxWaitMs: 0)
    }

    // F-289 F-240 T-29cc2d4b
    @Test func showsHowItWentAndClearsItsCutWhenItEndedBeforeTheWindowHeard() throws {
        let fixture = Fixture()
        fixture.clipboard.set(
            .ready(
                mode: .cut, sourcePaths: ["/Users/demo/elsewhere.txt", "/Users/demo/locked.txt"], sourceEntries: [:],
                capturedAt: "2026-10-08T10:00:00.000Z"), from: nil)
        let failed = WriteOperationItem(
            sourcePath: "/Users/demo/locked.txt", destinationPath: "/Users/demo/Folder/locked.txt", status: .failed,
            error: "The disk is full.")
        var ended = otherWindowsCopy(.partial, items: [arrived, failed])
        ended.action = .paste

        try fixture.session.receive(
            .adopted(
                WriteOperationAdoption(
                    operationId: "other-op", event: ended, clearsCutClipboard: "2026-10-08T10:00:00.000Z")))

        #expect(fixture.events.contains(.ended(ended, inTabOnScreen: false)))
        #expect(fixture.clipboard.contents == .empty)
    }

    // F-240 T-c135e08d
    @Test func takesAnOperationItHearsOfTwiceOnce() throws {
        let fixture = Fixture()
        var running = otherWindowsCopy(.running)
        running.action = .paste
        var ended = otherWindowsCopy(
            .failed,
            items: [
                WriteOperationItem(
                    sourcePath: "/Users/demo/elsewhere.txt", destinationPath: nil, status: .failed,
                    error: "The disk is full.")
            ])
        ended.action = .paste

        try fixture.session.receive(.adopted(WriteOperationAdoption(operationId: "other-op", event: running)))
        #expect(fixture.session.card?.stage == .running)
        // Told again (asked after the message): taken once.
        try fixture.session.receive(.adopted(WriteOperationAdoption(operationId: "other-op", event: ended)))
        #expect(!fixture.events.contains { if case .ended = $0 { true } else { false } })

        // Its end comes as any other progress does, and is shown once.
        try fixture.session.receive(.progress(ended))
        #expect(fixture.events.filter { if case .ended = $0 { true } else { false } }.count == 1)
    }

    // F-240 T-f4897f9f
    @Test func showsItHereOnceThisWindowTakesItOverAndLeavesTheSelectionAlone() throws {
        let fixture = Fixture()
        fixture.session.otherWindowProgress(otherWindowsCopy(.running))
        fixture.host.selectedPaths = ["/Users/demo/Folder/keep.txt"]
        var running = otherWindowsCopy(.running)
        running.action = .paste

        try fixture.session.receive(.adopted(WriteOperationAdoption(operationId: "other-op", event: running)))
        #expect(fixture.session.foreign == nil)
        #expect(fixture.session.card?.stage == .running)

        // The copy arrives in the folder on screen.
        try fixture.session.receive(.progress(otherWindowsCopy(.completed, items: [arrived])))

        #expect(fixture.session.card == nil)
        // What it would have selected belonged to the window that started it.
        #expect(fixture.host.refreshes.count == 1)
        #expect(fixture.host.refreshes[0].path == "/Users/demo/Folder")
        #expect(fixture.host.refreshes[0].selecting == nil)
        // It is over: this window may start the next one.
        #expect(!fixture.session.isWriteLocked)
    }

    // B-VIEW-171: the operation's progress shows whichever tab is in front; what arrived is selected only in the
    // tab it was started from.
    // T-00a2c789
    @Test func showsARunningOperationInEveryTabAndSelectsWhatArrivedOnlyWhereItStarted() async throws {
        for switchesTab in [true, false] {
            let fixture = Fixture()
            let started = Task {
                try await fixture.coordinator.startAnalysis(
                    CopyPasteAnalysisRequest(
                        mode: .copy, sourcePaths: ["/Users/demo/source.txt"],
                        destinationDirectoryPath: "/Users/demo/Folder"), window: fixture.session)
            }
            _ = try await started.value
            fixture.session.applyCard(
                WriteOperationCardState(action: .paste, stage: .starting, targetPath: "/Users/demo/Folder"))
            let handle = try fixture.coordinator.startCopyPaste(
                CopyPasteStart(analysisId: "analysis-1", policy: WindowWriteActions.safePolicy),
                window: fixture.session)
            fixture.session.adoptWriteOperation(handle.operationId)
            if switchesTab { fixture.host.activeTabID = 2 }
            #expect(fixture.session.card != nil)

            fixture.service.emit(
                CopyPasteProgressEvent(
                    operationId: handle.operationId, analysisId: "analysis-1", mode: .copy, status: .completed,
                    completedItemCount: 1, totalItemCount: 1, completedByteCount: 0, totalBytes: nil,
                    currentSourcePath: nil, currentDestinationPath: nil, runtimeConflict: nil,
                    result: CopyPasteOperationResult(
                        operationId: handle.operationId, mode: .copy, status: .completed,
                        destinationDirectoryPath: "/Users/demo/Folder", startedAt: Date(), finishedAt: Date(),
                        summary: CopyPasteOperationSummary(
                            topLevelItemCount: 1, totalItemCount: 1, completedItemCount: 1, failedItemCount: 0,
                            skippedItemCount: 0, cancelledItemCount: 0, completedByteCount: 0, totalBytes: nil),
                        items: [
                            CopyPasteItemResult(
                                sourcePath: "/Users/demo/source.txt", destinationPath: "/Users/demo/Folder/source.txt",
                                sourceKind: .file, status: .completed, error: nil)
                        ], error: nil)))

            #expect(fixture.session.card == nil)
            let refresh = try #require(fixture.host.refreshes.last)
            #expect(refresh.path == "/Users/demo/Folder")
            #expect(refresh.selecting == (switchesTab ? nil : ["/Users/demo/Folder/source.txt"]))
            await fixture.coordinator.shutDown(maxWaitMs: 0)
        }
    }
}
