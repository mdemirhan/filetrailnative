// "Preparing to Paste…" comes only when the analysis is slow and never flashes (D-018; the dialog itself is
// components/AppDialogs.tsx:290-308), on the timers moved by hand
import AppKit
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit
@testable import FTOperations

/// A write service whose analysis runs until the test says how it ended; Cancel ends it.
private final class HeldAnalysisService: CoordinatorWriteService, @unchecked Sendable {
    var status = CopyPasteAnalysisJobStatus.analyzing
    var isDone = false
    var polls = 0
    var cancels = 0

    func subscribe(_ listener: @escaping @Sendable (CopyPasteProgressEvent) -> Void) -> @Sendable () -> Void { {} }

    func startCopyPasteAnalysis(_ request: CopyPasteAnalysisRequest, keep: Set<String>) throws
        -> CopyPasteAnalysisStartHandle
    {
        CopyPasteAnalysisStartHandle(analysisId: "analysis-1", status: .queued)
    }

    func getCopyPasteAnalysisUpdate(_ analysisId: String) throws -> CopyPasteAnalysisUpdate {
        polls += 1
        return CopyPasteAnalysisUpdate(analysisId: analysisId, status: status, done: isDone, report: nil, error: nil)
    }

    func cancelCopyPasteAnalysis(_ analysisId: String) -> Bool {
        cancels += 1
        status = .cancelled
        isDone = true
        return true
    }

    func startCopyPaste(_ start: CopyPasteExecutionRequest, keep: Set<String>) throws -> CopyPasteOperationHandle {
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

    private func dialog(onCancel: @escaping () -> Void = {}) -> PreparingDialog {
        PreparingDialog(timers: timers, present: { [sheet] in sheet.present($0) }, onCancel: onCancel)
    }

    // F-863 (D-018): an analysis over within 500 ms never shows the dialog, and nothing waits.
    // T-43d49580
    @Test func aFastAnalysisShowsNoDialog() async {
        let preparing = dialog()
        timers.advance(0.499)
        #expect(sheet.shown == 0)
        let cancelled = await preparing.finish()
        #expect(!cancelled)
        timers.advance(10)
        #expect(sheet.shown == 0 && sheet.dismissed == 0)
    }

    // F-863 (D-018): still running at 500 ms, the dialog comes; Cancel stops the analysis.
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

    // F-863 (D-018): once up, the dialog stays 300 ms, however soon the analysis ends.
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

    // F-863: all four titles.
    // B-CLIP-066
    @Test func hasATitleForEachAction() {
        #expect(PreparingSheet.title(.paste) == "Preparing to Paste\u{2026}")
        #expect(PreparingSheet.title(.moveTo) == "Preparing to Move\u{2026}")
        #expect(PreparingSheet.title(.copyTo) == "Preparing to Copy\u{2026}")
        #expect(PreparingSheet.title(.duplicate) == "Preparing to Duplicate\u{2026}")
    }

    // MARK: The copy-like flow

    private func makeActions(_ service: HeldAnalysisService) -> (WindowWriteActions, () -> Void) {
        let host = FakeHost()
        let coordinator = WriteCoordinator(writeService: service, options: WriteCoordinatorOptions())
        let session = ExplorerWriteSession(coordinator: coordinator, host: host, clipboard: SharedClipboard())
        var dialogs = WriteDialogs()
        dialogs.show = { _, _, _ in }
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
        service.status = .complete
        service.isDone = true
        let (actions, keep) = makeActions(service)
        let outcome = await actions.copyTo(["/Users/demo/a.txt"], destination: "/Users/demo/Folder")
        keep()
        if case .error = outcome {} else { Issue.record("\(outcome)") }
        #expect(sheet.shown == 0 && sheet.titles.isEmpty)
    }

    // A slow check shows the dialog named for the action, and its Cancel stops the analysis and the flow.
    // B-CLIP-066 B-CLIP-067 T-3862a35c T-43d49580 T-8c905b93 T-b0ae40c8
    @Test func aSlowCopyShowsTheDialogAndCancelEndsTheFlow() async throws {
        let service = HeldAnalysisService()
        let (actions, keep) = makeActions(service)
        let run = Task { @MainActor in
            await actions.copyTo(["/Users/demo/a.txt"], destination: "/Users/demo/Folder")
        }
        let polled = await waitUntil { service.polls > 0 }
        #expect(polled)
        #expect(sheet.shown == 0)
        timers.advance(PreparingDialog.showDelay)
        #expect(sheet.titles == ["Preparing to Copy\u{2026}"])
        let pressCancel = try #require(sheet.pressCancel)
        pressCancel()
        #expect(service.cancels == 1)
        let outcome = await run.value
        #expect(outcome == .cancelled)
        #expect(actions.session.card == nil)
        keep()
    }

    // A check that ended while the dialog stays up doesn't start the write once Cancel was pressed.
    // B-CLIP-067 T-1152bed3
    @Test func cancelWhileTheDialogStaysUpEndsTheFlow() async throws {
        let service = HeldAnalysisService()
        let (actions, keep) = makeActions(service)
        let run = Task { @MainActor in
            await actions.moveTo(["/Users/demo/a.txt"], destination: "/Users/demo/Folder", initiator: nil)
        }
        let polled = await waitUntil { service.polls > 0 }
        #expect(polled)
        timers.advance(PreparingDialog.showDelay)
        #expect(sheet.titles == ["Preparing to Move\u{2026}"])
        service.status = .complete
        service.isDone = true
        let polls = service.polls
        let polledAgain = await waitUntil { service.polls > polls }
        #expect(polledAgain)
        await Task.yield()
        let pressCancel = try #require(sheet.pressCancel)
        pressCancel()
        let outcome = await run.value
        #expect(outcome == .cancelled)
        keep()
    }
}
