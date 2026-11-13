// What one tab asks of the file operations, Undo and Redo among them. The review sheet, the progress card and the
// toasts around them are not here.
import AppKit
import FTFileSystem
import FTFoundation
import FTOperations

/// How a copy-like start went.
enum CopyLikeOutcome: Equatable, Sendable {
    /// It runs, as this operation.
    case queued(operationId: String)
    /// The review found clashes: the review sheet decides, then `startCopyPaste`.
    case review(CopyPasteAnalysisReport)
    /// Something stood in the way; nothing was changed.
    case blocked(message: String)
    case error(message: String)
    case cancelled
}

/// One tab's file operations, through its explorer window's side (`ExplorerWriteSession`). One method per action.
@MainActor
final class WindowWriteActions {
    /// Pressing the primary button without changing anything never loses data.
    static let safePolicy = CopyPastePolicy(file: .skip, directory: .skip, mismatch: .skip)

    let session: ExplorerWriteSession
    weak var tab: MainWindowController?
    let dialogs: WriteDialogs
    /// Which items of the last batch rename were folders, by the path asked for: the Rename sheet opens again on the
    /// items that weren't renamed, numbering each as it was.
    private(set) var batchRenameFolders: [String: Bool] = [:]
    /// The timers of "Preparing to Paste…".
    var preparingTimers: any TimerScheduling = TaskTimerScheduler()
    /// Puts up "Preparing to Paste…".
    var presentPreparing: @MainActor (WriteOperationAction, NSWindow?, @escaping () -> Void) -> (() -> Void)? =
        PreparingSheet.show

    init(session: ExplorerWriteSession, tab: MainWindowController?, dialogs: WriteDialogs = WriteDialogs()) {
        self.session = session
        self.tab = tab
        self.dialogs = dialogs
    }

    private var coordinator: WriteCoordinator { session.coordinator }
    private var window: NSWindow? { tab?.window }

    // MARK: Busy

    /// True (and the busy notice shown) when a write runs here or in another window. When only another window's stands
    /// in the way, the coordinator is asked first: this window may have missed its end, and then lets go of it instead;
    /// nothing is shown, and the next try goes ahead.
    func refuseWhileBusy(_ action: WriteStartAction) -> Bool {
        guard session.isWriteLocked else { return false }
        if session.card == nil, session.releaseEndedForeign() {
            return true
        }
        dialogs.showBusy(action, in: window)
        return true
    }

    // MARK: Copy, Cut and Paste

    /// Copy or Cut: the selected items go on the app's clipboard, replacing what was on it
    /// (each path once, empty ones dropped).
    func putOnClipboard(_ mode: ClipboardMode, paths: [String], entries: [String: ClipboardSourceEntry] = [:]) {
        guard !paths.isEmpty, let clipboard = session.clipboard else { return }
        let capturedAt = ISO8601DateFormatter.withFractionalSeconds.string(from: Date())
        clipboard.set(ClipboardRules.set(mode, paths, capturedAt: capturedAt, entries: entries), from: tab?.windowID)
        tab?.clipboardChanged()
    }

    /// Copy To (a drag that copies).
    @discardableResult
    func copyTo(_ sources: [String], destination: String, initiator: CopyLikeInitiator? = nil) async
        -> CopyLikeOutcome
    {
        await copyLike(mode: .copy, sources: sources, destination: destination, action: .copyTo, initiator: initiator)
    }

    /// Move To (and a drag that moves).
    @discardableResult
    func moveTo(_ sources: [String], destination: String, initiator: CopyLikeInitiator? = .moveDialog) async
        -> CopyLikeOutcome
    {
        await copyLike(mode: .cut, sources: sources, destination: destination, action: .moveTo, initiator: initiator)
    }

    /// Duplicate: a copy of each item in `folder`, the folder on screen.
    @discardableResult
    func duplicate(_ sources: [String], in folder: String) async -> CopyLikeOutcome {
        guard !sources.isEmpty, !folder.isEmpty else { return .cancelled }
        return await copyLike(mode: .copy, sources: sources, destination: folder, action: .duplicate)
    }

    /// Checks what a copy-like write would do; with nothing to review, starts it with
    /// `defaultPolicy` (the safe policy, or a retry's). Items a cut would leave where they already are (a drag, Move
    /// To or Paste) and, for a paste, clipboard items gone since they were copied are left out and the rest go;
    /// `onSourcesMissing` hears of the gone ones. With `reportsRefusals` off the caller says what went wrong.
    func copyLike(
        mode: FTOperations.CopyPasteMode, sources: [String], destination: String, action: WriteOperationAction,
        clearsCutClipboard: String? = nil, initiator: CopyLikeInitiator? = nil,
        onSourcesMissing: (([String]) -> Void)? = nil, reportsRefusals: Bool = true, checksBusy: Bool = true,
        defaultPolicy: CopyPastePolicy = WindowWriteActions.safePolicy, moveFromSearchResults: Bool = false
    ) async -> CopyLikeOutcome {
        if checksBusy, refuseWhileBusy(.operation(action)) { return .cancelled }
        session.applyCard(
            WriteOperationCardState(
                action: action, stage: .analyzing, targetPath: destination, currentSourcePath: sources.first))
        // Cancel in "Preparing to Paste…", and Stop on the card, stop the review itself.
        let signal = StopSignal()
        session.reviewStop = signal
        defer { if session.reviewStop === signal { session.reviewStop = nil } }
        var preparing: PreparingDialog?
        let outcome: Result<CopyPasteAnalysisReport, any Error>
        do {
            outcome = .success(
                try await coordinator.analyze(
                    CopyPasteAnalysisRequest(mode: mode, sourcePaths: sources, destinationDirectoryPath: destination),
                    window: session, signal: signal
                ) {
                    // "Preparing to Paste…" if this takes a while.
                    preparing = PreparingDialog(
                        timers: preparingTimers,
                        present: { [presentPreparing, weak self] in presentPreparing(action, self?.window, $0) },
                        onCancel: { signal.stop() })
                })
        } catch {
            guard preparing != nil else {
                // Refused before it began.
                session.applyCard(nil)
                return reportsRefusals ? refused(.operation(action), error) : refusal(error)
            }
            outcome = .failure(error)
        }
        // Stopped by Cancel, by the window closing or by quitting: the dialog goes at once, and nothing follows.
        if signal.isStopped {
            preparing?.dismiss()
            session.applyCard(nil)
            return .cancelled
        }
        if await preparing?.finish() == true {
            session.applyCard(nil)
            return .cancelled
        }
        let report: CopyPasteAnalysisReport
        switch outcome {
        case .success(let reviewed):
            report = reviewed
        case .failure(let error):
            session.applyCard(nil)
            let trimmed = errorMessage(error).trimmingCharacters(in: .whitespacesAndNewlines)
            let message = trimmed.isEmpty ? Self.preparationFailure(action) : trimmed
            if reportsRefusals { dialogs.showRefusal(.operation(action), message: message, in: window) }
            return .error(message: message)
        }
        if moveFromSearchResults { session.noteMoveFromSearchResults(analysisId: report.analysisId) }
        if !report.issues.isEmpty {
            return await leaveOut(
                report, mode: mode, sources: sources, destination: destination, action: action,
                clearsCutClipboard: clearsCutClipboard, initiator: initiator, onSourcesMissing: onSourcesMissing,
                reportsRefusals: reportsRefusals, defaultPolicy: defaultPolicy,
                moveFromSearchResults: moveFromSearchResults)
        }
        if Self.hasConflicts(report) {
            session.applyCard(nil)
            return .review(report)
        }
        return await startCopyPaste(
            report, policy: defaultPolicy, action: action, clearsCutClipboard: clearsCutClipboard,
            reportsRefusals: reportsRefusals)
    }

    /// Starts a paste from the report of a finished review, with the review's choices.
    func startCopyPaste(
        _ report: CopyPasteAnalysisReport, policy: CopyPastePolicy, action: WriteOperationAction,
        overrides: [CopyPasteNodeOverride] = [], clearsCutClipboard: String? = nil, reportsRefusals: Bool = true
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
                        report: report, action: action, policy: policy,
                        overrides: overrides.isEmpty ? nil : overrides, clearsCutClipboard: clears),
                    window: session)
            }
            if let clears {
                session.clearCutAfterMove(operationId: handle.operationId, capturedAt: clears)
            }
            session.noteStarted(analysisId: report.analysisId, operationId: handle.operationId)
            if TabDragDrop.externalDropAnalyses.remove(report.analysisId) != nil {
                TabDragDrop.externalDropOperations.insert(handle.operationId)
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
            return reportsRefusals ? refused(.operation(action), error) : refusal(error)
        }
    }

    /// Stop (`cancelWriteOperation`): stops this window's operation, or the review of one that hasn't started yet.
    /// False when there is neither, or it couldn't be stopped.
    @discardableResult
    func cancel() -> Bool {
        guard let operationId = session.activeOperationId else {
            guard let review = session.reviewStop, !review.isStopped else { return false }
            review.stop()
            return true
        }
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

    // MARK: Rename

    /// A name typed into the rename field. It is trimmed and checked first; one that begins
    /// with a dot asks (the field closes meanwhile); while another write runs the field closes and says so. A refusal
    /// stays in the field.
    func commitRename(path: String, typed: String, hiddenFilesShown: Bool) async
        -> MainWindowController.RenameOutcome
    {
        let currentName = NodePath.basename(path)
        // Spaces around a name are dropped (the coordinator drops them too), before anything is decided from it:
        // " .env" would hide the item as ".env" does.
        let name = InlineRenameRules.trimmedName(typed)
        if name.utf16.elementsEqual(currentName.utf16) { return .unchanged }
        if let error = ItemNames.error(for: name) { return .refused(error) }
        if refuseWhileBusy(.operation(.rename)) { return .unchanged }
        if LocalWriteRules.needsDotNameConfirmation(name, currentName: currentName, hiddenFilesShown: hiddenFilesShown)
        {
            let window = window
            Task { @MainActor in
                guard await dialogs.confirm(LocalWriteRules.dotNameQuestion, window) else { return }
                // A refusal now has no field to go under, so it gets a dialog of its own.
                if case .error(let message) = await rename(path, to: name) {
                    dialogs.showRefusal(.operation(.rename), message: message, in: window)
                }
            }
            return .unchanged
        }
        switch await rename(path, to: name) {
        case .queued: return .started
        case .error(let message): return .refused(message)
        default: return .unchanged
        }
    }

    /// Renames `path` to `name` (checked and asked about already). A refusal is `.error`, for the
    /// caller to show where the name was typed; while another write runs, the busy notice is shown.
    func rename(_ path: String, to name: String) async -> CopyLikeOutcome {
        await startLocal(
            .rename,
            card: WriteOperationCardState(
                action: .rename, stage: .starting, targetPath: path, totalItemCount: 1, currentSourcePath: path),
            showsRefusal: false
        ) { [coordinator, session] in
            try await coordinator.rename(sourcePath: path, destinationName: name, window: session)
        }
    }

    /// Rename for an item that has no row to type in (a folder of the tree): the name is asked for in a
    /// prompt, then goes as a typed name does; a refusal stays in the prompt with the reason.
    func renameInDialog(_ path: String, hiddenFilesShown: Bool) async {
        await dialogs.askName(.rename(path), window) { [weak self] typed in
            guard let self else { return .close }
            switch await self.commitRename(path: path, typed: typed, hiddenFilesShown: hiddenFilesShown) {
            case .refused(let message): return .refuse(message)
            case .unchanged, .started: return .close
            }
        }
    }

    // MARK: New Folder

    /// As in Finder, in the folder on screen the folder is made at once with a free name, and
    /// its name is then edited in its row (also while the list is filtered: the filter is cleared to show it).
    /// Elsewhere (a selected folder, the tree) the name is asked for first, since the new folder is not in the list.
    func newFolder(in folder: String, selectInTree: Bool = false) async -> CopyLikeOutcome {
        let onScreen = session.host?.currentPath
        let listedNames = tab?.content.listed.map(\.name) ?? []
        if folder == onScreen, session.host?.isSearching != true, !selectInTree {
            let name = LocalWriteRules.freeNewFolderName(listedNames)
            // A second press while the first folder is being made is refused before anything is noted: the first
            // one's name field still opens in its row.
            if refuseWhileBusy(.operation(.newFolder)) { return .cancelled }
            let pendingPath = Self.childPath(folder, name)
            session.pendingInlineRenamePath = pendingPath
            // The listing may not know of an "untitled folder" made elsewhere meanwhile.
            let outcome = await createFolder(in: folder, named: name, nextFreeName: true, selectInTree: false)
            if case .queued = outcome { return outcome }
            // The folder won't be made, so nothing is waiting to be renamed in its row.
            if session.pendingInlineRenamePath == pendingPath { session.pendingInlineRenamePath = nil }
            if case .error(let message) = outcome {
                dialogs.show("The folder couldn\u{2019}t be made", message, window)
            }
            return outcome
        }
        // The name suggested is free in the folder the new one goes into.
        let initialName =
            folder == onScreen
            ? LocalWriteRules.freeNewFolderName(listedNames) : await freeNewFolderName(in: folder)
        // A bad name, or one the coordinator refused, stays in the prompt with the reason.
        // While another write runs, or before a name with a leading dot is asked about, the prompt closes.
        final class Submitted {
            var outcome = CopyLikeOutcome.cancelled
            var dotName: String?
        }
        let submitted = Submitted()
        await dialogs.askName(.newFolder(in: folder, initialName: initialName), window) { [weak self] typed in
            guard let self else { return .close }
            if let nameError = ItemNames.error(for: typed) { return .refuse(nameError) }
            if self.refuseWhileBusy(.operation(.newFolder)) { return .close }
            let hiddenShown = self.tab?.includeHidden ?? false
            if LocalWriteRules.needsDotNameConfirmation(typed, currentName: nil, hiddenFilesShown: hiddenShown) {
                submitted.dotName = typed
                return .close
            }
            let outcome = await self.createFolder(
                in: folder, named: typed, nextFreeName: false, selectInTree: selectInTree)
            if case .error(let message) = outcome { return .refuse(message) }
            submitted.outcome = outcome
            return .close
        }
        guard let dotName = submitted.dotName else { return submitted.outcome }
        guard await dialogs.confirm(LocalWriteRules.dotNameQuestion, window) else { return .cancelled }
        let outcome = await createFolder(in: folder, named: dotName, nextFreeName: false, selectInTree: selectInTree)
        // A refusal now has no prompt to go under, so it gets a dialog of its own.
        if case .error(let message) = outcome {
            dialogs.showRefusal(.operation(.newFolder), message: message, in: window)
        }
        return outcome
    }

    private func createFolder(in folder: String, named name: String, nextFreeName: Bool, selectInTree: Bool) async
        -> CopyLikeOutcome
    {
        await startLocal(
            .newFolder,
            card: WriteOperationCardState(action: .newFolder, stage: .starting, targetPath: folder, totalItemCount: 1),
            showsRefusal: false,
            beforeAdopting: { [weak self] _ in
                self?.session.pendingTreeSelectionPath = selectInTree ? Self.childPath(folder, name) : nil
            },
            start: { [coordinator, session] in
                try await coordinator.createFolder(
                    parentDirectoryPath: folder, folderName: name, nextFreeName: nextFreeName, window: session)
            })
    }

    /// A free name in a folder that is not the one on screen, from the names it has.
    private func freeNewFolderName(in folder: String) async -> String {
        guard let service = tab?.services.directoryService,
            let snapshot = try? await service.snapshot(path: folder, includeHidden: true)
        else {
            // The coordinator still refuses a name that is taken; it can be changed then.
            return LocalWriteRules.freeNewFolderName([])
        }
        return LocalWriteRules.freeNewFolderName(snapshot.entries.map(\.name))
    }

    static func childPath(_ parent: String, _ name: String) -> String {
        parent == "/" ? "/\(name)" : "\(parent)/\(name)"
    }

    // MARK: Trash and Delete Immediately

    /// Moves items to the Trash; a folder of the tree asks first. Their disk having no Trash, the items
    /// that couldn't go are offered for deleting immediately, as Finder does.
    func trash(_ paths: [String], askFirst: Bool = false) async -> CopyLikeOutcome {
        guard !paths.isEmpty else { return .cancelled }
        if askFirst, await !dialogs.confirm(LocalWriteRules.trashQuestion(paths), window) {
            return .cancelled
        }
        return await remove(paths, .trash)
    }

    /// Asked about first, Cancel the default: it can't be undone. While another
    /// operation runs it can't start, so it isn't asked about either.
    func deleteImmediately(_ paths: [String]) async -> CopyLikeOutcome {
        guard !paths.isEmpty else { return .cancelled }
        if refuseWhileBusy(.operation(.deleteImmediately)) { return .cancelled }
        guard await dialogs.confirm(LocalWriteRules.deleteImmediatelyQuestion(paths), window) else {
            return .cancelled
        }
        return await remove(paths, .deleteImmediately)
    }

    private func remove(_ paths: [String], _ action: WriteOperationAction) async -> CopyLikeOutcome {
        // What is already in the Trash isn't moved there again: Move to Trash does nothing there, and Delete
        // Immediately is in its menu.
        if action == .trash, paths.contains(where: { Paths.isInsideTrash($0, homePath: coordinator.homePath) }) {
            return .cancelled
        }
        return await startLocal(
            action,
            card: WriteOperationCardState(
                action: action, stage: .starting, totalItemCount: paths.count, currentSourcePath: paths.first),
            showsRefusal: true,
            beforeAdopting: { [weak self] operationId in
                self?.session.pendingTreeSelectionPath = nil
                if action == .trash { self?.offerDeleteWhenNoTrash(operationId) }
            },
            start: { [coordinator, session] in
                action == .trash
                    ? try await coordinator.trash(paths: paths, window: session)
                    : try await coordinator.deleteImmediately(paths: paths, window: session)
            })
    }

    /// Once the Trash ends in the tab it started from: what couldn't go because its disk has no Trash is offered for
    /// deleting immediately, instead of a failure that leaves no way to delete it.
    private func offerDeleteWhenNoTrash(_ operationId: String) {
        final class Once {
            var token: ExplorerWindowObservation?
        }
        let once = Once()
        let session = session
        let dialogs = dialogs
        let tab = tab
        once.token = session.observe { [once] event in
            guard case .ended(let end, let inTabOnScreen) = event, end.operationId == operationId else { return }
            once.token?.invalidate()
            once.token = nil
            let withoutTrash = LocalWriteRules.itemsWithoutTrash(end)
            guard !withoutTrash.isEmpty, inTabOnScreen else { return }
            Task { @MainActor in
                guard await dialogs.confirm(LocalWriteRules.deleteWithoutTrashQuestion(withoutTrash), tab?.window)
                else { return }
                let actions = WindowWriteActions(session: session, tab: tab, dialogs: dialogs)
                _ = await actions.remove(withoutTrash, .deleteImmediately)
            }
        }
    }

    // MARK: Empty Trash

    /// Finder's question, then Finder empties every Trash. Items on the
    /// clipboard from one are gone, and the clipboard lets go of them (a cut of any is cancelled); a Trash on screen
    /// is read again. A failure is told in a dialog.
    func emptyTrash() async -> CopyLikeOutcome {
        if refuseWhileBusy(.emptyTrash) { return .cancelled }
        guard await dialogs.confirm(LocalWriteRules.emptyTrashQuestion, window) else { return .cancelled }
        if refuseWhileBusy(.emptyTrash) { return .cancelled }
        let empty = emptyTrashRunner
        let outcome = await coordinator.emptyTrash { await empty() }
        guard outcome.ok else {
            let notice = LocalWriteRules.describeEmptyTrashFailure(outcome.error ?? "")
            dialogs.show(notice.title, notice.message, window)
            return .error(message: notice.message)
        }
        dropTrashedFromClipboard()
        if let host = session.host, Paths.isInsideTrash(host.currentPath, homePath: coordinator.homePath) {
            tab?.readAgain()
        }
        return .queued(operationId: "")
    }

    /// What empties the Trash, which `AppWriteOperations` gives. Without it nothing is erased.
    var emptyTrashRunner: @MainActor () async -> (ok: Bool, error: String?) = {
        (false, "Nothing here can empty the Trash.")
    }

    /// The clipboard lets go of items now in a Trash; a cut, or a copy with none left, is emptied.
    private func dropTrashedFromClipboard() {
        guard let clipboard = session.clipboard,
            case .ready(let mode, let sources, let entries, let capturedAt) = clipboard.contents
        else { return }
        let homePath = coordinator.homePath
        let kept = sources.filter { !Paths.isInsideTrash($0, homePath: homePath) }
        guard kept.count != sources.count else { return }
        let next: CopyPasteClipboard =
            mode == .cut || kept.isEmpty
            ? .empty
            : .ready(
                mode: mode, sourcePaths: kept, sourceEntries: entries.filter { kept.contains($0.key) },
                capturedAt: capturedAt)
        clipboard.set(next, follows: capturedAt, from: tab?.windowID)
        tab?.clipboardChanged()
        tab?.dragDrop.findSearchResultsAgain()
    }

    // MARK: Starting a local operation

    /// Then the start request, then `adoptWriteOperation` and the "queued" card. The lock
    /// is taken before the request is sent, not when the coordinator answers: a second press that comes in between
    /// (a quick double ⌘⌫) then finds it taken. While another write runs, the busy notice is shown.
    private func startLocal(
        _ action: WriteOperationAction, card: WriteOperationCardState, showsRefusal: Bool,
        beforeAdopting: ((String) -> Void)? = nil, start: () async throws -> WriteOperationHandle
    ) async -> CopyLikeOutcome {
        if refuseWhileBusy(.operation(action)) { return .cancelled }
        tab?.onFolderUsed?()
        session.applyCard(card)
        do {
            let handle = try await session.early.whileStarting { try await start() }
            beforeAdopting?(handle.operationId)
            session.adoptWriteOperation(handle.operationId)
            if session.activeOperationId == handle.operationId, session.card?.stage == .starting {
                var queued = card
                queued.stage = .queued
                session.applyCard(queued)
            }
            return .queued(operationId: handle.operationId)
        } catch {
            session.applyCard(nil)
            let message = errorMessage(error)
            if message.contains(WriteServiceMessages.writeOperationBusy) {
                dialogs.showBusy(.operation(action), in: window)
                return .blocked(message: WriteDialogs.busyMessage)
            }
            if showsRefusal {
                dialogs.showRefusal(.operation(action), message: message, in: window)
            }
            return .error(message: message)
        }
    }

    // MARK: Undo and Redo

    /// Undo of the last file operation.
    @discardableResult
    func undo() async -> CopyLikeOutcome {
        await startUndo(.undo)
    }

    /// Redo of the last file operation undone.
    @discardableResult
    func redo() async -> CopyLikeOutcome {
        await startUndo(.redo)
    }

    /// `startUndo`: undoes (or redoes) the last file operation: asks first about what the coordinator found it can't
    /// simply do, then runs all of it as any operation runs, or none of it. Nothing to undo (or Can't Undo) does
    /// nothing.
    func startUndo(_ direction: UndoDirection) async -> CopyLikeOutcome {
        let action: WriteOperationAction = direction == .undo ? .undo : .redo
        if refuseWhileBusy(.operation(action)) { return .cancelled }
        let prepared: UndoPrepared
        do {
            prepared = try await coordinator.prepareUndo(direction)
        } catch {
            let message = errorMessage(error)
            dialogs.showRefusal(.operation(action), message: message, in: window)
            return .error(message: message)
        }
        guard let ticket = prepared.ticket else {
            if prepared.refusal == .busy {
                dialogs.showBusy(.operation(action), in: window)
                return .blocked(message: WriteDialogs.busyMessage)
            }
            return .cancelled
        }
        // Each question is all or nothing: Cancel (or Escape) leaves everything as it is.
        if !prepared.nameTaken.isEmpty,
            await !dialogs.confirm(
                Self.undoQuestion(.nameTaken(names: prepared.nameTaken), direction, prepared.action), window)
        {
            return .cancelled
        }
        if !prepared.changed.isEmpty,
            await !dialogs.confirm(
                Self.undoQuestion(.changed(items: prepared.changed), direction, prepared.action), window)
        {
            return .cancelled
        }
        if refuseWhileBusy(.operation(action)) { return .cancelled }
        let card = WriteOperationCardState(action: action, stage: .starting)
        session.applyCard(card)
        session.runningUndoLabel = prepared.label
        do {
            let handle = try await session.early.whileStarting {
                try await coordinator.startUndo(ticket: ticket, window: session)
            }
            session.adoptWriteOperation(handle.operationId)
            if session.activeOperationId == handle.operationId, session.card?.stage == .starting {
                var queued = card
                queued.stage = .queued
                session.applyCard(queued)
            }
            return .queued(operationId: handle.operationId)
        } catch {
            session.applyCard(nil)
            session.runningUndoLabel = nil
            return refused(.operation(action), error)
        }
    }

    /// The undo question in the words of what it undoes, as the alert asks it: going ahead
    /// is the default only when it keeps both names. Up to 5 of the names are listed under it.
    static func undoQuestion(_ question: UndoQuestion, _ direction: UndoDirection, _ action: WriteOperationAction?)
        -> WriteQuestion
    {
        let text = UndoQuestionText.of(question, direction: direction, action: action)
        return WriteQuestion(
            title: text.title, message: text.message, confirmLabel: text.confirmLabel, destructive: false,
            cancelIsDefault: !text.confirmIsDefault, list: question.listedNames)
    }

    // MARK: Batch rename

    /// Renames the items the Rename sheet settled. Like every write, it waits for no other: one
    /// that is running is said, and the sheet stays closed. Which items were folders is kept, for the sheet to open
    /// again on those that weren't renamed.
    func batchRename(_ request: BatchRenameRequest) async -> CopyLikeOutcome {
        let first = request.items.first?.sourcePath
        if refuseWhileBusy(.operation(.batchRename)) { return .cancelled }
        batchRenameFolders = Dictionary(
            request.items.map { ($0.sourcePath, $0.isFolder) }, uniquingKeysWith: { _, last in last })
        return await startLocal(
            .batchRename,
            card: WriteOperationCardState(
                action: .batchRename, stage: .starting, targetPath: first, totalItemCount: request.items.count,
                currentSourcePath: first),
            showsRefusal: true
        ) { [coordinator, session] in
            try await coordinator.batchRename(request, window: session)
        }
    }

    // MARK: Helpers

    /// A start the coordinator refused: busy says so as every write does, anything else names its reason.
    private func refused(_ action: WriteStartAction, _ error: any Error) -> CopyLikeOutcome {
        let outcome = refusal(error)
        switch outcome {
        case .blocked: dialogs.showBusy(action, in: window)
        case .error(let message): dialogs.showRefusal(action, message: message, in: window)
        default: break
        }
        return outcome
    }

    /// What a refused start comes to, for a caller that tells of it itself.
    private func refusal(_ error: any Error) -> CopyLikeOutcome {
        let message = errorMessage(error)
        if message.contains(WriteServiceMessages.writeOperationBusy) {
            return .blocked(message: WriteDialogs.busyMessage)
        }
        return .error(message: message)
    }

    static func hasConflicts(_ report: CopyPasteAnalysisReport) -> Bool {
        report.summary.fileConflictCount > 0 || report.summary.directoryConflictCount > 0
            || report.summary.mismatchConflictCount > 0
    }

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
    /// A date as the clipboard records when items were put on it: UTC, with milliseconds ("2026-11-11T14:46:00.000Z").
    fileprivate static var withFractionalSeconds: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}
