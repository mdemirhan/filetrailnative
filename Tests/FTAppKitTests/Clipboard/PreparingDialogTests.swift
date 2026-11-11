// "Preparing to Paste…" comes only when the analysis is slow and never flashes, on the timers moved by hand
import AppKit
import FTFoundation
import Foundation
import Testing
import os

@testable import FTAppKit
@testable import FTOperations

/// A write service whose review runs until the test says how it ended, or ends at once as `endsAtOnce` says; Stop
/// ends it.
private final class HeldAnalysisService: CoordinatorWriteService, @unchecked Sendable {
    private struct State {
        var reviews = 0
        var stops = 0
        var waiting: CheckedContinuation<CopyPasteAnalysisReport, any Error>?
    }

    var endsAtOnce: Result<CopyPasteAnalysisReport, any Error>?
    private let state = OSAllocatedUnfairLock(initialState: State())

    /// How many reviews began.
    var reviews: Int { state.withLock { $0.reviews } }
    /// How many times a review was told to stop.
    var stops: Int { state.withLock { $0.stops } }

    func subscribe(_ listener: @escaping @Sendable (CopyPasteProgressEvent) -> Void) -> @Sendable () -> Void { {} }

    func analyze(_ request: CopyPasteAnalysisRequest, signal: StopSignal) async throws -> CopyPasteAnalysisReport {
        if let endsAtOnce {
            state.withLock { $0.reviews += 1 }
            return try endsAtOnce.get()
        }
        return try await withCheckedThrowingContinuation { continuation in
            state.withLock {
                $0.reviews += 1
                $0.waiting = continuation
            }
            signal.onStop { [self] in
                state.withLock { $0.stops += 1 }
                answer(.failure(StopError()))
            }
        }
    }

    /// The review under way ends so.
    func answer(_ outcome: Result<CopyPasteAnalysisReport, any Error>) {
        let waiting = state.withLock { state in
            defer { state.waiting = nil }
            return state.waiting
        }
        waiting?.resume(with: outcome)
    }

    func startCopyPaste(
        report: CopyPasteAnalysisReport, policy: CopyPastePolicy, overrides: [CopyPasteNodeOverride]?
    ) throws -> CopyPasteOperationHandle {
        CopyPasteOperationHandle(operationId: "copy-op-1", status: .queued)
    }

    func resolveRuntimeConflict(
        _ operationId: String, conflictId: String, action: CopyPasteChoice, applyToRemaining: Bool
    ) -> Bool { true }

    func cancelOperation(_ operationId: String) -> Bool { true }
}

@MainActor
private final class FakeHost: WriteSessionHost {
    var isClosed = false
    var activeTabID: Int? = 1
    var currentPath = "/Users/demo/Folder"
    var selectedPaths: [String] = []
    var isSearching = false
    var selectedTreePath: String?

    func applyWriteEnd(_ refresh: WriteEndRefresh) {}
    func followMovesOnScreen(_ moves: [PathMove]) {}
    func writeLockChanged() {}
}

/// The dialog as a record: when it was put up and taken away, and its Cancel.
@MainActor
private final class FakeSheet {
    var shown = 0
    var dismissed = 0
    var titles: [String] = []
    var pressCancel: (() -> Void)?
    var canShow = true

    func present(_ onCancel: @escaping () -> Void) -> (() -> Void)? {
        guard canShow else { return nil }
        shown += 1
        pressCancel = onCancel
        return { [weak self] in self?.dismissed += 1 }
    }
}

/// The notices the window put up.
@MainActor
private final class Notices {
    var messages: [String] = []
}

/// Whether a `finish()` under way has answered yet.
@MainActor
private final class Finishing {
    private(set) var answer: Bool?
    private var task: Task<Void, Never>?

    init(_ dialog: PreparingDialog) {
        task = Task { @MainActor [weak self] in
            let cancelled = await dialog.finish()
            self?.answer = cancelled
        }
    }

    func settled() async -> Bool? {
        await task?.value
        return answer
    }
}

@MainActor
@Suite struct PreparingDialogTests {
    private let timers = ManualTimers()
    private let sheet = FakeSheet()
    private let notices = Notices()

    private func dialog(onCancel: @escaping () -> Void = {}) -> PreparingDialog {
        PreparingDialog(timers: timers, present: { [sheet] in sheet.present($0) }, onCancel: onCancel)
    }

    // An analysis over within 500 ms never shows the dialog, and nothing waits.
    @Test func aFastAnalysisShowsNoDialog() async {
        let preparing = dialog()
        timers.advance(0.499)
        #expect(sheet.shown == 0)
        let cancelled = await preparing.finish()
        #expect(!cancelled)
        timers.advance(10)
        #expect(sheet.shown == 0 && sheet.dismissed == 0)
    }

    // Still running at 500 ms, the dialog comes; Cancel stops the analysis.
    @Test func aSlowAnalysisShowsTheDialogAndCancelStopsIt() async throws {
        var cancels = 0
        let preparing = dialog { cancels += 1 }
        timers.advance(0.5)
        #expect(sheet.shown == 1 && preparing.isShowing)
        let pressCancel = try #require(sheet.pressCancel)
        pressCancel()
        #expect(cancels == 1)
        // The press took the sheet away, and nothing keeps it up: the flow goes on at once.
        let cancelled = await preparing.finish()
        #expect(cancelled)
        #expect(sheet.dismissed == 0)
    }

    // Once up, the dialog stays 300 ms, however soon the analysis ends.
    @Test func theDialogStaysUpTheMinimumTime() async {
        let preparing = dialog()
        timers.advance(0.5)
        let finishing = Finishing(preparing)
        await Task.yield()
        timers.advance(0.299)
        await Task.yield()
        #expect(finishing.answer == nil && sheet.dismissed == 0)
        timers.advance(0.01)
        let answer = await finishing.settled()
        #expect(answer == false)
        #expect(sheet.dismissed == 1)
    }

    // A dialog up longer than the minimum goes as soon as the analysis ends.
    @Test func aLongAnalysisTakesTheDialogAwayAtOnce() async {
        let preparing = dialog()
        timers.advance(2)
        let cancelled = await preparing.finish()
        #expect(!cancelled)
        #expect(sheet.dismissed == 1)
    }

    // Cancel while the dialog only stays up (the analysis has ended) still cancels.
    @Test func cancelDuringTheMinimumTimeCancels() async throws {
        var cancels = 0
        let preparing = dialog { cancels += 1 }
        timers.advance(0.5)
        let finishing = Finishing(preparing)
        await Task.yield()
        let pressCancel = try #require(sheet.pressCancel)
        pressCancel()
        let answer = await finishing.settled()
        #expect(answer == true)
        #expect(cancels == 1 && sheet.dismissed == 0)
    }

    // No room for it when it is due (another sheet is up): nothing stays or waits.
    @Test func aDialogThatCannotShowHoldsNothingUp() async {
        sheet.canShow = false
        let preparing = dialog()
        timers.advance(0.5)
        #expect(!preparing.isShowing)
        let cancelled = await preparing.finish()
        #expect(!cancelled)
    }

    // All four titles.
    @Test func hasATitleForEachAction() {
        #expect(PreparingSheet.title(.paste) == "Preparing to Paste\u{2026}")
        #expect(PreparingSheet.title(.moveTo) == "Preparing to Move\u{2026}")
        #expect(PreparingSheet.title(.copyTo) == "Preparing to Copy\u{2026}")
        #expect(PreparingSheet.title(.duplicate) == "Preparing to Duplicate\u{2026}")
    }

    // MARK: The copy-like flow

    private func makeActions(_ service: HeldAnalysisService) -> (WindowWriteActions, () -> Void) {
        let host = FakeHost()
        let coordinator = WriteCoordinator(
            writeService: service, fileSystem: NativeWriteFileSystem(), options: WriteCoordinatorOptions())
        let session = ExplorerWriteSession(coordinator: coordinator, host: host, clipboard: SharedClipboard())
        var dialogs = WriteDialogs()
        dialogs.show = { [notices] _, message, _ in notices.messages.append(message) }
        let actions = WindowWriteActions(session: session, tab: nil, dialogs: dialogs)
        actions.preparingTimers = timers
        actions.presentPreparing = { [sheet] action, _, onCancel in
            sheet.titles.append(PreparingSheet.title(action))
            return sheet.present(onCancel)
        }
        return (actions, { withExtendedLifetime((host, coordinator)) {} })
    }

    // A quick check goes straight on: no dialog, and the flow goes on (here to its report).
    @Test func aQuickCopyGoesOnWithoutTheDialog() async {
        let service = HeldAnalysisService()
        service.endsAtOnce = .failure(OperationError(""))
        let (actions, keep) = makeActions(service)
        let outcome = await actions.copyTo(["/Users/demo/a.txt"], destination: "/Users/demo/Folder")
        keep()
        if case .error = outcome {} else { Issue.record("\(outcome)") }
        #expect(sheet.shown == 0 && sheet.titles.isEmpty)
    }

    // A slow check shows the dialog named for the action, and its Cancel stops the analysis and the flow.
    @Test func aSlowCopyShowsTheDialogAndCancelEndsTheFlow() async throws {
        let service = HeldAnalysisService()
        let (actions, keep) = makeActions(service)
        let run = Task { @MainActor in
            await actions.copyTo(["/Users/demo/a.txt"], destination: "/Users/demo/Folder")
        }
        let reviewing = await waitUntil { service.reviews > 0 }
        #expect(reviewing)
        #expect(sheet.shown == 0)
        timers.advance(PreparingDialog.showDelay)
        #expect(sheet.titles == ["Preparing to Copy\u{2026}"])
        let pressCancel = try #require(sheet.pressCancel)
        pressCancel()
        #expect(service.stops == 1)
        let outcome = await run.value
        #expect(outcome == .cancelled)
        #expect(actions.session.card == nil)
        keep()
    }

    // A check that ended while the dialog stays up doesn't start the write once Cancel was pressed.
    @Test func cancelWhileTheDialogStaysUpEndsTheFlow() async throws {
        let service = HeldAnalysisService()
        let (actions, keep) = makeActions(service)
        let run = Task { @MainActor in
            await actions.moveTo(["/Users/demo/a.txt"], destination: "/Users/demo/Folder", initiator: nil)
        }
        let reviewing = await waitUntil { service.reviews > 0 }
        #expect(reviewing)
        timers.advance(PreparingDialog.showDelay)
        #expect(sheet.titles == ["Preparing to Move\u{2026}"])
        service.answer(.failure(OperationError("")))
        // The window has the review's end, and waits for the dialog's minimum time.
        let session = actions.session
        let ended = await waitUntil { session.coordinator.watchCount(session) == 0 }
        #expect(ended)
        let pressCancel = try #require(sheet.pressCancel)
        pressCancel()
        let outcome = await run.value
        #expect(outcome == .cancelled)
        keep()
    }

    // Its window closing, or the app quitting, stops the check: the dialog goes at once, and nothing is said.
    @Test(arguments: [false, true])
    func closingTheWindowOrQuittingEndsTheFlow(quitting: Bool) async throws {
        let service = HeldAnalysisService()
        let (actions, keep) = makeActions(service)
        let run = Task { @MainActor in
            await actions.copyTo(["/Users/demo/a.txt"], destination: "/Users/demo/Folder")
        }
        let reviewing = await waitUntil { service.reviews > 0 }
        #expect(reviewing)
        timers.advance(PreparingDialog.showDelay)
        #expect(sheet.shown == 1)

        let coordinator = actions.session.coordinator
        if quitting {
            await coordinator.shutDown(maxWaitMs: 0)
        } else {
            coordinator.windowClosed(actions.session)
        }

        #expect(service.stops == 1)
        let outcome = await run.value
        #expect(outcome == .cancelled)
        #expect(sheet.dismissed == 1)
        #expect(notices.messages.isEmpty)
        #expect(actions.session.card == nil)
        keep()
    }
}
