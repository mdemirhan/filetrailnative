// Port of the write half of apps/desktop/src/main/bootstrap.ts: the crash journal and its recovery before any window
// can write, the write service and the coordinator with its windows, and the retries of what recovery couldn't reach
import AppKit
import FTFileSystem
import FTFoundation
import FTOperations

/// The app's file operations: one coordinator, the journal recovery runs from, and each explorer window's side.
@MainActor
final class AppWriteOperations {
    /// The app's, once it has started (the windows reach it through here).
    static weak var current: AppWriteOperations?

    let coordinator: WriteCoordinator
    let journal: FileWriteJournal
    private let fileSystem: NativeWriteFileSystem
    private var retry: RecoveryRetry?
    private weak var windows: ExplorerWindows?
    private var sessions: [Int: ExplorerWriteSession] = [:]
    var dialogs = WriteDialogs()
    /// What recovery at start says the person must know (items left under a hidden name, or waiting for their disk).
    private(set) var startupNotices: [String] = []

    /// Opens the journal in `userData`, finishes or undoes what an earlier run left half done, and makes the
    /// coordinator. Runs before any window can write.
    init(
        userData: URL, directoryService: DirectoryService, windows: ExplorerWindows,
        log: @escaping @MainActor (String) -> Void
    ) {
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        let diskHasTrash = makeDiskHasTrash()
        let trashItem = TrashItem.live(homePath: homePath)
        // Items replaced by a paste go to the Trash, so a replace can always be undone.
        let fileSystem = NativeWriteFileSystem(trash: { try trashItem($0) })
        self.fileSystem = fileSystem
        self.windows = windows
        let journal = FileWriteJournal.open(userData.appendingPathComponent("replace-journal.json").path)
        self.journal = journal
        let cache = directoryService.cache
        let recoveryCaches = RecoveryCaches(
            clearListings: { cache.clear() },
            forgetSizes: { paths in
                DispatchQueue.main.async { MainActor.assumeIsolated { FolderSizeWrites.forget(changedPaths: paths) } }
            })
        let recoveryLog = RecoveryLogger(
            info: { message, details in
                let said = details.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
                DispatchQueue.main.async { MainActor.assumeIsolated { log("\(message) \(said)") } }
            },
            error: { message, error in
                DispatchQueue.main.async { MainActor.assumeIsolated { log("\(message): \(error)") } }
            })
        // A Replace cut short by a crash is finished or undone before anything else is written.
        let recovery = recoverWrites(
            journal, fileSystem, logger: recoveryLog, caches: recoveryCaches, answerWithinMs: recoveryAnswerWithinMs)
        startupNotices = recovery.notices
        let service = WriteService(WriteServiceDependencies(fileSystem: fileSystem, writeJournal: journal))
        weak var weakSelf: AppWriteOperations?
        coordinator = WriteCoordinator(
            writeService: service, fileSystem: fileSystem,
            options: WriteCoordinatorOptions(
                homePath: homePath, diskHasTrash: { diskHasTrash($0) }, writeJournal: journal,
                broadcastProgress: { event, owner in weakSelf?.broadcast(event, owner: owner) },
                successorOf: { window in weakSelf?.successor(of: window) },
                caches: WriteCaches(
                    forget: { changed, removed in
                        cache.clear()
                        FolderSizeWrites.forget(changedPaths: changed, removedItems: removed)
                    },
                    writeStarting: { FolderSizeWrites.noteWriteStarting() },
                    writeEnded: { FolderSizeWrites.noteWriteEnded() }),
                logError: { message, error in log(error.map { "\(message): \(errorMessage($0))" } ?? message) }))
        weakSelf = self
        // What couldn't be reached at start (its disk wasn't connected, or didn't answer) is tried again now and then,
        // while nothing else is being written, until it is done.
        let coordinator = coordinator
        let runWriteAlone = coordinator.runWriteAloneForRecovery
        retry = RecoveryRetry.start(
            leftoverIds: Set(journal.entries().map(\.id)),
            recover: { entryIds in
                recoverWrites(
                    journal, fileSystem, logger: recoveryLog, caches: recoveryCaches, entryIds: entryIds,
                    answerWithinMs: recoveryAnswerWithinMs, retry: true, runWriteAlone: runWriteAlone)
            },
            remainingIds: { Set(journal.entries().map(\.id)) }, isBusy: { coordinator.isBusy },
            onFinished: { messages in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { AppWriteOperations.current?.showRecoveryNotices(messages) }
                }
            })
        Self.current = self
    }

    // MARK: Windows

    /// The side of the file operations of the explorer window `group` (made the first time it is asked for).
    func session(for group: ExplorerTabGroup) -> ExplorerWriteSession {
        if let session = sessions[group.windowID] { return session }
        let session = ExplorerWriteSession(coordinator: coordinator, host: group, clipboard: windows?.clipboard)
        session.explorerWindowID = group.windowID
        sessions[group.windowID] = session
        // An operation handed to it before it listened is asked for.
        session.askForAdoption()
        return session
    }

    /// The actions of tab `tab`.
    func actions(for tab: MainWindowController) -> WindowWriteActions? {
        guard let group = tab.group else { return nil }
        return WindowWriteActions(session: session(for: group), tab: tab, dialogs: dialogs)
    }

    /// An explorer window closed: what it ran goes on in the window in front, or stops.
    func explorerWindowClosed(_ group: ExplorerTabGroup) {
        guard let session = sessions.removeValue(forKey: group.windowID) else { return }
        coordinator.windowClosed(session)
    }

    /// A tab came to the front: another window's operation whose end its window missed is let go of (B-CLIP-108).
    func tabCameToFront(_ tab: MainWindowController) {
        guard let group = tab.group else { return }
        sessions[group.windowID]?.cameToFront()
    }

    /// `successorOf`: the window in front, unless the window closed with Stop and Close.
    private func successor(of window: any WriteOperationWindow) -> (any WriteOperationWindow)? {
        guard let session = window as? ExplorerWriteSession,
            let tab = windows?.successor(ofExplorerWindow: session.explorerWindowID), let group = tab.group
        else { return nil }
        return self.session(for: group)
    }

    /// Every window but the owner hears how the operation is doing; every window's tabs follow what it moved, and
    /// every window's folder sizes forget what it changed (B-VIEW-172, B-INFO-147 to 149).
    private func broadcast(_ event: WriteOperationEvent, owner: any WriteOperationWindow) {
        guard let windows else { return }
        for group in windows.liveGroups {
            let session = session(for: group)
            if session !== owner {
                session.otherWindowProgress(event)
            }
        }
        windows.writeOperationProgress(
            WriteOperationProgress(
                status: event.status.rawValue,
                result: event.result.map {
                    WriteOperationOutcome(
                        action: $0.action.rawValue, mode: $0.mode.flatMap { CopyPasteMode(rawValue: $0.rawValue) },
                        items: $0.items.map(\.effect))
                }))
        if event.status.isTerminal, let result = event.result {
            let intoTrash = event.action == .trash || event.action == .undo || event.action == .redo
            for tab in windows.allTabs {
                tab.folderSizes.forgetChangedSizes(result.changedPaths, intoTrash: intoTrash)
            }
        }
    }

    // MARK: Notices

    /// Items that waited for their disk and are in place now.
    private func showRecoveryNotices(_ messages: [String]) {
        Self.showRecoveryNotices(messages, dialogs: dialogs, window: windows?.front?.window)
    }

    /// What recovery at start says the person must know, once the windows are open.
    func showStartupNotices() {
        let notices = startupNotices
        startupNotices = []
        Self.showStartupNotices(notices, dialogs: dialogs, window: windows?.front?.window)
    }

    /// `showRecoveryNotices` (main.ts): an information, on the window in front or on its own.
    static func showRecoveryNotices(_ messages: [String], dialogs: WriteDialogs, window: NSWindow?) {
        guard !messages.isEmpty else { return }
        let title =
            messages.count == 1
            ? "An item waiting for its disk is in place now" : "Items waiting for their disk are in place now"
        dialogs.showInfo(title, messages.joined(separator: "\n\n"), window)
    }

    /// `showPendingStartupNotices` (main.ts): a warning on the first window.
    static func showStartupNotices(_ notices: [String], dialogs: WriteDialogs, window: NSWindow?) {
        guard !notices.isEmpty else { return }
        dialogs.show("Work was cut short when File Trail last stopped", notices.joined(separator: "\n\n"), window)
    }

    // MARK: Quitting

    /// `activeOperation`, as the quit question names it.
    var busyKind: BusyOperationKind? {
        coordinator.activeOperation.flatMap { BusyOperationKind(rawValue: $0.kind.rawValue) }
    }

    /// Stops the running operation (not Empty Trash) and waits up to 15 s; the retries and the folder sizes stop.
    func shutDown() async {
        await Self.stopBackgroundWork(coordinator, retry: retry, folderSizes: FolderSizeService.shared.jobs)
    }

    /// What quitting stops, so that nothing keeps the process alive with no window: the recovery retries, the
    /// running operation (waited for up to 15 s), and the folder measurements.
    static func stopBackgroundWork(
        _ coordinator: WriteCoordinator, retry: RecoveryRetry?, folderSizes: FolderSizeJobs
    ) async {
        retry?.stop()
        await coordinator.shutDown()
        folderSizes.stopAll()
    }
}

extension ExplorerTabGroup: WriteSessionHost {
    var isClosed: Bool { isDestroyed }
    var activeTabID: Int? { selected?.windowID }
    var currentPath: String { selected?.folder.path ?? "" }
    var selectedPaths: [String] { selected?.selectedPaths ?? [] }
    var isSearching: Bool { selected?.searchRootPath != nil }

    var selectedTreePath: String? {
        guard let item = selected?.sidebarController.selectedTreeItemID, item.hasPrefix("fs:") else { return nil }
        return String(item.dropFirst(3))
    }

    func applyWriteEnd(_ refresh: WriteEndRefresh) {
        selected?.applyWriteEnd(refresh)
    }

    func followMovesOnScreen(_ moves: [PathMove]) {
        selected?.followOnScreen(moves)
    }

    /// The folder watch is held while a write is locked (`held: … || isWriteOperationLocked`, B-CLIP-147,
    /// B-VIEW-187): each tab reads what waited once it is let go.
    func writeLockChanged() {
        for tab in tabs { tab.writeLockChanged() }
    }
}
