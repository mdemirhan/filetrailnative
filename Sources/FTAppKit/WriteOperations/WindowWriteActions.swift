// Port of the copy-like starts of apps/desktop/src/renderer/hooks/useExplorerActions.ts (analyzeCopyLikeRequest,
// executeCopyLikePlan, cancelWriteOperation, resolveRuntimeConflict, showWriteOperationBusyNotice, the clipboard's
// Copy and Cut): what one tab asks of the file operations. The flow around them (the review sheet, the progress card,
// the toasts) is P5-08's; rename, New Folder, Trash, Delete, Empty Trash, Undo, Redo and batch rename are P3-06 to
// P3-08's, and say so until then.
import AppKit
import FTFoundation
import FTOperations

/// How a copy-like start went (`CopyLikePreStartOutcome`).
enum CopyLikeOutcome: Equatable, Sendable {
    /// It runs, as this operation.
    case queued(operationId: String)
    /// The analysis found clashes: the review sheet decides (P5-08), then `startCopyPaste`.
    case review(CopyPasteAnalysisReport)
    /// Something stood in the way; nothing was changed.
    case blocked(message: String)
    case error(message: String)
    case cancelled
}

/// One tab's file operations, through its explorer window's side (`ExplorerWriteSession`). One method per action.
@MainActor
final class WindowWriteActions {
    /// `ANALYSIS_POLL_INTERVAL_MS`.
    static let analysisPollIntervalMs: UInt64 = 120
    /// `SAFE_COPY_PASTE_POLICY`: pressing the primary button without changing anything never loses data.
    static let safePolicy = CopyPastePolicy(file: .skip, directory: .skip, mismatch: .skip)

    let session: ExplorerWriteSession
    weak var tab: MainWindowController?
    let dialogs: WriteDialogs

    init(session: ExplorerWriteSession, tab: MainWindowController?, dialogs: WriteDialogs = WriteDialogs()) {
        self.session = session
        self.tab = tab
        self.dialogs = dialogs
    }

    private var coordinator: WriteCoordinator { session.coordinator }
    private var window: NSWindow? { tab?.window }

    /// Tells `handler` of the window's progress, questions and results (P5-08 connects them to the card and toasts).
    func observe(_ handler: @escaping (WindowWriteEvent) -> Void) -> ExplorerWindowObservation {
        session.observe(handler)
    }

    // MARK: Busy

    /// `isWriteOperationInFlight` with `showWriteOperationBusyNotice`: true (and the notice shown) when a write runs
    /// here or in another window. When only another window's stands in the way, the coordinator is asked first: this
    /// window may have missed its end, and then lets go of it instead; nothing is shown, and the next try goes ahead.
    func refuseWhileBusy(_ action: WriteStartAction) -> Bool {
        guard session.isWriteLocked else { return false }
        if session.card == nil, session.releaseEndedForeign() {
            return true
        }
        dialogs.showBusy(action, in: window)
        return true
    }

    // MARK: Copy, Cut and Paste

    /// Copy or Cut (`runCopyClipboardAction`): the selected items go on the app's clipboard.
    func putOnClipboard(_ mode: CopyPasteMode, paths: [String], entries: [String: ClipboardSourceEntry] = [:]) {
        guard !paths.isEmpty, let clipboard = session.clipboard else { return }
        let capturedAt = ISO8601DateFormatter.withFractionalSeconds.string(from: Date())
        clipboard.set(
            .ready(mode: mode, sourcePaths: paths, sourceEntries: entries, capturedAt: capturedAt),
            from: tab?.windowID)
        tab?.clipboardChanged()
    }

    /// Paste: what the clipboard holds into `destination` (the folder on screen). A cut is a Move To
    /// (`startMoveToDestination`): its notices, card and result say so; it is cleared once the paste moved something.
    @discardableResult
    func paste(into destination: String) async -> CopyLikeOutcome {
        guard case .ready(let mode, let sources, _, let capturedAt) = session.clipboard?.contents else {
            return .cancelled
        }
        let isCut = mode == .cut
        return await copyLike(
            mode: isCut ? .cut : .copy, sources: sources, destination: destination, action: isCut ? .moveTo : .paste,
            clearsCutClipboard: isCut ? capturedAt : nil)
    }

    /// Copy To (a drag that copies).
    @discardableResult
    func copyTo(_ sources: [String], destination: String) async -> CopyLikeOutcome {
        await copyLike(mode: .copy, sources: sources, destination: destination, action: .copyTo)
    }

    /// Move To.
    @discardableResult
    func moveTo(_ sources: [String], destination: String) async -> CopyLikeOutcome {
        await copyLike(mode: .cut, sources: sources, destination: destination, action: .moveTo)
    }

    /// Duplicate (`startDuplicatePaths`): a copy of each item in `folder`, the folder on screen.
    @discardableResult
    func duplicate(_ sources: [String], in folder: String) async -> CopyLikeOutcome {
        guard !sources.isEmpty, !folder.isEmpty else { return .cancelled }
        return await copyLike(mode: .copy, sources: sources, destination: folder, action: .duplicate)
    }

    /// `analyzeCopyLikeRequest`: checks what a copy-like write would do; with nothing to review, starts it with the
    /// safe policy.
    func copyLike(
        mode: FTOperations.CopyPasteMode, sources: [String], destination: String, action: WriteOperationAction,
        clearsCutClipboard: String? = nil
    ) async -> CopyLikeOutcome {
        if refuseWhileBusy(.operation(action)) { return .cancelled }
        session.applyCard(
            WriteOperationCardState(
                action: action, stage: .analyzing, targetPath: destination, currentSourcePath: sources.first))
        do {
            let handle = try await coordinator.startAnalysis(
                CopyPasteAnalysisRequest(mode: mode, sourcePaths: sources, destinationDirectoryPath: destination),
                window: session)
            var update = try coordinator.analysisUpdate(handle.analysisId, window: session)
            while !update.done {
                try await Task.sleep(nanoseconds: Self.analysisPollIntervalMs * 1_000_000)
                update = try coordinator.analysisUpdate(handle.analysisId, window: session)
            }
            if update.status == .cancelled {
                session.applyCard(nil)
                return .cancelled
            }
            guard update.status == .complete, let report = update.report else {
                session.applyCard(nil)
                let message = update.error ?? Self.preparationFailure(action)
                dialogs.showRefusal(.operation(action), message: message, in: window)
                return .error(message: message)
            }
            if let issue = report.issues.first {
                session.applyCard(nil)
                // P5-08 leaves out the items the issues are about and goes on with the rest.
                dialogs.showRefusal(.operation(action), message: issue.message, in: window)
                return .blocked(message: issue.message)
            }
            if Self.hasConflicts(report) {
                session.applyCard(nil)
                return .review(report)
            }
            return await startCopyPaste(
                report, policy: Self.safePolicy, action: action, clearsCutClipboard: clearsCutClipboard)
        } catch {
            session.applyCard(nil)
            return refused(.operation(action), error)
        }
    }

    /// `executeCopyLikePlan`: starts a paste from a finished analysis, with the review's choices.
    func startCopyPaste(
        _ report: CopyPasteAnalysisReport, policy: CopyPastePolicy, action: WriteOperationAction,
        overrides: [CopyPasteNodeOverride] = [], clearsCutClipboard: String? = nil
    ) async -> CopyLikeOutcome {
        session.applyCard(
            WriteOperationCardState(
                action: action, stage: .starting, targetPath: report.destinationDirectoryPath,
                totalItemCount: report.summary.totalNodeCount, totalBytes: report.summary.totalBytes,
                currentSourcePath: report.sourcePaths.first))
        // Only the cut the paste was made from is cleared: one made since (while the review was open) stays.
        let clears = report.mode == .cut ? clearsCutClipboard : nil
        do {
            let handle = try await session.early.whileStarting {
                try coordinator.startCopyPaste(
                    CopyPasteStart(
                        analysisId: report.analysisId, action: action, policy: policy,
                        overrides: overrides.isEmpty ? nil : overrides, clearsCutClipboard: clears),
                    window: session)
            }
            if let clears {
                session.clearCutAfterMove(operationId: handle.operationId, capturedAt: clears)
            }
            session.adoptWriteOperation(handle.operationId)
            if session.activeOperationId == handle.operationId, session.card?.stage == .starting {
                session.applyCard(
                    WriteOperationCardState(
                        action: action, stage: .queued, targetPath: report.destinationDirectoryPath,
                        totalItemCount: report.summary.totalNodeCount, totalBytes: report.summary.totalBytes,
                        currentSourcePath: report.sourcePaths.first))
            }
            return .queued(operationId: handle.operationId)
        } catch {
            session.applyCard(nil)
            return refused(.operation(action), error)
        }
    }

    /// Stop (`cancelWriteOperation`): stops this window's operation. False when there is none, or it couldn't be
    /// stopped.
    @discardableResult
    func cancel() -> Bool {
        guard let operationId = session.activeOperationId else { return false }
        return coordinator.cancel(operationId, window: session)
    }

    /// Answers the question this window's operation waits on.
    @discardableResult
    func resolveConflict(_ conflictId: String, resolution: CopyPasteChoice, applyToRemaining: Bool = false) -> Bool {
        guard let operationId = session.activeOperationId else { return false }
        return coordinator.resolveConflict(
            operationId, conflictId: conflictId, resolution: resolution, applyToRemaining: applyToRemaining,
            window: session)
    }

    // MARK: Not ported yet (P3-06 to P3-08)

    func rename(_ path: String, to name: String) async throws -> CopyLikeOutcome {
        throw WriteActionNotAvailable(action: .operation(.rename))
    }

    func newFolder(in folder: String) async throws -> CopyLikeOutcome {
        throw WriteActionNotAvailable(action: .operation(.newFolder))
    }

    func trash(_ paths: [String]) async throws -> CopyLikeOutcome {
        throw WriteActionNotAvailable(action: .operation(.trash))
    }

    func deleteImmediately(_ paths: [String]) async throws -> CopyLikeOutcome {
        throw WriteActionNotAvailable(action: .operation(.deleteImmediately))
    }

    func emptyTrash() async throws -> CopyLikeOutcome {
        throw WriteActionNotAvailable(action: .emptyTrash)
    }

    func undo() async throws -> CopyLikeOutcome {
        throw WriteActionNotAvailable(action: .operation(.undo))
    }

    func redo() async throws -> CopyLikeOutcome {
        throw WriteActionNotAvailable(action: .operation(.redo))
    }

    func batchRename(_ items: [(sourcePath: String, destinationName: String)]) async throws -> CopyLikeOutcome {
        throw WriteActionNotAvailable(action: .operation(.batchRename))
    }

    // MARK: Helpers

    /// A start the coordinator refused: busy says so as every write does, anything else names its reason.
    private func refused(_ action: WriteStartAction, _ error: any Error) -> CopyLikeOutcome {
        let message = errorMessage(error)
        if message.contains(WriteServiceMessages.writeOperationBusy) {
            dialogs.showBusy(action, in: window)
            return .blocked(message: WriteDialogs.busyMessage)
        }
        dialogs.showRefusal(action, message: message, in: window)
        return .error(message: message)
    }

    /// `reportHasConflicts`.
    static func hasConflicts(_ report: CopyPasteAnalysisReport) -> Bool {
        report.summary.fileConflictCount > 0 || report.summary.directoryConflictCount > 0
            || report.summary.mismatchConflictCount > 0
    }

    /// `getCopyLikePreparationFailureMessage`.
    static func preparationFailure(_ action: WriteOperationAction) -> String {
        let verb =
            switch action {
            case .moveTo: "move"
            case .duplicate: "duplicate"
            case .copyTo: "copy"
            default: "paste"
            }
        return "File Trail couldn\u{2019}t check the items to \(verb). Nothing was changed."
    }
}

extension ISO8601DateFormatter {
    /// `new Date().toISOString()`.
    fileprivate static var withFractionalSeconds: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}
