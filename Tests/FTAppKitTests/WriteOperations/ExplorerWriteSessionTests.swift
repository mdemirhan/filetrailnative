// One explorer window's side of the file operations, driven as the coordinator drives it (its own operations' progress,
// other windows' broadcasts, hand-overs)
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

    /// A report with nothing in the way.
    func analyze(_ request: CopyPasteAnalysisRequest, signal: StopSignal) async throws -> CopyPasteAnalysisReport {
        CopyPasteAnalysisReport(
            analysisId: "analysis-1", mode: request.mode, sourcePaths: request.sourcePaths,
            destinationDirectoryPath: request.destinationDirectoryPath, nodes: [], issues: [],
            summary: CopyPasteAnalysisSummary(
                topLevelItemCount: 0, totalNodeCount: 0, totalBytes: 0, fileConflictCount: 0,
                directoryConflictCount: 0, mismatchConflictCount: 0), cutSourcePaths: request.cutSourcePaths)
    }

    func startCopyPaste(
        report: CopyPasteAnalysisReport, policy: CopyPastePolicy, overrides: [CopyPasteNodeOverride]?
    ) throws -> CopyPasteOperationHandle {
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
    /// A tab with two panes: which one is active, and each one's folder and selection. Nil for one pane.
    var activePaneID: Int?
    var panes: [WritePaneSelection]?
    private(set) var refreshes: [WriteEndRefresh] = []
    private(set) var followed: [[PathMove]] = []

    var paneSelections: [WritePaneSelection] {
        panes ?? [WritePaneSelection(paneID: nil, directoryPath: currentPath, paths: selectedPaths)]
    }

    /// The pane `id` becomes the active one: the tab's folder and selection are its own.
    func activate(_ id: Int) {
        guard let pane = panes?.first(where: { $0.paneID == id }) else { return }
        activePaneID = id
        currentPath = pane.directoryPath
        selectedPaths = pane.paths
    }

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
            writeService: service, fileSystem: NativeWriteFileSystem(),
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
        let report = try await coordinator.analyze(
            CopyPasteAnalysisRequest(mode: .copy, sourcePaths: ["/Users/demo/a.txt"], destinationDirectoryPath: "/x"),
            window: other, signal: StopSignal())
        let handle = try coordinator.startCopyPaste(
            CopyPasteStart(report: report, policy: WindowWriteActions.safePolicy), window: other)
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

/// The end of a paste this window started, as the write service tells it: each item of `items` with how it went
/// and, in a paste of copied and cut items, what it was to do.
private func pasteEnded(
    _ operationId: String, mode: FTOperations.CopyPasteMode,
    _ items: [(name: String, status: CopyPasteItemResult.Status, mode: FTOperations.CopyPasteMode?)]
) -> CopyPasteProgressEvent {
    let completed = items.filter { $0.status == .completed }.count
    let failed = items.filter { $0.status == .failed }.count
    let status: CopyPasteOperationStatus = failed == 0 ? .completed : completed == 0 ? .failed : .partial
    return CopyPasteProgressEvent(
        operationId: operationId, analysisId: "analysis-1", mode: mode, status: status,
        completedItemCount: completed, totalItemCount: items.count, completedByteCount: 0, totalBytes: nil,
        currentSourcePath: nil, currentDestinationPath: nil, runtimeConflict: nil,
        result: CopyPasteOperationResult(
            operationId: operationId, mode: mode, status: status, destinationDirectoryPath: "/Users/demo/Folder",
            startedAt: Date(), finishedAt: Date(),
            summary: CopyPasteOperationSummary(
                topLevelItemCount: items.count, totalItemCount: items.count, completedItemCount: completed,
                failedItemCount: failed, skippedItemCount: 0, cancelledItemCount: 0, completedByteCount: 0,
                totalBytes: nil),
            items: items.map {
                CopyPasteItemResult(
                    sourcePath: "/Users/demo/\($0.name)", destinationPath: "/Users/demo/Folder/\($0.name)",
                    sourceKind: .file, status: $0.status, error: $0.status == .failed ? "The disk is full." : nil,
                    mode: $0.mode)
            }, error: nil))
}

private let arrived = WriteOperationItem(
    sourcePath: "/Users/demo/elsewhere.txt", destinationPath: "/Users/demo/Folder/elsewhere.txt", status: .completed)

private let gatheredAt = "2026-10-08T10:00:00.000Z"

/// `copied.txt` copied, then `elsewhere.txt` and `locked.txt` added to move: a clipboard built with Add, which a Copy
/// or Cut that replaces it keeps to be put back.
private func gathered() -> CopyPasteClipboard {
    let copied = ClipboardRules.set(.copy, ["/Users/demo/copied.txt"], capturedAt: gatheredAt)
    return ClipboardRules.applyAdd(
        ClipboardRules.planAdd(copied, .cut, ["/Users/demo/elsewhere.txt", "/Users/demo/locked.txt"]), to: copied,
        stamp: "2026-10-08T10:00:05.000Z"
    ).clipboard
}

/// The end of a paste of `gathered()`: `copied.txt` copied and `elsewhere.txt` moved, and `locked.txt` moved too or
/// failed.
private func gatheredPasteEnded(lockedMoved: Bool) -> WriteOperationEvent {
    let copied = WriteOperationItem(
        sourcePath: "/Users/demo/copied.txt", destinationPath: "/Users/demo/Folder/copied.txt", status: .completed,
        mode: .copy)
    var moved = arrived
    moved.mode = .cut
    let locked = WriteOperationItem(
        sourcePath: "/Users/demo/locked.txt", destinationPath: "/Users/demo/Folder/locked.txt",
        status: lockedMoved ? .completed : .failed, error: lockedMoved ? nil : "The disk is full.", mode: .cut)
    var ended = otherWindowsCopy(lockedMoved ? .completed : .partial, items: [copied, moved, locked])
    ended.action = .paste
    ended.result?.mode = .copy
    return ended
}

@MainActor
@Suite struct ExplorerWriteSessionTests {
    // Its end arrives before the start request returns: it is finished when the window hears the handle.
    @Test func finishesANewFolderWhoseCompletionArrivesBeforeItsStartRequestReturns() async throws {
        let fixture = Fixture()
        let session = fixture.session
        let made = "/Users/demo/Folder/untitled folder 2"
        session.pendingInlineRenamePath = "/Users/demo/Folder/untitled folder"
        session.applyCard(
            WriteOperationCardState(
                action: .newFolder, stage: .starting, targetPath: "/Users/demo/Folder", totalItemCount: 1))
        let result = LocalWriteResults.result(
            operationId: "folder-op", action: .newFolder, targetPath: made, startedAt: Date(timeIntervalSince1970: 0),
            finishedAt: Date(timeIntervalSince1970: 1), totalItemCount: 1, completedItemCount: 1,
            items: [WriteOperationItem(sourcePath: nil, destinationPath: made, status: .completed)], status: .completed,
            error: nil)
        let operationId = await session.early.whileStarting {
            session.handleProgress(
                WriteOperationEvent(
                    operationId: "folder-op", action: .newFolder, status: .completed, totalItemCount: 1,
                    result: result))
            return "folder-op"
        }
        #expect(session.card != nil)
        session.adoptWriteOperation(operationId)
        #expect(await waitUntil { session.card == nil })
        #expect(!session.isWriteLocked)
        #expect(session.activeOperationId == nil)
        // The one actually made is the one renamed, and it is selected.
        #expect(session.pendingInlineRenamePath == made)
        #expect(fixture.host.refreshes.last?.selecting == [made])
        // The next New Folder isn't refused.
        #expect(!fixture.actions.refuseWhileBusy(.operation(.newFolder)))
        #expect(fixture.shown.isEmpty)
    }

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

    @Test func letsGoOfItWhenItMissedItsEndAsItComesToTheFront() {
        let fixture = Fixture()
        fixture.session.otherWindowProgress(otherWindowsCopy(.running))
        #expect(fixture.session.isWriteLocked)

        fixture.session.cameToFront()

        #expect(!fixture.session.isWriteLocked)
    }

    @Test func keepsRefusingWhileTheCoordinatorSaysItStillRuns() async throws {
        let fixture = Fixture()
        _ = try await fixture.otherWindowPastes()
        fixture.session.cameToFront()

        #expect(fixture.actions.refuseWhileBusy(.operation(.trash)))
        #expect(fixture.shown.map(\.0) == ["Couldn\u{2019}t Move to Trash"])
        #expect(fixture.session.isWriteLocked)
        await fixture.coordinator.shutDown(maxWaitMs: 0)
    }

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

    /// What the paste moved leaves the clipboard; what it didn't get to move stays, still cut.
    @Test func showsHowItWentAndTakesWhatItMovedOffItsCutWhenItEndedBeforeTheWindowHeard() throws {
        let fixture = Fixture()
        fixture.clipboard.set(
            ClipboardRules.set(
                .cut, ["/Users/demo/elsewhere.txt", "/Users/demo/locked.txt"], capturedAt: "2026-10-08T10:00:00.000Z"),
            from: nil)
        let failed = WriteOperationItem(
            sourcePath: "/Users/demo/locked.txt", destinationPath: "/Users/demo/Folder/locked.txt", status: .failed,
            error: "The disk is full.")
        var ended = otherWindowsCopy(.partial, items: [arrived, failed])
        ended.action = .moveTo
        ended.result?.action = .moveTo
        ended.result?.mode = .cut

        fixture.session.receive(
            .adopted(
                WriteOperationAdoption(
                    operationId: "other-op", event: ended, clearsCutClipboard: "2026-10-08T10:00:00.000Z")))

        #expect(fixture.events.contains(.ended(ended, inTabOnScreen: false)))
        #expect(fixture.clipboard.contents.sourcePaths == ["/Users/demo/locked.txt"])
        #expect(fixture.clipboard.contents.mode == .cut)
    }

    /// A paste that copied some items and moved others used the clipboard up: the copied items leave with the moved
    /// ones.
    @Test func aPasteOfCopiedAndCutItemsUsesTheClipboardUp() throws {
        let fixture = Fixture()
        let capturedAt = "2026-10-08T10:00:00.000Z"
        let both = ClipboardRules.setMode(
            ClipboardRules.set(.copy, ["/Users/demo/copied.txt", "/Users/demo/elsewhere.txt"], capturedAt: capturedAt),
            ["/Users/demo/elsewhere.txt"], to: .cut, at: capturedAt)
        fixture.clipboard.set(both, from: nil)
        let copied = WriteOperationItem(
            sourcePath: "/Users/demo/copied.txt", destinationPath: "/Users/demo/Folder/copied.txt", status: .completed,
            mode: .copy)
        var moved = arrived
        moved.mode = .cut
        var ended = otherWindowsCopy(.completed, items: [copied, moved])
        ended.action = .paste
        ended.result?.mode = .copy

        fixture.session.receive(
            .adopted(WriteOperationAdoption(operationId: "other-op", event: ended, clearsCutClipboard: capturedAt)))

        #expect(fixture.clipboard.contents == .empty)
    }

    /// A Copy took the clipboard's place while its paste ran, and the clipboard, built with Add, is kept to be put
    /// back: the paste used it up there too. Put Back brings back only what the paste didn't get to, where it brought
    /// back the copied items and the moved ones, followed to where they had just been pasted and still to be moved.
    @Test func aPasteUsesUpItsClipboardKeptToBePutBack() throws {
        for lockedMoved in [false, true] {
            let fixture = Fixture()
            fixture.clipboard.set(gathered(), from: nil)
            let fresh = ClipboardRules.set(.copy, ["/Users/demo/new.txt"], capturedAt: "2026-10-08T10:01:00.000Z")
            #expect(fixture.clipboard.replace(with: fresh, from: nil) == gathered())
            // What is kept as the window hears of the end: it follows the write on it then.
            var keptAsTheWindowHeard: [String]?
            let clipboard = fixture.clipboard
            let observation = fixture.session.observe { event in
                if case .ended = event { keptAsTheWindowHeard = clipboard.previous?.sourcePaths ?? [] }
            }

            fixture.session.receive(
                .adopted(
                    WriteOperationAdoption(
                        operationId: "other-op", event: gatheredPasteEnded(lockedMoved: lockedMoved),
                        clearsCutClipboard: gatheredAt)))
            withExtendedLifetime(observation) {}

            #expect(fixture.clipboard.contents == fresh)
            let left = lockedMoved ? [] : ["/Users/demo/locked.txt"]
            #expect(keptAsTheWindowHeard == left, "locked moved: \(lockedMoved)")
            #expect(fixture.clipboard.previous?.sourcePaths ?? [] == left, "locked moved: \(lockedMoved)")
            if !lockedMoved {
                #expect(fixture.clipboard.previous?.mode == .cut)
                #expect(fixture.clipboard.previous?.capturedAt == gatheredAt)
            }
            // With nothing left of it there is nothing to put back.
            #expect(fixture.clipboard.putBack(from: nil) == !lockedMoved)
        }
    }

    /// A Copy made while a paste of a cut ran, the cut never added to: nothing is kept to be put back, and the new
    /// clipboard is not the paste's. The paste's end takes nothing off it, not even an item of it the paste moved:
    /// the window then follows that one to where it went, as after any write, and it stays copied.
    @Test func aClipboardMadeSinceThePasteStartedIsLeftAsItIs() throws {
        let fixture = Fixture()
        fixture.clipboard.set(
            ClipboardRules.set(.cut, ["/Users/demo/elsewhere.txt", "/Users/demo/locked.txt"], capturedAt: gatheredAt),
            from: nil)
        let fresh = ClipboardRules.set(
            .copy, ["/Users/demo/elsewhere.txt", "/Users/demo/new.txt"], capturedAt: "2026-10-08T10:01:00.000Z")
        #expect(fixture.clipboard.replace(with: fresh, from: nil) == nil)
        let locked = WriteOperationItem(
            sourcePath: "/Users/demo/locked.txt", destinationPath: "/Users/demo/Folder/locked.txt", status: .completed)
        var ended = otherWindowsCopy(.completed, items: [arrived, locked])
        ended.action = .moveTo
        ended.result?.action = .moveTo
        ended.result?.mode = .cut

        fixture.session.receive(
            .adopted(WriteOperationAdoption(operationId: "other-op", event: ended, clearsCutClipboard: gatheredAt)))

        #expect(fixture.clipboard.contents == fresh)
        #expect(fixture.clipboard.previous == nil)
        let result = try #require(ended.result)
        let followed = ClipboardRules.followThroughWrite(
            fixture.clipboard.contents,
            ClipboardWrite(action: result.action, mode: result.mode, items: result.items.map(\.effect)))
        #expect(followed.sourcePaths == ["/Users/demo/Folder/elsewhere.txt", "/Users/demo/new.txt"])
        #expect(followed.mode == .copy)
        #expect(followed.capturedAt == fresh.capturedAt)
    }

    /// Two clipboards made since the paste started, the first of them built with Add and so kept to be put back:
    /// neither is the paste's, and its end leaves both as they are.
    @Test func aClipboardKeptThatIsNotThePastesIsLeftAsItIs() throws {
        let fixture = Fixture()
        fixture.clipboard.set(
            ClipboardRules.set(.cut, ["/Users/demo/elsewhere.txt"], capturedAt: "2026-10-08T09:00:00.000Z"), from: nil)
        // While it is pasted: the items are gathered again, then a Copy replaces them.
        fixture.clipboard.replace(with: gathered(), from: nil)
        let fresh = ClipboardRules.set(.copy, ["/Users/demo/new.txt"], capturedAt: "2026-10-08T10:01:00.000Z")
        #expect(fixture.clipboard.replace(with: fresh, from: nil) == gathered())
        var ended = otherWindowsCopy(.completed, items: [arrived])
        ended.action = .moveTo
        ended.result?.action = .moveTo
        ended.result?.mode = .cut

        fixture.session.receive(
            .adopted(
                WriteOperationAdoption(
                    operationId: "other-op", event: ended, clearsCutClipboard: "2026-10-08T09:00:00.000Z")))

        #expect(fixture.clipboard.contents == fresh)
        #expect(fixture.clipboard.previous == gathered())
    }

    /// A paste started here of copied and cut items, which got to all but one: what it pasted, copied and moved,
    /// leaves the clipboard, and the one it didn't get to stays, still cut. Pasted again, that one moves and the
    /// clipboard is empty.
    @Test func aPasteOfBothStartedHereLeavesOnlyWhatItDidntGetTo() async throws {
        let fixture = Fixture()
        fixture.clipboard.set(gathered(), from: nil)
        let first = await fixture.actions.pasteFromClipboard(into: "/Users/demo/Folder")
        guard case .queued(let operationId) = first else {
            Issue.record("the paste didn't start: \(first)")
            return
        }
        fixture.service.emit(
            pasteEnded(
                operationId, mode: .copy,
                [("copied.txt", .completed, .copy), ("elsewhere.txt", .completed, .cut), ("locked.txt", .failed, .cut)]
            ))
        #expect(await waitUntil { fixture.session.card == nil })
        #expect(fixture.clipboard.contents.sourcePaths == ["/Users/demo/locked.txt"])
        #expect(fixture.clipboard.contents.mode == .cut)
        #expect(fixture.clipboard.contents.capturedAt == gatheredAt)

        let again = await fixture.actions.pasteFromClipboard(into: "/Users/demo/Folder")
        guard case .queued(let second) = again else {
            Issue.record("the second paste didn't start: \(again)")
            return
        }
        fixture.service.emit(pasteEnded(second, mode: .cut, [("locked.txt", .completed, nil)]))
        #expect(await waitUntil { fixture.clipboard.contents == .empty })
        await fixture.coordinator.shutDown(maxWaitMs: 0)
    }

    /// A paste started here of copied and cut items that moved none of them (the cut one failed) used nothing up:
    /// the clipboard stays whole, its copied item to be pasted again and its cut one to be tried again.
    @Test func aPasteOfBothStartedHereThatMovedNothingLeavesTheClipboardWhole() async throws {
        let fixture = Fixture()
        let both = ClipboardRules.setMode(
            ClipboardRules.set(.copy, ["/Users/demo/copied.txt", "/Users/demo/locked.txt"], capturedAt: gatheredAt),
            ["/Users/demo/locked.txt"], to: .cut, at: gatheredAt)
        fixture.clipboard.set(both, from: nil)
        let outcome = await fixture.actions.pasteFromClipboard(into: "/Users/demo/Folder")
        guard case .queued(let operationId) = outcome else {
            Issue.record("the paste didn't start: \(outcome)")
            return
        }
        fixture.service.emit(
            pasteEnded(operationId, mode: .copy, [("copied.txt", .completed, .copy), ("locked.txt", .failed, .cut)]))
        #expect(await waitUntil { fixture.session.card == nil })
        #expect(fixture.clipboard.contents == both)
        await fixture.coordinator.shutDown(maxWaitMs: 0)
    }

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

        fixture.session.receive(.adopted(WriteOperationAdoption(operationId: "other-op", event: running)))
        #expect(fixture.session.card?.stage == .running)
        // Told again (asked after the message): taken once.
        fixture.session.receive(.adopted(WriteOperationAdoption(operationId: "other-op", event: ended)))
        #expect(!fixture.events.contains { if case .ended = $0 { true } else { false } })

        // Its end comes as any other progress does, and is shown once.
        fixture.session.receive(.progress(ended))
        #expect(fixture.events.filter { if case .ended = $0 { true } else { false } }.count == 1)
    }

    @Test func showsItHereOnceThisWindowTakesItOverAndLeavesTheSelectionAlone() throws {
        let fixture = Fixture()
        fixture.session.otherWindowProgress(otherWindowsCopy(.running))
        fixture.host.selectedPaths = ["/Users/demo/Folder/keep.txt"]
        var running = otherWindowsCopy(.running)
        running.action = .paste

        fixture.session.receive(.adopted(WriteOperationAdoption(operationId: "other-op", event: running)))
        #expect(fixture.session.foreign == nil)
        #expect(fixture.session.card?.stage == .running)

        // The copy arrives in the folder on screen.
        fixture.session.receive(.progress(otherWindowsCopy(.completed, items: [arrived])))

        #expect(fixture.session.card == nil)
        // What it would have selected belonged to the window that started it.
        #expect(fixture.host.refreshes.count == 1)
        #expect(fixture.host.refreshes[0].path == "/Users/demo/Folder")
        #expect(fixture.host.refreshes[0].selecting == nil)
        // It is over: this window may start the next one.
        #expect(!fixture.session.isWriteLocked)
    }

    // An operation this window started leaves the selection alone when the person picked something
    // else while it ran, when results are on screen, and when it landed in another folder than the one on screen.
    @Test func leavesTheSelectionAloneWhenItWasPickedOrIsNotOnScreen() async throws {
        enum Meanwhile: CaseIterable { case nothing, picked, searching, elsewhere }
        for meanwhile in Meanwhile.allCases {
            let fixture = Fixture()
            fixture.host.selectedPaths = ["/Users/demo/Folder/keep.txt"]
            let report = try await fixture.coordinator.analyze(
                CopyPasteAnalysisRequest(
                    mode: .copy, sourcePaths: ["/Users/demo/elsewhere.txt"],
                    destinationDirectoryPath: "/Users/demo/Folder"), window: fixture.session, signal: StopSignal())
            fixture.session.applyCard(
                WriteOperationCardState(action: .paste, stage: .starting, targetPath: "/Users/demo/Folder"))
            let handle = try fixture.coordinator.startCopyPaste(
                CopyPasteStart(report: report, policy: WindowWriteActions.safePolicy), window: fixture.session)
            fixture.session.adoptWriteOperation(handle.operationId)
            switch meanwhile {
            case .nothing: break
            case .picked: fixture.host.selectedPaths = ["/Users/demo/Folder/other.txt"]
            case .searching: fixture.host.isSearching = true
            case .elsewhere: fixture.host.currentPath = "/Users/demo"
            }
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
                                sourcePath: "/Users/demo/elsewhere.txt",
                                destinationPath: "/Users/demo/Folder/elsewhere.txt", sourceKind: .file,
                                status: .completed, error: nil)
                        ], error: nil)))
            let refresh = try #require(fixture.host.refreshes.last)
            #expect(refresh.selecting == (meanwhile == .nothing ? ["/Users/demo/Folder/elsewhere.txt"] : nil))
            await fixture.coordinator.shutDown(maxWaitMs: 0)
        }
    }

    // The operation's progress shows whichever tab is in front; what arrived is selected only in the
    // tab it was started from.
    @Test func showsARunningOperationInEveryTabAndSelectsWhatArrivedOnlyWhereItStarted() async throws {
        for switchesTab in [true, false] {
            let fixture = Fixture()
            let started = Task {
                try await fixture.coordinator.analyze(
                    CopyPasteAnalysisRequest(
                        mode: .copy, sourcePaths: ["/Users/demo/source.txt"],
                        destinationDirectoryPath: "/Users/demo/Folder"), window: fixture.session, signal: StopSignal())
            }
            let report = try await started.value
            fixture.session.applyCard(
                WriteOperationCardState(action: .paste, stage: .starting, targetPath: "/Users/demo/Folder"))
            let handle = try fixture.coordinator.startCopyPaste(
                CopyPasteStart(report: report, policy: WindowWriteActions.safePolicy), window: fixture.session)
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

    // A copy to the other pane takes a while, and the other pane becomes the active one meanwhile. What the copy
    // made is selected there, unless something was picked in that pane since the copy started.
    @Test func whatAWriteMadeIsNotSelectedOverAPickMadeInThePaneThatBecameActiveMeanwhile() {
        let source = "/Users/demo/Folder/a.txt"
        let made = "/Users/demo/Other/a.txt"
        for picks in [false, true] {
            let fixture = Fixture()
            let host = fixture.host
            host.panes = [
                WritePaneSelection(paneID: 1, directoryPath: "/Users/demo/Folder", paths: [source]),
                WritePaneSelection(paneID: 2, directoryPath: "/Users/demo/Other", paths: []),
            ]
            host.activate(1)
            fixture.session.applyCard(
                WriteOperationCardState(
                    action: .copyTo, stage: .starting, targetPath: "/Users/demo/Other", totalItemCount: 1))
            fixture.session.adoptWriteOperation("copy-op")

            if picks { host.panes?[1].paths = ["/Users/demo/Other/picked.txt"] }
            host.activate(2)
            let result = LocalWriteResults.result(
                operationId: "copy-op", action: .copyTo, targetPath: "/Users/demo/Other",
                startedAt: Date(timeIntervalSince1970: 0), finishedAt: Date(timeIntervalSince1970: 1),
                totalItemCount: 1, completedItemCount: 1,
                items: [WriteOperationItem(sourcePath: source, destinationPath: made, status: .completed)],
                status: .completed, error: nil)
            fixture.session.handleProgress(
                WriteOperationEvent(
                    operationId: "copy-op", action: .copyTo, status: .completed, totalItemCount: 1, result: result))

            let refresh = fixture.host.refreshes.last
            #expect(refresh?.path == "/Users/demo/Other", "picks: \(picks)")
            #expect(refresh?.selecting == (picks ? nil : [made]), "picks: \(picks)")
        }
    }
}
