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

    // The toolbar's search field folds before the toolbar lays out a width it hasn't room for (`windowWillResize`).
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        if frameRect.width != frame.width { explorerTab?.explorerToolbar.windowWillResize(toWidth: frameRect.width) }
        super.setFrame(frameRect, display: flag)
    }

    override func setFrame(_ frameRect: NSRect, display displayFlag: Bool, animate animateFlag: Bool) {
        if frameRect.width != frame.width { explorerTab?.explorerToolbar.windowWillResize(toWidth: frameRect.width) }
        super.setFrame(frameRect, display: displayFlag, animate: animateFlag)
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
    /// The active pane's folder, by the path its listing gave (`BrowserPane.folderPath`), and how it shows it.
    var folderPath: String { activePane.folderPath }
    private var folderLetGo: Bool { activePane.folderLetGo }
    /// How the tab shows its folder, kept between launches with its folder. The sidebar keeps its tree and sections.
    var treeRootPath: String { sidebar.treeRootPath }
    var favoritePath: String? { sidebar.favoritePath }
    var viewMode: ExplorerViewMode { activePane.viewMode }
    var searchViewMode: ExplorerViewMode { activePane.searchViewMode }
    var sortBy: SortByPreference { activePane.sortBy }
    var sortDirection: SortDirectionPreference { activePane.sortDirection }
    /// Hidden Files is the tab's, not a pane's: both panes and the tree show hidden items or neither does.
    var includeHidden: Bool {
        get { activePane.includeHidden }
        set { for pane in panes { pane.includeHidden = newValue } }
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
    /// Where the second pane was when it was last closed, for ⌘\ to open it there again, with what it had on screen.
    /// It is the tab's while it is open: Reopen Closed Tab and Duplicate Tab don't bring it.
    var closedSecondPane: (start: StartupTab, history: NavigationHistory, view: TabViewState?)?
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
    /// The system's clipboard, which Paste as File writes from.
    let systemClipboard = SystemClipboard()
    /// Copy Contents, onto the clipboard Paste as File reads.
    lazy var contentsCopier = CopyContentsAction(
        pasteboard: { [unowned self] in systemClipboard.pasteboard }, window: { [unowned self] in window },
        toasts: { [unowned self] in notifications?.toasts })
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
    /// The Activity list under its toolbar button.
    lazy var activityUI = TabActivity(tab: self)
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
    /// The event being handled, which says whether a key is held down; tests give their own.
    var currentEvent: @MainActor () -> NSEvent? = { NSApp.currentEvent }
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
    /// The folder view's popover while it is open (`showFolderViewPopover`).
    var folderViewPopover: FolderViewPopover?
    /// Opens the Help window on a topic (`?`, the toolbar's Help): the app's, unless a test puts its own.
    var openHelp: ((HelpTopicID?) -> Void)?
    /// Previews an item: the system's Quick Look panel, unless a test puts its own, so nothing comes on screen.
    var showQuickLook: ((String) -> Void)?
    /// Shares items: the system's share popover, unless a test puts its own, so nothing comes on screen.
    var showSharePicker: (([String], NSRect, NSView) -> Void)?
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
        // The divider is kept with the tab.
        workspace.onPaneSplitChosen = { [weak self] _ in
            guard let self else { return }
            self.group?.tabChanged(self)
        }
        workspace.activePaneKeyboard = { [weak self] in
            guard let content = self?.activePane.content else { return (true, true) }
            return (content.keyboardIsInPane, content.windowIsActive)
        }
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
        // What is done in the folders is done in the active pane's.
        onFolderUsed = { [weak self] in self?.activePane.visitTracker.use() }
        #if DEBUG
            AutomationLayoutPrefs.registerOnce()
            AutomationSidebarPrefs.registerOnce()
            AutomationContentPrefs.registerOnce()
            AutomationNotificationPrefs.registerOnce()
            AutomationInfoPrefs.registerOnce()
            AutomationClipboardPrefs.registerOnce()
            AutomationSearchPrefs.registerOnce()
        #endif
        if let second = tab.secondPane {
            restoreSecondPane(second, history: nil, active: tab.activePane == 1, split: tab.paneSplit)
        }
        updateTitle()
        if loadNow { ensureLoaded() }
    }

    /// A tab as `snapshot` kept it: its folder, tree, view and history, each pane's (Reopen Closed Tab, Duplicate Tab).
    convenience init(snapshot: TabSnapshot, frame: NSRect?) {
        // The tree's row is the active pane's: a favorite the second pane is on isn't the first pane's folder.
        let startup = StartupTab(
            path: snapshot.currentPath, rootPath: snapshot.treeRootPath,
            favoritePath: snapshot.selectedTreeItemID == "favorite:\(snapshot.currentPath)"
                ? snapshot.currentPath : nil,
            viewMode: snapshot.viewMode, searchViewMode: snapshot.searchViewMode, sortBy: snapshot.sortBy,
            sortDirection: snapshot.sortDirection, includeHidden: snapshot.includeHidden,
            foldersFirst: snapshot.foldersFirst, favoritesExpanded: snapshot.favoritesExpanded,
            locationsExpanded: snapshot.locationsExpanded, viewSizes: snapshot.viewSizes,
            filterMode: snapshot.filterMode, groupBy: snapshot.groupBy, searchGroupBy: snapshot.searchGroupBy,
            groupReversed: snapshot.groupReversed, searchGroupReversed: snapshot.searchGroupReversed)
        self.init(tab: startup, history: (snapshot.historyPaths, snapshot.historyIndex), frame: frame)
        startingPane = snapshot.focusedPane
        if let view = snapshot.view { carry(view, of: snapshot) }
        if let second = snapshot.secondPane {
            restoreSecondPane(
                second.pane, history: (second.historyPaths, second.historyIndex), view: second.view,
                active: snapshot.activePane == 1, split: snapshot.paneSplit)
        }
    }

    /// The tab starts with the view the other one had. Its folder is read as it first shows, the task
    /// for that not having run yet.
    private func carry(_ view: TabViewState, of snapshot: TabSnapshot) {
        panes[0].carry(view)
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
    /// Its first pane, and its second while it shows two.
    var openTab: OpenTabPreference {
        var tab = paneTab(panes[0])
        if panes.count > 1 {
            tab.secondPane = savedPane(panes[1])
            tab.activePane = activePaneIndex == 1 ? 1 : nil
            tab.paneSplit = workspace.paneSplit
        }
        return tab
    }

    /// The active pane alone, as a new window starts from it: its pane is a new one, which starts with the filter
    /// mode chosen last.
    var activePaneTab: OpenTabPreference {
        var tab = paneTab(activePane)
        tab.filterMode = nil
        return tab
    }

    private func paneTab(_ pane: BrowserPane) -> OpenTabPreference {
        let path = pane.shownFolderPath
        return OpenTabPreference(
            path: path.isEmpty ? nil : path, treeRootPath: treeRootPath.isEmpty ? nil : treeRootPath,
            favoritePath: favoritePath.map(DiskPath.init) == DiskPath(path) ? favoritePath : nil,
            viewMode: pane.viewMode,
            searchViewMode: pane.searchViewMode, sortBy: pane.sortBy, sortDirection: pane.sortDirection,
            includeHidden: pane.includeHidden, foldersFirst: pane.foldersFirst, favoritesExpanded: favoritesExpanded,
            locationsExpanded: locationsExpanded, viewSizes: savedViewSizes(pane),
            filterMode: pane.content.folderFilterMode, groupBy: pane.groupBy, searchGroupBy: pane.searchGroupBy,
            groupReversed: pane.groupReversed, searchGroupReversed: pane.searchGroupReversed)
    }

    /// The sizes a pane is saved with: its own, or for one not shown yet the app's as they are now, so a workspace
    /// or the tabs kept at quit hold what it would have shown.
    private func savedViewSizes(_ pane: BrowserPane) -> PaneViewSizes {
        pane.viewSizes ?? PaneViewSizes(preferences)
    }

    /// A pane as a saved tab keeps its second one.
    func savedPane(_ pane: BrowserPane) -> OpenPanePreference {
        let path = pane.shownFolderPath
        return OpenPanePreference(
            path: path.isEmpty ? nil : path, viewMode: pane.viewMode, searchViewMode: pane.searchViewMode,
            sortBy: pane.sortBy, sortDirection: pane.sortDirection, includeHidden: pane.includeHidden,
            foldersFirst: pane.foldersFirst, viewSizes: savedViewSizes(pane),
            filterMode: pane.content.folderFilterMode, groupBy: pane.groupBy, searchGroupBy: pane.searchGroupBy,
            groupReversed: pane.groupReversed, searchGroupReversed: pane.searchGroupReversed)
    }

    /// The tab as a new tab or a reopened one starts from it.
    var startupTab: StartupTab {
        StartupTab(
            path: shownFolderPath, rootPath: treeRootPath, favoritePath: favoritePath, viewMode: viewMode,
            searchViewMode: searchViewMode, sortBy: sortBy, sortDirection: sortDirection,
            includeHidden: includeHidden, foldersFirst: foldersFirst, favoritesExpanded: favoritesExpanded,
            locationsExpanded: locationsExpanded, viewSizes: activePane.viewSizes, groupBy: activePane.groupBy,
            searchGroupBy: activePane.searchGroupBy, groupReversed: activePane.groupReversed,
            searchGroupReversed: activePane.searchGroupReversed)
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
        Task {
            // The result's folder as the disk spells it, which is how the folder on screen is known: a search may
            // have run from another spelling of it (/var for /private/var), and only the disk says the two are one.
            let target = await BlockingWork.run { DiskPath(parent).asOnDisk().string }
            let move: HistoryMove = !folderLetGo && samePath(target, folderPath) ? .replace : .push
            guard await navigate(to: target, history: move) else { return }
            // By its name in the folder opened: the listing gives its rows the folder's real path, which may be spelled
            // otherwise than the one the search ran from (/private/var for /var). The row spelled exactly so comes
            // first, where the folder holds the name with its accent spelled both ways; one spelled the other way only
            // when no row is spelled so.
            let name = NodePath.basename(path)
            let row =
                content.listedEntry(at: path)
                ?? content.listed.first { $0.name.utf16.elementsEqual(name.utf16) }
                ?? content.listed.first { $0.path == path }
            content.select(paths: [row?.path ?? path])
            content.focusList()
        }
    }

    /// What the tab keeps of itself.
    /// Its fields are the first pane's; the second pane, while there is one, comes with its history. The tree's row is
    /// the one selected, which follows the active pane.
    var snapshot: TabSnapshot {
        let pane = focusedPane ?? lastFocusedPane
        let first = panes[0]
        let active = activePane
        var snapshot = TabSnapshot(
            currentPath: first.shownFolderPath, historyPaths: first.navigationHistory.paths,
            historyIndex: max(0, first.navigationHistory.index),
            viewMode: first.viewMode, searchViewMode: first.searchViewMode, sortBy: first.sortBy,
            sortDirection: first.sortDirection, treeRootPath: treeRootPath,
            selectedTreeItemID: sidebar.selectedTreeItemID ?? (active.folderLetGo ? nil : "fs:\(active.folderPath)"),
            leftPaneSubview: sidebar.leftPaneSubview == .favorites ? .favorites : .tree,
            focusedPane: pane == .tree ? .tree : .content,
            includeHidden: first.includeHidden, foldersFirst: first.foldersFirst, favoritesExpanded: favoritesExpanded,
            locationsExpanded: locationsExpanded, view: liveView)
        snapshot.viewSizes = first.viewSizes
        snapshot.filterMode = first.content.folderFilterMode
        snapshot.groupBy = first.groupBy
        snapshot.searchGroupBy = first.searchGroupBy
        snapshot.groupReversed = first.groupReversed
        snapshot.searchGroupReversed = first.searchGroupReversed
        if panes.count > 1 {
            let second = panes[1]
            snapshot.secondPane = PaneSnapshot(
                pane: savedPane(second), historyPaths: second.navigationHistory.paths,
                historyIndex: max(0, second.navigationHistory.index), view: liveView(of: second))
            snapshot.activePane = activePaneIndex
            snapshot.paneSplit = workspace.paneSplit
        }
        return snapshot
    }

    /// The view on screen: the first pane's (`BrowserPane.liveView`), as the snapshot's other fields are, with the tree
    /// as the tab has it.
    private var liveView: TabViewState? {
        guard var view = liveView(of: panes[0]) else { return nil }
        view.treeNodes = sidebar.model.nodes
        return view
    }

    /// `pane`'s view on screen, with the tree's scrolls as the tab has them, which the active pane puts back as it shows
    /// its first folder. A view the pane was started with keeps its scrolls.
    private func liveView(of pane: BrowserPane) -> TabViewState? {
        guard var view = pane.liveView else { return nil }
        if pane.carriedView == nil {
            view.treeScrollTop = sidebar.tree.scrollTop
            view.sidebarSectionsScrollTop = sidebar.sections.scrollTop
        }
        return view
    }

    /// What Reopen Closed Tab brings back of the tab: its snapshot, without what a search showing in a pane had on
    /// screen, as the search isn't brought back.
    var closedSnapshot: TabSnapshot {
        var kept = snapshot
        if panes[0].showsSearchResults { kept.view = kept.view?.leavingSearchResults() }
        if panes.count > 1, panes[1].showsSearchResults, let view = kept.secondPane?.view {
            kept.secondPane?.view = view.leavingSearchResults()
        }
        return kept
    }

    /// What the tab bar calls the tab; with two panes, its label names both (`twoPaneLabel`).
    var tabDescription: TabDescription {
        guard let session = searchStore?.session else {
            return ExplorerTabs.describe(
                currentPath: shownFolderPath, searchVisible: false, searchQuery: "", searchRootPath: "",
                searchRunning: false, homePath: trashHomePath, startupDiskName: services.startupDisk.name)
        }
        return ExplorerTabs.describe(
            currentPath: shownFolderPath, searchVisible: session.resultsVisible, searchQuery: session.committedQuery,
            searchRootPath: session.rootPath, searchRunning: session.isRunning, homePath: trashHomePath,
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
        panes[0].takePlace(
            path: snapshot.currentPath, historyPaths: snapshot.historyPaths, historyIndex: snapshot.historyIndex)
        if panes.count > 1, let second = snapshot.secondPane {
            panes[1].takePlace(
                path: second.pane.path ?? "", historyPaths: second.historyPaths, historyIndex: second.historyIndex)
        }
        let favoritePrefix = "favorite:"
        let favorite = snapshot.selectedTreeItemID.flatMap {
            $0.hasPrefix(favoritePrefix) ? String($0.dropFirst(favoritePrefix.count)) : nil
        }
        // The tree follows the active pane, which may be the second.
        sidebar.restore(
            rootPath: snapshot.treeRootPath, folder: activePane.shownFolderPath, favoritePath: favorite,
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
    /// folders this tab's panes were still being decided on were only passed through; each pane here has a tracker of
    /// its own.
    func wentToTheBack(for other: MainWindowController) {
        for pane in panes { pane.visitTracker.showing(other.shownFolderPath) }
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
        let name = ExplorerTabs.folderDisplayName(
            shownFolderPath, homePath: trashHomePath, startupDiskName: services.startupDisk.name)
        window?.title = name.isEmpty ? "File Trail" : name
        window?.representedURL = folderLetGo ? nil : DiskPath(folderPath).url(isDirectory: true)
    }

    /// The startup disk was renamed: the window title, the toolbar's title, the path bar, the sidebar and the Info panel
    /// say its new name. The tab bar follows with the window's titles (`ExplorerTabGroup.startupDiskNameChanged`). A
    /// tab waiting unread reads nothing for it: its Info panel asks for its item once the tab is first shown.
    func startupDiskNameChanged() {
        updateTitle()
        explorerToolbar.reload()
        for pane in panes { pane.content.contentShell.pathBarRow.namesChanged() }
        sidebar.model.namesChanged()
        if loaded { infoController?.namesChanged() }
    }

    // MARK: Navigation

    /// Opens the folder at `path` in the active pane (`BrowserPane.go`).
    func go(to path: String, history: HistoryMove = .push, open: SidebarOpen = .other, keepingSearch: Bool = false) {
        activePane.go(to: path, history: history, open: open, keepingSearch: keepingSearch)
    }

    /// Reads the folder at `path` in the active pane, then shows it (`BrowserPane.navigate`).
    @discardableResult
    func navigate(
        to path: String, history move: HistoryMove = .push, open: SidebarOpen = .other, keepingSearch: Bool = false,
        goToFailure: ((String) -> Void)? = nil
    ) async -> Bool {
        await activePane.navigate(
            to: path, history: move, open: open, keepingSearch: keepingSearch, goToFailure: goToFailure)
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

    /// What the plan of the items to open needs of the entries on screen.
    private func commandEntries(_ entries: [DirectoryEntry]) -> [CommandEntry] {
        entries.map { CommandEntry(path: $0.path, kind: FTFoundation.EntryKind(rawValue: $0.kind.rawValue) ?? .other) }
    }

    /// Double-click, Return (set to Open) and ⌘↓: opens the items, archives extracted. ⌘-double-click on a folder
    /// opens it in a new tab, as in Finder.
    func open(_ entries: [DirectoryEntry], inNewTab: Bool = false) {
        if inNewTab, entries.count == 1, entries[0].isDirectoryLike {
            openFolderInNewTab(entries[0])
            return
        }
        perform(OpenItems.openPlan(commandEntries(entries), limit: preferences.openItemLimit))
    }

    /// A selected folder opens in a new tab or window; a symbolic link to a folder opens the folder it points to, as it
    /// does when opened in place.
    private func openSelectedFolder(_ folder: String, place: SelectedFolderPlace) {
        let open: (String) -> Void = { [weak self] path in
            guard let self else { return }
            switch place {
            case .tab: self.group?.openTab(path: path, from: self)
            case .window: self.group?.openNewWindow(from: self, path: path)
            case .otherPane: self.openSecondPane(at: path)
            }
        }
        let asked = DiskPath(folder)
        guard content.entries.first(where: { DiskPath($0.path) == asked })?.kind == .symlinkDirectory else {
            open(folder)
            return
        }
        Task {
            if let target = await Self.resolved(folder) { open(target) }
        }
    }

    private enum SelectedFolderPlace { case tab, window, otherPane }

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
    /// Looked up as `BlockingWork`: a link into a slow volume must not freeze the window, nor hold up the app's
    /// other work.
    private static func resolved(_ path: String) async -> String? {
        await BlockingWork.run { try? NativeFileSystem().realpath(path) }
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
            // A held key (Return, ⌘↓, ⌘O) opens folders and files again on every repeat, but extracts an archive and
            // mounts a disk image once per press: each repeat would take the archive apart again beside what the
            // first one gave, or open the image's disk in another window or tab.
            // What the press extracted or mounted is selected once it is there, in this tab or a new one: the
            // repeats that follow would open that, so they open nothing until the key is let go.
            let firstPress = !Self.isKeyRepeat(currentEvent())
            if firstPress {
                Self.heldKeyTookApart = false
                Self.openPresses += 1
            } else if Self.heldKeyTookApart {
                return
            }
            let press = Self.openPresses
            func takesApart(_ path: String) -> Bool {
                ArchiveNames.isArchive(NodePath.basename(path)) || DiskImageNames.isDiskImagePath(path)
            }
            func opensOnThisPress(_ path: String) -> Bool {
                if firstPress, takesApart(path) { Self.heldKeyTookApart = true }
                return firstPress || !takesApart(path)
            }
            for step in steps {
                switch step {
                case .navigate(let path):
                    go(to: path)
                case .resolveThenNavigate(let path):
                    // Another tab may have come to the front while the link was looked up.
                    let pane = activePane
                    let token = pane.navigationCount
                    Task {
                        guard let target = await Self.resolved(path), token == pane.navigationCount, isKeyOrOnly else {
                            return
                        }
                        pane.go(to: target)
                    }
                case .resolveThenOpen(let path):
                    Task {
                        guard let target = await Self.resolved(path) else { return }
                        // A link to an archive, itself named as one: what it holds comes out beside the link,
                        // where it was opened, not beside the archive it leads to.
                        if ArchiveNames.isArchive(NodePath.basename(target)),
                            ArchiveNames.isArchive(NodePath.basename(path)), !DiskImageNames.isDiskImagePath(target)
                        {
                            if firstPress {
                                // Unless another press came while the link was looked up.
                                if press == Self.openPresses { Self.heldKeyTookApart = true }
                                extractToOpen([path])
                            }
                        } else if opensOnThisPress(target) {
                            openExternally(target)
                        }
                    }
                case .openExternally(let path):
                    if opensOnThisPress(path) { openExternally(path) }
                case .handToSystem(let path):
                    onFolderUsed?()
                    openFile(DiskPath(path).fileURL())
                case .extract(let paths):
                    if firstPress {
                        Self.heldKeyTookApart = true
                        extractToOpen(paths)
                    }
                }
            }
        }
    }

    /// The key now held down (Return, ⌘↓, ⌘O) extracted an archive or mounted a disk image when it was pressed. It is
    /// so until a key is let go, or the next press of a key that opens.
    static var heldKeyTookApart = false {
        didSet {
            guard heldKeyTookApart, keyUpMonitor == nil else { return }
            keyUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { event in
                heldKeyTookApart = false
                return event
            }
        }
    }
    private static var keyUpMonitor: Any?
    /// The presses that opened something, counted: a lookup that ends after another press is not that press's.
    private static var openPresses = 0

    /// A file or app opens in what macOS chooses; a disk image is mounted here and an archive extracted here, rather
    /// than by Archive Utility (Open With still hands it to an app). Either counts as using the folder.
    func openExternally(_ path: String) {
        if noteUseAndOpenDiskImage(path) { return }
        if ArchiveNames.isArchive(NodePath.basename(path)) {
            extractToOpen([path])
            return
        }
        openFile(DiskPath(path).fileURL())
    }

    /// Opening archives: they are extracted, each next to itself, as File ▸ Extract does.
    func extractToOpen(_ paths: [String]) {
        guard !paths.isEmpty, let actions = writeActions else { return }
        onFolderUsed?()
        Task { _ = await actions.extract(paths) }
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

    /// Opens the command palette, or closes it: the app's menu sets it, for a key of the palette's that reaches the
    /// window and not the menu.
    static var showCommandPalette: (@MainActor () -> Void)?
    /// The Templates folder File ▸ New File makes files from (`AppStatePaths.templates`); the app sets it.
    static var templatesFolderPath: String?
    /// Told once Open Templates Folder has made sure the folder is there, so it can be watched.
    static var templatesFolderOpened: (@MainActor () -> Void)?

    /// A command the list's keys ask for: the key is one the menu does not listen for (a command's second key, Space,
    /// F2, ⌘←). Whether the window ran it. Keys don't go by what dims the menu (only `ShortcutPolicy.canHandle` is
    /// asked): a command that can't start says why itself.
    /// `isRepeat`: the key is held down. A workspace opens once per press, not a window for every repeat.
    private func runKeyCommand(_ id: ShortcutCommandID, isRepeat: Bool) -> Bool {
        if id == .openSelectedItem { return openSelectedItem() }
        if id == .showCommandPalette {
            guard let show = Self.showCommandPalette else { return false }
            if !isRepeat { show() }
            return true
        }
        if let slot = Workspaces.slot(of: id) {
            if !isRepeat { group?.openWorkspace(slot: slot) }
            return true
        }
        if let slot = Workspaces.inThisWindowSlot(of: id) {
            if !isRepeat { group?.openWorkspace(slot: slot, inPlaceOf: self) }
            return true
        }
        guard let command = AppCommand(rawValue: id.rawValue), ShortcutPolicy.canHandle(command, shortcutContext)
        else { return false }
        perform(command)
        return true
    }

    /// A command of the window's keys run from the command palette, which no menu item has: Open Selected Item and
    /// the page moves, in the pane that has the keyboard. Whether it did anything.
    @discardableResult
    func runPaletteKeyCommand(_ id: ShortcutCommandID) -> Bool {
        let page: (forward: Bool, half: Bool)? =
            switch id {
            case .pageUp: (false, false)
            case .pageDown: (true, false)
            case .halfPageUp: (false, true)
            case .halfPageDown: (true, true)
            default: nil
            }
        guard let page else { return runKeyCommand(id, isRepeat: false) }
        guard ShortcutPolicy.canHandleExplorerKeyboardShortcuts(shortcutContext) else { return false }
        switch focusedPane {
        case .tree: return sidebar.movePage(forward: page.forward, size: page.half ? .half : .full)
        case .content:
            let keyboard = (content.pane as? ListViewController)?.keyboard ?? (content.pane as? ItemGridPane)?.keyboard
            return keyboard?.movePage(forward: page.forward, size: page.half ? .half : .full) ?? false
        case nil: return false
        }
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
        if WriteStartingShortcuts.runs(command.rawValue, isRepeat: event.isARepeat) {
            _ = runKeyCommand(command, isRepeat: event.isARepeat)
        }
        return true
    }

    /// Whether `event` is a key held down, repeating. Only a key press can say.
    static func isKeyRepeat(_ event: NSEvent?) -> Bool {
        guard let event, event.type == .keyDown else { return false }
        return event.isARepeat
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

    /// A name typed into a row of `pane`: the pane that had the field takes the outcome, whichever pane is active by
    /// the time the name has been checked (a click on the other pane ends the field too).
    private func submitRename(in pane: BrowserPane, path: String, typed: String) {
        guard renameTask == nil else { return }
        let content = pane.content
        let hiddenFilesShown = pane.includeHidden
        renameTask = Task { [weak self] in
            guard let self else { return }
            defer { self.renameTask = nil }
            let outcome: RenameOutcome =
                if let renameItem = self.renameItem {
                    await renameItem(path, typed)
                } else if let actions = self.writeActions {
                    // The write coordinator renames it (WriteOperations/).
                    await actions.commitRename(path: path, typed: typed, hiddenFilesShown: hiddenFilesShown)
                } else {
                    // A tab has the file operations once the app has started them.
                    .unchanged
                }
            guard content.inlineRename?.key == DiskPath(path) else {
                // The folder was left while the name was checked (a click on another folder ends the field and opens
                // that folder): with no field to show it under, the refusal gets a dialog of its own.
                if case .refused(let message) = outcome, !content.listed.contains(where: { $0.path == path }) {
                    let name = NodePath.basename(path)
                    self.renameNotice(title: "\u{201C}\(name)\u{201D} couldn\u{2019}t be renamed", message: message)
                }
                return
            }
            switch outcome {
            case .unchanged, .started:
                content.endRename()
            case .refused(let message):
                content.refuseRename(message)
            }
        }
    }

    /// ⌘F, and Search Subfolders on the empty filter: the search field takes the keyboard.
    func focusFileSearch() {
        search.focusField()
    }

    /// The folder Open in New Tab and Open in New Window open: the one folder selected, or with the sidebar focused its
    /// selected folder.
    var selectedFolder: String? {
        if focusedPane == .tree { return sidebar.selectedTreeTargetPath }
        return selectedContentFolder
    }

    // MARK: The content pane

    /// Connects the content pane to the window: what it reads from the services, and what it reports.
    func wireContent(_ pane: BrowserPane) {
        let content = pane.content
        content.loaders = ContentLoaders(
            metadata: { [weak self] folder, paths, listedAdded in
                guard let service = self?.services.directoryService else { return [] }
                let batch = try? await service.metadata(
                    directoryPath: folder, paths: paths, listedAdded: listedAdded)
                return batch?.items ?? []
            },
            hiddenCount: { [weak self] folder in
                guard let service = self?.services.directoryService else { return 0 }
                return (try? await service.snapshot(path: folder, includeHidden: true).entries.count) ?? 0
            },
            iconStore: { [weak self] in self?.services.iconStore },
            homePath: DiskPath.home.string,
            openPrivacySettings: {
                Task { _ = await SystemActions.openFullDiskAccessSettings() }
            })
        content.loaders.values = { [weak self] paths, field in
            guard let service = self?.services.directoryService else { return paths.map { _ in .number(nil) } }
            return await service.values(of: paths, field: field)
        }
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
            self?.paneChanged(.selection, in: pane)
        }
        content.shortcutsProvider = { [weak self] in
            ShortcutCommands.resolve(self?.preferences.shortcutOverrides ?? [:])
        }
        // The list that has the keyboard is the one acted on: after a right-click in the other pane, which gives it
        // the keyboard without making it the active one, Return opens or renames what is selected there.
        content.onReturn = { [weak self, weak pane] in
            guard let self, let pane else { return }
            self.activate(pane)
            self.pressedReturn()
        }
        // Tab walks the tree and the panes in the order they are on screen; with the tree hidden it stays among the
        // panes, and with one pane in the list.
        content.onSwitchPane = { [weak self, weak pane] in
            guard let self, let pane else { return }
            self.tabKeyPressed(from: pane)
        }
        content.onCommand = { [weak self] id in
            self?.runKeyCommand(id, isRepeat: Self.isKeyRepeat(NSApp.currentEvent)) ?? false
        }
        content.onRenameSubmit = { [weak self, weak pane] path, name in
            guard let self, let pane else { return }
            self.submitRename(in: pane, path: path, typed: name)
        }
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
        // Pin Filter follows the filter typed, cleared or pinned.
        content.onFilterStateChanged = { [weak self] in self?.notify(.commands) }
        // The chip switches the view on screen and its filter, and makes its mode the one new views start with.
        content.onToggleFilterMode = { [weak self, weak pane] in
            guard let self, let pane else { return }
            let mode = pane.content.toggleFilterMode()
            pane.searchStore?.header.showFilterMode(pane.content.filterMode)
            self.updatePreferences { $0.listFilterMatch = mode }
            // The pane's mode is saved with it.
            self.group?.tabChanged(self)
        }
        content.onColumnWidthsChanged = { [weak self, weak pane] widths in
            guard let pane else { return }
            self?.saveColumnWidths(widths, in: pane)
        }
        // A size set here is this pane's own, and the app's from now on: what a pane with none of its own starts
        // from. The other panes keep theirs.
        // In a folder whose view keeps the size, a size set is a change of that view, unsaved until Update.
        content.onCompactListWidthChanged = { [weak self, weak pane] density, width in
            guard let pane else { return }
            if pane.folderViewKeeps(.size) {
                pane.changeShownFolderView { $0.size?.compactListWidths[density] = width }
                return
            }
            pane.setViewSize { $0.compactListWidths[density] = width }
            pane.changeSharedSettings { $0.compactListWidths[density] = width }
            if let self { self.group?.tabChanged(self) }
        }
        content.onIconSizeChanged = { [weak self, weak pane] density, size in
            guard let pane else { return }
            if pane.folderViewKeeps(.size) {
                pane.changeShownFolderView { $0.size?.iconSizes[density] = size }
                return
            }
            pane.setViewSize { $0.iconSizes[density] = size }
            pane.changeSharedSettings { $0.iconSizes[density] = size }
            if let self { self.group?.tabChanged(self) }
        }
        content.onPreviewCountChanged = { [weak self, weak pane] density, count in
            guard let pane else { return }
            if pane.folderViewKeeps(.size) {
                pane.changeShownFolderView { $0.size?.previewCounts[density] = count }
                return
            }
            pane.setViewSize { $0.previewCounts[density] = count }
            pane.changeSharedSettings { $0.previewCounts[density] = count }
            if let self { self.group?.tabChanged(self) }
        }
        content.onHeaderMenu = { [weak self, weak pane] column in
            guard let self, let pane else { return nil }
            return self.headerMenu(for: column, in: pane)
        }
        content.onColumnMoved = { [weak self, weak pane] column, before in
            guard let self, let pane else { return }
            self.dropColumn(column, before: before, in: pane)
        }
        content.contentShell.pathBarRow.onFolderViewClick = { [weak self, weak pane] anchor in
            guard let self, let pane else { return }
            self.activate(pane)
            self.showFolderViewPopover(for: pane, from: anchor)
        }
        content.setView(
            sortBy: pane.shownSortBy, direction: pane.shownSortDirection, foldersFirst: pane.shownFoldersFirst,
            includeHidden: pane.includeHidden)
        content.setViewFilterMode(pane.startFilterMode ?? preferences.listFilterMatch)
        content.sizeShortcuts = sizeShortcuts
        content.setColumns(pane.columns(from: preferences))
        content.setMode(pane.shownMode)
    }

    /// The List's widths, as a drag, a step or a double-click left them in `pane`: that pane's own, as its other sizes
    /// are, and the app's from now on (what a pane with none of its own starts from). The other panes keep theirs.
    private func saveColumnWidths(_ widths: [DetailColumn: Double], in pane: BrowserPane) {
        let searching = pane.searchStore?.showsResults == true
        // As the column's width is drawn, then kept as a whole number the way the saved state keeps it.
        func width(_ column: DetailColumn) -> Double {
            DetailsColumns.clamp(widths[column] ?? 0, column: column, search: searching)
        }
        if searching {
            // Search results keep widths of their own (`searchColumnWidths`), Folder among them.
            var kept = SearchColumnWidths.defaults
            for key in SearchColumnKey.allCases {
                let column = DetailColumn(rawValue: key.rawValue) ?? .name
                kept[key] = AppPreferenceLimits.clampSearchColumnWidth(key, width(column))
            }
            pane.setViewSize { $0.searchColumnWidths = kept }
            updatePreferences { $0.searchColumnWidths = kept }
        } else {
            var kept = DetailColumnWidths.defaults
            for key in DetailColumnKey.allCases {
                let column = DetailColumn(rawValue: key.rawValue) ?? .name
                kept[key] = AppPreferenceLimits.clampDetailColumnWidth(key, width(column))
            }
            // A folder's view that keeps its columns keeps their widths: a change of the view, unsaved until Update.
            if pane.folderViewKeeps(.columns) {
                pane.changeShownFolderView { $0.columns?.widths = kept }
                return
            }
            pane.setViewSize { $0.detailColumnWidths = kept }
            pane.changeSharedSettings { $0.detailColumnWidths = kept }
        }
        // Saved with the pane. A drag calls this at each step, so the folders watched aren't gone over again.
        group?.saveSession()
    }

    /// The columns and the density again, from the preferences (Settings changed them, or a scenario did).
    /// The keys of the size commands, which the status bar's slider names.
    var sizeShortcuts: ShortcutDisplay {
        ShortcutDisplay(shortcuts: ShortcutCommands.resolve(preferences.shortcutOverrides))
    }

    func refreshColumns() {
        for pane in panes { pane.refreshColumns() }
    }

    /// `pane`'s search changed how it stands: the tab's label and magnifier, and the commands.
    func searchStateChanged(in pane: BrowserPane) {
        group?.refreshTitles()
        updateSearchTabAccessory()
        paneChanged(.search, in: pane)
    }

    /// A tab with search results in a pane, active or not, shows a magnifier before its label, in the accent while
    /// one of them searches.
    func updateSearchTabAccessory() {
        guard let window else { return }
        let searches = panes.compactMap { $0.searchStore?.session }.filter(\.isSearchMode)
        guard !searches.isEmpty else {
            if window.tab.accessoryView != nil { window.tab.accessoryView = nil }
            return
        }
        let view = (window.tab.accessoryView as? SearchTabMagnifier) ?? SearchTabMagnifier()
        view.searching = searches.contains(where: \.isRunning)
        if window.tab.accessoryView !== view { window.tab.accessoryView = view }
    }

    /// Refresh: the caches of the listing are let go of, and the folder is read again with the selection kept.
    func refresh() {
        services.directoryService.cache.clear()
        readAgain()
        // The tree's way to hear of subfolders added or removed outside the app, for the folder watch
        // leaves it alone.
        guard treeFollowsReadingAgain else { return }
        let open = sidebar.model.openReadingAgain(folderPath)
        if open.forceTreeReload { sidebar.folderOpened(folderPath, open) }
    }

    /// The folder on screen read again brings the tree along; a folder being opened now will do that itself.
    var treeFollowsReadingAgain: Bool { activePane.treeFollowsReadingAgain }

    /// The folder selected in the file list, if it is the one item selected and a folder: its row's path.
    private var selectedContentFolder: String? {
        let items = content.selectedEntries
        guard items.count == 1, items[0].isDirectoryLike else { return nil }
        return items[0].path
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
        explorerToolbar.searchField.showOptionsMark()
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
        sidebar.openInOtherPane = { [weak self] path in self?.openSecondPane(at: path) }
        sidebar.stateChanged = { [weak self] in
            guard let self else { return }
            self.group?.tabChanged(self)
        }
        sidebar.selectionChanged = { [weak self] in
            self?.noteFocusedPane()
            self?.notify(.selection)
            self?.notify(.focusedPane)
        }
        sidebar.model.openFolder = { [weak self] path, open in
            guard let self else { return }
            // By `==`, which takes an accent encoded either way for the same: a favorite kept from an earlier launch
            // may spell the folder on screen the other way.
            let replaces = open.replacesFolderOnScreen && path == self.shownFolderPath
            self.go(to: path, history: replaces ? .replace : .push, open: open)
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
            viewMode: shownViewMode, previewCount: content.previewCount, sortBy: activePane.shownSortBy,
            groupBy: activePane.activeGroupBy, groupReversed: activePane.activeGroupReversed,
            foldersFirst: activePane.shownFoldersFirst,
            hiddenFilesShown: includeHidden,
            folderTreeOpen: panels?.folderTreeOpen ?? true, infoPanelOpen: panels?.propertiesOpen ?? false,
            infoRowOpen: panels?.detailRowOpen ?? false, twoPanesShown: showsTwoPanes,
            filterPinned: content.pinnedFilter != nil,
            favoriteIsSet: favoriteTargetPath.map { sidebar.isFavorite($0) } ?? false,
            textEditing: isTextFieldEditing,
            pasteAsFileKind: context.systemClipboard?.kind,
            copyContentsGuess: context.selectedPathsInViewOrder.count == 1
                ? context.selectedPathsInViewOrder.first.map { CopyContents.guess(forName: NodePath.basename($0)) }
                : nil,
            compressTitle: ArchiveNames.compressTitle(
                count: context.selectedPathsInViewOrder.count,
                firstName: context.selectedPathsInViewOrder.first.map(NodePath.basename)),
            convertImagesCount: context.selectedPathsInViewOrder.count,
            folderViewRemembered: activePane.shownFolderView?.isOwnSaved == true,
            shownColumns: shownColumns,
            clipboardCutCount: services.clipboard.contents.cutPaths.count,
            clipboardCopiedCount: services.clipboard.contents.copiedPaths.count
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
    /// Reads whether the Trash has anything in it; tests use their own. The home folder is given as the system spells
    /// it, which is what the Trash's folders are worked out from (`TrashFolders`).
    var trashIsEmptyReader: @Sendable () -> Bool? = {
        TrashState.isEmpty(home: NSHomeDirectory(), uid: getuid())
    }

    /// Counts the reads asked for, so an older one that answers late does not replace a newer answer.
    private var trashReads = 0

    func refreshTrashState() {
        let read = trashIsEmptyReader
        trashReads += 1
        let asked = trashReads
        Task { [weak self] in
            let empty = await BlockingWork.run(qos: .utility) { read() }
            guard let self, asked == self.trashReads, self.trashIsEmpty != empty else { return }
            self.trashIsEmpty = empty
            self.commandsChanged()
        }
    }

    /// The home folder whose Trash gets the bar and is called "Trash" in the titles; tests use their own.
    var trashHomePath = DiskPath.home.string

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
        go(to: target, history: .back)
    }

    @objc func goForward(_ sender: Any?) {
        guard let target = navigationHistory.forwardTarget else { return }
        go(to: target, history: .forward)
    }

    @objc func goToEnclosingFolder(_ sender: Any?) {
        guard !folderLetGo, folderPath != "/" else { return }
        go(to: DiskPath(folderPath).parent.string)
    }

    /// The toolbar's Enclosing Folder: it doesn't look at which pane has the keyboard, and
    /// with no folder on screen it opens the top of the disk (`parentDirectoryPath("")`).
    func goToParentFolder() {
        guard !isCustomizingToolbar, !isDialogOpen, let parent = ExplorerTabs.parentDirectoryPath(shownFolderPath)
        else {
            return
        }
        go(to: parent)
    }

    /// File ▸ Open, ⌘O and the toolbar's Open (`openPaths`): opens the items.
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
        for pane in panes { pane.visitTracker.dispose() }
        // An open clipboard or Undo History list goes with the tab, and so does what it listens to; Folder
        // Customization too, which would otherwise stay up with nothing left to customize.
        closeFolderViewPopover()
        clipboardUI.close()
        undoHistoryUI.close()
        activityUI.close()
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
            // Behind this one now: its automatic folder size goes.
            other.infoController?.update()
        }
        for pane in panes { pane.searchStore?.session.returnToForeground() }
        infoController?.update()
        group?.tabBecameKey(self)
        // Its folder sizes go first, and its automatic one no longer gives way.
        FolderSizeService.shared.jobs.frontOwner = windowID
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
        infoController?.update()
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        group?.tabVisibilityChanged(self)
        infoController?.update()
    }

    // MARK: Observers

    func notify(_ change: ExplorerWindowChange) {
        // The tree marks the folders of both panes while there are two.
        let folderChanged = change == .folder || change == .otherPane(.folder)
        if folderChanged || change == .panels {
            sidebar.paneFolders = showsTwoPanes ? panes.map(\.shownFolderPath) : []
        }
        // Each pane shows the Trash's bar on its own folder, not on its search results.
        let searchChanged = change == .search || change == .otherPane(.search)
        if folderChanged || searchChanged || change == .commands { refreshTrashHeader() }
        // The Trash on screen changed, or came to the screen: what it holds may not be what was last read.
        if folderChanged, panes.contains(where: { $0.content.contentShell.trashHeader != nil }) {
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

    /// A preference changed in any window or in Settings. Only what reads a key that changed is done again
    /// (`PreferenceAreas`): the tree is not built again for a column's width, in this tab or in any other.
    func preferencesChanged(_ change: PreferencesChange) {
        let areas = PreferenceAreas.touched(by: change, inWindow: windowID)
        if areas.contains(.columns) {
            for pane in panes { pane.sharedSettingsChanged() }
        }
        if areas.contains(.sidebar) { sidebar.applyPreferences() }
        if areas.contains(.columns) { refreshColumns() }
        if areas.contains(.notifications) { notificationsSettingChanged() }
        if areas.contains(.clipboardMarks) { clipboardMarksChanged() }
        if areas.contains(.commands) { notify(.preferences) }
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
        case .viewAsPreviews: setMode(.previews)
        case .showPreviews9, .showPreviews4, .showPreviews2, .showPreviews1:
            guard let count = PreviewGrid.count(of: command) else { return }
            content.showPreviews(count: count)
            if shownViewMode != .previews { setMode(.previews) }
            content.flashViewSize()
        case .increaseSize, .decreaseSize, .resetSize:
            if let change = ViewSize.Change(command) { content.stepViewSize(change) }
        // Search results have groups of their own (`searchGroupBy`); the pane sees to which.
        case .groupByNone, .groupByName, .groupByModified, .groupByCreated, .groupByLastOpened, .groupByAdded,
            .groupBySize, .groupByKind, .groupByTags, .groupByFolder:
            if let field = GroupByPreference(command: command) { activePane.setGroupBy(field) }
        case .reverseGroupOrder:
            activePane.toggleGroupReversed()
        // Search results have an order of their own, chosen in the List view's headers.
        case .sortByName, .sortByKind, .sortByModified, .sortByCreated, .sortByAdded, .sortByLastOpened, .sortBySize,
            .toggleFoldersFirst:
            guard searchRootPath == nil else { return }
            switch command {
            case .sortByName: sort(by: .name)
            case .sortByKind: sort(by: .kind)
            case .sortByModified: sort(by: .modified)
            case .sortByCreated: sort(by: .created)
            case .sortByAdded: sort(by: .added)
            case .sortByLastOpened: sort(by: .lastOpened)
            case .sortBySize: sort(by: .size)
            default:
                activePane.toggleFoldersFirst()
            }
        case .togglePinFilter:
            content.togglePin()
        // Search results have columns of their own, chosen on their header: a folder's aren't changed from there.
        case .showModifiedColumn, .showSizeColumn, .showKindColumn, .showCreatedColumn, .showAddedColumn,
            .showLastOpenedColumn, .showPermissionsColumn:
            guard searchRootPath == nil else { return }
            if let key = OptionalDetailColumnKey(columnCommand: command) { toggleColumn(key, in: activePane) }
        case .rememberFolderView, .updateFolderView, .revertFolderView, .folderViewOptions, .resetFolderView,
            .manageFolderViews:
            performFolderViewCommand(command)
        case .toggleHiddenFiles:
            includeHidden.toggle()
            sidebar.hiddenFilesChanged(includeHidden)
            // Each pane reads its folder again, or searches again, and keeps what is selected in it and where it
            // is scrolled; the other pane leaves the tree to the active one.
            let keepingTree = !sidebar.model.rootPath.isEmpty
            for pane in panes {
                pane.viewChanged(keepingTree: pane !== activePane || keepingTree, keepingSelection: true)
                pane.searchStore?.session.hiddenFilesChanged(includeHidden)
            }
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
            let home = DiskPath.home.string
            if let place = GoMenuPlaceCommand(rawValue: command.rawValue)?.place(homePath: home) {
                if place.asLocation {
                    sidebar.openLocation(place.path)
                } else {
                    go(to: place.path)
                }
            }
        case .goHomeRootTree: sidebar.rootTree(at: DiskPath.home.string)
        case .rootTreeAtSelection:
            if let target = sidebar.rootTreeTarget(
                focusedPane: focusedPane, lastFocusedPane: lastFocusedPane,
                selectedContentFolder: selectedContentFolder, currentPath: shownFolderPath)
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
        case .closePane: closePane()
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
        case .saveWorkspace: group?.saveWorkspace(from: self)
        case .toggleTwoPanes: toggleTwoPanes()
        case .duplicatePane: duplicatePane()
        case .switchToOtherPane: switchToOtherPane()
        case .openSelectionInOtherPane:
            if let target = selectedFolder { openSelectedFolder(target, place: .otherPane) }
        case .copyToOtherPane: sendSelectionToOtherPane(copying: true)
        case .moveToOtherPane: sendSelectionToOtherPane(copying: false)
        case .swapPanes: swapPanes()
        case .showFolderInOtherPane: openSecondPane(at: shownFolderPath)
        case .goToOtherPaneFolder:
            if let other = otherPane, !other.shownFolderPath.isEmpty { go(to: other.shownFolderPath) }
        case .equalizePanes: equalizePanes()
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
        case .openTemplatesFolder: openTemplatesFolder()
        case .deselectAll: content.deselectAllEntries()
        case .invertSelection: content.invertSelection()
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
        case .copyContents:
            if selectedPaths.count == 1, let path = selectedPaths.first {
                // The tab is held until the copy ends: what the copier asks of it (its window, its toasts) must
                // still be there when a slow read comes back after the tab was closed.
                Task { [self] in
                    await contentsCopier.copy(path)
                    withExtendedLifetime(self) {}
                }
            }
        case .convertImages:
            openConvertImagesSheet(selectedPaths)
        case .shareSelection:
            shareSelection()
        case .undo, .redo, .editCut, .editCopy, .editPaste, .moveSelection, .duplicateSelection, .newFolder,
            .newFolderWithSelection, .newTextFile, .saveAsTemplate, .pasteAsFile, .trashSelection, .emptyTrash,
            .copySelection,
            .cutSelection,
            .pasteSelection, .addToCopied, .addToCut, .moveItemsHere, .removeFromClipboard,
            .compressSelection, .extractSelection, .extractSelectionTo:
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
        showInfoRow(animated: workspace.isReady)
        if !workspace.isReady { workspace.becomeReady() }
        notify(.panels)
    }
}

extension MainWindowController: ExplorerWindowContext {
    var shownFolderPath: String { activePane.shownFolderPath }

    func navigate(to path: String, target: NavigationTarget) {
        switch target {
        case .push: go(to: path)
        case .newTab: group?.openTab(path: path, from: self)
        case .newWindow: group?.openNewWindow(from: self, path: path)
        }
    }

    var historyPaths: [String] { navigationHistory.paths }
    var historyIndex: Int { max(0, navigationHistory.index) }
    var canGoBack: Bool { navigationHistory.canGoBack }
    var canGoForward: Bool { navigationHistory.canGoForward }

    func goToHistoryIndex(_ index: Int) {
        let paths = historyPaths
        guard paths.indices.contains(index), index != historyIndex else { return }
        go(to: paths[index], history: .jump(index: index))
    }

    func canPerform(_ command: AppCommand) -> Bool {
        CommandAvailability.canRun(command, commandContext)
    }

    /// Whether `command` could run were no file operation running. A write command reached by the key of its
    /// dimmed item asks this of what is selected before it starts, and leaves the busy notice to its own start.
    func selectionAllows(_ command: AppCommand) -> Bool {
        var context = commandContext
        context.writeOperationLocked = false
        return CommandAvailability.canRun(command, context)
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
            copyPasteModalOpen: isBatchRenameOpen || isConvertImagesOpen || CopyPasteDialogs.isOpen(in: window)
                || content.inlineRename != nil,
            focusedPane: commandPane,
            // Customizing the toolbar is a sheet over the window: the commands wait for it to end.
            locationSheetOpen: isCustomizingToolbar || goToBox != nil,
            selectedTreeTargetKind: sidebar.selectedTreeTargetKind)
    }

    /// Everything the command rules read: the one state of the menu bar, the toolbar
    /// and the keys.
    private var commandContext: CommandAvailabilityContext {
        let home = DiskPath.home.string
        let entries = commandEntries
        let lead = content.selection.leadPath.map(DiskPath.init)
        var context = CommandAvailabilityContext(
            shortcutContext: shortcutContext,
            currentPath: shownFolderPath, selectedPathsInViewOrder: selectedPaths, activeContentEntries: entries,
            listShowsItems: !content.entryPaths.isEmpty,
            selectedEntry: entries.first { DiskPath($0.path) == lead } ?? entries.first,
            selectedTreeTargetPath: sidebar.selectedTreeTargetPath,
            clipboardHasItems: services.clipboard.contents.hasItems,
            selectionOnClipboard: services.clipboard.contents.holdsAny(of: clipboardSourcePaths),
            pasteDestinationPath: pasteDestinationPath,
            isSearchMode: searchRootPath != nil, openItemLimit: preferences.openItemLimit,
            writeOperationLocked: isWriteLocked, canGoBack: canGoBack,
            canGoForward: canGoForward, hasCachedSearch: searchStore?.session.hasCachedSearch ?? false,
            tabCount: group?.tabs.count ?? 1, paneCount: panes.count,
            otherPanePath: otherPane.map { otherPaneDestination($0) ?? "" },
            otherPaneFolder: otherPane.map(\.shownFolderPath),
            trashPath: FavoriteLabel.trashPath(homePath: home), homePath: home,
            trashIsEmpty: trashIsEmpty, ejectTargetPath: ejectTargetPath,
            trashIsFavorite: sidebar.isFavorite(FavoriteLabel.trashPath(homePath: home)),
            viewSizeSteps: content.viewSize?.steps ?? .unavailable, filterPinnable: content.canTogglePin,
            // While a text field has the keyboard, what is on the clipboard is for it.
            systemClipboard: isTextFieldEditing ? nil : systemClipboard.choice,
            folderView: FolderViewCommandState(
                own: activePane.shownFolderView?.isOwnSaved == true,
                unsaved: activePane.shownFolderView?.hasUnsavedChanges == true))
        context.listIsGrouped = activePane.activeGroupBy != .none
        return context
    }

    /// The folders File > Calculate Size measures now.
    var calculateSizePaths: [String] { CommandAvailability.calculateSizePaths(commandTargets) }

    /// What the commands' target rules read.
    private var commandTargets: CommandAvailability.TargetContext {
        let trashPath = FavoriteLabel.trashPath(homePath: DiskPath.home.string)
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
