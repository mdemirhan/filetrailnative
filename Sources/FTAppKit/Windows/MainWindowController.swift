// One tab of an explorer window, as a native window tab
import AppKit
import FTFileSystem
import FTFoundation

/// The window of one tab. Its close button and Close Window close the whole explorer window; the close button of a
/// tab in the tab bar closes the tab.
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

    /// What the Window menu calls the window: its tab's label. The title itself stays the folder's name, which the
    /// toolbar shows.
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

    /// A key nothing in the window took: its own table, which serves every pane.
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

    // The system's tab commands go through the app's own, so the busy, sheet and tab-limit rules hold.
    override func moveTabToNewWindow(_ sender: Any?) {
        explorerTab?.perform(.moveTabToNewWindow)
    }

    /// Out of its tab group into a window of its own, the same tab, as a tab dragged out of the tab bar goes: a tab the
    /// system dropped on a window that is full leaves it again this way.
    func leaveTabGroup() {
        super.moveTabToNewWindow(nil)
    }

    override func mergeAllWindows(_ sender: Any?) {
        explorerTab?.perform(.mergeAllWindows)
    }
}

/// One tab of an explorer window: sidebar, toolbar, current folder and its history, and how it shows its folder. Each
/// tab is a window of its own, in the native tab group of its explorer window.
final class MainWindowController: NSWindowController, NSWindowDelegate {
    enum HistoryMove {
        /// A new step: the entries after the current one are cut off.
        case push
        /// Back and Forward move the index at once, before the folder is read, and show the folder as it was left.
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

    /// What a folder that can't be read does.
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
        case opened
        /// It couldn't be read, and didn't open.
        case failed
        /// A newer navigation took over.
        case superseded

        var didOpen: Bool {
            if case .opened = self { return true }
            return false
        }
    }

    /// The default size of an explorer window, and the smallest it can be.
    static let defaultContentSize = NSSize(width: 1200, height: 760)
    static let minimumSize = NSSize(width: 760, height: 480)
    private static var nextWindowID = 1

    /// A number for a second pane's folder watch, from the same count as the tabs' own.
    static func makeWatchID() -> Int {
        defer { nextWindowID += 1 }
        return nextWindowID
    }

    /// The number its folder watch and menu state are filed under.
    let windowID: Int
    /// The explorer window it is a tab of.
    weak var group: ExplorerTabGroup?
    /// The active pane's folder, and how it shows it (`BrowserPane`).
    var folder: URL { activePane.folder }
    private var folderLetGo: Bool { activePane.folderLetGo }
    /// How the tab shows its folder, kept between launches with its folder. The sidebar keeps its tree and sections.
    var treeRootPath: String { sidebar.treeRootPath }
    var favoritePath: String? { sidebar.favoritePath }
    var viewMode: ExplorerViewMode { activePane.viewMode }
    var searchViewMode: ExplorerViewMode { activePane.searchViewMode }
    var sortBy: SortByPreference { activePane.sortBy }
    var sortDirection: SortDirectionPreference { activePane.sortDirection }
    var includeHidden: Bool {
        get { activePane.includeHidden }
        set { activePane.includeHidden = newValue }
    }
    var foldersFirst: Bool {
        get { activePane.foldersFirst }
        set { activePane.foldersFirst = newValue }
    }
    var isNavigating: Bool { activePane.isNavigating }
    var favoritesExpanded: Bool { sidebar.favoritesExpanded }
    var locationsExpanded: Bool { sidebar.locationsExpanded }

    var onClose: (() -> Void)?
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
    /// The tab's panes, left to right, and the one the toolbar, the sidebar, the Info panel and the commands follow.
    var panes: [BrowserPane]
    var activePaneIndex = 0
    /// Where the second pane was when it was last closed, for ⌘\ to open it there again.
    var closedSecondPane: (start: StartupTab, history: NavigationHistory)?
    /// The folder watch of a second pane just closed, for the window's watches to let go of.
    var closedPaneWatchID: Int?
    var activePane: BrowserPane { panes[activePaneIndex] }
    /// The active pane's file list.
    var content: ContentPaneController { activePane.content }
    /// What this window knows of folder sizes.
    let folderSizes: WindowFolderSizes
    /// The window's grid: sidebar, content, Info panel and the toolbar.
    let workspace: WorkspaceView
    /// The window's system toolbar, which holds the workspace's toolbar row.
    let explorerToolbar: ExplorerToolbar
    /// The right-click menus of the tab. Their file operations go to the write coordinator (WriteOperations/),
    /// Copy, Cut and Paste through the clipboard.
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
    /// The clipboard's marks, button list and paste, and the drags out of and onto the tab.
    lazy var clipboardUI = TabClipboard(tab: self)
    /// The Undo History list under its toolbar button.
    lazy var undoHistoryUI = TabUndoHistory(tab: self)
    lazy var dragDrop = TabDragDrop(tab: self)
    private let infoPanel = InfoPanelView()
    /// What the Info panel and the Info Row describe.
    private(set) var infoController: InfoController?
    /// The system's Customize Toolbar sheet is up.
    var isCustomizingToolbar: Bool { explorerToolbar.isCustomizing }
    /// The folder a search runs from while the active pane shows its results (`TabSearch` sets it).
    var searchRootPath: String? {
        get { activePane.searchRootPath }
        set { activePane.searchRootPath = newValue }
    }
    private var searchStore: TabSearch? { activePane.searchStore }
    /// The active pane's search: its session, the toolbar field, the results bar.
    var search: TabSearch { activePane.search }
    /// Services of its own, instead of the app's (a window in a test).
    var servicesOverride: ExplorerServices?
    /// What Edit opens files with; tests give their own, so nothing opens on this Mac.
    var opener: SystemOpener = .workspace
    /// Opens an activated file or app in what macOS chooses; tests give their own.
    var openFile: @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }
    private var observers: [(token: Weak<ExplorerWindowObservation>, handler: (ExplorerWindowChange) -> Void)] = []
    /// The active pane's history: folder paths and the one on screen.
    var navigationHistory: NavigationHistory { activePane.navigationHistory }
    /// How the folders in the active pane's history were left, for Back and Forward.
    var folderMemories: FolderViewMemories { activePane.folderMemories }
    /// The rename being carried out, so a second one does not start meanwhile.
    private var renameTask: Task<Void, Never>?
    /// Told when the folder is used for something (a file opened): the visits the Go To box counts.
    var onFolderUsed: (() -> Void)?
    /// What the Rename sheet needs when several items are selected and Return, F2 or Rename is chosen.
    var openBatchRename: (([DirectoryEntry]) -> Void)?
    /// Opens Settings (⌘,, the toolbar's Settings button): the app's Settings window, unless a test puts its own.
    var openSettings: (() -> Void)?
    /// Opens the Help window on a topic (`?`, the toolbar's Help): the app's, unless a test puts its own.
    var openHelp: ((HelpTopicID?) -> Void)?
    /// Previews an item: the system's Quick Look panel, unless a test puts its own, so nothing comes on screen.
    var showQuickLook: ((String) -> Void)?
    /// Carries out a rename and answers with its outcome, in place of the write coordinator (tests). Without it the
    /// coordinator renames (`WindowWriteActions.commitRename`), or, in a window without the app's file operations, the
    /// file system itself.
    var renameItem: ((_ path: String, _ name: String) async -> RenameOutcome)?
    /// A file operation ended with the tab at the back: as it comes back, its open tree branches are read again with
    /// its folder.
    var treeOutOfDate = false

    /// A tab on `tab`'s folder, with `history` (none: just the folder). It reads its folder when it is first shown,
    /// or at once with `loadNow`. `startsTheWindow`: the tab on screen as its window opens, which falls back to Home.
    init(
        tab: StartupTab, history: (paths: [String], index: Int)? = nil, frame: NSRect? = nil, loadNow: Bool = true,
        startsTheWindow: Bool = false
    ) {
        windowID = Self.nextWindowID
        Self.nextWindowID += 1
        let sizes = FolderSizeService.shared.sizes(for: windowID)
        folderSizes = sizes
        panes = [BrowserPane(tab: tab, history: history, folderSizes: sizes, startsTheWindow: startsTheWindow)]
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
        for pane in panes {
            pane.tab = self
            pane.watchID = windowID
        }
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
        workspace.mainCell.content = activePane.content.view
        workspace.inspectorCell.content = infoPanel
        workspace.statusCell.content = activePane.content.contentShell.pathBarRow
        // The tree's resizer is in no pane, so it walks Tab itself: on to the toolbar, or back into the tree.
        workspace.treeResizer.onTab = { [weak self] backward in
            guard let self else { return }
            if backward {
                self.perform(.focusTreePane)
            } else if let window = self.window {
                ToolbarKeyboard.enterFromStart(of: window)
            }
        }
        // The Info panel's resizer too. Nothing in the panel takes the keyboard: Tab goes on past it, to the start of
        // the row.
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

        wireContent(activePane)
        installMenusAndNotifications()
        installClipboardAndDrags()
        wirePathBar(activePane)
        infoController = InfoController(host: self, panel: infoPanel, row: activePane.content.contentShell.infoRow)
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

    /// The tab starts with the view the other one had. Its folder is read as it first shows, the task
    /// for that not having run yet.
    private func carry(_ view: TabViewState, of snapshot: TabSnapshot) {
        activePane.carry(view)
        sidebar.holdsScrollPosition = true
        sidebar.restoreView(
            nodes: ExplorerTabs.settleTreeNodes(view.treeNodes), selectedItem: snapshot.selectedTreeItemID,
            subview: snapshot.leftPaneSubview == .favorites ? .favorites : .tree)
        sidebar.startScrolled(tree: view.treeScrollTop, sections: view.sidebarSectionsScrollTop)
    }

    /// The tab starts with the tree of the tab it came from, scrolled as that one is, with its own
    /// folder's row in view if the tree has it yet. The tree then follows the folder from there.
    func startSidebar(like source: MainWindowController) {
        sidebar.holdsScrollPosition = true
        sidebar.restoreView(
            nodes: ExplorerTabs.settleTreeNodes(source.sidebar.model.nodes), selectedItem: sidebar.selectedTreeItemID,
            subview: sidebar.leftPaneSubview)
        sidebar.startScrolled(
            tree: source.sidebar.tree.scrollTop, sections: source.sidebar.sections.scrollTop, revealsSelection: true)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: The tab

    /// The tab as it is saved between launches.
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
    var shownViewMode: ExplorerViewMode { activePane.shownViewMode }

    /// Whether a text field of the tab (the search field, the results' filter, a rename) has the keyboard.
    var isTextFieldEditing: Bool {
        guard let editor = window?.firstResponder as? NSTextView else { return false }
        return editor.isFieldEditor
    }

    /// Reveal in Folder: the folder a result is in opens, with the result selected and the list focused.
    func revealSearchResult(_ path: String) {
        AppMenuPresenter.shared.close()
        guard let parent = ExplorerTabs.parentDirectoryPath(path) else { return }
        let target = URL(fileURLWithPath: parent)
        let move: HistoryMove = !folderLetGo && target.comparablePath == folder.comparablePath ? .replace : .push
        Task {
            guard await navigate(to: target, history: move) else { return }
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

    /// What the tab keeps of itself.
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

    /// The view on screen: the active pane's (`BrowserPane.liveView`), with the tree as the tab has it. A view the
    /// pane was started with keeps its scrolls.
    private var liveView: TabViewState? {
        guard var view = activePane.liveView else { return nil }
        view.treeNodes = sidebar.model.nodes
        if activePane.carriedView == nil {
            view.treeScrollTop = sidebar.tree.scrollTop
            view.sidebarSectionsScrollTop = sidebar.sections.scrollTop
        }
        return view
    }

    /// What the tab bar calls the tab; with two panes, its label names both (`twoPaneLabel`).
    var tabDescription: TabDescription {
        guard let session = searchStore?.session else {
            return ExplorerTabs.describe(
                currentPath: shownFolderPath, searchVisible: false, searchQuery: "", searchRootPath: "",
                searchRunning: false, startupDiskName: services.startupDisk.name)
        }
        return ExplorerTabs.describe(
            currentPath: shownFolderPath, searchVisible: session.resultsVisible, searchQuery: session.committedQuery,
            searchRootPath: session.rootPath, searchRunning: session.isRunning,
            startupDiskName: services.startupDisk.name)
    }

    /// A folder has been on screen in this tab.
    private var hasShownFolder: Bool { activePane.hasShownFolder }
    /// The pane the keyboard goes to as the tab shows its first folder: the one the tab it came from had it in.
    var startingPane = TabSnapshot.FocusedPane.content
    /// The tab was opened on a folder: its first folder can count as a visit for the Go To box.
    var opensAsArrival = false

    /// Reads the tab's folders the first time it is shown, or again when they were sent elsewhere in the background.
    func ensureLoaded() {
        for pane in panes { pane.ensureLoaded() }
    }

    /// A pane's first read ended: the tab is ready once its first pane's has.
    func paneFinishedFirstRead(_ pane: BrowserPane) {
        guard pane === panes.first, let ready = onReady else { return }
        onReady = nil
        ready()
    }

    /// Whether the tab's folder has been, or is being, read.
    var loaded: Bool { activePane.loaded }

    /// The tab was sent to another folder while in the background (its folder moved, or its disk went): the folder
    /// is read when the tab is next shown.
    var stale: Bool { activePane.stale }

    /// The keyboard is in the pane the tab starts with before the tab comes to the front: AppKit would give it the
    /// window's first key view, the sidebar's, whose selected row would then light up until the first folder arrives.
    func giveKeyboardToStartingPane() {
        guard !hasShownFolder, let window else { return }
        if startingPane == .tree, panels.folderTreeOpen { sidebar.focusTree() } else { content.focusList() }
        window.initialFirstResponder = window.firstResponder as? NSView
    }

    /// Runs `action` once the first read of the active pane's folder has finished, with whether it showed the folder.
    func whenFirstReadFinished(_ action: @escaping (Bool) -> Void) { activePane.whenFirstReadFinished(action) }

    /// `followMovedItems` and `leaveUnmountedDisks` for a tab in the background: it takes the place `snapshot` gives
    /// it (folder, history, tree root) and reads its folder when it is next shown.
    func takePlace(_ snapshot: TabSnapshot) {
        activePane.takePlace(snapshot)
        let favoritePrefix = "favorite:"
        let favorite = snapshot.selectedTreeItemID.flatMap {
            $0.hasPrefix(favoritePrefix) ? String($0.dropFirst(favoritePrefix.count)) : nil
        }
        sidebar.restore(
            rootPath: snapshot.treeRootPath, folder: snapshot.currentPath, favoritePath: favorite,
            favoritesExpanded: sidebar.favoritesExpanded, locationsExpanded: sidebar.locationsExpanded,
            includeHidden: includeHidden)
        updateTitle()
        notify(.history)
        group?.tabChanged(self)
    }

    /// The folder on screen, or one it is inside, was renamed or moved: it is read at its new place, in place in the
    /// history.
    func followOnScreen(_ moves: [PathMove]) {
        for pane in panes { pane.followOnScreen(moves) }
    }

    /// Reads the folder on screen again, quietly: something changed in it (`BrowserPane.reload`).
    func reload(changedPaths: [String]? = nil) { activePane.reload(changedPaths: changedPaths) }

    /// The folder read again because the app asks, not because of a change from outside: Show Info's
    /// item goes.
    func readAgain() { activePane.readAgain() }

    typealias FolderChangeHold = FolderChangeGate.Hold

    /// Changes made outside the app wait while something the list changing under would upset is going on: a name being
    /// typed, a menu or a sheet open, a file operation running, a drag.
    var folderChangesHeld: Bool { activePane.folderChangesHeld }

    func folderChangesHeld(by hold: FolderChangeHold) -> Bool { activePane.folderChangesHeld(by: hold) }

    /// Puts `hold` on, or takes it off, in every pane; what waited is read once nothing holds it any more. Each holder
    /// lets go of its own hold only: a menu that closes leaves a sheet that came up meanwhile holding them.
    func holdFolderChanges(_ hold: FolderChangeHold, _ held: Bool) {
        for pane in panes { pane.holdFolderChanges(hold, held) }
    }

    /// A name was typed, or a file operation here or in another window ended: what waited may be read now.
    func recheckFolderChanges() {
        for pane in panes { pane.recheckFolderChanges() }
    }

    /// Reads what waited now even though `hold` is on (the result sheet, so what the operation made shows behind it).
    func readFolderChanges(despite hold: FolderChangeHold) {
        for pane in panes { pane.readFolderChanges(despite: hold) }
    }

    /// The changes waiting to be read in the active pane.
    var pendingChange: FolderChangeGate.Pending? { activePane.pendingChange }

    /// A change from outside is being taken in: Show Info's item stays.
    var isTakingInOutsideChange: Bool { activePane.isTakingInOutsideChange }

    /// While a dialog is open or a name is being typed a press on the tab bar does nothing and the keyboard stays: the
    /// tabs keep the focus where it is and refuse to change. A left press is still a press on the dialog's scrim, which
    /// may close the dialog. Last, so what closes on a press outside it still hears it.
    private func holdTabBar(of window: NSWindow) {
        WindowEventRouting.add(window, last: true) { [weak self, weak window] event in
            guard let self, let window, [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type),
                self.group?.holdsTabBar == true, ExplorerTabGroup.isTabBarPress(at: event.locationInWindow, in: window)
            else { return false }
            if event.type == .leftMouseDown { DialogScrim.front(in: window)?.onScrimPress?() }
            return true
        }
    }

    /// Another tab came to the front. The window's one tracker hears of a folder on screen changing (`showing`), so the
    /// folder this tab was still being decided on was only passed through; each tab here has a tracker of its own.
    func wentToTheBack(for other: MainWindowController) {
        visitTracker.showing(other.shownFolderPath)
        for pane in panes where pane.dropWaitingReadAgain() { treeOutOfDate = true }
    }

    /// The tab is on screen again after another one, or for the first time. Show Info's item doesn't
    /// outlast it.
    func cameBack() {
        infoController?.letShowInfosItemGo()
        // The keyboard goes back to the pane the tab had it in, not the search field a window remembers on its own.
        // A tab just made gives it out when its first folder comes. A dialog open on the tab keeps
        // it and hands it back to the pane when it closes.
        if hasShownFolder, DialogScrim.front(in: window) == nil { keyboardBackToPane() }
        // Its dates stood still while it was at the back.
        RelativeClock.shared.windowStateDidChange()
        let refreshingTree = treeOutOfDate
        treeOutOfDate = false
        for pane in panes {
            guard pane.loaded, !pane.stale else {
                pane.ensureLoaded()
                continue
            }
            // Just made, it is reading its folder already.
            pane.cameBack(refreshingTree: refreshingTree && pane.drivesSidebar)
        }
    }

    static let retryDelay = 0.25
    /// What waits out `retryDelay` in the active pane; tests move it by hand.
    var timers: any TimerScheduling {
        get { activePane.timers }
        set { activePane.timers = newValue }
    }

    func updateTitle() {
        // The window title is the folder name, which the toolbar shows; the tab bar and the Window menu have the
        // tab's label (ExplorerTabGroup.refreshTitles).
        let name = ExplorerTabs.folderDisplayName(shownFolderPath, startupDiskName: services.startupDisk.name)
        window?.title = name.isEmpty ? "File Trail" : name
        window?.representedURL = folderLetGo ? nil : folder
    }

    /// The startup disk was renamed: the window title, the toolbar's title, the path bar, the sidebar and the Info panel
    /// say its new name. The tab bar follows with the window's titles (`ExplorerTabGroup.startupDiskNameChanged`). A
    /// tab waiting unread reads nothing for it: its Info panel asks for its item once the tab is first shown.
    func startupDiskNameChanged() {
        updateTitle()
        explorerToolbar.reload()
        content.contentShell.pathBarRow.namesChanged()
        sidebar.model.namesChanged()
        if loaded { infoController?.namesChanged() }
    }

    // MARK: Navigation

    func go(to url: URL, history: HistoryMove = .push, open: SidebarOpen = .other, keepingSearch: Bool = false) {
        activePane.go(to: url, history: history, open: open, keepingSearch: keepingSearch)
    }

    /// Reads `url` in the active pane, then shows it (`BrowserPane.navigate`).
    @discardableResult
    func navigate(
        to url: URL, history move: HistoryMove = .push, open: SidebarOpen = .other, keepingSearch: Bool = false,
        goToFailure: ((String) -> Void)? = nil
    ) async -> Bool {
        await activePane.navigate(
            to: url, history: move, open: open, keepingSearch: keepingSearch, goToFailure: goToFailure)
    }

    /// Where a pane is, history and sidebar row with it.
    struct TabPlace {
        let path: String
        let history: NavigationHistory
        let sidebarRow: TreeItemID?
    }

    var tabPlace: TabPlace { activePane.place }

    /// A drag's springs are undone (`BrowserPane.comeBack`).
    func comeBack(to place: TabPlace) async { await activePane.comeBack(to: place) }

    // MARK: Opening items

    /// The folder visits the Go To box counts.
    lazy var visitTracker = FolderVisitTracker { path, kind in
        MainWindowController.visitStore()?.recordFolderVisit(path, kind: kind)
    }

    /// What the plan of the items to open needs of the entries on screen.
    private func commandEntries(_ entries: [DirectoryEntry]) -> [CommandEntry] {
        entries.map { CommandEntry(path: $0.path, kind: FTFoundation.EntryKind(rawValue: $0.kind.rawValue) ?? .other) }
    }

    /// Double-click, Return (set to Open) and ⌘↓: opens the items, or edits them as "Double-click a file to" says.
    /// ⌘-double-click on a folder opens it in a new tab, as in Finder.
    func open(_ entries: [DirectoryEntry], inNewTab: Bool = false) {
        if inNewTab, entries.count == 1, entries[0].isDirectoryLike {
            openFolderInNewTab(entries[0])
            return
        }
        let prefs = preferences
        // Search results always open, never the edit-in-editor activation.
        let activation = searchRootPath != nil ? FileActivationAction.open : prefs.fileActivationAction
        perform(
            OpenItems.activation(commandEntries(entries), fileActivation: activation, limit: prefs.openItemLimit))
    }

    /// A selected folder opens in a new tab or window; a symbolic link to a folder opens the folder it points to, as it
    /// does when opened in place.
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

    /// Where a link points.
    /// Looked up off the main thread: a link into a slow volume must not freeze the window.
    private static func resolved(_ path: String) async -> String? {
        await Task.detached(priority: .userInitiated) { try? NativeFileSystem().realpath(path) }.value
    }

    private func perform(_ plan: OpenItems.Plan) {
        switch plan {
        case .nothing:
            break
        case .tooMany(let action, let selected, let limit):
            showNotice(
                title: OpenItems.limitTitle(action: action),
                message: OpenItems.limitMessage(action: action, selected: selected, limit: limit))
        case .edit(let paths):
            let editor = preferences.defaultTextEditor
            onFolderUsed?()
            let opener = opener
            Task { [weak self] in
                let result = await SystemActions.openPaths(paths, withApplication: editor.appPath, opener: opener)
                guard !result.ok else { return }
                self?.showNotice(
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
                    let pane = activePane
                    let token = pane.navigationCount
                    Task {
                        guard let target = await Self.resolved(path), token == pane.navigationCount, isKeyOrOnly else {
                            return
                        }
                        pane.go(to: URL(fileURLWithPath: target))
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

    /// A file or app opens in what macOS chooses, a disk image here, as in Finder.
    /// Either counts as using the folder.
    func openExternally(_ path: String) {
        if !noteUseAndOpenDiskImage(path) { openFile(URL(fileURLWithPath: path)) }
    }

    /// The start of opening a path, whichever control asks. True when `path` was a disk image, and is dealt with here.
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
            showNotice(title: title, message: message)
        }
    }

    // MARK: Keys and rename

    /// Return in the file list (with an item selected): Open or Rename, as the Return key setting says.
    private func pressedReturn() {
        let selected = content.selectedEntries
        guard !selected.isEmpty else { return }
        switch preferences.returnKeyAction {
        case .rename: renameSelected()
        case .open: open(selected)
        }
    }

    /// A command the list's keys ask for: the key is one the menu does not listen for (a command's second key, Space,
    /// F2, ⌘←). Whether the window ran it. Keys don't go by what dims the menu (only `ShortcutPolicy.canHandle` is
    /// asked): a command that can't start says why itself.
    private func runKeyCommand(_ id: ShortcutCommandID) -> Bool {
        if id == .openSelectedItem { return openSelectedItem() }
        guard let command = AppCommand(rawValue: id.rawValue), ShortcutPolicy.canHandle(command, shortcutContext)
        else { return false }
        perform(command)
        return true
    }

    /// A key whose menu item is dimmed: the item would keep it and do nothing, so the window takes the key before the
    /// menu and runs the command, which shows why it can't start: the busy notice, the open limit's notice,
    /// Duplicate's toast. An item that is on keeps its own key.
    func keyOfDimmedItem(_ event: NSEvent) -> Bool {
        guard !isTextFieldEditing, !isDialogOpen,
            let pressed = Shortcuts.fromKeyboardEvent(ContentKeyboard.shortcutEvent(event)),
            let id = ShortcutCommands.resolve(preferences.shortcutOverrides).command(pressed: pressed),
            id != .openSelectedItem, let command = AppCommand(rawValue: id.rawValue), !canPerform(command),
            ShortcutPolicy.canHandle(command, shortcutContext)
        else { return false }
        if WriteStartingShortcuts.runs(id.rawValue, isRepeat: event.isARepeat) { perform(command) }
        return true
    }

    /// ⌘↓: what is selected in the focused pane, the list or the tree, is activated, whatever the limit: over it, the
    /// limit's notice says so.
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

    /// `isTextEditingShortcut` with a text field that has the keyboard.
    func textFieldKeepsKey(_ event: NSEvent) -> Bool {
        guard isTextFieldEditing, !event.modifierFlags.intersection([.command, .control]).isEmpty,
            let pressed = Shortcuts.fromKeyboardEvent(ContentKeyboard.shortcutEvent(event))
        else { return false }
        return Shortcuts.isTextEditingShortcut(pressed)
    }

    /// A key that reached the window: the commands that the focused pane left alone (one table for every pane). A key
    /// that has a command is the command's, even when it can't run now.
    func windowKeyDown(_ event: NSEvent) -> Bool {
        guard !isTextFieldEditing, !isDialogOpen,
            let pressed = Shortcuts.fromKeyboardEvent(ContentKeyboard.shortcutEvent(event)),
            let command = ShortcutCommands.resolve(preferences.shortcutOverrides).command(pressed: pressed)
        else { return false }
        if WriteStartingShortcuts.runs(command.rawValue, isRepeat: event.isARepeat) { _ = runKeyCommand(command) }
        return true
    }

    /// F2, Rename and Return: one item is renamed in its row, several in the Rename sheet.
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
                    // A tab has the file operations once the app has started them.
                    .unchanged
                }
            guard self.content.inlineRename?.path == path else {
                // The folder was left while the name was checked (a click on another folder ends the field and opens
                // that folder): with no field to show it under, the refusal gets a dialog of its own.
                if case .refused(let message) = outcome, !self.content.listed.contains(where: { $0.path == path }) {
                    let name = NodePath.basename(path)
                    self.renameNotice(title: "\u{201C}\(name)\u{201D} couldn\u{2019}t be renamed", message: message)
                }
                return
            }
            switch outcome {
            case .unchanged, .started:
                self.content.endRename()
            case .refused(let message):
                self.content.refuseRename(message)
            }
        }
    }

    /// ⌘F, and Search Subfolders on the empty filter: the search field takes the keyboard.
    func focusFileSearch() {
        search.focusField()
    }

    /// The folder Open in New Tab and Open in New Window open: the one folder selected, or with the sidebar focused its
    /// selected folder.
    private var selectedFolder: URL? {
        if focusedPane == .tree { return sidebar.selectedTreeTargetPath.map { URL(fileURLWithPath: $0) } }
        return selectedContentFolder
    }

    // MARK: The content pane

    /// Connects the content pane to the window: what it reads from the services, and what it reports.
    func wireContent(_ pane: BrowserPane) {
        let content = pane.content
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
                Task { _ = await SystemActions.openFullDiskAccessSettings() }
            })
        content.onActivate = { [weak self, weak pane] entries, newTab in
            guard let self, let pane else { return }
            self.activate(pane)
            self.open(entries, inNewTab: newTab)
        }
        content.onSortRequested = { [weak pane] field in pane?.sort(by: field) }
        content.onSortSetFromOutside = { [weak pane] field, ascending in
            pane?.setSort(field, ascending ? .asc : .desc)
        }
        content.onSelectionChanged = { [weak self, weak pane] selection in
            guard let pane else { return }
            pane.searchStore?.session.noteSelection(selection)
            if pane.searchRootPath != nil { pane.updatePathBar() }
            self?.noteFocusedPane()
            self?.notify(.selection)
        }
        content.shortcutsProvider = { [weak self] in
            ShortcutCommands.resolve(self?.preferences.shortcutOverrides ?? [:])
        }
        content.onReturn = { [weak self] in self?.pressedReturn() }
        // Tab walks the tree and the panes in the order they are on screen; with the tree hidden it stays among the
        // panes, and with one pane in the list.
        content.onSwitchPane = { [weak self, weak pane] in
            guard let self, let pane else { return }
            self.tabKeyPressed(from: pane)
        }
        content.onCommand = { [weak self] id in self?.runKeyCommand(id) ?? false }
        content.onRenameSubmit = { [weak self] path, name in self?.submitRename(path: path, typed: name) }
        content.onRenameStateChanged = { [weak self, weak content] in
            guard let self else { return }
            // While a name is being typed, changes made outside the app wait.
            if content?.inlineRename == nil { self.recheckFolderChanges() }
            self.notify(.focusedPane)
        }
        // A refusal the field was showing when its item left the list.
        content.onRenameLost = { [weak self] _, refusal in
            guard let refusal else { return }
            self?.renameNotice(title: WriteStartAction.operation(.rename).failureTitle, message: refusal)
        }
        content.onSearchSubfolders = { [weak self] in self?.focusFileSearch() }
        // The chip switches the filter on screen and makes its mode the default for the filters to come.
        content.onToggleFilterMode = { [weak self, weak pane] in
            guard let self, let pane else { return }
            let mode = pane.content.toggleFilterMode()
            pane.searchStore?.header.showFilterMode(pane.content.filterMode)
            self.updatePreferences { $0.listFilterMatch = mode }
        }
        content.onColumnWidthsChanged = { [weak self, weak pane] widths in
            guard let pane else { return }
            self?.saveColumnWidths(widths, searching: pane.searchStore?.showsResults == true)
        }
        content.onCompactListWidthChanged = { [weak self] density, width in
            self?.updatePreferences { $0.compactListWidths[density] = width }
        }
        content.onIconSizeChanged = { [weak self] density, size in
            self?.updatePreferences { $0.iconSizes[density] = size }
        }
        content.setView(
            sortBy: pane.sortBy, direction: pane.sortDirection, foldersFirst: pane.foldersFirst,
            includeHidden: pane.includeHidden)
        content.setDefaultFilterMode(preferences.listFilterMatch)
        content.sizeShortcuts = sizeShortcuts
        content.setColumns(ListColumnState(preferences: preferences))
        content.setMode(pane.viewMode)
    }

    /// The widths the List keeps are the window's own (`detailColumnWidths` is a window session key).
    private func saveColumnWidths(_ widths: [DetailColumn: Double], searching: Bool) {
        // As the column's width is drawn, then kept as a whole number the way the saved state keeps it.
        func width(_ column: DetailColumn) -> Double {
            DetailsColumns.clamp(widths[column] ?? 0, column: column, search: searching)
        }
        if searching {
            // Search results keep widths of their own (`searchColumnWidths`), Folder among them.
            updatePreferences {
                for key in SearchColumnKey.allCases {
                    let column = DetailColumn(rawValue: key.rawValue) ?? .name
                    $0.searchColumnWidths[key] = AppPreferenceLimits.clampSearchColumnWidth(key, width(column))
                }
            }
            // What the window saves with every navigation, so it keeps them.
            updatePanels { $0.searchColumnWidths = preferences.searchColumnWidths }
            return
        }
        updatePreferences {
            for key in DetailColumnKey.allCases {
                let column = DetailColumn(rawValue: key.rawValue) ?? .name
                $0.detailColumnWidths[key] = AppPreferenceLimits.clampDetailColumnWidth(key, width(column))
            }
        }
        updatePanels { $0.detailColumnWidths = preferences.detailColumnWidths }
    }

    /// The columns and the density again, from the preferences (Settings changed them, or a scenario did).
    /// The keys of the size commands, which the status bar's slider names.
    var sizeShortcuts: ShortcutDisplay {
        ShortcutDisplay(shortcuts: ShortcutCommands.resolve(preferences.shortcutOverrides))
    }

    func refreshColumns() {
        for pane in panes { pane.refreshColumns() }
    }

    /// The search changed how it stands: the tab's label and magnifier, and the commands.
    func searchStateChanged() {
        group?.refreshTitles()
        updateSearchTabAccessory()
        notify(.search)
    }

    /// A search tab shows a magnifier before its label, in the accent while it searches.
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

    /// Refresh: the caches of the listing are let go of, and the folder is read again with the selection kept.
    func refresh() {
        services.directoryService.cache.clear()
        readAgain()
        // The tree's way to hear of subfolders added or removed outside the app, for the folder watch
        // leaves it alone.
        guard treeFollowsReadingAgain else { return }
        let open = sidebar.model.openReadingAgain(folder.path)
        if open.forceTreeReload { sidebar.folderOpened(folder, open) }
    }

    /// The folder on screen read again brings the tree along; a folder being opened now will do that itself.
    var treeFollowsReadingAgain: Bool { activePane.treeFollowsReadingAgain }

    /// The folder selected in the file list, if it is the one item selected and a folder.
    private var selectedContentFolder: URL? {
        let items = content.selectedEntries
        guard items.count == 1, items[0].isDirectoryLike else { return nil }
        return items[0].url
    }

    /// The keyboard goes back to the pane that last had it, from a toolbar button about to stop taking it, so the
    /// pane's keys still work (`focusedPane` stays); left to itself, AppKit would hand it to the next view, the search
    /// field.
    func keyboardBackToPane() {
        if lastFocusedPane == .tree, panels.folderTreeOpen { sidebar.focusTree() } else { content.focusList() }
    }

    /// The pane that last had the keyboard.
    private func noteFocusedPane() {
        if let pane = focusedPane { lastFocusedPane = pane }
    }

    /// What the commands read of the keyboard, as it last was.
    private var keyboardHolder: (pane: ExplorerPane?, editing: Bool) = (nil, false)

    /// The keyboard moved in the window.
    func keyboardMoved() {
        followKeyboardToPane()
        noteFocusedPane()
        let now = (pane: focusedPane, editing: isTextFieldEditing)
        guard now != keyboardHolder else { return }
        keyboardHolder = now
        notify(.focusedPane)
    }

    /// What the command rules look at of the selection in the file list.
    private var commandEntries: [CommandEntry] { commandEntries(content.selectedEntries) }

    /// The folder File ▸ Add to Favorites acts on.
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
        sidebar.model.startupDiskName = { [weak self] in
            self?.services.startupDisk.name ?? VolumePaths.defaultStartupDiskName
        }
        sidebar.updatePreferences = { [weak self] change in self?.updatePreferences(change) }
        sidebar.directoryService = { [weak self] in
            self?.services.directoryService ?? ExplorerServices.current.directoryService
        }
        sidebar.openInNewTab = { [weak self] path in
            guard let self else { return }
            self.group?.openTab(path: path, from: self)
        }
        sidebar.focusContent = { [weak self] in self?.tabKeyPressedInTree() }
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

    /// The folder on screen is let go of: the file list shows nothing.
    private func releaseFolder() {
        // Letting go of the folder puts the search results away too.
        searchStore?.session.putResultsAway()
        showNoFolder()
        sidebar.focusTree()
        group?.tabChanged(self)
        notify(.folder)
        notify(.selection)
    }

    private func showNoFolder() { activePane.showNoFolder() }

    // MARK: Menu state

    /// What the application menu shows of this tab, from what the toolbar and the keys
    /// read.
    var menuState: ApplicationMenuState {
        let context = commandContext
        let panels = group?.session.panels
        return ApplicationMenuState.build(
            viewMode: shownViewMode, sortBy: sortBy, foldersFirst: foldersFirst, hiddenFilesShown: includeHidden,
            folderTreeOpen: panels?.folderTreeOpen ?? true, infoPanelOpen: panels?.propertiesOpen ?? false,
            infoRowOpen: panels?.detailRowOpen ?? false, twoPanesShown: showsTwoPanes,
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
    /// every file operation.
    var trashIsEmpty: Bool?
    /// Reads whether the Trash has anything in it; tests use their own.
    var trashIsEmptyReader: @Sendable () -> Bool? = {
        TrashState.isEmpty(home: FileManager.default.homeDirectoryForCurrentUser.path, uid: getuid())
    }

    /// Counts the reads asked for, so an older one that answers late does not replace a newer answer.
    private var trashReads = 0

    func refreshTrashState() {
        let read = trashIsEmptyReader
        trashReads += 1
        let asked = trashReads
        Task { [weak self] in
            let empty = await Task.detached(priority: .utility) { read() }.value
            guard let self, asked == self.trashReads, self.trashIsEmpty != empty else { return }
            self.trashIsEmpty = empty
            self.commandsChanged()
        }
    }

    /// The home folder whose Trash gets the bar; tests use their own.
    var trashHomePath = FileManager.default.homeDirectoryForCurrentUser.path

    /// The Trash itself on screen has its bar, not a folder in it, and not over search results, in each pane. Empty
    /// follows Empty Trash in the menu: dimmed with nothing to erase, or while a file operation runs.
    private func refreshTrashHeader() {
        let canEmpty = canPerform(.emptyTrash)
        for pane in panes {
            let shell = pane.content.contentShell
            guard pane.searchRootPath == nil, Paths.isTrashFolder(pane.shownFolderPath, homePath: trashHomePath) else {
                shell.trashHeader = nil
                continue
            }
            shell.trashHeader = pane.trashHeader
            pane.trashHeader.emptyButton.isEnabled = canEmpty
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

    /// The toolbar's Enclosing Folder: it doesn't look at which pane has the keyboard, and
    /// with no folder on screen it opens the top of the disk (`parentDirectoryPath("")`).
    func goToParentFolder() {
        guard !isCustomizingToolbar, !isDialogOpen, let parent = ExplorerTabs.parentDirectoryPath(shownFolderPath)
        else {
            return
        }
        go(to: URL(fileURLWithPath: parent))
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
    func setSearchViewMode(_ mode: ExplorerViewMode) { activePane.setSearchViewMode(mode) }

    func setMode(_ mode: ExplorerViewMode) { activePane.setMode(mode) }

    func sort(by field: SortByPreference) { activePane.sort(by: field) }

    func setSort(_ field: SortByPreference, _ direction: SortDirectionPreference) {
        activePane.setSort(field, direction)
    }

    private func viewChanged(keepingTree: Bool = false) { activePane.viewChanged(keepingTree: keepingTree) }

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
        // Closing a tab stops its searches.
        for pane in panes { pane.searchStore?.session.close() }
        group?.tabWillClose(self)
        visitTracker.dispose()
        // An open clipboard or Undo History list goes with the tab, and so does what it listens to.
        clipboardUI.close()
        undoHistoryUI.close()
        if let window { WindowEventRouting.forget(window) }
        FolderSizeService.shared.forget(windowID: windowID)
        onClose?()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard group?.acceptsKey(self) != false else { return }
        ensureLoaded()
        refreshTrashState()
        // The tab on screen is the one live search; the others of its window go on in the background.
        for other in group?.tabs ?? [] where other !== self {
            for pane in other.panes { pane.searchStore?.session.enterBackground() }
        }
        for pane in panes { pane.searchStore?.session.returnToForeground() }
        group?.frontSearch = searchStore
        group?.tabBecameKey(self)
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

    func notify(_ change: ExplorerWindowChange) {
        if change == .folder || change == .search || change == .commands { refreshTrashHeader() }
        // The Trash on screen changed, or came to the screen: what it holds may not be what was last read.
        if change == .folder, panes.contains(where: { $0.content.contentShell.trashHeader != nil }) {
            refreshTrashState()
        }
        observers.removeAll { $0.token.value?.isValid != true }
        for observer in observers { observer.handler(change) }
        reportMenuStateSoon()
    }

    /// What Copy or Cut put on the app's clipboard changed (every window hears it from the shared clipboard): the
    /// marks, the toolbar's button and its list follow.
    func clipboardChanged() {
        clipboardMarksChanged()
        notify(.clipboard)
    }

    /// A preference changed in any window or in Settings: the keys the whole app shares.
    func preferencesChanged(_ change: PreferencesChange) {
        // A Settings edit of the search options updates the live values without running anything again.
        let searchDefaults: Set<PreferenceKey> = [
            .searchPatternMode, .searchMatchScope, .searchRecursive, .searchSkipGitFolders, .searchSkipGitIgnored,
        ]
        // Only the keys edited, and only in the tab on screen: a tab behind keeps the options of its own search.
        if let search = searchStore, group == nil || group?.selected === self {
            let edited = searchDefaults.intersection(change.keys)
            if !edited.isEmpty { search.session.applyDefaults(preferences, keys: edited) }
        }
        sidebar.applyPreferences()
        for pane in panes {
            pane.content.setDefaultFilterMode(preferences.listFilterMatch)
            pane.searchStore?.header.showFilterMode(pane.content.filterMode)
        }
        refreshColumns()
        notificationsSettingChanged()
        if change.keys.contains(.markClipboardItems) || change.keys.isEmpty { clipboardMarksChanged() }
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
    func perform(_ command: AppCommand) {
        // While the toolbar is customized the window waits, as under a sheet: only editing still works.
        if isCustomizingToolbar, MenuCommandRouter.nativeEditSelector(command) == nil, command != .customizeToolbar {
            return
        }
        // So it does under the Go To box or an alert: only a field's editing commands act.
        if isDialogOpen {
            if let selector = MenuCommandRouter.nativeEditSelector(command), isTextFieldEditing {
                performFieldEdit(selector)
            }
            return
        }
        // A text field with the keyboard (the search field, the results' filter) does Cut, Copy, Paste, Select All and
        // Undo itself.
        if let selector = MenuCommandRouter.nativeEditSelector(command), isTextFieldEditing {
            performFieldEdit(selector)
            return
        }
        // A name being edited in its row waits for nothing but Settings and the field's own
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
        case .increaseSize, .decreaseSize, .resetSize:
            if let change = ViewSize.Change(command) { content.stepViewSize(change) }
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
            viewChanged(keepingTree: !sidebar.model.rootPath.isEmpty)
            searchStore?.session.hiddenFilesChanged(includeHidden)
        case .refreshOrApplySearchSort:
            // In search mode ⌘R runs the same search again.
            if let session = searchStore?.session, session.isSearchMode { session.rerun() } else { refresh() }
        case .showLastSearchResults:
            if searchStore?.session.hasCachedSearch == true { search.showLastResults() }
        case .revealInFolder:
            // The lead result's folder, or the first selected's when there is no lead.
            if searchRootPath != nil, let path = content.selection.leadPath ?? selectedPaths.first {
                revealSearchResult(path)
            }
        case .customizeToolbar: beginCustomizingToolbar()
        // The places of the Go menu: the startup disk and the Trash act exactly as a click on their Locations
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
            // A hidden tree comes back first.
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
        case .toggleTwoPanes: toggleTwoPanes()
        case .switchToOtherPane: switchToOtherPane()
        case .toggleFolderTree: updatePanels { $0.folderTreeOpen.toggle() }
        case .toggleInfoPanel: updatePanels { $0.propertiesOpen.toggle() }
        case .toggleInfoRow: updatePanels { $0.detailRowOpen.toggle() }
        case .focusContentPane: content.focusList()
        case .renameSelection: renameSelected()
        case .editSelection:
            // Anything but files among the items and Edit does nothing, over the limit too.
            guard commandEntries.count == selectedPaths.count, commandEntries.allSatisfy(\.kind.isEditableFile)
            else { return }
            let prefs = preferences
            self.perform(OpenItems.editPlan(content.selection.paths, limit: prefs.openItemLimit))
        case .focusFileSearch: focusFileSearch()
        case .quickLookSelection: quickLookSelection()
        case .editSelectAll:
            // Every entry while the file list has the keyboard, sent to the pane and not up a
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
        // Hiding the tree while it has the keyboard gives the keyboard to the list. Asked first: a view going hidden
        // lets go of the keyboard.
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

    func canPerform(_ command: AppCommand) -> Bool {
        CommandAvailability.canRun(command, commandContext)
    }

    func commandAvailability() -> (AppCommand) -> Bool {
        let context = commandContext
        return { CommandAvailability.canRun($0, context) }
    }

    /// What decides whether a command or a key can act now.
    var shortcutContext: ShortcutContext {
        ShortcutContext(
            actionNoticeOpen: frontAlert != nil,
            // `copyPasteModalOpen` holds the Rename sheet and a name being typed in its row too.
            copyPasteModalOpen: isBatchRenameOpen || CopyPasteDialogs.isOpen(in: window)
                || content.inlineRename != nil,
            focusedPane: commandPane,
            // Customizing the toolbar is a sheet over the window: the commands wait for it to end.
            locationSheetOpen: isCustomizingToolbar || goToBox != nil,
            selectedTreeTargetKind: sidebar.selectedTreeTargetKind)
    }

    /// Everything the command rules read: the one state of the menu bar, the toolbar
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
            tabCount: group?.tabs.count ?? 1, paneCount: panes.count,
            trashPath: FavoriteLabel.trashPath(homePath: home), homePath: home,
            trashIsEmpty: trashIsEmpty, ejectTargetPath: ejectTargetPath,
            trashIsFavorite: sidebar.isFavorite(FavoriteLabel.trashPath(homePath: home)),
            viewSizeSteps: content.viewSize?.steps ?? .unavailable)
    }

    /// The folders File > Calculate Size measures now.
    var calculateSizePaths: [String] { CommandAvailability.calculateSizePaths(commandTargets) }

    /// What the commands' target rules read.
    private var commandTargets: CommandAvailability.TargetContext {
        let trashPath = FavoriteLabel.trashPath(homePath: FileManager.default.homeDirectoryForCurrentUser.path)
        return CommandAvailability.TargetContext(
            currentPath: shownFolderPath, selectedPathsInViewOrder: selectedPaths, activeContentEntries: commandEntries,
            selectedTreeTargetPath: sidebar.selectedTreeTargetPath, isSearchMode: searchRootPath != nil,
            trashPath: trashPath, trashIsFavorite: sidebar.isFavorite(trashPath), focusedPane: commandPane)
    }

    var selectedPaths: [String] { content.selection.paths }

    var focusedPane: ExplorerPane? {
        // Starting a rename leaves no pane focused: the window's own shortcuts wait. So does any other text
        // field (the path bar's, the results' filter): only the panes' own focus counts (`onFocusChange`).
        if content.inlineRename != nil || isTextFieldEditing { return nil }
        guard let responder = window?.firstResponder as? NSView else { return nil }
        if responder.isDescendant(of: content.view) || responder.isDescendant(of: content.contentShell.pathBarRow) {
            return .content
        }
        if responder.isDescendant(of: sidebar.view) { return .tree }
        return nil
    }

    var viewState: ExplorerViewState { activePane.viewState }

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

    func updatePreferences(_ change: (inout EditedPreferences) -> Void) {
        guard let channel = services.preferences else { return }
        channel.update(from: windowID, change)
    }

    var services: ExplorerServices { servicesOverride ?? ExplorerServices.current }

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
