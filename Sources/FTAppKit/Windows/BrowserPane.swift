// One pane of a tab: a folder, its history and how it is shown, its search and its file list
import AppKit
import FTFileSystem
import FTFoundation

/// One pane of a tab: the folder it shows and its history, the view, order and hidden files it shows it with, its
/// search, and the file list. The tab (`MainWindowController`) holds the window, the sidebar, the toolbar and the Info
/// panel, which follow the pane the tab has active.
@MainActor
final class BrowserPane {
    typealias HistoryMove = MainWindowController.HistoryMove
    typealias ReadFailure = MainWindowController.ReadFailure
    typealias NavigationOutcome = MainWindowController.NavigationOutcome
    typealias FolderChangeHold = FolderChangeGate.Hold

    /// The tab it is a pane of; set as the tab is made.
    weak var tab: MainWindowController!
    let content: ContentPaneController
    private(set) var folder: URL
    /// The pane let go of its folder: it shows none until one is opened, and keeps none: its label, snapshot and saved
    /// tab have an empty path (`shownFolderPath`). `folder` is then only where a new read would start from.
    private(set) var folderLetGo = false
    var viewMode: ExplorerViewMode
    var searchViewMode: ExplorerViewMode
    var sortBy: SortByPreference
    var sortDirection: SortDirectionPreference
    var includeHidden: Bool
    var foldersFirst: Bool
    /// The pane's history: folder paths and the one on screen.
    var navigationHistory: NavigationHistory
    /// How the folders in the history were left, for Back and Forward.
    private(set) var folderMemories: FolderViewMemories = [:]
    /// The folder a search runs from while the pane shows its results (`TabSearch` sets it).
    var searchRootPath: String? {
        didSet {
            guard searchRootPath != oldValue else { return }
            updatePathBar()
            tab?.notify(.search)
        }
    }
    private(set) var searchStore: TabSearch?
    /// The pane's search: its session, the toolbar field while the pane is active, the results bar.
    var search: TabSearch {
        if let searchStore { return searchStore }
        let made = TabSearch(tab: tab)
        searchStore = made
        return made
    }
    private var navigationToken = 0
    private(set) var isNavigating = false
    /// The folder the navigation under way is opening.
    private var navigationTarget: URL?
    /// When changes made outside the app are read: see `FolderChangeGate`.
    private var folderChanges = FolderChangeGate(maxChangedPaths: FolderWatches.maxChangedPaths)
    /// The changes waiting to be read.
    var pendingChange: FolderChangeGate.Pending? { folderChanges.pending }
    /// A change from outside is being taken in: Show Info's item stays.
    private(set) var isTakingInOutsideChange = false
    /// Where the first read of the pane's folder stands. A tab brought back, or merged in, waits unread until it is
    /// first shown, or first sent somewhere.
    private enum FirstRead {
        case notStarted
        case reading
        /// Whether it showed the folder.
        case finished(read: Bool)
    }

    private var firstRead = FirstRead.notStarted
    /// Who waits for the first read to finish.
    private var afterFirstRead: [(Bool) -> Void] = []
    /// Whether the pane's folder has been, or is being, read.
    var loaded: Bool {
        if case .notStarted = firstRead { return false }
        return true
    }
    /// The pane was sent to another folder while its tab was in the background (its folder moved, or its disk went):
    /// the folder is read when the tab is next shown.
    private(set) var stale = false
    /// A folder has been on screen in this pane.
    private(set) var hasShownFolder = false
    /// The view the pane was started with (`carry`), until its first folder has been shown that way.
    private(set) var carriedView: TabViewState?
    /// The pane on screen as its window opens, which falls back to Home.
    private let startsTheWindow: Bool
    /// What waits out `retryDelay`; tests move it by hand.
    var timers: any TimerScheduling = TaskTimerScheduler()

    init(
        tab startup: StartupTab, history: (paths: [String], index: Int)?, folderSizes: WindowFolderSizes,
        startsTheWindow: Bool
    ) {
        self.startsTheWindow = startsTheWindow
        content = ContentPaneController(mode: startup.viewMode, folderSizes: folderSizes, loaders: .placeholder)
        folderLetGo = startup.path.isEmpty
        folder = URL(fileURLWithPath: startup.path.isEmpty ? startup.rootPath : startup.path)
        viewMode = startup.viewMode
        searchViewMode = startup.searchViewMode
        sortBy = startup.sortBy
        sortDirection = startup.sortDirection
        includeHidden = startup.includeHidden
        foldersFirst = startup.foldersFirst
        if let history, history.paths.indices.contains(history.index) {
            navigationHistory = NavigationHistory(paths: history.paths, index: history.index)
        } else {
            navigationHistory = startup.path.isEmpty ? NavigationHistory() : NavigationHistory(startingAt: startup.path)
        }
    }

    /// The tab's sidebar follows this pane: the pane is the one the tab has active.
    var drivesSidebar: Bool { tab?.activePane === self }

    private var sidebar: SidebarViewController { tab.sidebarController }

    /// Runs `work` in a task that holds the tab until it ends, as the tab's own tasks did: a tab closed meanwhile is
    /// still there for what the work does after its read.
    private func holdingTab(_ work: @escaping @MainActor (BrowserPane) async -> Void) {
        let held = tab
        Task {
            await work(self)
            withExtendedLifetime(held) {}
        }
    }

    var shownFolderPath: String { folderLetGo ? "" : folder.path }

    /// The view on screen: search results have one of their own.
    var shownViewMode: ExplorerViewMode { searchStore?.showsResults == true ? searchViewMode : viewMode }

    var viewState: ExplorerViewState {
        ExplorerViewState(
            viewMode: viewMode, searchViewMode: searchViewMode, sortBy: sortBy, sortDirection: sortDirection,
            includeHidden: includeHidden, foldersFirst: foldersFirst)
    }

    // MARK: What the pane keeps

    /// The pane starts with the view it had. Its folder is read as it first shows.
    func carry(_ view: TabViewState) {
        carriedView = view
        folderMemories = view.folderViewMemories
    }

    /// The view on screen: none for a pane whose folder is yet to be read somewhere else. A pane that has not read its
    /// first folder still has what it was started with. With search results showing, their selection, filter and
    /// scroll are what is taken: a pane has one set of them. The tree's part is the tab's to fill in.
    var liveView: TabViewState? {
        guard !stale else { return nil }
        if let carriedView { return carriedView }
        guard hasShownFolder else { return nil }
        var view = TabViewState()
        view.folderViewMemories = folderMemories
        if case .failed(let error) = content.loadState {
            view.directoryError = error
        } else {
            view.directoryError = content.readError
        }
        if let shown = content.captureFolderView() {
            view.contentSelection = shown.selection
            view.listFilterQuery = content.filter
            view.listFilterMode = content.filter.isEmpty ? nil : content.filterMode
            view.contentScroll = CGPoint(x: shown.scrollLeft, y: shown.scrollTop)
        }
        return view
    }

    // MARK: The first read

    /// Reads the pane's folder the first time it is shown, or again when it was sent elsewhere in the background.
    func ensureLoaded() {
        if loaded {
            if stale {
                stale = false
                // At once: the pane is being read, and has no need to read again as it comes to the front.
                isNavigating = true
                navigationTarget = folder
                let path = folder.path
                holdingTab { pane in
                    await pane.openNearestExistingFolder(
                        path, history: .none, keepingSearch: true, restoringView: true)
                    if pane.drivesSidebar { pane.sidebar.refreshBranches() }
                }
            }
            return
        }
        firstRead = .reading
        holdingTab { pane in
            let read: Bool
            if pane.folderLetGo {
                pane.showNoFolder()
                if pane.drivesSidebar { pane.sidebar.refreshBranches() }
                read = false
            } else if pane.startsTheWindow {
                read = await pane.readStartupFolder()
            } else {
                read = await pane.readFirstFolder()
            }
            pane.finishFirstRead(read)
        }
    }

    /// The first read ended: what waited for it goes on.
    private func finishFirstRead(_ read: Bool) {
        guard case .reading = firstRead else { return }
        tab?.paneFinishedFirstRead(self)
        firstRead = .finished(read: read)
        for action in afterFirstRead { action(read) }
        afterFirstRead = []
    }

    /// The sidebar's row of the tab's favorite stays selected as its folder opens, the tree filled in on its own: a
    /// favorite is not looked up in the tree.
    private func openKeepingFavoriteRow() -> SidebarOpen? {
        guard drivesSidebar, let favorite = tab.favoritePath, favorite == folder.path else { return nil }
        let root = tab.treeRootPath
        let model = sidebar.model
        Task { await model.loadChildren(root) }
        return SidebarOpen(origin: .alias)
    }

    /// A pane that carries a view has its tree and row as they were (`mode: "none"`): nothing follows the folder.
    private func openKeepingCarriedTree() -> SidebarOpen? {
        guard carriedView != nil else { return nil }
        if drivesSidebar {
            let root = tab.treeRootPath
            let model = sidebar.model
            Task { await model.loadChildren(root) }
        }
        return SidebarOpen(origin: .alias)
    }

    /// A pane shown for the first time, or one just opened: its folder, or the nearest one above it that can be read.
    /// Whether its own folder opened.
    private func readFirstFolder() async -> Bool {
        let open = openKeepingCarriedTree() ?? openKeepingFavoriteRow() ?? .other
        return await openNearestExistingFolder(
            folder.path, history: .none, open: open, readFailure: firstReadFailure, restoringView: true,
            arrives: tab.opensAsArrival)
    }

    /// What a failed read does to the pane's first folder. A carried folder stays on screen as it was, with its error
    /// if it had one; one that was fine and has since gone gives way.
    private var firstReadFailure: ReadFailure {
        guard let carriedView else { return .leavesFolderOnScreen }
        return carriedView.directoryError != nil ? .opens : .opensUnlessGone
    }

    /// The pane on screen as its window opens: a saved favorite opens even if it can't be read, showing why; any other
    /// folder that can't be read gives way to Home, with the tree at Home.
    private func readStartupFolder() async -> Bool {
        if let open = openKeepingFavoriteRow() {
            return await attemptNavigation(to: folder, history: .none, open: open, readFailure: .opens).didOpen
        }
        switch await attemptNavigation(to: folder, history: .none) {
        case .opened: return true
        case .superseded: return false
        case .failed: break
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard folder.path != home else { return false }
        if drivesSidebar { sidebar.model.initializeTree(home) }
        return await attemptNavigation(to: URL(fileURLWithPath: home), history: .replace).didOpen
    }

    /// Runs `action` once the first read of the pane's folder has finished, with whether it showed the folder.
    func whenFirstReadFinished(_ action: @escaping (Bool) -> Void) {
        if case .finished(let read) = firstRead {
            action(read)
        } else {
            afterFirstRead.append(action)
        }
    }

    /// `followMovedItems` and `leaveUnmountedDisks` for a pane in the background: it takes the place `snapshot` gives
    /// it (folder and history) and reads its folder when it is next shown. Whether its folder changed.
    @discardableResult
    func takePlace(_ snapshot: TabSnapshot) -> Bool {
        if snapshot.historyPaths.indices.contains(snapshot.historyIndex) {
            navigationHistory = NavigationHistory(paths: snapshot.historyPaths, index: snapshot.historyIndex)
        } else {
            navigationHistory = NavigationHistory(startingAt: snapshot.currentPath)
        }
        let moved = shownFolderPath != snapshot.currentPath
        if !snapshot.currentPath.isEmpty {
            folder = URL(fileURLWithPath: snapshot.currentPath)
            folderLetGo = false
        }
        if moved, loaded { stale = true }
        return moved
    }

    /// The folder on screen, or one it is inside, was renamed or moved: it is read at its new place, in place in the
    /// history.
    func followOnScreen(_ moves: [PathMove]) {
        let path = shownFolderPath
        let followed = ExplorerTabs.followMovedPath(path, moves)
        guard !path.isEmpty, followed != path else { return }
        let target = URL(fileURLWithPath: followed)
        if loaded {
            go(to: target, history: .replace)
        } else {
            folder = target
            tab.updateTitle()
            tab.group?.tabChanged(tab)
        }
    }

    // MARK: Changes from outside

    /// Reads the folder on screen again, quietly: something changed in it. `changedPaths` are the items the change
    /// touched (nil: anything in it may have).
    func reload(changedPaths: [String]? = nil) {
        guard loaded, !folderLetGo else { return }
        updateFolderChanges { $0.changed(folder.path, changedPaths, $1) }
    }

    /// The folder read again because the app asks, not because of a change from outside: Show Info's item goes.
    func readAgain() {
        if drivesSidebar { tab.infoController?.letShowInfosItemGo() }
        // Nothing is said to have changed: the rows keep the details they have, so a folder a write went into shows its
        // old date until something outside says otherwise.
        reload(changedPaths: [])
    }

    var folderChangesHeld: Bool { folderChanges.isHeld }

    func folderChangesHeld(by hold: FolderChangeHold) -> Bool { folderChanges.holds.contains(hold) }

    func holdFolderChanges(_ hold: FolderChangeHold, _ held: Bool) {
        updateFolderChanges { $0.hold(hold, held, $1) }
    }

    func recheckFolderChanges() {
        updateFolderChanges { $0.recheck($1) }
    }

    func readFolderChanges(despite hold: FolderChangeHold) {
        updateFolderChanges { $0.readDespite(hold, $1) }
    }

    /// The pane as the gate asks about it: the folder on screen and what is going on in it.
    private var folderChangeSituation: FolderChangeGate.Situation {
        let opening: FolderChangeGate.Situation.Opening =
            !isNavigating
            ? .nothing : navigationTarget?.comparablePath == folder.comparablePath ? .thisFolder : .anotherFolder
        // A file operation running here or in another window holds them too (WriteOperations/).
        return FolderChangeGate.Situation(
            folderPath: folder.path, opening: opening, renaming: content.inlineRename != nil,
            writeLocked: tab.isWriteLocked)
    }

    /// Tells the gate what happened, and does what it says.
    private func updateFolderChanges(
        _ event: (inout FolderChangeGate, FolderChangeGate.Situation) -> FolderChangeGate.Effect
    ) {
        switch event(&folderChanges, folderChangeSituation) {
        case .none:
            break
        case .scheduleRetry:
            _ = timers.schedule(after: MainWindowController.retryDelay) { [weak self] in
                self?.updateFolderChanges { $0.retryElapsed($1) }
            }
        case .read(let changedPaths):
            holdingTab { pane in
                await pane.quietRead(changedPaths.map { Array($0) })
                pane.updateFolderChanges { $0.readEnded($1) }
            }
        }
    }

    /// A folder read again in place: the selection, scroll and details stay; the error clears when the answer arrives.
    private func quietRead(_ changedPaths: [String]?) async {
        let url = folder
        let result = await readFolder(url)
        // The folder was left meanwhile: the user's folder wins.
        guard url == folder, !isNavigating, !folderLetGo else { return }
        switch result {
        case .success(let snapshot):
            isTakingInOutsideChange = true
            defer { isTakingInOutsideChange = false }
            content.show(
                folder: url.path, entries: snapshot.entries, selecting: nil, keepingScroll: true,
                changedPaths: changedPaths)
            tab.notify(.folder)
        case .failure(let error):
            if FolderReadFailure.isGone(error) {
                await openNearestExistingFolder(above: url.path)
            } else {
                content.showError(folder: url.path, error: FolderReadFailure.readError(error))
            }
        }
    }

    /// The folder on screen is gone: the nearest folder above it that still exists is opened in its place, and the
    /// selection is not carried over.
    @discardableResult
    private func openNearestExistingFolder(above path: String) async -> Bool {
        for candidate in ExplorerTabs.pathAndAncestors(path).dropFirst() {
            switch await attemptNavigation(to: URL(fileURLWithPath: candidate), history: .replace) {
            case .opened: return true
            case .superseded: return false
            case .failed: continue
            }
        }
        return false
    }

    /// Opens `path`, or the nearest folder above it that can be read. A newer navigation that takes over ends the
    /// attempt. Whether `path` itself opened.
    @discardableResult
    private func openNearestExistingFolder(
        _ path: String, history: HistoryMove, open: SidebarOpen = .other, keepingSearch: Bool = false,
        readFailure: ReadFailure = .leavesFolderOnScreen, restoringView: Bool = false, arrives: Bool = false
    ) async -> Bool {
        let outcome = await attemptNavigation(
            to: URL(fileURLWithPath: path), history: history, open: open, keepingSearch: keepingSearch,
            readFailure: readFailure, restoringView: restoringView, arrives: arrives)
        if case .failed = outcome {
            finishCarrying(nil)
            await openNearestExistingFolder(above: path)
        }
        return outcome.didOpen
    }

    /// A pane that comes back reads its folder again where it stands, for it may have changed while another tab was
    /// in front. The selection, the search results and the place in the history stay; one that can't be read stays,
    /// showing why; one that is gone gives way to the nearest folder above it. `refreshingTree`: the tree's open
    /// branches are read again too.
    private func reloadFolderInPlace(refreshingTree: Bool) async {
        let path = folder.path
        let open = drivesSidebar ? sidebar.model.openReadingAgain(path) : SidebarOpen(origin: .alias)
        let outcome = await attemptNavigation(
            to: folder, history: .none, open: open, keepingSearch: true, readFailure: .opensUnlessGone, quiet: true,
            keepingSelection: true)
        var opened = outcome.didOpen
        if case .failed = outcome { opened = await openNearestExistingFolder(above: path) }
        if refreshingTree, opened, drivesSidebar { await sidebar.model.refreshBranches() }
    }

    /// The tab came back: the folder is read again once the tab has been drawn. What it said: whether the tree's
    /// branches should be read again later instead.
    func cameBack(refreshingTree: Bool) {
        guard hasShownFolder, !isNavigating, !folderLetGo else { return }
        readAgainAfterDrawing(refreshingTree: refreshingTree)
    }

    /// The folder is read again once the tab has been drawn, so the switch doesn't wait for it, and not at all if another
    /// tab has come to the front by then.
    private(set) var waitingReadAgain: ReadAgain?

    enum ReadAgain {
        case folder
        /// The folder with its open tree branches.
        case folderAndTree
    }

    /// Another tab came to the front: what was waiting is dropped. Whether the tree's branches were waiting too.
    func dropWaitingReadAgain() -> Bool {
        defer { waitingReadAgain = nil }
        return waitingReadAgain == .folderAndTree
    }

    private func readAgainAfterDrawing(refreshingTree: Bool) {
        waitingReadAgain = refreshingTree || waitingReadAgain == .folderAndTree ? .folderAndTree : .folder
        // The main queue takes what is added while it runs on its next turn of the run loop, after this turn's drawing.
        DispatchQueue.main.async { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let waiting = self.waitingReadAgain else { return }
                    let refreshingTree = waiting == .folderAndTree
                    self.waitingReadAgain = nil
                    guard self.hasShownFolder, !self.isNavigating, !self.folderLetGo else {
                        if refreshingTree { self.tab?.treeOutOfDate = true }
                        return
                    }
                    self.holdingTab { await $0.reloadFolderInPlace(refreshingTree: refreshingTree) }
                }
            }
        }
    }

    // MARK: Navigation

    func go(to url: URL, history: HistoryMove = .push, open: SidebarOpen = .other, keepingSearch: Bool = false) {
        holdingTab { await $0.navigate(to: url, history: history, open: open, keepingSearch: keepingSearch) }
    }

    /// Reads a folder through the directory service: in the order the pane keeps, with hidden files and folders first
    /// as the pane has them.
    private func readFolder(_ url: URL) async -> Result<DirectorySnapshot, any Error> {
        let service = tab.services.directoryService
        let path = url.path
        let key = DirectorySortKey(rawValue: sortBy.rawValue) ?? .name
        let direction: SortDirection = sortDirection == .asc ? .ascending : .descending
        let hidden = includeHidden
        let first = foldersFirst
        return await Result {
            try await service.snapshot(
                path: path, includeHidden: hidden, sortBy: key, sortDirection: direction, foldersFirst: first)
        }
    }

    /// Reads `url`, then shows it. False when a later navigation replaced this one or the folder didn't open. `open`
    /// says how the sidebar reached it, which decides how the sidebar's tree follows and which of its rows is selected.
    /// The listing in front stays on screen until the new one arrives.
    /// With `goToFailure` it is Go To (`viaGoTo`): a folder that can't be read leaves the one on screen, and the
    /// read's message goes there instead.
    @discardableResult
    func navigate(
        to url: URL, history move: HistoryMove = .push, open: SidebarOpen = .other, keepingSearch: Bool = false,
        goToFailure: ((String) -> Void)? = nil
    ) async -> Bool {
        let outcome = await attemptNavigation(
            to: url, history: move, open: open, keepingSearch: keepingSearch, goToFailure: goToFailure)
        if case .opened = outcome { return true }
        return false
    }

    /// What the folder just shown takes from the view the pane was started with, besides what `content.show` restored.
    private func showCarried(_ carried: TabViewState, folderWasRead: Bool) {
        content.setFilter(carried.listFilterQuery, mode: carried.listFilterMode)
        // Something selected outside the filter shows the whole list again.
        if let lead = content.selection.leadPath, !content.filter.isEmpty,
            !content.entries.contains(where: { $0.path == lead }), content.listed.contains(where: { $0.path == lead })
        {
            content.clearFilter()
        }
        // A folder with a message over it (a Go To that failed) has it still.
        if folderWasRead, let error = carried.directoryError {
            content.showReadError(error)
        }
    }

    /// The pane's first folder has been shown, as `carried` had it if that was its folder.
    private func finishCarrying(_ carried: TabViewState?) {
        if drivesSidebar { sidebar.holdsScrollPosition = false }
        guard carriedView != nil else { return }
        carriedView = nil
        if let carried, drivesSidebar {
            sidebar.restoreScroll(tree: carried.treeScrollTop, sections: carried.sidebarSectionsScrollTop)
        }
    }

    /// Search results were left at the place in the history `move` goes to, and that place still holds the same folder.
    private func searchResultsWereLeft(at move: HistoryMove) -> Bool {
        guard let session = searchStore?.session, session.hasCachedSearch, let place = session.returnPlace,
            place.index == move.target(from: navigationHistory.index)
        else { return false }
        return navigationHistory.holds(place)
    }

    /// `readFailure` is what a folder that can't be read does; by default only the sidebar's favorites, locations and
    /// links open anyway. `quiet`: the folder is on screen and is only read again, so no "Loading…". `keepingSelection`:
    /// it is read in place, its selection and scroll staying. `arrives`: the pane's first folder counts as gone to (the
    /// one step of its history is there already).
    func attemptNavigation(
        to url: URL, history move: HistoryMove = .push, open: SidebarOpen = .other, keepingSearch: Bool = false,
        goToFailure: ((String) -> Void)? = nil, readFailure: ReadFailure? = nil, quiet: Bool = false,
        keepingSelection: Bool = false, restoringView: Bool = false, arrives: Bool = false
    ) async -> NavigationOutcome {
        // A pane sent somewhere before it was first read takes this as its first read.
        if !loaded {
            firstRead = .reading
            let outcome = await attemptNavigation(
                to: url, history: move, open: open, keepingSearch: keepingSearch, goToFailure: goToFailure,
                readFailure: readFailure, quiet: quiet, keepingSelection: keepingSelection,
                restoringView: restoringView, arrives: arrives)
            finishFirstRead(outcome.didOpen)
            return outcome
        }
        navigationToken += 1
        let token = navigationToken
        isNavigating = true
        navigationTarget = url
        defer { if token == navigationToken { isNavigating = false } }
        let move = open.pushesHistory ? move : HistoryMove.none
        // The folder being left is remembered first: what was selected and where the list was scrolled.
        // Nothing is remembered when search results are showing.
        if !folderLetGo, url.comparablePath != folder.comparablePath, searchRootPath == nil,
            let memory = content.captureFolderView()
        {
            folderMemories = folderMemories.remembering(
                memory, at: folder.path, historyPaths: navigationHistory.paths + [folder.path])
        }
        // Read before anything moves: the place being left is the one in the history now, and the results to come back
        // are those left where this goes.
        let bringsResultsBack = !keepingSearch && searchResultsWereLeft(at: move)
        let leftPlace = NavigationHistory.Place(index: navigationHistory.index, path: folder.path)
        // Back, Forward and the hold menus move within the history at once, before the folder is read.
        switch move {
        case .back: navigationHistory.goBack()
        case .forward: navigationHistory.goForward()
        case .jump(let index): navigationHistory.jump(to: index)
        case .push, .none, .replace: break
        }
        let keepsSearch = keepingSearch
        content.beginLoading(quiet: quiet)
        let read = await readFolder(url)
        guard token == navigationToken, let tab else { return .superseded }

        var entries: [DirectoryEntry] = []
        // The folder is known by the real path its listing gives (`response.path`), not the spelling it was asked by; one
        // that can't be listed has only that spelling.
        var shown = url
        var opensWithError = false
        switch read {
        case .success(let snapshot):
            entries = snapshot.entries
            shown = URL(fileURLWithPath: snapshot.path)
        case .failure(let error):
            let readError = FolderReadFailure.readError(error)
            if let goToFailure {
                content.showReadError(readError)
                goToFailure(readError.message)
                return .failed
            }
            switch readFailure ?? (open.origin.opensWhenUnreadable ? .opens : .leavesFolderOnScreen) {
            case .opens: opensWithError = true
            case .opensUnlessGone: opensWithError = !FolderReadFailure.isGone(error)
            case .leavesFolderOnScreen: opensWithError = false
            }
            guard opensWithError else {
                // A quiet read shows nothing: the search for a folder that can be read goes on from it.
                if !quiet { content.showReadError(readError) }
                if drivesSidebar { sidebar.openFailed() }
                tab.notify(.history)
                return .failed
            }
        }

        // Opening a folder puts search results away, once it has arrived, the folder on screen too (Reveal in
        // Folder there); only a read in place that asks to keep them (an order, hidden files, a tab coming back)
        // leaves them.
        if !keepsSearch, let search = searchStore, search.session.isSearchMode {
            // Back and Forward can bring them back; choosing the folder they cover closes them.
            let sameFolder = shown.comparablePath == folder.comparablePath
            search.session.hideResults(returnPlace: sameFolder ? nil : leftPlace)
        }

        // A folder is added to the history only after its listing has arrived and been applied.
        let visits = tab.visitTracker
        switch move {
        case .push:
            navigationHistory.record(shown.path, mode: .push)
            if !opensWithError { visits.arrive(shown.path, viaGoTo: goToFailure != nil) }
        case .replace:
            navigationHistory.record(shown.path, mode: .replace)
        case .back, .forward, .jump:
            // Back and Forward never count as a visit.
            if !opensWithError { visits.showing(shown.path) }
        case .none:
            // A pane that starts on a folder by another spelling: its one step is the folder as it is.
            if navigationHistory.current == url.path, shown.path != url.path {
                navigationHistory.record(shown.path, mode: .replace)
            }
            if arrives, !opensWithError { visits.arrive(shown.path, viaGoTo: false) }
        }
        // What the pane was started with is for the folder it was started on, not one that took its place.
        let carried = url.comparablePath == folder.comparablePath ? carriedView : nil
        folder = shown
        folderLetGo = false

        // Opening a folder normally starts with nothing selected, and the list at the top.
        let memory =
            carried.map {
                FolderViewMemory(
                    selection: $0.contentSelection, scrollTop: $0.contentScroll.y, scrollLeft: $0.contentScroll.x)
            } ?? ((move.restoresView && !bringsResultsBack) || restoringView ? folderMemories[shown.path] : nil)
        tab.updateTitle()
        if !keepsSearch, let search = searchStore, !search.session.isSearchMode { search.session.setDraft("") }
        // A folder opened from the sidebar leaves the keyboard there. The pane's first folder wasn't: AppKit gives a
        // window that comes to the front its first key view, which is the sidebar's, and a fresh tab focuses the list.
        let isFirstFolder = !hasShownFolder
        hasShownFolder = true
        let window = tab.window
        let sidebarKeyboard = drivesSidebar && sidebar.isFocused && !isFirstFolder ? window?.firstResponder : nil
        switch read {
        case .success:
            // The rows of a folder read again keep the details they have, and not only when it is read in place:
            // nothing is said to have changed (hidden files shown, a new sort).
            content.show(
                folder: shown.path, entries: entries, selecting: keepingSelection ? nil : [],
                keepingScroll: keepingSelection, changedPaths: [], restoring: memory)
            // Before the window draws, so the folder underneath does not flash by. The folder is what they lie over: the
            // tree and the path bar show it.
            if bringsResultsBack { searchStore?.session.showCachedResults() }
        case .failure(let error):
            content.showError(folder: shown.path, error: FolderReadFailure.readError(error))
        }
        if let carried { showCarried(carried, folderWasRead: !opensWithError) }
        if drivesSidebar {
            if let sidebarKeyboard {
                window?.makeFirstResponder(sidebarKeyboard)
            } else if let window, isFirstFolder, tab.startingPane == .tree, tab.panels.folderTreeOpen {
                // The keyboard goes back to the pane the tab had it in.
                sidebar.focusTree()
                window.initialFirstResponder = window.firstResponder as? NSView
            } else if let window, isFirstFolder || window.firstResponder == nil || window.firstResponder === window {
                // When no pane has the keyboard it goes to the file list (a fresh tab focuses the list).
                content.focusList()
                if isFirstFolder { window.initialFirstResponder = content.focusView }
            }
            if opensWithError {
                sidebar.folderOpenedWithError(shown, open)
            } else {
                sidebar.folderOpened(shown, open)
            }
        }
        tab.notify(.history)
        updatePathBar()
        tab.notify(.folder)
        window?.contentView?.layoutSubtreeIfNeeded()
        if let carried { content.pane?.scrollPosition = (carried.contentScroll.y, carried.contentScroll.x) }
        if isFirstFolder { finishCarrying(carried) }
        // The results' list has only now been laid out, so their selection can be brought into view.
        if bringsResultsBack, searchStore?.session.isSearchMode == true { content.applySelection(content.selection) }
        window?.displayIfNeeded()
        tab.group?.tabChanged(tab)
        return .opened
    }

    /// Where the pane is, history and sidebar row with it (`TabPlace`).
    var place: MainWindowController.TabPlace {
        MainWindowController.TabPlace(
            path: folder.path, history: navigationHistory, sidebarRow: drivesSidebar ? sidebar.model.selected : nil)
    }

    /// A drag's springs are undone: the folder opens as it was left, and its history and sidebar row come back with it,
    /// once it has opened. A folder that can't (gone meanwhile) leaves the pane where the drag left it.
    func comeBack(to place: MainWindowController.TabPlace) async {
        let outcome = await attemptNavigation(
            to: URL(fileURLWithPath: place.path), history: .none, open: SidebarOpen(origin: .alias),
            readFailure: .leavesFolderOnScreen, restoringView: true)
        guard outcome.didOpen, let tab else { return }
        navigationHistory = place.history
        if drivesSidebar { sidebar.model.restoreSelected(place.sidebarRow) }
        tab.notify(.history)
        tab.group?.tabChanged(tab)
    }

    /// A link to a folder was looked up: nothing has opened in the pane since `token` was taken.
    var navigationCount: Int { navigationToken }

    // MARK: How the folder is shown

    /// The folder on screen is let go of: the file list shows nothing.
    func showNoFolder() {
        folderLetGo = true
        folderChanges.letGo()
        content.showNoFolder()
        tab.updateTitle()
        updatePathBar()
    }

    /// The view search results show in, whether they show now or not.
    func setSearchViewMode(_ mode: ExplorerViewMode) {
        searchViewMode = mode
        if let search = searchStore, search.showsResults { content.setMode(mode) }
        tab.notify(.view)
        tab.group?.tabChanged(tab)
    }

    func setMode(_ mode: ExplorerViewMode) {
        // Search results have a view of their own in each pane (`searchViewMode`).
        if let search = searchStore, search.showsResults {
            searchViewMode = mode
        } else {
            viewMode = mode
        }
        content.setMode(mode)
        tab.notify(.view)
        tab.group?.tabChanged(tab)
    }

    /// The sort commands and the column headers: the field already in use reverses the direction;
    /// another sorts by it, descending for Date Modified and Size and ascending for Name and Kind.
    func sort(by field: SortByPreference) {
        let next = DetailsSorting.next(current: sortBy, direction: sortDirection, requested: field)
        setSort(next.sortBy, next.direction)
    }

    /// Puts the folder in this order: it is read again ("replace"), and the selection is not kept.
    func setSort(_ field: SortByPreference, _ direction: SortDirectionPreference) {
        sortBy = field
        sortDirection = direction
        viewChanged()
    }

    /// The pane's order, Folders First or hidden files changed: the content pane shows it, the folder is read again in
    /// place and the choice is saved with the tab.
    /// `keepingTree`: the tree sees to itself, and the folder read again leaves it alone.
    func viewChanged(keepingTree: Bool = false) {
        content.setView(
            sortBy: sortBy, direction: sortDirection, foldersFirst: foldersFirst, includeHidden: includeHidden)
        tab.notify(.view)
        tab.group?.tabChanged(tab)
        // No folder to read again (`toggleHiddenFiles` with an empty currentPath).
        guard loaded, !folderLetGo else { return }
        // The row of a favorite, a location or a link stays, and the tree where it is.
        let open =
            keepingTree || !drivesSidebar
            ? SidebarOpen(origin: .alias) : sidebar.model.openKeepingRow(folder.path) ?? .other
        let folder = folder
        holdingTab { await $0.navigate(to: folder, history: .replace, open: open, keepingSearch: true) }
    }

    /// The folder on screen read again brings the tree along; a folder being opened now will do that itself.
    var treeFollowsReadingAgain: Bool { loaded && !folderLetGo && !isNavigating }

    /// The path bar shows the folder on screen; in search mode where the one selected result is, as Finder's does, or
    /// else the folder the search runs from.
    func updatePathBar() {
        let bar = content.contentShell.pathBarRow
        guard let searchRootPath else {
            bar.path = shownFolderPath
            return
        }
        let selected = content.selectedEntries
        bar.path = content.selection.paths.count == 1 && selected.count == 1 ? selected[0].path : searchRootPath
    }
}
