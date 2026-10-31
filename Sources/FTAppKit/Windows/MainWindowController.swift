// Port of a tab of apps/desktop/src/renderer/hooks/useExplorerTabs.ts: one tab of an explorer window, as a native window tab
import AppKit
import FTFileSystem
import FTFoundation

struct NavigationTiming: Sendable {
    let folder: URL
    let itemCount: Int
    /// Reading the folder from disk, off the main thread.
    let read: Duration
    /// `read` plus the wait for the main thread to take the result.
    let load: Duration
    /// Sorting, reloading the view and drawing it once.
    let display: Duration
}

/// The window of one tab. Its close button and Close Window close the whole explorer window, as the original's close
/// button does; the close button of a tab in the tab bar closes the tab.
final class ExplorerTabWindow: NSWindow {
    weak var explorerTab: MainWindowController?

    private var refusingFieldEditor: FileRefusingFieldEditor?
    private let firstClickGate = FirstClickGate()

    override func fieldEditor(_ createFlag: Bool, for object: Any?) -> NSText? {
        if refusingFieldEditor == nil, createFlag {
            let editor = FileRefusingFieldEditor()
            editor.isFieldEditor = true
            // A text field's typing can be undone (⌘Z in the search field, a name, the path bar).
            editor.allowsUndo = true
            refusingFieldEditor = editor
        }
        return refusingFieldEditor
    }

    /// What the Window menu calls the window: its tab's label, as the original's window title is. The title itself
    /// stays the folder's name, which the toolbar shows.
    var windowsMenuTitle: String? {
        didSet {
            // Set for every tab each time one opens, and finding the item goes through the whole menu.
            if windowsMenuTitle != oldValue { syncWindowsMenuItem() }
        }
    }

    override var title: String {
        didSet { syncWindowsMenuItem() }
    }

    override var representedURL: URL? {
        didSet { syncWindowsMenuItem() }
    }

    // AppKit puts the window in the Window menu, under its title, as it comes on screen.
    override func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
        super.order(place, relativeTo: otherWin)
        syncWindowsMenuItem()
    }

    override func becomeKey() {
        super.becomeKey()
        syncWindowsMenuItem()
    }

    /// Renames the window's Window menu item, once AppKit has made one.
    private func syncWindowsMenuItem() {
        guard let label = windowsMenuTitle, !isExcludedFromWindowsMenu,
            let item = NSApp.windowsMenu?.items.first(where: { $0.target as? NSWindow === self }),
            item.title != label
        else { return }
        NSApp.changeWindowsItem(self, title: label, filename: false)
    }

    override func performClose(_ sender: Any?) {
        guard let tab = explorerTab, let group = tab.group else {
            super.performClose(sender)
            return
        }
        let closesWindow = (sender as AnyObject?) === standardWindowButton(.closeButton) || sender is NSMenuItem
        if closesWindow || group.tabs.count == 1 {
            group.closeAsCloseButton()
        } else {
            super.performClose(sender)
        }
    }

    // The Window menu's list brings a tab forward through its window; while a dialog is open the tab on screen stays.
    override func makeKeyAndOrderFront(_ sender: Any?) {
        if let explorerTab, explorerTab.group?.refusesFront(explorerTab) == true { return }
        super.makeKeyAndOrderFront(sender)
    }

    // Every change of the keyboard passes here, a click's and a field's as well: what the commands read of it follows.
    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        let made = super.makeFirstResponder(responder)
        explorerTab?.keyboardMoved()
        return made
    }

    /// A key that moves the caret or deletes (⌘↑, ⌘⌫) stays with a text field that has the keyboard, even when the menu
    /// listens for it. The window is asked before the menu bar, and a dimmed item would keep the key too.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if explorerTab?.textFieldKeepsKey(event) == true, let field = firstResponder {
            field.keyDown(with: event)
            return true
        }
        if explorerTab?.keyOfDimmedItem(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    /// A key nothing in the window took: its own table, which serves every pane (`onKeyDown`).
    override func keyDown(with event: NSEvent) {
        if explorerTab?.windowKeyDown(event) == true { return }
        super.keyDown(with: event)
    }

    /// The app's own menus and tooltips see the window's events first, whether they come
    /// from the system or are sent to the window directly.
    override func sendEvent(_ event: NSEvent) {
        if firstClickGate.keepsBack(event, in: self) { return }
        if WindowEventRouting.intercept(event, in: self) { return }
        if WindowOverlayView.existing(in: self)?.forward(event) == true { return }
        if event.type == .rightMouseDown,
            let button = ToolbarButton.takingRightPress(at: event.locationInWindow, in: self)
        {
            // A sheet or a modal window keeps the window's presses from it, as `WindowOverlayView.forward` has it. Passed
            // on, the press would open the toolbar's own menu under the sheet.
            if attachedSheet == nil, NSApp.modalWindow == nil || NSApp.modalWindow === self {
                button.rightMouseDown(with: event)
            }
            return
        }
        super.sendEvent(event)
    }

    // The system's tab commands go through the app's own, so the busy, sheet and 100-tab rules hold.
    override func moveTabToNewWindow(_ sender: Any?) {
        explorerTab?.perform(.moveTabToNewWindow)
    }

    override func mergeAllWindows(_ sender: Any?) {
        explorerTab?.perform(.mergeAllWindows)
    }
}

/// One tab of an explorer window (the original's tab): sidebar, toolbar, current folder and its history, and how it
/// shows its folder. Each tab is a window of its own, in the native tab group of its explorer window.
final class MainWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    enum HistoryMove {
        /// A new step: the entries after the current one are cut off (B-NAV-002).
        case push
        /// Back and Forward move the index at once, before the folder is read, and show the folder as it was left
        /// (B-NAV-014, B-NAV-015, B-SEL-118).
        case back, forward
        /// Touches nothing (startup, a quiet read, a tab brought back).
        case none
        /// Overwrites the current entry (Refresh, a new sort, hidden files, Folders First).
        case replace
        /// A jump within the history (the Back and Forward hold menus): to `index`, adding nothing.
        case jump(index: Int)

        /// The position it moves the history to, when it moves within it.
        func target(from index: Int) -> Int? {
            switch self {
            case .back: index - 1
            case .forward: index + 1
            case .jump(let target): target
            case .push, .none, .replace: nil
            }
        }

        /// The folder is shown the way it was left.
        var restoresView: Bool {
            switch self {
            case .back, .forward, .jump: true
            default: false
            }
        }
    }

    /// `persistOnError`: what a folder that can't be read does.
    enum ReadFailure {
        /// The folder on screen stays, with the read's message over it, and nothing goes in the history.
        case leavesFolderOnScreen
        /// It opens all the same, empty, showing why.
        case opens
        /// So it does unless it is gone: then nothing opens, so that the folder above can.
        case opensUnlessGone
    }

    /// What came of opening a folder.
    enum NavigationOutcome {
        case opened(NavigationTiming)
        /// It couldn't be read, and didn't open.
        case failed
        /// A newer navigation took over.
        case superseded

        var didOpen: Bool {
            if case .opened = self { return true }
            return false
        }
    }

    static let logsTimings = ProcessInfo.processInfo.environment["FILETRAIL_TIMING"] != nil
    /// The default size of an explorer window, and the smallest it can be (`main.ts:401-447`).
    static let defaultContentSize = NSSize(width: 1200, height: 760)
    static let minimumSize = NSSize(width: 760, height: 480)
    private static var nextWindowID = 1

    /// The number its folder watch and menu state are filed under.
    let windowID: Int
    /// The explorer window it is a tab of.
    weak var group: ExplorerTabGroup?
    private(set) var folder: URL
    /// The tab let go of its folder (B-TREE-060): it shows none until one is opened, and keeps none: its label, snapshot
    /// and saved tab have an empty path (`shownFolderPath`), as the original's currentPath is empty. `folder` is then
    /// only where a new read would start from.
    private var folderLetGo = false
    /// How the tab shows its folder, kept between launches with its folder. The sidebar keeps its tree and sections.
    var treeRootPath: String { sidebar.treeRootPath }
    var favoritePath: String? { sidebar.favoritePath }
    private(set) var viewMode: ExplorerViewMode
    private(set) var searchViewMode: ExplorerViewMode
    private(set) var sortBy: SortByPreference
    private(set) var sortDirection: SortDirectionPreference
    private(set) var includeHidden: Bool
    private(set) var foldersFirst: Bool
    var favoritesExpanded: Bool { sidebar.favoritesExpanded }
    var locationsExpanded: Bool { sidebar.locationsExpanded }

    var onClose: (() -> Void)?
    /// Called once, after the first folder has been drawn (used by the launch benchmark).
    var onFirstDraw: (() -> Void)?
    /// Called once the tab has shown its first folder, or found it can't.
    var onReady: (() -> Void)?

    private let sidebar = SidebarViewController()
    /// Eject, from a disk's button in the sidebar, its menu and File ▸ Eject.
    private let ejectCoordinator = EjectCoordinator(volumes: { SidebarVolumes.shared.volumes })
    private lazy var ejectPresenter = InWindowEjectPresenter(window: { [weak self] in self?.window })
    /// The pane that last had the keyboard, for the commands that act on it when none does.
    private var lastFocusedPane: ExplorerPane?
    /// The sidebar, for the parts of the window that put a menu on a row or follow its selection.
    var sidebarController: SidebarViewController { sidebar }
    let content: ContentPaneController
    /// What this window knows of folder sizes (`useFolderSizeCache`).
    let folderSizes: WindowFolderSizes
    /// The window's grid: sidebar, content, Info panel and the toolbar.
    let workspace: WorkspaceView
    /// The window's system toolbar, which holds the workspace's toolbar row.
    let explorerToolbar: ExplorerToolbar
    /// The right-click menus of the tab (P5-09). Their file operations go to the write coordinator (WriteOperations/),
    /// Copy, Cut and Paste through the clipboard (P5-08).
    lazy var contextMenus: ContextMenuCoordinator = {
        let menus = ContextMenuCoordinator(tab: self)
        menus.fileOperation = { [weak self] action, subject in
            switch action {
            case .copy, .cut, .paste: self?.contextMenuFileOperation(action, subject)
            default: self?.performContextFileOperation(action, subject)
            }
        }
        menus.revealSearchResult = { [weak self] path in self?.revealSearchResult(path) }
        menus.showInfo = { [weak self] path in self?.infoController?.showInfo(for: path) }
        menus.notices = InWindowNoticePresenter()
        return menus
    }()
    /// The clipboard's marks, button list and paste, and the drags out of and onto the tab (P5-08).
    lazy var clipboardUI = TabClipboard(tab: self)
    lazy var dragDrop = TabDragDrop(tab: self)
    private let infoPanel = InfoPanelView()
    /// What the Info panel and the Info Row describe (P5-06).
    private(set) var infoController: InfoController?
    /// The system's Customize Toolbar sheet is up.
    var isCustomizingToolbar: Bool { explorerToolbar.isCustomizing }
    /// The folder a search runs from while the tab shows its results (`TabSearch` sets it).
    var searchRootPath: String? {
        didSet {
            guard searchRootPath != oldValue else { return }
            updatePathBar()
            notify(.search)
        }
    }
    private var searchStore: TabSearch?
    /// The tab's search: its session, the toolbar field, the results bar (P5-07).
    var search: TabSearch {
        if let searchStore { return searchStore }
        let made = TabSearch(tab: self)
        searchStore = made
        return made
    }
    /// Services of its own, instead of the app's (a window in a test).
    var servicesOverride: ExplorerServices?
    /// What Edit opens files with; tests give their own, so nothing opens on this Mac.
    var opener: SystemOpener = .workspace
    /// Opens an activated file or app in what macOS chooses; tests give their own.
    var openFile: @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }
    private var observers: [(token: Weak<ExplorerWindowObservation>, handler: (ExplorerWindowChange) -> Void)] = []
    /// The tab's history: folder paths and the one on screen (B-NAV-001).
    private(set) var navigationHistory: NavigationHistory
    /// How the folders in the history were left, for Back and Forward (B-NAV-043).
    private(set) var folderMemories: FolderViewMemories = [:]
    /// The rename being carried out, so a second one does not start meanwhile.
    private var renameTask: Task<Void, Never>?
    /// Told when the folder is used for something (a file opened): the visits the Go To box counts.
    var onFolderUsed: (() -> Void)?
    /// What the Rename sheet needs when several items are selected and Return, F2 or Rename is chosen (P6-03 opens it).
    var openBatchRename: (([DirectoryEntry]) -> Void)?
    /// Opens Settings (⌘,, the toolbar's Settings button): the app's Settings window, unless a test puts its own.
    var openSettings: (() -> Void)?
    /// Opens the Help window on a page (`?`, the toolbar's Help): the app's, unless a test puts its own.
    var openHelp: ((HelpTopicID?) -> Void)?
    /// Previews an item: the system's Quick Look panel, unless a test puts its own, so nothing comes on screen.
    var showQuickLook: ((String) -> Void)?
    /// ⌘F with text typed into the list, and Search Subfolders: the text to search the folder for (P5-07 runs the search).
    var onSearchRequested: ((String) -> Void)?
    /// Carries out a rename and answers with its outcome, in place of the write coordinator (tests). Without it the
    /// coordinator renames (`WindowWriteActions.commitRename`), or, in a window without the app's file operations, the
    /// file system itself.
    var renameItem: ((_ path: String, _ name: String) async -> RenameOutcome)?
    /// While a name is being typed, changes made outside the app wait (B-SEL-139).
    private var renameHoldsChanges = false
    private var navigationToken = 0
    private(set) var isNavigating = false
    /// The folder the navigation under way is opening (`pendingNavigationRef`).
    private var navigationTarget: URL?
    private(set) var pendingChange: PendingChange?
    /// A change waits for an opening of its folder to end: it is looked at again when this runs out (`retryTimerRef`).
    private var changeRetryWaiting = false
    private var quietReadInFlight = false
    /// A change from outside is being taken in: Show Info's item stays (`keepInfoTarget`).
    private(set) var isTakingInOutsideChange = false
    /// A tab brought back, or merged in, waits unread until it is first shown.
    private(set) var loaded = false
    /// Whether the first read of the tab's folder showed it (nil: not finished), and who waits for it.
    private var firstRead: Bool?
    private var afterFirstRead: [(Bool) -> Void] = []
    /// The tab was sent to another folder while in the background (its folder moved, or its disk went): the folder
    /// is read when the tab is next shown.
    private(set) var stale = false
    /// A file operation ended with the tab at the back (the original's `stale`): as it comes back, its open tree branches
    /// are read again with its folder.
    var treeOutOfDate = false
    /// See `init`.
    private let startsTheWindow: Bool

    /// A tab on `tab`'s folder, with `history` (none: just the folder). It reads its folder when it is first shown,
    /// or at once with `loadNow`. `startsTheWindow`: the tab on screen as its window opens, which falls back to Home.
    init(
        tab: StartupTab, history: (paths: [String], index: Int)? = nil, frame: NSRect? = nil, loadNow: Bool = true,
        startsTheWindow: Bool = false
    ) {
        windowID = Self.nextWindowID
        Self.nextWindowID += 1
        self.startsTheWindow = startsTheWindow
        let sizes = FolderSizeService.shared.sizes(for: windowID)
        folderSizes = sizes
        content = ContentPaneController(mode: tab.viewMode, folderSizes: sizes, loaders: .placeholder)
        folderLetGo = tab.path.isEmpty
        folder = URL(fileURLWithPath: tab.path.isEmpty ? tab.rootPath : tab.path)
        viewMode = tab.viewMode
        searchViewMode = tab.searchViewMode
        sortBy = tab.sortBy
        sortDirection = tab.sortDirection
        includeHidden = tab.includeHidden
        foldersFirst = tab.foldersFirst
        if let history, history.paths.indices.contains(history.index) {
            self.navigationHistory = NavigationHistory(paths: history.paths, index: history.index)
        } else {
            self.navigationHistory = tab.path.isEmpty ? NavigationHistory() : NavigationHistory(startingAt: tab.path)
        }
        let window = ExplorerTabWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultContentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.tabbingIdentifier = "FileTrailBrowser"
        window.minSize = Self.minimumSize
        window.isReleasedWhenClosed = false
        let layout = WindowMetrics.standard.explorer
        workspace = WorkspaceView(
            panes: PaneWidths(
                treeWidth: layout.defaultTreeWidth, inspectorWidth: layout.defaultInspectorWidth, layout: layout))
        // A toolbar of its own per tab: toolbars that share an identifier share their items.
        explorerToolbar = ExplorerToolbar(identifier: "filetrail.explorer.\(windowID)")
        WindowChrome.configure(window, toolbar: explorerToolbar.toolbar)
        super.init(window: window)
        window.explorerTab = self
        window.delegate = self

        window.contentView = workspace
        // The menus and tooltips over the title bar the toolbar is drawn in.
        WindowOverlayView.install(in: window)
        configureSidebar()
        sidebar.restore(
            rootPath: tab.rootPath, folder: tab.path, favoritePath: tab.favoritePath,
            favoritesExpanded: tab.favoritesExpanded, locationsExpanded: tab.locationsExpanded,
            includeHidden: tab.includeHidden)
        workspace.sidebarCell.content = sidebar.view
        workspace.mainCell.content = content.view
        workspace.inspectorCell.content = infoPanel
        // The tree's resizer is in no pane, so Tab is the browser's: on to the toolbar, or back into the tree.
        workspace.treeResizer.onTab = { [weak self] backward in
            guard let self else { return }
            if backward {
                self.perform(.focusTreePane)
            } else if let window = self.window {
                ToolbarKeyboard.enterFromStart(of: window)
            }
        }
        // The Info panel's resizer too. Its Hide button is the next in the original, but nothing in the port's panel takes
        // the keyboard: Tab goes on past it, to the start of the row.
        workspace.inspectorResizer.onTab = { [weak self] backward in
            guard let self else { return }
            if backward {
                self.content.focusList()
            } else if let window = self.window {
                ToolbarKeyboard.enterFromStart(of: window)
            }
        }
        holdTabBar(of: window)
        workspace.onWidthsChosen = { [weak self] panes in
            self?.updatePanels {
                $0.treeWidth = Int(panes.preferredTreeWidth)
                $0.inspectorWidth = Int(panes.preferredInspectorWidth)
            }
        }
        if let frame {
            window.setFrame(frame, display: false)
        } else {
            window.setContentSize(Self.defaultContentSize)
            window.center()
        }

        wireContent()
        installMenusAndNotifications()
        installClipboardAndDrags()
        wirePathBar()
        infoController = InfoController(host: self, panel: infoPanel, row: content.contentShell.infoRow)
        explorerToolbar.attach(self)
        connectSearchField()
        installBatchRename()
        onFolderUsed = { [weak self] in self?.visitTracker.use() }
        #if DEBUG
            AutomationLayoutPrefs.registerOnce()
            AutomationSidebarPrefs.registerOnce()
            AutomationContentPrefs.registerOnce()
            AutomationNotificationPrefs.registerOnce()
            AutomationInfoPrefs.registerOnce()
            AutomationClipboardPrefs.registerOnce()
            AutomationSearchPrefs.registerOnce()
        #endif
        updateTitle()
        if loadNow { ensureLoaded() }
    }

    /// A tab on `folder`, as the app's latest values show folders.
    convenience init(folder: URL) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let defaults = AppPreferences.defaults()
        self.init(
            tab: StartupTabs.resolve(defaults, homePath: home, startupFolderPath: folder.path, restoreTabs: false)
                .tabs[0])
    }

    /// A tab as `snapshot` kept it: its folder, tree, view and history (Reopen Closed Tab, Duplicate Tab).
    convenience init(snapshot: TabSnapshot, frame: NSRect?) {
        let startup = StartupTab(
            path: snapshot.currentPath, rootPath: snapshot.treeRootPath,
            favoritePath: snapshot.selectedTreeItemID?.hasPrefix("favorite:") == true ? snapshot.currentPath : nil,
            viewMode: snapshot.viewMode, searchViewMode: snapshot.searchViewMode, sortBy: snapshot.sortBy,
            sortDirection: snapshot.sortDirection, includeHidden: snapshot.includeHidden,
            foldersFirst: snapshot.foldersFirst, favoritesExpanded: snapshot.favoritesExpanded,
            locationsExpanded: snapshot.locationsExpanded)
        self.init(tab: startup, history: (snapshot.historyPaths, snapshot.historyIndex), frame: frame)
        startingPane = snapshot.focusedPane
        if let view = snapshot.view { carry(view, of: snapshot) }
    }

    /// `showSnapshot`: the tab starts with the view the other one had. Its folder is read as it first shows, the task
    /// for that not having run yet.
    private func carry(_ view: TabViewState, of snapshot: TabSnapshot) {
        carriedView = view
        folderMemories = view.folderViewMemories
        sidebar.holdsScrollPosition = true
        sidebar.restoreView(
            nodes: ExplorerTabs.settleTreeNodes(view.treeNodes), selectedItem: snapshot.selectedTreeItemID,
            subview: snapshot.leftPaneSubview == .favorites ? .favorites : .tree)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: The tab

    /// The tab as it is saved between launches (`toOpenTabPreference`).
    var openTab: OpenTabPreference {
        let path = shownFolderPath
        return OpenTabPreference(
            path: path.isEmpty ? nil : path, treeRootPath: treeRootPath.isEmpty ? nil : treeRootPath,
            favoritePath: favoritePath == path ? favoritePath : nil, viewMode: viewMode, searchViewMode: searchViewMode,
            sortBy: sortBy, sortDirection: sortDirection, includeHidden: includeHidden, foldersFirst: foldersFirst,
            favoritesExpanded: favoritesExpanded, locationsExpanded: locationsExpanded)
    }

    /// The tab as a new tab or a reopened one starts from it.
    var startupTab: StartupTab {
        StartupTab(
            path: shownFolderPath, rootPath: treeRootPath, favoritePath: favoritePath, viewMode: viewMode,
            searchViewMode: searchViewMode, sortBy: sortBy, sortDirection: sortDirection,
            includeHidden: includeHidden, foldersFirst: foldersFirst, favoritesExpanded: favoritesExpanded,
            locationsExpanded: locationsExpanded)
    }

    /// The view on screen: search results have one of their own (`shownViewMode`).
    var shownViewMode: ExplorerViewMode { searchStore?.showsResults == true ? searchViewMode : viewMode }

    /// Whether a text field of the tab (the search field, the results' filter, a rename) has the keyboard.
    var isTextFieldEditing: Bool {
        guard let editor = window?.firstResponder as? NSTextView else { return false }
        return editor.isFieldEditor
    }

    /// Reveal in Folder (B-SRCH-148): the folder a result is in opens, with the result selected and the list focused.
    func revealSearchResult(_ path: String) {
        AppMenuPresenter.shared.close()
        guard let parent = ExplorerTabs.parentDirectoryPath(path) else { return }
        let target = URL(fileURLWithPath: parent)
        let move: HistoryMove = !folderLetGo && target.comparablePath == folder.comparablePath ? .replace : .push
        Task {
            guard await navigate(to: target, history: move) != nil else { return }
            // By its name in the folder opened: the listing gives its rows the folder's real path, which may be spelled
            // otherwise than the one the search ran from (/private/var for /var).
            let name = NodePath.basename(path)
            let row =
                content.listed.first { $0.path == path }
                ?? content.listed.first { $0.name.utf16.elementsEqual(name.utf16) }
            content.select(paths: [row?.path ?? path])
            content.focusList()
        }
    }

    /// What the tab keeps of itself (`captureLiveTab`).
    var snapshot: TabSnapshot {
        let pane = focusedPane ?? lastFocusedPane
        return TabSnapshot(
            currentPath: shownFolderPath, historyPaths: navigationHistory.paths,
            historyIndex: max(0, navigationHistory.index),
            viewMode: viewMode, searchViewMode: searchViewMode, sortBy: sortBy, sortDirection: sortDirection,
            treeRootPath: treeRootPath,
            selectedTreeItemID: sidebar.selectedTreeItemID ?? (folderLetGo ? nil : "fs:\(folder.path)"),
            leftPaneSubview: sidebar.leftPaneSubview == .favorites ? .favorites : .tree,
            focusedPane: pane == .tree ? .tree : .content,
            includeHidden: includeHidden, foldersFirst: foldersFirst, favoritesExpanded: favoritesExpanded,
            locationsExpanded: locationsExpanded, view: liveView)
    }

    /// The view on screen (`captureLiveTab`): none for a tab whose folder is yet to be read somewhere else. A tab that
    /// has not read its first folder still has what it was started with. With search results showing, their selection,
    /// filter and scroll are what is taken: a tab has one set of them.
    private var liveView: TabViewState? {
        guard !stale else { return nil }
        if var carriedView {
            carriedView.treeNodes = sidebar.model.nodes
            return carriedView
        }
        guard hasShownFolder else { return nil }
        var view = TabViewState()
        view.treeNodes = sidebar.model.nodes
        view.treeScrollTop = sidebar.tree.scrollTop
        view.sidebarSectionsScrollTop = sidebar.sections.scrollTop
        view.folderViewMemories = folderMemories
        if case .failed(let message) = content.loadState {
            view.directoryError = message
        } else {
            view.directoryError = content.readError
        }
        if let shown = content.captureFolderView() {
            view.contentSelection = shown.selection
            view.listFilterQuery = content.filter
            view.contentScroll = CGPoint(x: shown.scrollLeft, y: shown.scrollTop)
        }
        return view
    }

    /// What the tab bar calls the tab.
    var tabDescription: TabDescription {
        guard let session = searchStore?.session else {
            return ExplorerTabs.describe(
                currentPath: shownFolderPath, searchVisible: false, searchQuery: "", searchRootPath: "",
                searchRunning: false)
        }
        return ExplorerTabs.describe(
            currentPath: shownFolderPath, searchVisible: session.resultsVisible, searchQuery: session.committedQuery,
            searchRootPath: session.rootPath, searchRunning: session.isRunning)
    }

    /// Reads the tab's folder the first time it is shown, or again when it was sent elsewhere in the background.
    /// A folder has been on screen in this tab.
    private var hasShownFolder = false
    /// The view the tab was started with (`carry`), until its first folder has been shown that way.
    private var carriedView: TabViewState?
    /// The pane the keyboard goes to as the tab shows its first folder: the one the tab it came from had it in.
    var startingPane = TabSnapshot.FocusedPane.content
    /// The tab was opened on a folder (`openPathInNewTab`): its first folder can count as a visit for the Go To box.
    var opensAsArrival = false

    func ensureLoaded() {
        if loaded {
            if stale {
                stale = false
                // At once: the tab is being read, and has no need to read again as it comes to the front.
                isNavigating = true
                navigationTarget = folder
                Task {
                    await openNearestExistingFolder(
                        folder.path, history: .none, keepingSearch: true, restoringView: true)
                    sidebar.refreshBranches()
                }
            }
            return
        }
        loaded = true
        Task {
            let read: Bool
            if folderLetGo {
                showNoFolder()
                sidebar.refreshBranches()
                read = false
            } else if startsTheWindow {
                read = await readStartupFolder()
            } else {
                read = await readFirstFolder()
            }
            if let ready = onReady {
                onReady = nil
                ready()
            }
            firstRead = read
            for action in afterFirstRead { action(read) }
            afterFirstRead = []
        }
    }

    /// The sidebar's row of the tab's favorite stays selected as its folder opens, the tree filled in on its own: a
    /// favorite is not looked up in the tree.
    private func openKeepingFavoriteRow() -> SidebarOpen? {
        guard let favorite = favoritePath, favorite == folder.path else { return nil }
        let root = treeRootPath
        Task { await sidebar.model.loadChildren(root) }
        return SidebarOpen(origin: .alias)
    }

    /// A tab that carries a view has its tree and row as they were (`mode: "none"`): nothing follows the folder.
    private func openKeepingCarriedTree() -> SidebarOpen? {
        guard carriedView != nil else { return nil }
        let root = treeRootPath
        Task { await sidebar.model.loadChildren(root) }
        return SidebarOpen(origin: .alias)
    }

    /// A tab shown for the first time, or one just opened: its folder, or the nearest one above it that can be read.
    /// Whether its own folder opened.
    private func readFirstFolder() async -> Bool {
        let open = openKeepingCarriedTree() ?? openKeepingFavoriteRow() ?? .other
        return await openNearestExistingFolder(
            folder.path, history: .none, open: open, readFailure: firstReadFailure, restoringView: true,
            arrives: opensAsArrival)
    }

    /// What a failed read does to the tab's first folder. The original doesn't read a carried folder (`mode: "none"`):
    /// the tab stays on it as it was, with its error if it had one. Here it is read, so one that was fine and has since
    /// gone gives way, as it does there on hearing of that.
    private var firstReadFailure: ReadFailure {
        guard let carriedView else { return .leavesFolderOnScreen }
        return carriedView.directoryError != nil ? .opens : .opensUnlessGone
    }

    /// The tab on screen as its window opens (`App.tsx`): a saved favorite opens even if it can't be read, showing why;
    /// any other folder that can't be read gives way to Home, with the tree at Home (B-NAV-122, B-TREE-186).
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
        sidebar.model.initializeTree(home)
        return await attemptNavigation(to: URL(fileURLWithPath: home), history: .replace).didOpen
    }

    /// Runs `action` once the first read of the tab's folder has finished, with whether it showed the folder.
    func whenFirstReadFinished(_ action: @escaping (Bool) -> Void) {
        if let firstRead {
            action(firstRead)
        } else {
            afterFirstRead.append(action)
        }
    }

    /// `followMovedItems` and `leaveUnmountedDisks` for a tab in the background: it takes the place `snapshot` gives
    /// it (folder, history, tree root) and reads its folder when it is next shown.
    func takePlace(_ snapshot: TabSnapshot) {
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
        let favoritePrefix = "favorite:"
        let favorite = snapshot.selectedTreeItemID.flatMap {
            $0.hasPrefix(favoritePrefix) ? String($0.dropFirst(favoritePrefix.count)) : nil
        }
        sidebar.restore(
            rootPath: snapshot.treeRootPath, folder: snapshot.currentPath, favoritePath: favorite,
            favoritesExpanded: sidebar.favoritesExpanded, locationsExpanded: sidebar.locationsExpanded,
            includeHidden: includeHidden)
        if moved, loaded { stale = true }
        updateTitle()
        updateNavigationItems()
        group?.tabChanged(self)
    }

    /// `followForeignMoveOnScreen`: the folder on screen, or one it is inside, was renamed or moved: it is read at its
    /// new place, in place in the history.
    func followOnScreen(_ moves: [PathMove]) {
        let path = shownFolderPath
        let followed = ExplorerTabs.followMovedPath(path, moves)
        guard !path.isEmpty, followed != path else { return }
        let target = URL(fileURLWithPath: followed)
        if loaded {
            go(to: target, history: .replace)
        } else {
            folder = target
            updateTitle()
            group?.tabChanged(self)
        }
    }

    /// Reads the folder on screen again, quietly: something changed in it. `changedPaths` are the items the change
    /// touched (nil: anything in it may have).
    func reload(changedPaths: [String]? = nil) {
        guard loaded, !folderLetGo else { return }
        pendingChange = PendingChange.merging(pendingChange, path: folder.path, changedPaths)
        flushPendingChange()
    }

    /// The folder read again because the app asks (`refreshDirectory`), not because of a change from outside: Show Info's
    /// item goes.
    func readAgain() {
        infoController?.letShowInfosItemGo()
        // Nothing is said to have changed: the rows keep the details they have (`navigateTo` keeps the metadata cache), so
        // a folder a write went into shows its old date until something outside says otherwise.
        reload(changedPaths: [])
    }

    /// Changes made outside the app wait while something the list changing under would upset is going on: a name being
    /// typed, a menu or a sheet open, a file operation running, a drag (B-VIEW-187).
    var folderChangesHeld = false {
        didSet {
            if !folderChangesHeld { flushPendingChange() }
        }
    }

    /// The changes waiting to be read, merged: the set of changed items is the union, or nil (a full read) if any change
    /// did not say which items changed, or there are more than 1,000 (B-VIEW-188).
    struct PendingChange {
        /// The folder that changed.
        var path: String
        var changedPaths: Set<String>?

        /// What was waiting of another folder gives way (`addPending`).
        @MainActor static func merging(_ pending: PendingChange?, path: String, _ paths: [String]?) -> PendingChange {
            guard let pending, pending.path == path else {
                return PendingChange(path: path, changedPaths: paths.map(Set.init))
            }
            guard let existing = pending.changedPaths, let paths else {
                return PendingChange(path: path, changedPaths: nil)
            }
            let union = existing.union(paths)
            return PendingChange(path: path, changedPaths: union.count > FolderWatches.maxChangedPaths ? nil : union)
        }
    }

    /// While a dialog is open or a name is being typed a press on the tab bar does nothing and the keyboard stays: the
    /// original's tabs sit under the dialog's scrim, keep the focus where it is (`onMouseDown` `preventDefault` in
    /// TabStrip.tsx) and refuse to change (`canChangeTabs`). A left press is still a press on that scrim, which may close
    /// the dialog. Last, so what closes on a press outside it still hears it.
    private func holdTabBar(of window: NSWindow) {
        WindowEventRouting.add(window, last: true) { [weak self, weak window] event in
            guard let self, let window, [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type),
                self.group?.holdsTabBar == true, ExplorerTabGroup.isTabBarPress(at: event.locationInWindow, in: window)
            else { return false }
            if event.type == .leftMouseDown { DialogScrim.front(in: window)?.onScrimPress?() }
            return true
        }
    }

    func flushPendingChange() {
        // A file operation running here or in another window holds them too (B-CLIP-147, WriteOperations/).
        guard let pending = pendingChange, !changeRetryWaiting, !folderChangesHeld, !renameHoldsChanges, !isWriteLocked,
            !quietReadInFlight
        else { return }
        // Changes to a folder no longer on screen don't matter (useFolderWatch.ts:60), and another folder being opened leaves
        // this one behind: reading it again would go back to it, or read the new one for them (B-VIEW-195).
        guard pending.path == folder.path, !isNavigating || navigationTarget?.comparablePath == folder.comparablePath
        else {
            pendingChange = nil
            return
        }
        // The folder on screen is being read already, by a read that may have started before the change: it is tried again
        // shortly (B-VIEW-189).
        if isNavigating {
            changeRetryWaiting = true
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.retryDelay) { [weak self] in
                MainActor.assumeIsolated {
                    self?.changeRetryWaiting = false
                    self?.flushPendingChange()
                }
            }
            return
        }
        pendingChange = nil
        quietReadInFlight = true
        Task {
            await quietRead(pending.changedPaths.map { Array($0) })
            quietReadInFlight = false
            flushPendingChange()
        }
    }

    /// A folder read again in place: the selection, scroll and details stay; the error clears when the answer arrives
    /// (B-NAV-115, B-NAV-134).
    private func quietRead(_ changedPaths: [String]?) async {
        let url = folder
        let result = await readFolder(url)
        // The folder was left meanwhile: the user's folder wins (B-VIEW-195).
        guard url == folder, !isNavigating, !folderLetGo else { return }
        switch result.snapshot {
        case .success(let snapshot):
            isTakingInOutsideChange = true
            defer { isTakingInOutsideChange = false }
            content.show(
                folder: url.path, entries: snapshot.entries, selecting: nil, keepingScroll: true,
                changedPaths: changedPaths)
            notify(.folder)
        case .failure(let error):
            if FolderReadFailure.isGone(error) {
                await openNearestExistingFolder(above: url.path)
            } else {
                content.showError(folder: url.path, message: FolderReadFailure.message(error))
            }
        }
    }

    /// The folder on screen is gone: the nearest folder above it that still exists is opened in its place, and the
    /// selection is not carried over (B-VIEW-194).
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

    /// `navigateToNearestExistingFolder`: opens `path`, or the nearest folder above it that can be read. A newer navigation
    /// that takes over ends the attempt. Whether `path` itself opened.
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

    /// `reloadFolderInPlace`: a tab that comes back reads its folder again where it stands, for it may have changed while
    /// another tab was in front. The selection, the search results and the place in the history stay; one that can't be
    /// read stays, showing why; one that is gone gives way to the nearest folder above it. `refreshingTree`: the tree's open
    /// branches are read again too.
    private func reloadFolderInPlace(refreshingTree: Bool) async {
        let path = folder.path
        let outcome = await attemptNavigation(
            to: folder, history: .none, open: sidebar.model.openReadingAgain(path), keepingSearch: true,
            readFailure: .opensUnlessGone, quiet: true, keepingSelection: true)
        var opened = outcome.didOpen
        if case .failed = outcome { opened = await openNearestExistingFolder(above: path) }
        if refreshingTree, opened { await sidebar.model.refreshBranches() }
    }

    /// Another tab came to the front. The window's one tracker hears of a folder on screen changing (`showing`), so the
    /// folder this tab was still being decided on was only passed through; each tab here has a tracker of its own.
    func wentToTheBack(for other: MainWindowController) {
        visitTracker.showing(other.shownFolderPath)
        if waitingReadAgain == true { treeOutOfDate = true }
        waitingReadAgain = nil
    }

    /// The tab is on screen again after another one, or for the first time (`showSnapshot`). Show Info's item doesn't
    /// outlast it (B-INFO-008).
    func cameBack() {
        infoController?.letShowInfosItemGo()
        // The keyboard goes back to the pane the tab had it in, not the search field a window remembers on its own
        // (useExplorerTabs.ts). A tab just made gives it out when its first folder comes. A dialog open on the tab keeps
        // it (useDialogFocus.ts) and hands it back to the pane when it closes.
        if hasShownFolder, DialogScrim.front(in: window) == nil { keyboardBackToPane() }
        // Its dates stood still while it was at the back.
        RelativeClock.shared.windowStateDidChange()
        let refreshingTree = treeOutOfDate
        treeOutOfDate = false
        guard loaded, !stale else {
            ensureLoaded()
            return
        }
        // Just made, it is reading its folder already.
        guard hasShownFolder, !isNavigating, !folderLetGo else { return }
        readAgainAfterDrawing(refreshingTree: refreshingTree)
    }

    /// The folder is read again once the tab has been drawn, so the switch doesn't wait for it, and not at all if another
    /// tab has come to the front by then. The value says whether the read covers the tree.
    private var waitingReadAgain: Bool?

    private func readAgainAfterDrawing(refreshingTree: Bool) {
        waitingReadAgain = refreshingTree || waitingReadAgain == true
        // The main queue takes what is added while it runs on its next turn of the run loop, after this turn's drawing.
        DispatchQueue.main.async { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let refreshingTree = self.waitingReadAgain else { return }
                    self.waitingReadAgain = nil
                    guard self.hasShownFolder, !self.isNavigating, !self.folderLetGo else {
                        if refreshingTree { self.treeOutOfDate = true }
                        return
                    }
                    Task { await self.reloadFolderInPlace(refreshingTree: refreshingTree) }
                }
            }
        }
    }

    private static let retryDelay = 0.25

    private func updateTitle() {
        // The window title is the folder name, which the toolbar shows; the tab bar and the Window menu have the
        // tab's label (ExplorerTabGroup.refreshTitles).
        let name = ExplorerTabs.folderDisplayName(shownFolderPath)
        window?.title = name.isEmpty ? "File Trail" : name
        window?.representedURL = folderLetGo ? nil : folder
    }

    // MARK: Navigation

    func go(to url: URL, history: HistoryMove = .push, open: SidebarOpen = .other, keepingSearch: Bool = false) {
        Task { await navigate(to: url, history: history, open: open, keepingSearch: keepingSearch) }
    }

    /// What a read of a folder gave, and how long it took.
    struct FolderRead {
        var snapshot: Result<DirectorySnapshot, any Error>
        var duration: Duration
    }

    /// Reads a folder through the directory service: in the order the tab keeps, with hidden files and folders first
    /// as the tab has them.
    private func readFolder(_ url: URL) async -> FolderRead {
        let service = services.directoryService
        let path = url.path
        let key = DirectorySortKey(rawValue: sortBy.rawValue) ?? .name
        let direction: SortDirection = sortDirection == .asc ? .ascending : .descending
        let hidden = includeHidden
        let first = foldersFirst
        let clock = ContinuousClock()
        let started = clock.now
        let snapshot = await Result {
            try await service.snapshot(
                path: path, includeHidden: hidden, sortBy: key, sortDirection: direction, foldersFirst: first)
        }
        return FolderRead(snapshot: snapshot, duration: clock.now - started)
    }

    /// Reads `url`, then shows it. Returns nil when a later navigation replaced this one or the folder didn't open. `open`
    /// says how the sidebar reached it, which decides how the sidebar's tree follows and which of its rows is selected.
    /// The listing in front stays on screen until the new one arrives (B-NAV-113).
    /// With `goToFailure` it is Go To (`viaGoTo`): a folder that can't be read leaves the one on screen, and the
    /// read's message goes there instead (B-DLG-013).
    @discardableResult
    func navigate(
        to url: URL, history move: HistoryMove = .push, open: SidebarOpen = .other, keepingSearch: Bool = false,
        goToFailure: ((String) -> Void)? = nil
    ) async -> NavigationTiming? {
        let outcome = await attemptNavigation(
            to: url, history: move, open: open, keepingSearch: keepingSearch, goToFailure: goToFailure)
        if case .opened(let timing) = outcome { return timing }
        return nil
    }

    /// What the folder just shown takes from the tab it was started with, besides what `content.show` restored.
    private func showCarried(_ carried: TabViewState, folderWasRead: Bool) {
        content.setFilter(carried.listFilterQuery)
        // Something selected outside the filter shows the whole list again (useExplorerNavigationController.ts).
        if let lead = content.selection.leadPath, !content.filter.isEmpty,
            !content.entries.contains(where: { $0.path == lead }), content.listed.contains(where: { $0.path == lead })
        {
            content.clearFilter()
        }
        // A folder with a message over it (a Go To that failed) has it still, for the original reads nothing here.
        // `beginLoading` first: `showReadError` goes back to the state from before it.
        if folderWasRead, let message = carried.directoryError {
            content.beginLoading(quiet: false)
            content.showReadError(message)
        }
    }

    /// The tab's first folder has been shown, as `carried` had it if that was its folder.
    private func finishCarrying(_ carried: TabViewState?) {
        guard carriedView != nil else { return }
        carriedView = nil
        sidebar.holdsScrollPosition = false
        if let carried {
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

    /// `navigateTo`. `readFailure` is what a folder that can't be read does; by default only the sidebar's favorites,
    /// locations and links open anyway (B-NAV-006, B-NAV-007, B-NAV-022). `quiet`: the folder is on screen and is only
    /// read again, so no "Loading…". `keepingSelection`: it is read in place, its selection and scroll staying. `arrives`:
    /// the tab's first folder counts as gone to, as `openPathInNewTab`'s does (the one step of its history is there already).
    private func attemptNavigation(
        to url: URL, history move: HistoryMove = .push, open: SidebarOpen = .other, keepingSearch: Bool = false,
        goToFailure: ((String) -> Void)? = nil, readFailure: ReadFailure? = nil, quiet: Bool = false,
        keepingSelection: Bool = false, restoringView: Bool = false, arrives: Bool = false
    ) async -> NavigationOutcome {
        self.loaded = true
        navigationToken += 1
        let token = navigationToken
        isNavigating = true
        navigationTarget = url
        defer { if token == navigationToken { isNavigating = false } }
        let clock = ContinuousClock()
        let started = clock.now
        let move = open.pushesHistory ? move : HistoryMove.none
        // The folder being left is remembered first: what was selected and where the list was scrolled (B-NAV-043).
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
        // Back, Forward and the hold menus move within the history at once, before the folder is read (B-NAV-014).
        switch move {
        case .back: navigationHistory.goBack()
        case .forward: navigationHistory.goForward()
        case .jump(let index): navigationHistory.jump(to: index)
        case .push, .none, .replace: break
        }
        let keepsSearch = keepingSearch
        content.beginLoading(quiet: quiet)
        let read = await readFolder(url)
        guard token == navigationToken else { return .superseded }
        let readAt = clock.now

        var entries: [DirectoryEntry] = []
        // The folder is known by the real path its listing gives (`response.path`), not the spelling it was asked by; one
        // that can't be listed has only that spelling (B-NAV-006).
        var shown = url
        var opensWithError = false
        switch read.snapshot {
        case .success(let snapshot):
            entries = snapshot.entries
            shown = URL(fileURLWithPath: snapshot.path)
        case .failure(let error):
            let message = FolderReadFailure.message(error)
            if let goToFailure {
                content.showReadError(message)
                goToFailure(message)
                return .failed
            }
            switch readFailure ?? (open.origin.opensWhenUnreadable ? .opens : .leavesFolderOnScreen) {
            case .opens: opensWithError = true
            case .opensUnlessGone: opensWithError = !FolderReadFailure.isGone(error)
            case .leavesFolderOnScreen: opensWithError = false
            }
            guard opensWithError else {
                // A quiet read shows nothing: the search for a folder that can be read goes on from it.
                if !quiet { content.showReadError(message) }
                sidebar.openFailed()
                updateNavigationItems()
                return .failed
            }
        }

        // Opening a folder puts search results away, once it has arrived (B-NAV-021), the folder on screen too (Reveal in
        // Folder there, B-NAV-211); only a read in place that asks to keep them (an order, hidden files, a tab coming back)
        // leaves them (B-SRCH-069, B-NAV-215).
        if !keepsSearch, let search = searchStore, search.session.isSearchMode {
            // Back and Forward can bring them back; choosing the folder they cover closes them.
            let sameFolder = shown.comparablePath == folder.comparablePath
            search.session.hideResults(returnPlace: sameFolder ? nil : leftPlace)
        }

        // A folder is added to the history only after its listing has arrived and been applied (B-NAV-006).
        switch move {
        case .push:
            navigationHistory.record(shown.path, mode: .push)
            if !opensWithError { visitTracker.arrive(shown.path, viaGoTo: goToFailure != nil) }
        case .replace:
            navigationHistory.record(shown.path, mode: .replace)
        case .back, .forward, .jump:
            // Back and Forward never count as a visit (B-NAV-019).
            if !opensWithError { visitTracker.showing(shown.path) }
        case .none:
            // A tab that starts on a folder by another spelling: its one step is the folder as it is.
            if navigationHistory.current == url.path, shown.path != url.path {
                navigationHistory.record(shown.path, mode: .replace)
            }
            if arrives, !opensWithError { visitTracker.arrive(shown.path, viaGoTo: false) }
        }
        // What the tab was started with is for the folder it was started on, not one that took its place.
        let carried = url.comparablePath == folder.comparablePath ? carriedView : nil
        folder = shown
        folderLetGo = false

        // Opening a folder normally starts with nothing selected, and the list at the top (B-SEL-029, B-NAV-059).
        let memory =
            carried.map {
                FolderViewMemory(
                    selection: $0.contentSelection, scrollTop: $0.contentScroll.y, scrollLeft: $0.contentScroll.x)
            } ?? ((move.restoresView && !bringsResultsBack) || restoringView ? folderMemories[shown.path] : nil)
        updateTitle()
        if !keepsSearch, let search = searchStore, !search.session.isSearchMode { search.session.setDraft("") }
        // A folder opened from the sidebar leaves the keyboard there. The tab's first folder wasn't: AppKit gives a window
        // that comes to the front its first key view, which is the sidebar's, and a fresh tab focuses the list.
        let isFirstFolder = !hasShownFolder
        hasShownFolder = true
        let sidebarKeyboard = sidebar.isFocused && !isFirstFolder ? window?.firstResponder : nil
        switch read.snapshot {
        case .success:
            // The rows of a folder read again keep the details they have, as `navigateTo` keeps the metadata cache, and
            // not only when it is read in place: nothing is said to have changed (hidden files shown, a new sort).
            content.show(
                folder: shown.path, entries: entries, selecting: keepingSelection ? nil : [],
                keepingScroll: keepingSelection, changedPaths: [], restoring: memory)
            // Before the window draws, so the folder underneath does not flash by. The folder is what they lie over: the
            // tree and the path bar show it.
            if bringsResultsBack { searchStore?.session.showCachedResults() }
        case .failure(let error):
            content.showError(folder: shown.path, message: FolderReadFailure.message(error))
        }
        if let carried { showCarried(carried, folderWasRead: !opensWithError) }
        if let sidebarKeyboard {
            window?.makeFirstResponder(sidebarKeyboard)
        } else if let window, isFirstFolder, startingPane == .tree, panels.folderTreeOpen {
            // The keyboard goes back to the pane the tab had it in (useExplorerTabs.ts).
            sidebar.focusTree()
            window.initialFirstResponder = window.firstResponder as? NSView
        } else if let window, isFirstFolder || window.firstResponder == nil || window.firstResponder === window {
            // When no pane has the keyboard it goes to the file list (B-SEL-167, B-NAV-191: a fresh tab focuses the list).
            content.focusList()
            if isFirstFolder { window.initialFirstResponder = content.focusView }
        }
        if opensWithError {
            sidebar.folderOpenedWithError(shown, open)
        } else {
            sidebar.folderOpened(shown, open)
        }
        updateNavigationItems()
        updatePathBar()
        notify(.folder)
        window?.contentView?.layoutSubtreeIfNeeded()
        if let carried { content.pane?.scrollPosition = (carried.contentScroll.y, carried.contentScroll.x) }
        if isFirstFolder { finishCarrying(carried) }
        // The results' list has only now been laid out, so their selection can be brought into view.
        if bringsResultsBack, searchStore?.session.isSearchMode == true { content.applySelection(content.selection) }
        window?.displayIfNeeded()
        if let callback = onFirstDraw {
            onFirstDraw = nil
            callback()
        }
        group?.tabChanged(self)

        let timing = NavigationTiming(
            folder: shown, itemCount: entries.count, read: read.duration, load: readAt - started,
            display: clock.now - readAt)
        if Self.logsTimings {
            FileHandle.standardError.write(
                Data(
                    String(
                        format: "navigate %@ (%d items): load %.1f ms, display %.1f ms\n",
                        shown.path, timing.itemCount, timing.load.milliseconds,
                        timing.display.milliseconds
                    ).utf8))
        }
        return .opened(timing)
    }

    /// Where the tab is, history and sidebar row with it (`TabPlace`).
    struct TabPlace {
        let path: String
        let history: NavigationHistory
        let sidebarRow: TreeItemID?
    }

    var tabPlace: TabPlace {
        TabPlace(path: folder.path, history: navigationHistory, sidebarRow: sidebar.model.selected)
    }

    /// A drag's springs are undone: the folder opens as it was left, and its history and sidebar row come back with it,
    /// once it has opened. A folder that can't (gone meanwhile) leaves the tab where the drag left it.
    func comeBack(to place: TabPlace) async {
        let outcome = await attemptNavigation(
            to: URL(fileURLWithPath: place.path), history: .none, open: SidebarOpen(origin: .alias),
            readFailure: .leavesFolderOnScreen, restoringView: true)
        guard outcome.didOpen else { return }
        navigationHistory = place.history
        sidebar.model.restoreSelected(place.sidebarRow)
        updateNavigationItems()
        group?.tabChanged(self)
    }

    // MARK: Opening items

    /// The folder visits the Go To box counts (B-NAV-200 to B-NAV-204).
    private lazy var visitTracker = FolderVisitTracker { path, kind in
        MainWindowController.visitStore()?.recordFolderVisit(path, kind: kind)
    }

    /// What the plan of the items to open needs of the entries on screen.
    private func commandEntries(_ entries: [DirectoryEntry]) -> [CommandEntry] {
        entries.map { CommandEntry(path: $0.path, kind: FTFoundation.EntryKind(rawValue: $0.kind.rawValue) ?? .other) }
    }

    /// Double-click, Return (set to Open) and ⌘↓: opens the items, or edits them as "Double-click a file to" says
    /// (`activateContentPaths`). ⌘-double-click on a folder opens it in a new tab, as in Finder.
    func open(_ entries: [DirectoryEntry], inNewTab: Bool = false) {
        if inNewTab, entries.count == 1, entries[0].isDirectoryLike {
            openFolderInNewTab(entries[0])
            return
        }
        let prefs = preferences
        // Search results always open, never the edit-in-editor activation (B-SRCH-147).
        let activation = searchRootPath != nil ? FileActivationAction.open : prefs.fileActivationAction
        perform(
            OpenItems.activation(commandEntries(entries), fileActivation: activation, limit: prefs.openItemLimit))
    }

    /// `openFolderInNewTab`: a folder alias on screen opens the folder it points to, as it does when opened in place.
    private func openSelectedFolder(_ folder: URL, place: SelectedFolderPlace) {
        let open: (String) -> Void = { [weak self] path in
            guard let self else { return }
            switch place {
            case .tab: self.group?.openTab(path: path, from: self)
            case .window: self.group?.openNewWindow(from: self, path: path)
            }
        }
        guard content.entries.first(where: { $0.path == folder.path })?.kind == .symlinkDirectory else {
            open(folder.path)
            return
        }
        Task {
            if let target = await Self.resolved(folder.path) { open(target) }
        }
    }

    private enum SelectedFolderPlace { case tab, window }

    private func openFolderInNewTab(_ entry: DirectoryEntry) {
        if entry.kind == .symlinkDirectory {
            Task {
                guard let target = await Self.resolved(entry.path) else { return }
                group?.openTab(path: target, from: self)
            }
        } else {
            group?.openTab(path: entry.path, from: self)
        }
    }

    /// `path:resolve`: where a link points.
    /// Looked up off the main thread: a link into a slow volume must not freeze the window.
    private static func resolved(_ path: String) async -> String? {
        await Task.detached(priority: .userInitiated) { try? NativeFileSystem().realpath(path) }.value
    }

    private func perform(_ plan: OpenItems.Plan) {
        switch plan {
        case .nothing:
            break
        case .tooMany(let action, let selected, let limit):
            notice(
                title: OpenItems.limitTitle(action: action),
                message: OpenItems.limitMessage(action: action, selected: selected, limit: limit))
        case .edit(let paths):
            let editor = preferences.defaultTextEditor
            onFolderUsed?()
            let opener = opener
            Task { [weak self] in
                let result = await SystemActions.openPaths(paths, withApplication: editor.appPath, opener: opener)
                guard !result.ok else { return }
                self?.notice(
                    title: ActionNoticeText.openFailureTitle(editor.appName),
                    message: ActionNoticeText.openFailureMessage(
                        count: paths.count, appName: editor.appName,
                        detail: result.error ?? "\(editor.appName) didn’t answer."))
            }
        case .steps(let steps):
            for step in steps {
                switch step {
                case .navigate(let path):
                    go(to: URL(fileURLWithPath: path))
                case .resolveThenNavigate(let path):
                    // Another tab may have come to the front while the link was looked up.
                    let token = navigationToken
                    Task {
                        guard let target = await Self.resolved(path), token == navigationToken, isKeyOrOnly else {
                            return
                        }
                        go(to: URL(fileURLWithPath: target))
                    }
                case .resolveThenOpen(let path):
                    Task {
                        guard let target = await Self.resolved(path) else { return }
                        openExternally(target)
                    }
                case .openExternally(let path):
                    openExternally(path)
                }
            }
        }
    }

    /// `openPathExternally`: a file or app opens in what macOS chooses, a disk image here, as in Finder (B-NAV-072).
    /// Either counts as using the folder (B-NAV-071).
    func openExternally(_ path: String) {
        if !noteUseAndOpenDiskImage(path) { openFile(URL(fileURLWithPath: path)) }
    }

    /// The start of `openPathExternally`, whichever control asks. True when `path` was a disk image, and is dealt with here.
    func noteUseAndOpenDiskImage(_ path: String) -> Bool {
        onFolderUsed?()
        guard DiskImageNames.isDiskImagePath(path), let group else { return false }
        group.openDiskImage(path)
        return true
    }

    /// The tab is still the one on screen (its window is not behind another tab of its group).
    private var isKeyOrOnly: Bool {
        guard let window else { return false }
        return window.tabGroup?.selectedWindow == nil || window.tabGroup?.selectedWindow === window
    }

    /// A rename's refusal with no field left to show it under: through the file operations' dialogs when the app has
    /// started them.
    private func renameNotice(title: String, message: String) {
        if let actions = writeActions {
            actions.dialogs.show(title, message, window)
        } else {
            notice(title: title, message: message)
        }
    }

    /// A notice the person dismisses (`showModalNotice`): the open limit.
    private func notice(title: String, message: String) {
        showNotice(title: title, message: message)
    }

    // MARK: Keys and rename

    /// Return in the file list (with an item selected): Open or Rename, as the Return key setting says (B-SEL-106).
    private func pressedReturn() {
        let selected = content.selectedEntries
        guard !selected.isEmpty else { return }
        switch preferences.returnKeyAction {
        case .rename: renameSelected()
        case .open: open(selected)
        }
    }

    /// A command the list's keys ask for: the key is one the menu does not listen for (a command's second key, Space,
    /// F2, ⌘←). Whether the window ran it. Keys don't go by what dims the menu (`onKeyDown` asks only
    /// `canHandleRendererCommand`): a command that can't start says why itself.
    private func runKeyCommand(_ id: ShortcutCommandID) -> Bool {
        if id == .openSelectedItem { return openSelectedItem() }
        guard let command = RendererCommand(rawValue: id.rawValue), ShortcutPolicy.canHandle(command, shortcutContext)
        else { return false }
        perform(command)
        return true
    }

    /// A key whose menu item is dimmed: the item would keep it and do nothing, where the original's window hears the key
    /// before its menu (useExplorerShortcuts.ts:1569-1603) and runs the command, which shows why it can't start: the
    /// busy notice, the open limit's notice, Duplicate's toast. An item that is on keeps its own key.
    func keyOfDimmedItem(_ event: NSEvent) -> Bool {
        guard !isTextFieldEditing, !isDialogOpen,
            let pressed = Shortcuts.fromKeyboardEvent(ContentKeyboard.shortcutEvent(event)),
            let id = ShortcutCommands.resolve(preferences.shortcutOverrides).commandByShortcut[pressed],
            id != .openSelectedItem, let command = RendererCommand(rawValue: id.rawValue), !canPerform(command),
            ShortcutPolicy.canHandle(command, shortcutContext)
        else { return false }
        if WriteStartingShortcuts.runs(id.rawValue, isRepeat: event.isARepeat) { perform(command) }
        return true
    }

    /// ⌘↓ (`openSelectedContentWithCommand`, `openTreeNodeWithCommand`): what is selected in the focused pane is
    /// activated, whatever the limit: over it, the limit's notice says so.
    private func openSelectedItem() -> Bool {
        guard ShortcutPolicy.canHandleExplorerKeyboardShortcuts(shortcutContext) else { return false }
        switch focusedPane {
        case .content:
            let selected = content.selectedEntries
            guard !selected.isEmpty else { return false }
            open(selected)
        case .tree: _ = sidebar.openSelection()
        case nil: return false
        }
        return true
    }

    /// `isTextEditingShortcut` with a text field that has the keyboard (useExplorerShortcuts.ts:1089-1098).
    func textFieldKeepsKey(_ event: NSEvent) -> Bool {
        guard isTextFieldEditing, !event.modifierFlags.intersection([.command, .control]).isEmpty,
            let pressed = Shortcuts.fromKeyboardEvent(ContentKeyboard.shortcutEvent(event))
        else { return false }
        return Shortcuts.isTextEditingShortcut(pressed)
    }

    /// A key that reached the window: the commands that the focused pane left alone (`onKeyDown`, its one table for
    /// every pane). A key that has a command is the command's, even when it can't run now.
    func windowKeyDown(_ event: NSEvent) -> Bool {
        guard !isTextFieldEditing, !isDialogOpen,
            let pressed = Shortcuts.fromKeyboardEvent(ContentKeyboard.shortcutEvent(event)),
            let command = ShortcutCommands.resolve(preferences.shortcutOverrides).commandByShortcut[pressed]
        else { return false }
        if WriteStartingShortcuts.runs(command.rawValue, isRepeat: event.isARepeat) { _ = runKeyCommand(command) }
        return true
    }

    /// F2, Rename and Return: one item is renamed in its row, several in the Rename sheet (B-SEL-106, B-SEL-113).
    /// While another write runs it is said now, before a name is typed that couldn't be used until it ends.
    func renameSelected() {
        let selected = content.selectedEntries
        if !selected.isEmpty, let actions = writeActions,
            actions.refuseWhileBusy(.operation(selected.count > 1 ? .batchRename : .rename))
        {
            return
        }
        switch selected.count {
        case 0: return
        case 1: _ = content.beginRename(path: selected[0].path)
        default: openBatchRename?(selected)
        }
    }

    /// What came of a name typed into the rename field.
    enum RenameOutcome: Equatable {
        /// The item is at this path now.
        case renamed(String)
        /// Nothing to rename: the name is the one it has.
        case unchanged
        /// The reason the name was refused; the field stays open.
        case refused(String)
        /// The rename runs as a file operation: the field closes, and its end selects the item where it is now.
        case started
    }

    private func submitRename(path: String, typed: String) {
        guard renameTask == nil else { return }
        renameTask = Task { [weak self] in
            guard let self else { return }
            defer { self.renameTask = nil }
            let outcome: RenameOutcome =
                if let renameItem = self.renameItem {
                    await renameItem(path, typed)
                } else if let actions = self.writeActions {
                    // The write coordinator renames it (WriteOperations/).
                    await actions.commitRename(path: path, typed: typed, hiddenFilesShown: self.includeHidden)
                } else {
                    await self.interimRename(path: path, typed: typed)
                }
            guard self.content.inlineRename?.path == path else {
                // The folder was left while the name was checked (a click on another folder ends the field and opens
                // that folder): with no field to show it under, the refusal gets a dialog of its own (B-SEL-140).
                if case .refused(let message) = outcome, !self.content.listed.contains(where: { $0.path == path }) {
                    let name = NodePath.basename(path)
                    self.renameNotice(title: "\u{201C}\(name)\u{201D} couldn\u{2019}t be renamed", message: message)
                }
                return
            }
            switch outcome {
            case .renamed(let newPath):
                self.content.endRename()
                await self.reloadSelecting([newPath])
            case .unchanged, .started:
                self.content.endRename()
            case .refused(let message):
                self.content.refuseRename(message)
            }
        }
    }

    /// The rename in a window without the app's file operations: the typed name is trimmed and checked, a name that
    /// begins with a dot asks first, and the file system does the rest.
    private func interimRename(path: String, typed: String) async -> RenameOutcome {
        let source = URL(fileURLWithPath: path)
        let current = source.lastPathComponent
        let name = InlineRenameRules.trimmedName(typed)
        if name == current { return .unchanged }
        if let error = ItemNames.error(for: name) { return .refused(error) }
        if !current.hasPrefix("."), InlineRenameRules.needsDotConfirmation(name: name, hiddenFilesShown: includeHidden),
            await !confirmDotName()
        {
            return .unchanged
        }
        let target = source.deletingLastPathComponent().appendingPathComponent(name)
        // The file system is asked off the main thread, as the original's worker does.
        return await Task.detached(priority: .userInitiated) { Self.renameOnDisk(from: source, to: target) }.value
    }

    private nonisolated static func renameOnDisk(from source: URL, to target: URL) -> RenameOutcome {
        let fileManager = FileManager.default
        // A name that differs only in case is the same item on a disk that ignores case.
        if fileManager.fileExists(atPath: target.path), target.path.lowercased() != source.path.lowercased() {
            return .refused("An item named “\(target.lastPathComponent)” already exists.")
        }
        do {
            try fileManager.moveItem(at: source, to: target)
            return .renamed(target.path)
        } catch {
            return .refused((error as NSError).localizedDescription)
        }
    }

    /// Finder's question about a name that hides the item, word for word. Cancel is the default.
    private func confirmDotName() async -> Bool {
        await askDotName()
    }

    /// Reads the folder on screen again and selects `paths` (an item just renamed), the list staying where it is.
    private func reloadSelecting(_ paths: [String]) async {
        let url = folder
        let result = await readFolder(url)
        guard url == folder, !isNavigating, !folderLetGo, case .success(let snapshot) = result.snapshot else { return }
        content.show(folder: url.path, entries: snapshot.entries, selecting: paths, keepingScroll: true)
        notify(.folder)
    }

    /// ⌘F: the search field takes the keyboard. Text typed into the list's filter goes into it, and is searched at
    /// once (B-SEL-083, B-SRCH-048, B-SRCH-052).
    func focusFileSearch() {
        let text = content.filter
        search.focusField()
        if !text.isEmpty { onSearchRequested?(text) }
    }

    /// "Search Subfolders" on the empty filter: the same, and the search runs.
    private func searchSubfolders() {
        focusFileSearch()
    }

    private func updateNavigationItems() {
        notify(.history)
    }

    /// The folder Open in New Tab and Open in New Window open: the one folder selected, or with the sidebar focused its
    /// selected folder (B-TREE-155).
    private var selectedFolder: URL? {
        if focusedPane == .tree { return sidebar.selectedTreeTargetPath.map { URL(fileURLWithPath: $0) } }
        let items = content.selectedEntries
        guard items.count == 1, items[0].isDirectoryLike else { return nil }
        return items[0].url
    }

    // MARK: The content pane

    /// Connects the content pane to the window: what it reads from the services, and what it reports.
    private func wireContent() {
        content.loaders = ContentLoaders(
            metadata: { [weak self] folder, paths in
                guard let service = self?.services.directoryService else { return [] }
                return (try? await service.metadata(directoryPath: folder, paths: paths).items) ?? []
            },
            hiddenCount: { [weak self] folder in
                guard let service = self?.services.directoryService else { return 0 }
                return (try? await service.snapshot(path: folder, includeHidden: true).entries.count) ?? 0
            },
            iconStore: { [weak self] in self?.services.iconStore },
            homePath: FileManager.default.homeDirectoryForCurrentUser.path,
            openPrivacySettings: {
                guard
                    let url = URL(
                        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
                else { return }
                NSWorkspace.shared.open(url)
            })
        content.onActivate = { [weak self] entries, newTab in self?.open(entries, inNewTab: newTab) }
        content.onSortRequested = { [weak self] field in self?.sort(by: field) }
        content.onSortSetFromOutside = { [weak self] field, ascending in
            self?.setSort(field, ascending ? .asc : .desc)
        }
        content.onSelectionChanged = { [weak self] selection in
            self?.searchStore?.session.noteSelection(selection)
            if self?.searchRootPath != nil { self?.updatePathBar() }
            self?.noteFocusedPane()
            self?.notify(.selection)
        }
        content.shortcutsProvider = { [weak self] in
            ShortcutCommands.resolve(self?.preferences.shortcutOverrides ?? [:])
        }
        content.onReturn = { [weak self] in self?.pressedReturn() }
        // With the tree hidden Tab stays in the list (useExplorerShortcuts.ts paneTabSwitch).
        content.onSwitchPane = { [weak self] in
            guard let self else { return }
            if self.panels.folderTreeOpen { self.perform(.focusTreePane) } else { self.content.focusList() }
        }
        content.onCommand = { [weak self] id in self?.runKeyCommand(id) ?? false }
        content.onRenameSubmit = { [weak self] path, name in self?.submitRename(path: path, typed: name) }
        content.onRenameStateChanged = { [weak self] in
            guard let self else { return }
            self.renameHoldsChanges = self.content.inlineRename != nil
            if !self.renameHoldsChanges { self.flushPendingChange() }
            self.notify(.focusedPane)
        }
        // A refusal the field was showing when its item left the list (`getCopyLikePreStartFailureTitle("rename")`).
        content.onRenameLost = { [weak self] _, refusal in
            guard let refusal else { return }
            self?.renameNotice(title: WriteStartAction.operation(.rename).failureTitle, message: refusal)
        }
        content.onSearchSubfolders = { [weak self] in self?.searchSubfolders() }
        content.onColumnWidthsChanged = { [weak self] widths in self?.saveColumnWidths(widths) }
        content.setView(
            sortBy: sortBy, direction: sortDirection, foldersFirst: foldersFirst, includeHidden: includeHidden)
        content.setColumns(ListColumnState(preferences: preferences))
        content.setMode(viewMode)
    }

    /// The widths the List keeps are the window's own (`detailColumnWidths` is a window session key).
    private func saveColumnWidths(_ widths: [DetailColumn: Double]) {
        let searching = searchStore?.showsResults == true
        func width(_ column: DetailColumn) -> JSONNode {
            .number(DetailsColumns.clamp(widths[column] ?? 0, column: column, search: searching))
        }
        if searching {
            // Search results keep widths of their own (`searchColumnWidths`), Folder among them.
            updatePreferences([
                "searchColumnWidths": .object([
                    "name": width(.name), "folder": width(.folder), "modified": width(.modified),
                    "size": width(.size), "kind": width(.kind), "created": width(.created),
                    "permissions": width(.permissions),
                ])
            ])
            // What the window saves with every navigation, so it keeps them.
            updatePanels { $0.searchColumnWidths = preferences.searchColumnWidths }
            return
        }
        updatePreferences([
            "detailColumnWidths": .object([
                "name": width(.name), "modified": width(.modified), "size": width(.size), "kind": width(.kind),
                "created": width(.created), "permissions": width(.permissions),
            ])
        ])
        updatePanels { $0.detailColumnWidths = preferences.detailColumnWidths }
    }

    /// The columns and the density again, from the preferences (Settings changed them, or a scenario did).
    func refreshColumns() {
        if let search = searchStore, search.showsResults {
            content.setColumns(search.columnState(preferences))
        } else {
            content.setColumns(ListColumnState(preferences: preferences))
        }
    }

    /// The search changed how it stands (P5-07): the tab's label and magnifier, and the commands.
    func searchStateChanged() {
        group?.refreshTitles()
        updateSearchTabAccessory()
        notify(.search)
    }

    /// `.tab-strip-search`: a search tab shows a magnifier before its label, in the accent while it searches.
    private func updateSearchTabAccessory() {
        guard let window, let session = searchStore?.session else { return }
        guard session.isSearchMode else {
            if window.tab.accessoryView != nil { window.tab.accessoryView = nil }
            return
        }
        let view = (window.tab.accessoryView as? SearchTabMagnifier) ?? SearchTabMagnifier()
        view.searching = session.isRunning
        if window.tab.accessoryView !== view { window.tab.accessoryView = view }
    }

    /// Refresh: the caches of the listing are let go of, and the folder is read again with the selection kept
    /// (B-NAV-124).
    func refresh() {
        services.directoryService.cache.clear()
        readAgain()
        // `refreshDirectory`: the tree's way to hear of subfolders added or removed outside the app, for the folder watch
        // leaves it alone.
        guard treeFollowsReadingAgain else { return }
        let open = sidebar.model.openReadingAgain(folder.path)
        if open.forceTreeReload { sidebar.folderOpened(folder, open) }
    }

    /// The folder on screen read again brings the tree along; a folder being opened now will do that itself.
    var treeFollowsReadingAgain: Bool { loaded && !folderLetGo && !isNavigating }

    /// The folder selected in the file list, if it is the one item selected and a folder.
    private var selectedContentFolder: URL? {
        let items = content.selectedEntries
        guard items.count == 1, items[0].isDirectoryLike else { return nil }
        return items[0].url
    }

    /// The keyboard goes back to the pane that last had it, from a toolbar button about to stop taking it. The browser
    /// leaves it on the page there, where the pane's keys still work (`focusedPane` stays); AppKit would hand it to the
    /// next view, the search field.
    func keyboardBackToPane() {
        if lastFocusedPane == .tree, panels.folderTreeOpen { sidebar.focusTree() } else { content.focusList() }
    }

    /// The pane that last had the keyboard (`lastExplorerFocusPaneRef`).
    private func noteFocusedPane() {
        if let pane = focusedPane { lastFocusedPane = pane }
    }

    /// What the commands read of the keyboard, as it last was.
    private var keyboardHolder: (pane: ExplorerPane?, editing: Bool) = (nil, false)

    /// The keyboard moved in the window (`setFocusedPane`, `useTextEditingFocus`).
    func keyboardMoved() {
        noteFocusedPane()
        let now = (pane: focusedPane, editing: isTextFieldEditing)
        guard now != keyboardHolder else { return }
        keyboardHolder = now
        notify(.focusedPane)
    }

    /// What the command rules look at of the selection in the file list.
    private var commandEntries: [CommandEntry] {
        content.selectedEntries.map {
            CommandEntry(path: $0.path, kind: FTFoundation.EntryKind(rawValue: $0.kind.rawValue) ?? .other)
        }
    }

    /// The folder File ▸ Add to Favorites acts on (`resolveFavoriteTargetPath`).
    var favoriteTargetPath: String? {
        CommandAvailability.favoriteTargetPath(commandTargets)
    }

    private var commandPane: FTFoundation.FocusedPane? { Self.commandPane(focusedPane) }

    private static func commandPane(_ pane: ExplorerPane?) -> FTFoundation.FocusedPane? {
        switch pane {
        case .tree: .tree
        case .content: .content
        case nil: nil
        }
    }

    /// The disk File ▸ Eject ejects: the sidebar's selected disk row.
    private var ejectTargetPath: String? {
        EjectPlanning.resolveEjectTargetPath(
            focusedPane: focusedPane == .content ? .content : (focusedPane == .tree ? .tree : nil),
            selectedTreeItemId: sidebar.selectedTreeItemID, volumes: SidebarVolumes.shared.volumes)
    }

    /// Opens the Sidebar's closures: what it needs of the window.
    private func configureSidebar() {
        sidebar.preferences = { [weak self] in self?.preferences ?? AppPreferences.defaults() }
        sidebar.updatePreferences = { [weak self] patch in self?.updatePreferences(patch) }
        sidebar.directoryService = { [weak self] in
            self?.services.directoryService ?? ExplorerServices.current.directoryService
        }
        sidebar.openInNewTab = { [weak self] path in
            guard let self else { return }
            self.group?.openTab(path: path, from: self)
        }
        sidebar.focusContent = { [weak self] in self?.perform(.focusContentPane) }
        sidebar.stateChanged = { [weak self] in
            guard let self else { return }
            self.group?.tabChanged(self)
        }
        sidebar.selectionChanged = { [weak self] in
            self?.noteFocusedPane()
            self?.notify(.selection)
            self?.notify(.focusedPane)
        }
        sidebar.model.openFolder = { [weak self] url, open in
            guard let self else { return }
            let replaces = open.replacesFolderOnScreen && url.path == self.shownFolderPath
            self.go(to: url, history: replaces ? .replace : .push, open: open)
        }
        sidebar.model.releaseFolder = { [weak self] in self?.releaseFolder() }
        sidebar.eject = { [weak self] path in self?.ejectCoordinator.requestEject(path: path) }
        sidebar.ejectingPaths = { [weak self] in self?.ejectCoordinator.ejectingPaths ?? [] }
        ejectCoordinator.presenter = ejectPresenter
        ejectCoordinator.onChange = { [weak self] in self?.sidebar.refresh() }
        ejectCoordinator.didFinish = { SidebarVolumes.shared.refresh() }
    }

    /// The folder on screen is let go of: the file list shows nothing (B-TREE-059, B-TREE-060).
    private func releaseFolder() {
        // `applyEmptyDirectorySnapshot` puts the results away too.
        searchStore?.session.putResultsAway()
        showNoFolder()
        sidebar.focusTree()
        group?.tabChanged(self)
        notify(.folder)
        notify(.selection)
    }

    private func showNoFolder() {
        folderLetGo = true
        pendingChange = nil
        content.showNoFolder()
        updateTitle()
        updatePathBar()
    }

    // MARK: Menu state

    /// What the application menu shows of this tab (`buildApplicationMenuState`), from what the toolbar and the keys
    /// read.
    var menuState: ApplicationMenuState {
        let context = commandContext
        let panels = group?.session.panels
        return ApplicationMenuState.build(
            viewMode: shownViewMode, sortBy: sortBy, foldersFirst: foldersFirst, hiddenFilesShown: includeHidden,
            folderTreeOpen: panels?.folderTreeOpen ?? true, infoPanelOpen: panels?.propertiesOpen ?? false,
            infoRowOpen: panels?.detailRowOpen ?? false,
            favoriteIsSet: favoriteTargetPath.map { sidebar.isFavorite($0) } ?? false,
            textEditing: isTextFieldEditing
        ) { CommandAvailability.canRun($0, context) }
    }

    private var menuReportQueued = false

    /// The menu hears of a change once the task that made it is done, once for all the changes made in the meantime.
    private func reportMenuStateSoon() {
        guard !menuReportQueued else { return }
        menuReportQueued = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.menuReportQueued = false
                self.group?.reportMenuState(self)
            }
        }
    }

    /// Whether the Trash has anything in it (nil: it can't be told), asked when the window comes to the front and after
    /// every file operation (`useTrashState`).
    var trashIsEmpty: Bool?

    func refreshTrashState() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let uid = getuid()
        Task { [weak self] in
            let empty = await Task.detached(priority: .utility) { TrashState.isEmpty(home: home, uid: uid) }.value
            guard let self, self.trashIsEmpty != empty else { return }
            self.trashIsEmpty = empty
            self.commandsChanged()
        }
    }

    /// Something the commands read changed that has no change of its own to tell of.
    func commandsChanged() {
        notify(.commands)
    }

    // MARK: Actions

    @objc func goBack(_ sender: Any?) {
        guard let target = navigationHistory.backTarget else { return }
        go(to: URL(fileURLWithPath: target), history: .back)
    }

    @objc func goForward(_ sender: Any?) {
        guard let target = navigationHistory.forwardTarget else { return }
        go(to: URL(fileURLWithPath: target), history: .forward)
    }

    @objc func goToEnclosingFolder(_ sender: Any?) {
        guard !folderLetGo, folder.comparablePath != "/" else { return }
        go(to: folder.deletingLastPathComponent())
    }

    /// `navigateToParentFolder`, the toolbar's Enclosing Folder: it doesn't look at which pane has the keyboard, and
    /// with no folder on screen it opens the top of the disk (`parentDirectoryPath("")`).
    func goToParentFolder() {
        guard !isCustomizingToolbar, !isDialogOpen, let parent = ExplorerTabs.parentDirectoryPath(shownFolderPath)
        else {
            return
        }
        go(to: URL(fileURLWithPath: parent))
    }

    @objc func goToPlace(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        go(to: url)
    }

    /// File ▸ Open, ⌘O and the toolbar's Open (`openPaths`): opens the items, whatever "Double-click a file to" says.
    @objc func openSelection(_ sender: Any?) {
        perform(OpenItems.openPlan(commandEntries, limit: preferences.openItemLimit))
    }

    @objc func showAsIcons(_ sender: Any?) { setMode(.icons) }

    @objc func showAsList(_ sender: Any?) { setMode(.details) }

    /// The toolbar's search field: what is typed there searches the folder (`TabSearch`).
    var searchField: ToolbarSearchField? {
        explorerToolbar.searchField
    }

    func connectSearchField() {
        search.connect(searchField)
    }

    /// The tab bar's "+" button, and New Tab: a tab on this folder.
    override func newWindowForTab(_ sender: Any?) {
        group?.openNewTab(from: self)
    }

    /// The view search results show in, whether they show now or not.
    func setSearchViewMode(_ mode: ExplorerViewMode) {
        searchViewMode = mode
        if let search = searchStore, search.showsResults { content.setMode(mode) }
        notify(.view)
        group?.tabChanged(self)
    }

    func setMode(_ mode: ExplorerViewMode) {
        // Search results have a view of their own in each tab (`searchViewMode`).
        if let search = searchStore, search.showsResults {
            searchViewMode = mode
        } else {
            viewMode = mode
        }
        content.setMode(mode)
        notify(.view)
        group?.tabChanged(self)
    }

    /// The sort commands and the column headers (`handleSortChange`): the field already in use reverses the direction;
    /// another sorts by it, descending for Date Modified and Size and ascending for Name and Kind.
    func sort(by field: SortByPreference) {
        let next = DetailsSorting.next(current: sortBy, direction: sortDirection, requested: field)
        setSort(next.sortBy, next.direction)
    }

    /// Puts the folder in this order: it is read again ("replace"), and the selection is not kept (B-NAV-127,
    /// B-NAV-132).
    func setSort(_ field: SortByPreference, _ direction: SortDirectionPreference) {
        sortBy = field
        sortDirection = direction
        viewChanged()
    }

    /// The tab's order, Folders First or hidden files changed: the content pane shows it, the folder is read again in
    /// place and the choice is saved with the tab.
    private func viewChanged() {
        content.setView(
            sortBy: sortBy, direction: sortDirection, foldersFirst: foldersFirst, includeHidden: includeHidden)
        notify(.view)
        group?.tabChanged(self)
        // No folder to read again (`toggleHiddenFiles` with an empty currentPath).
        guard loaded, !folderLetGo else { return }
        // `getSelectedTreeReloadOptions`: the row of a favorite, a location or a link stays, and the tree where it is.
        let open = sidebar.model.openKeepingRow(folder.path) ?? .other
        Task { await navigate(to: folder, history: .replace, open: open, keepingSearch: true) }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(goBack(_:)): return navigationHistory.canGoBack
        case #selector(goForward(_:)): return navigationHistory.canGoForward
        case #selector(goToEnclosingFolder(_:)): return !folderLetGo && folder.comparablePath != "/"
        case #selector(openSelection(_:)): return !content.selectedEntries.isEmpty
        case #selector(showAsIcons(_:)):
            menuItem.state = shownViewMode == .icons ? .on : .off
            return true
        case #selector(showAsList(_:)):
            menuItem.state = shownViewMode == .details ? .on : .off
            return true
        default: return true
        }
    }

    // MARK: Customize Toolbar

    /// The system's sheet (View ▸ Customize Toolbar…, View Options, the toolbar's right-click).
    func beginCustomizingToolbar() {
        AppMenuPresenter.shared.close()
        explorerToolbar.beginCustomizing()
    }

    // MARK: Window events

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        group?.shouldCloseTab(self) ?? true
    }

    func windowWillClose(_ notification: Notification) {
        // Closing a tab stops its search (B-SRCH-138).
        searchStore?.session.close()
        group?.tabWillClose(self)
        visitTracker.dispose()
        if let window { WindowEventRouting.forget(window) }
        FolderSizeService.shared.forget(windowID: windowID)
        onClose?()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard group?.acceptsKey(self) != false else { return }
        ensureLoaded()
        refreshTrashState()
        // The tab on screen is the one live search; the others of its window go on in the background (B-SRCH-153).
        for other in group?.tabs ?? [] where other !== self { other.searchStore?.session.enterBackground() }
        searchStore?.session.returnToForeground()
        group?.frontSearch = searchStore
        group?.tabBecameKey(self)
    }

    func windowDidResignKey(_ notification: Notification) {
        // The window going to the back ends a drag; a window of an app in the background has no focus to lose.
    }

    func windowDidMove(_ notification: Notification) {
        group?.tabBoundsChanged(self)
    }

    func windowDidResize(_ notification: Notification) {
        group?.tabBoundsChanged(self)
        explorerToolbar.windowResized()
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        group?.tabBoundsChanged(self)
    }

    func windowDidMiniaturize(_ notification: Notification) {
        group?.tabVisibilityChanged(self)
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        group?.tabVisibilityChanged(self)
    }

    // MARK: Observers

    fileprivate func notify(_ change: ExplorerWindowChange) {
        observers.removeAll { $0.token.value?.isValid != true }
        for observer in observers { observer.handler(change) }
        reportMenuStateSoon()
    }

    /// A preference change from any window (`onPreferencesChanged`): the keys the whole app shares.
    /// What Copy or Cut put on the app's clipboard changed (every window hears it from the shared clipboard): the
    /// marks, the toolbar's button and its list follow.
    func clipboardChanged() {
        clipboardMarksChanged()
        notify(.clipboard)
    }

    func preferencesChanged(_ change: PreferencesChange) {
        // A Settings edit of the search options updates the live values without running anything again (B-SRCH-091).
        let searchDefaults = [
            "searchPatternMode", "searchMatchScope", "searchRecursive", "searchSkipGitFolders", "searchSkipGitIgnored",
        ]
        // Only the keys edited, and only in the tab on screen: a tab behind keeps the options of its own search.
        if let search = searchStore, group == nil || group?.selected === self {
            let edited = searchDefaults.filter { change.patch[$0] != nil }
            if !edited.isEmpty { search.session.applyDefaults(preferences, keys: Set(edited)) }
        }
        sidebar.applyPreferences()
        refreshColumns()
        notificationsSettingChanged()
        if change.patch["markClipboardItems"] != nil || change.patch.isEmpty { clipboardMarksChanged() }
        notify(.preferences)
    }
}

extension MainWindowController: ExplorerWindowHandle {
    var currentMenuState: ApplicationMenuState? { menuState }

    /// An editing command for the field of this tab's window that has the keyboard. Up its own responder chain, not the
    /// key window's: the command may be sent to a window that isn't key (a menu acting on the window in front, a driven
    /// run in the background), where a nil-targeted action would find no field.
    private func performFieldEdit(_ selector: Selector) {
        if window?.firstResponder?.tryToPerform(selector, with: nil) != true {
            NSApp.sendAction(selector, to: nil, from: nil)
        }
    }

    /// Carries out a menu command in this tab, or in its explorer window.
    func perform(_ command: RendererCommand) {
        // While the toolbar is customized the window waits, as under a sheet: only editing still works.
        if isCustomizingToolbar, MenuCommandRouter.nativeEditSelector(command) == nil, command != .customizeToolbar {
            return
        }
        // So it does under the Go To box or an alert: only a field's editing commands act (B-DLG-064, B-NAV-112).
        if isDialogOpen {
            if let selector = MenuCommandRouter.nativeEditSelector(command), isTextFieldEditing {
                performFieldEdit(selector)
            }
            return
        }
        // A text field with the keyboard (the search field, the results' filter) does Cut, Copy, Paste, Select All and
        // Undo itself (`NATIVE_EDIT_COMMANDS`, T-f31f663b).
        if let selector = MenuCommandRouter.nativeEditSelector(command), isTextFieldEditing {
            performFieldEdit(selector)
            return
        }
        // `canHandleRendererCommand`: a name being edited in its row waits for nothing but Settings and the field's own
        // editing, and the list's commands need the list (or the tree, for those it takes).
        guard ShortcutPolicy.canHandle(command, shortcutContext) else { return }
        // Cut, Copy, Paste and the file operations go to the write coordinator (WriteOperations/).
        if !isCustomizingToolbar, performWriteCommand(command) { return }
        let fileManager = FileManager.default
        func place(_ url: URL?) {
            if let url { go(to: url) }
        }
        switch command {
        case .openLocationSheet: openLocationSheet()
        case .goBack: goBack(nil)
        case .goForward: goForward(nil)
        case .goEnclosingFolder:
            // With the sidebar focused, the parent row of the selected folder.
            if focusedPane == .tree {
                _ = sidebar.selectParent()
            } else {
                goToEnclosingFolder(nil)
            }
        case .openSelection:
            if focusedPane == .tree { _ = sidebar.openSelectedFolder() } else { openSelection(nil) }
        case .viewAsIcons: setMode(.icons)
        case .viewAsDetails: setMode(.details)
        case .viewAsList: setMode(.list)
        // Search results have an order of their own, chosen in the List view's headers.
        case .sortByName, .sortByKind, .sortByModified, .sortBySize, .toggleFoldersFirst:
            guard searchRootPath == nil else { return }
            switch command {
            case .sortByName: sort(by: .name)
            case .sortByKind: sort(by: .kind)
            case .sortByModified: sort(by: .modified)
            case .sortBySize: sort(by: .size)
            default:
                foldersFirst.toggle()
                viewChanged()
            }
        case .toggleHiddenFiles:
            includeHidden.toggle()
            sidebar.hiddenFilesChanged(includeHidden)
            viewChanged()
            searchStore?.session.hiddenFilesChanged(includeHidden)
        case .refreshOrApplySearchSort:
            // In search mode ⌘R runs the same search again (B-SRCH-140).
            if let session = searchStore?.session, session.isSearchMode { session.rerun() } else { refresh() }
        case .showLastSearchResults:
            if searchStore?.session.hasCachedSearch == true { search.showLastResults() }
        case .revealInFolder:
            // The lead result's folder, or the first selected's when there is no lead (`selectionLeadOrSelectedPath`).
            if searchRootPath != nil, let path = content.selection.leadPath ?? selectedPaths.first {
                revealSearchResult(path)
            }
        case .customizeToolbar: beginCustomizingToolbar()
        // The places of the Go menu (`GoMenuPlaces`): Macintosh HD and the Trash act exactly as a click on their Locations
        // rows, the folders as Go to Folder opens them.
        case .goDocuments, .goDesktop, .goDownloads, .goLibrary, .goMacintoshHD, .goApplications, .goTrash:
            let home = fileManager.homeDirectoryForCurrentUser.path
            if let place = GoMenuPlaceCommand(rawValue: command.rawValue)?.place(homePath: home) {
                if place.asLocation {
                    sidebar.openLocation(place.path)
                } else {
                    go(to: URL(fileURLWithPath: place.path))
                }
            }
        case .goHomeRootTree: sidebar.rootTree(at: fileManager.homeDirectoryForCurrentUser.path)
        case .rootTreeAtSelection:
            if let target = sidebar.rootTreeTarget(
                focusedPane: focusedPane, lastFocusedPane: lastFocusedPane,
                selectedContentFolder: selectedContentFolder?.path, currentPath: shownFolderPath)
            {
                sidebar.rootTree(at: target)
            }
        case .toggleFavorite:
            if let target = favoriteTargetPath { sidebar.toggleFavorite(target) }
        case .focusTreePane:
            // A hidden tree comes back first (useExplorerShortcuts.ts focusTreePane).
            if !panels.folderTreeOpen { updatePanels { $0.folderTreeOpen = true } }
            sidebar.focusTree()
        case .ejectVolume:
            if let target = ejectTargetPath { ejectCoordinator.requestEject(path: target) }
        case .newTab: group?.openNewTab(from: self)
        case .closeTab: group?.closeTab(self)
        case .reopenClosedTab: group?.reopenClosedTab(from: self)
        case .duplicateTab: group?.duplicateTab(self)
        case .selectNextTab: group?.selectAdjacentTab(from: self, .next)
        case .selectPreviousTab: group?.selectAdjacentTab(from: self, .previous)
        case .openSelectionInNewTab:
            if let target = selectedFolder { openSelectedFolder(target, place: .tab) }
        case .newWindow: group?.openNewWindow(from: self, path: nil)
        case .openSelectionInNewWindow:
            if let target = selectedFolder { openSelectedFolder(target, place: .window) }
        case .moveTabToNewWindow: group?.moveTabToNewWindow(self)
        case .mergeAllWindows: group?.mergeAllWindows(into: self)
        case .toggleFolderTree: updatePanels { $0.folderTreeOpen.toggle() }
        case .toggleInfoPanel: updatePanels { $0.propertiesOpen.toggle() }
        case .toggleInfoRow: updatePanels { $0.detailRowOpen.toggle() }
        case .focusContentPane: content.focusList()
        case .renameSelection: renameSelected()
        case .editSelection:
            // `editPaths`: anything but files among the items and it does nothing, over the limit too.
            guard commandEntries.count == selectedPaths.count, commandEntries.allSatisfy(\.kind.isEditableFile)
            else { return }
            let prefs = preferences
            self.perform(OpenItems.editPlan(content.selection.paths, limit: prefs.openItemLimit))
        case .focusFileSearch: focusFileSearch()
        case .quickLookSelection: quickLookSelection()
        case .editSelectAll:
            // `runGenericEditCommand`: every entry while the file list has the keyboard, sent to the pane and not up a
            // responder chain that needs the window to be key; any other view does its own Select All.
            if focusedPane == .content {
                content.selectAllEntries()
            } else {
                _ = window?.firstResponder?.tryToPerform(#selector(NSResponder.selectAll(_:)), with: nil)
            }
        case .calculateSize: infoController?.calculateSizeCommand()
        case .showClipboard: showClipboard()
        case .clearClipboard: clearClipboard()
        case .openSettings:
            if let openSettings {
                openSettings()
            } else {
                (NSApp.delegate as? AppDelegate)?.pageWindows?.openSettings()
            }
        case .openHelp, .openKeyboardShortcuts:
            // Help opens where it was left; Keyboard Shortcuts always opens that page.
            let topic: HelpTopicID? = command == .openKeyboardShortcuts ? .shortcuts : nil
            if let openHelp {
                openHelp(topic)
            } else {
                (NSApp.delegate as? AppDelegate)?.pageWindows?.openHelp(topic: topic)
            }
        case .openInTerminal:
            let paths = ShortcutTargets.openInTerminalPaths(
                .init(
                    focusedPane: commandPane, lastFocusedPane: Self.commandPane(lastFocusedPane),
                    selectedContentPaths: selectedPaths, selectedTreePath: sidebar.selectedTreeTargetPath,
                    currentPath: shownFolderPath))
            if let first = paths.first { contextMenus.openInTerminal(first) }
        case .showInFinder:
            let paths = CommandAvailability.showInFinderPaths(commandTargets)
            if !paths.isEmpty { contextMenus.revealInFinder(paths) }
        case .copyPath:
            if focusedPane == .tree, let tree = sidebar.selectedTreeTargetPath {
                contextMenus.copyPath([tree])
            } else {
                contextMenus.copyPath(selectedPaths)
            }
        case .undo, .redo, .editCut, .editCopy, .editPaste, .moveSelection, .duplicateSelection, .newFolder,
            .trashSelection, .emptyTrash, .copySelection, .cutSelection, .pasteSelection:
            // The write commands: `performWriteCommand` took them, unless the toolbar is being customized.
            if let selector = MenuCommandRouter.nativeEditSelector(command) {
                NSApp.sendAction(selector, to: nil, from: nil)
            }
        }
    }

    /// The panels the explorer window shows, as every one of its tabs shows them.
    func showPanels(_ panels: TabGroupSession.Panels) {
        let widths = workspace.panes
        if Int(widths.preferredTreeWidth) != panels.treeWidth
            || Int(widths.preferredInspectorWidth) != panels.inspectorWidth
        {
            workspace.restore(treeWidth: Double(panels.treeWidth), inspectorWidth: Double(panels.inspectorWidth))
        }
        // App.tsx: hiding the tree while it has the keyboard gives the keyboard to the list. Asked first: a view going
        // hidden lets go of the keyboard.
        let treeLosesKeyboard = !panels.folderTreeOpen && focusedPane == .tree
        workspace.show(folderTree: panels.folderTreeOpen, infoPanel: panels.propertiesOpen)
        if treeLosesKeyboard { content.focusList() }
        content.setInfoRowOpen(panels.detailRowOpen, animated: workspace.isReady)
        if !workspace.isReady { workspace.becomeReady() }
        notify(.panels)
    }
}

extension MainWindowController: ExplorerWindowContext {
    var currentFolder: URL { folder }
    var shownFolderPath: String { folderLetGo ? "" : folder.path }

    func navigate(to url: URL, target: NavigationTarget) {
        switch target {
        case .push: go(to: url)
        case .newTab: group?.openTab(path: url.path, from: self)
        case .newWindow: group?.openNewWindow(from: self, path: url.path)
        }
    }

    var historyPaths: [String] { navigationHistory.paths }
    var historyIndex: Int { max(0, navigationHistory.index) }
    var canGoBack: Bool { navigationHistory.canGoBack }
    var canGoForward: Bool { navigationHistory.canGoForward }

    func goToHistoryIndex(_ index: Int) {
        let paths = historyPaths
        guard paths.indices.contains(index), index != historyIndex else { return }
        go(to: URL(fileURLWithPath: paths[index]), history: .jump(index: index))
    }

    func canPerform(_ command: RendererCommand) -> Bool {
        CommandAvailability.canRun(command, commandContext)
    }

    /// What decides whether a command or a key can act now (`shortcutContext` of App.tsx).
    var shortcutContext: ShortcutContext {
        ShortcutContext(
            actionNoticeOpen: frontAlert != nil,
            // `copyPasteModalOpen` holds `renameDialogState` and `newFolderDialogState`, inline ones too.
            copyPasteModalOpen: isBatchRenameOpen || CopyPasteDialogs.isOpen(in: window)
                || content.inlineRename != nil,
            focusedPane: commandPane,
            // Customizing the toolbar is a sheet over the window (`sheetOpen`): the commands wait for it to end.
            locationSheetOpen: isCustomizingToolbar || goToBox != nil,
            selectedTreeTargetKind: sidebar.selectedTreeTargetKind)
    }

    /// Everything the command rules read (App.tsx `canRunRendererCommand`): the one state of the menu bar, the toolbar
    /// and the keys.
    private var commandContext: CommandAvailabilityContext {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let entries = commandEntries
        let lead = content.selection.leadPath
        return CommandAvailabilityContext(
            shortcutContext: shortcutContext,
            currentPath: shownFolderPath, selectedPathsInViewOrder: selectedPaths, activeContentEntries: entries,
            selectedEntry: entries.first { $0.path == lead } ?? entries.first,
            selectedTreeTargetPath: sidebar.selectedTreeTargetPath,
            clipboardHasItems: services.clipboard.contents.hasItems, pasteDestinationPath: pasteDestinationPath,
            isSearchMode: searchRootPath != nil, openItemLimit: preferences.openItemLimit,
            writeOperationLocked: isWriteLocked, canGoBack: canGoBack,
            canGoForward: canGoForward, hasCachedSearch: searchStore?.session.hasCachedSearch ?? false,
            tabCount: group?.tabs.count ?? 1, trashPath: FavoriteLabel.trashPath(homePath: home), homePath: home,
            trashIsEmpty: trashIsEmpty, ejectTargetPath: ejectTargetPath)
    }

    /// The folders File > Calculate Size measures now.
    var calculateSizePaths: [String] { CommandAvailability.calculateSizePaths(commandTargets) }

    /// What the commands' target rules read.
    private var commandTargets: CommandAvailability.TargetContext {
        CommandAvailability.TargetContext(
            currentPath: shownFolderPath, selectedPathsInViewOrder: selectedPaths, activeContentEntries: commandEntries,
            selectedTreeTargetPath: sidebar.selectedTreeTargetPath, isSearchMode: searchRootPath != nil,
            trashPath: FavoriteLabel.trashPath(homePath: FileManager.default.homeDirectoryForCurrentUser.path),
            focusedPane: commandPane)
    }

    var selectedPaths: [String] { content.selection.paths }

    var focusedPane: ExplorerPane? {
        // Starting a rename leaves no pane focused: the window's own shortcuts wait (B-SEL-123). So does any other text
        // field (the path bar's, the results' filter): only the panes' own focus counts (`onFocusChange`).
        if content.inlineRename != nil || isTextFieldEditing { return nil }
        guard let responder = window?.firstResponder as? NSView else { return nil }
        if responder.isDescendant(of: content.view) { return .content }
        if responder.isDescendant(of: sidebar.view) { return .tree }
        return nil
    }

    var viewState: ExplorerViewState {
        ExplorerViewState(
            viewMode: viewMode, searchViewMode: searchViewMode, sortBy: sortBy, sortDirection: sortDirection,
            includeHidden: includeHidden, foldersFirst: foldersFirst)
    }

    var panels: TabGroupSession.Panels {
        group?.session.panels ?? TabGroupSession.Panels(preferences.windowSession)
    }

    func updatePanels(_ change: (inout TabGroupSession.Panels) -> Void) {
        if let group {
            group.session.update(change)
        } else {
            var next = panels
            change(&next)
            showPanels(next)
        }
    }

    var preferences: AppPreferences {
        services.preferences?.preferences(for: windowID) ?? AppPreferences.defaults()
    }

    func updatePreferences(_ patch: [String: JSONNode]) {
        guard let channel = services.preferences else { return }
        channel.update(patch, from: windowID)
    }

    var services: ExplorerServices { servicesOverride ?? ExplorerServices.current }

    var searchState: ExplorerSearchState? {
        guard let session = searchStore?.session, session.isSearchMode else { return nil }
        return ExplorerSearchState(
            rootPath: session.rootPath, query: session.committedQuery, isRunning: session.isRunning,
            resultCount: session.shownResults.count)
    }

    func observe(_ handler: @escaping @MainActor (ExplorerWindowChange) -> Void) -> ExplorerWindowObservation {
        let token = ExplorerWindowObservation()
        observers.append((Weak(token), handler))
        return token
    }
}

extension Duration {
    var milliseconds: Double {
        Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
    }
}
