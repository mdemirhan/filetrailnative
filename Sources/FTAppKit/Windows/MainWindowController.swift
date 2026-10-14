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

    /// What the Window menu calls the window: its tab's label, as the original's window title is. The title itself
    /// stays the folder's name, which the toolbar shows.
    var windowsMenuTitle: String? {
        didSet { syncWindowsMenuItem() }
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

    /// The app's own menus, tooltips and the toolbar's customizing see the window's events first, whether they come
    /// from the system or are sent to the window directly.
    override func sendEvent(_ event: NSEvent) {
        if WindowEventRouting.intercept(event, in: self) { return }
        if forwardToolbarBand(event) { return }
        super.sendEvent(event)
    }

    /// The view a press in the toolbar band went to, which gets the drags and the release that follow.
    private var bandTarget: NSView?

    /// A press in the toolbar band goes straight to the app's view under it: the title bar's container covers the
    /// band's top, and AppKit would otherwise take a press there as one on the title bar (in a window in the back,
    /// for one). The traffic lights and the system tab bar keep theirs.
    private func forwardToolbarBand(_ event: NSEvent) -> Bool {
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            guard let content = contentView, let frameView = content.superview,
                let hit = frameView.hitTest(frameView.convert(event.locationInWindow, from: nil)),
                hit.isDescendant(of: content)
            else { return false }
            let band = WindowMetrics.standard.toolbar.minHeight
            let top = content.convert(event.locationInWindow, from: nil)
            let fromTop = content.isFlipped ? top.y : content.bounds.height - top.y
            guard fromTop < band else { return false }
            if !isKeyWindow { makeKey() }
            bandTarget = hit
            switch event.type {
            case .leftMouseDown:
                if hit.acceptsFirstResponder { makeFirstResponder(hit) }
                hit.mouseDown(with: event)
            case .rightMouseDown: hit.rightMouseDown(with: event)
            default: hit.otherMouseDown(with: event)
            }
            return true
        case .leftMouseDragged, .rightMouseDragged:
            guard let target = bandTarget else { return false }
            if event.type == .leftMouseDragged {
                target.mouseDragged(with: event)
            } else {
                target.rightMouseDragged(with: event)
            }
            return true
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            guard let target = bandTarget else { return false }
            bandTarget = nil
            switch event.type {
            case .leftMouseUp: target.mouseUp(with: event)
            case .rightMouseUp: target.rightMouseUp(with: event)
            default: target.otherMouseUp(with: event)
            }
            return true
        default:
            return false
        }
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
        case push, back, forward, none
        /// A jump within the history (the Back and Forward hold menus): to `index` of `paths`, adding nothing.
        case jump(paths: [String], index: Int)
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
    private lazy var ejectPresenter = AlertEjectPresenter(window: { [weak self] in self?.window })
    /// The pane that last had the keyboard, for the commands that act on it when none does.
    private var lastFocusedPane: ExplorerPane?
    /// The sidebar, for the parts of the window that put a menu on a row or follow its selection.
    var sidebarController: SidebarViewController { sidebar }
    private let browser = BrowserViewController()
    /// The window's grid: sidebar, content, Info panel and the toolbar.
    let workspace: WorkspaceView
    private let infoPanel = InfoPanelView()
    /// Customize Toolbar, while it is on.
    private(set) var customizer: ToolbarCustomizer?
    /// The folder a search runs from while the tab shows its results (P5-07 starts and ends searches).
    var searchRootPath: String? {
        didSet {
            if searchRootPath != oldValue { notify(.search) }
        }
    }
    /// Services of its own, instead of the app's (a window in a test).
    var servicesOverride: ExplorerServices?
    private var observers: [(token: Weak<ExplorerWindowObservation>, handler: (ExplorerWindowChange) -> Void)] = []
    private var backStack: [URL] = []
    private var forwardStack: [URL] = []
    private var navigationToken = 0
    /// A tab brought back, or merged in, waits unread until it is first shown.
    private(set) var loaded = false
    /// The tab was sent to another folder while in the background (its folder moved, or its disk went): the folder
    /// is read when the tab is next shown.
    private(set) var stale = false

    /// A tab on `tab`'s folder, with `history` (none: just the folder). It reads its folder when it is first shown,
    /// or at once with `loadNow`.
    init(tab: StartupTab, history: (paths: [String], index: Int)? = nil, frame: NSRect? = nil, loadNow: Bool = true) {
        windowID = Self.nextWindowID
        Self.nextWindowID += 1
        folder = URL(fileURLWithPath: tab.path)
        viewMode = tab.viewMode
        searchViewMode = tab.searchViewMode
        sortBy = tab.sortBy
        sortDirection = tab.sortDirection
        includeHidden = tab.includeHidden
        foldersFirst = tab.foldersFirst
        if let history, history.paths.indices.contains(history.index) {
            backStack = history.paths[..<history.index].map { URL(fileURLWithPath: $0) }
            forwardStack = history.paths[(history.index + 1)...].reversed().map { URL(fileURLWithPath: $0) }
        }
        let window = ExplorerTabWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultContentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        WindowChrome.configure(window)
        window.tabbingIdentifier = "FileTrailBrowser"
        window.minSize = Self.minimumSize
        window.isReleasedWhenClosed = false
        let layout = WindowMetrics.standard.explorer
        workspace = WorkspaceView(
            panes: PaneWidths(
                treeWidth: layout.defaultTreeWidth, inspectorWidth: layout.defaultInspectorWidth, layout: layout))
        super.init(window: window)
        window.explorerTab = self
        window.delegate = self

        window.contentView = workspace
        configureSidebar()
        sidebar.restore(
            rootPath: tab.rootPath, folder: tab.path, favoritePath: tab.favoritePath,
            favoritesExpanded: tab.favoritesExpanded, locationsExpanded: tab.locationsExpanded,
            includeHidden: tab.includeHidden)
        workspace.sidebarCell.content = sidebar.view
        workspace.mainCell.content = browser.view
        workspace.inspectorCell.content = infoPanel
        workspace.onWidthsChosen = { [weak self] panes in
            self?.updatePanels {
                $0.treeWidth = Int(panes.preferredTreeWidth)
                $0.inspectorWidth = Int(panes.preferredInspectorWidth)
            }
        }
        workspace.toolbar.onCustomize = { [weak self] in self?.perform(.customizeToolbar) }
        if let frame {
            window.setFrame(frame, display: false)
        } else {
            window.setContentSize(Self.defaultContentSize)
            window.center()
        }

        browser.onOpen = { [weak self] items in self?.open(items) }
        browser.onSortChanged = { [weak self] sort in self?.sortChangedInList(sort) }
        browser.setMode(viewMode == .icons ? .icons : .list)
        browser.setSort(key: Self.sortKey(sortBy), ascending: sortDirection == .asc)
        workspace.toolbar.attach(self)
        connectSearchField()
        #if DEBUG
            AutomationLayoutPrefs.registerOnce()
            AutomationSidebarPrefs.registerOnce()
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
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: The tab

    /// The tab as it is saved between launches (`toOpenTabPreference`).
    var openTab: OpenTabPreference {
        let path = folder.path
        return OpenTabPreference(
            path: path.isEmpty ? nil : path, treeRootPath: treeRootPath.isEmpty ? nil : treeRootPath,
            favoritePath: favoritePath == path ? favoritePath : nil, viewMode: viewMode, searchViewMode: searchViewMode,
            sortBy: sortBy, sortDirection: sortDirection, includeHidden: includeHidden, foldersFirst: foldersFirst,
            favoritesExpanded: favoritesExpanded, locationsExpanded: locationsExpanded)
    }

    /// The tab as a new tab or a reopened one starts from it.
    var startupTab: StartupTab {
        StartupTab(
            path: folder.path, rootPath: treeRootPath, favoritePath: favoritePath, viewMode: viewMode,
            searchViewMode: searchViewMode, sortBy: sortBy, sortDirection: sortDirection,
            includeHidden: includeHidden, foldersFirst: foldersFirst, favoritesExpanded: favoritesExpanded,
            locationsExpanded: locationsExpanded)
    }

    /// What the tab keeps of itself (`captureLiveTab`).
    var snapshot: TabSnapshot {
        let history = backStack + [folder] + forwardStack.reversed()
        return TabSnapshot(
            currentPath: folder.path, historyPaths: history.map(\.path), historyIndex: backStack.count,
            viewMode: viewMode, searchViewMode: searchViewMode, sortBy: sortBy, sortDirection: sortDirection,
            treeRootPath: treeRootPath,
            selectedTreeItemID: favoritePath.map { "favorite:\($0)" } ?? "fs:\(folder.path)",
            includeHidden: includeHidden, foldersFirst: foldersFirst, favoritesExpanded: favoritesExpanded,
            locationsExpanded: locationsExpanded)
    }

    /// What the tab bar calls the tab.
    var tabDescription: TabDescription {
        ExplorerTabs.describe(
            currentPath: folder.path, searchVisible: false, searchQuery: "", searchRootPath: "", searchRunning: false)
    }

    /// Reads the tab's folder the first time it is shown, or again when it was sent elsewhere in the background.
    func ensureLoaded() {
        if loaded {
            if stale {
                stale = false
                go(to: folder, history: .none)
            }
            return
        }
        loaded = true
        Task {
            await navigate(to: folder, history: .none)
            if let ready = onReady {
                onReady = nil
                ready()
            }
        }
    }

    /// `followMovedItems` and `leaveUnmountedDisks` for a tab in the background: it takes the place `snapshot` gives
    /// it (folder, history, tree root) and reads its folder when it is next shown.
    func takePlace(_ snapshot: TabSnapshot) {
        let history = snapshot.historyPaths.map { URL(fileURLWithPath: $0) }
        if history.indices.contains(snapshot.historyIndex) {
            backStack = Array(history[..<snapshot.historyIndex])
            forwardStack = history[(snapshot.historyIndex + 1)...].reversed()
        } else {
            backStack = []
            forwardStack = []
        }
        let moved = folder.path != snapshot.currentPath
        folder = URL(fileURLWithPath: snapshot.currentPath)
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
        let path = folder.path
        let followed = ExplorerTabs.followMovedPath(path, moves)
        guard !path.isEmpty, followed != path else { return }
        let target = URL(fileURLWithPath: followed)
        if loaded {
            go(to: target, history: .none)
        } else {
            folder = target
            updateTitle()
            group?.tabChanged(self)
        }
    }

    /// Reads the folder on screen again: something changed in it.
    func reload() {
        guard loaded else { return }
        go(to: folder, history: .none)
    }

    private func updateTitle() {
        // The window title is the folder name, which the toolbar shows; the tab bar and the Window menu have the
        // tab's label (ExplorerTabGroup.refreshTitles).
        let name = ExplorerTabs.folderDisplayName(folder.path)
        window?.title = name.isEmpty ? "File Trail" : name
        window?.representedURL = folder
    }

    // MARK: Navigation

    func go(to url: URL, history: HistoryMove = .push, open: SidebarOpen = .other) {
        Task { await navigate(to: url, history: history, open: open) }
    }

    /// Reads `url` off the main thread, then shows it. Returns nil when a later
    /// navigation replaced this one or the folder couldn't be read. `open` says how the sidebar reached it, which
    /// decides how the sidebar's tree follows and which of its rows is selected.
    @discardableResult
    func navigate(to url: URL, history: HistoryMove = .push, open: SidebarOpen = .other) async -> NavigationTiming? {
        self.loaded = true
        navigationToken += 1
        let token = navigationToken
        let clock = ContinuousClock()
        let started = clock.now
        let (result, read) = await Task.detached(priority: .userInitiated) {
            let clock = ContinuousClock()
            let started = clock.now
            let result = Result { try FolderLoader.load(url) }
            return (result, clock.now - started)
        }.value
        guard token == navigationToken else { return nil }
        let readAt = clock.now

        let listing: FolderListing
        switch result {
        case .success(let value):
            listing = value
        case .failure(let error):
            if let window { NSAlert(error: error).beginSheetModal(for: window, completionHandler: nil) }
            sidebar.openFailed()
            return nil
        }

        let previous = folder
        let history = open.pushesHistory ? history : HistoryMove.none
        switch history {
        case .push:
            if url.comparablePath != previous.comparablePath {
                backStack.append(previous)
                forwardStack.removeAll()
            }
        case .back:
            if !backStack.isEmpty { backStack.removeLast() }
            forwardStack.append(previous)
        case .forward:
            if !forwardStack.isEmpty { forwardStack.removeLast() }
            backStack.append(previous)
        case .none:
            break
        case .jump(let paths, let index):
            backStack = paths[..<index].map { URL(fileURLWithPath: $0) }
            forwardStack = paths[(index + 1)...].reversed().map { URL(fileURLWithPath: $0) }
        }
        folder = url

        // Coming back up to a parent selects the folder you came from, as Finder does.
        let cameFromChild = previous.deletingLastPathComponent().comparablePath == url.comparablePath
        updateTitle()
        searchField?.stringValue = ""
        // A folder opened from the sidebar leaves the keyboard there.
        let sidebarKeyboard = sidebar.isFocused ? window?.firstResponder : nil
        browser.show(listing, selecting: cameFromChild ? [previous] : [])
        if let sidebarKeyboard { window?.makeFirstResponder(sidebarKeyboard) }
        sidebar.folderOpened(url, open)
        updateNavigationItems()
        notify(.folder)
        window?.contentView?.layoutSubtreeIfNeeded()
        window?.displayIfNeeded()
        if let callback = onFirstDraw {
            onFirstDraw = nil
            callback()
        }
        group?.tabChanged(self)
        Task {
            let capacity = await Task.detached(priority: .utility) {
                FolderLoader.availableCapacity(at: url)
            }.value
            if token == navigationToken { browser.setAvailableCapacity(capacity) }
        }

        let timing = NavigationTiming(
            folder: url, itemCount: listing.items.count, read: read, load: readAt - started,
            display: clock.now - readAt)
        if Self.logsTimings {
            FileHandle.standardError.write(
                Data(
                    String(
                        format: "navigate %@ (%d items): load %.1f ms, display %.1f ms\n",
                        url.path, timing.itemCount, timing.load.milliseconds,
                        timing.display.milliseconds
                    ).utf8))
        }
        return timing
    }

    private func open(_ items: [FileItem]) {
        if items.count == 1, let target = FolderLoader.folderTarget(of: items[0]) {
            go(to: target)
            return
        }
        for item in items {
            if let target = FolderLoader.folderTarget(of: item) {
                group?.openTab(path: target.path, from: self)
            } else {
                NSWorkspace.shared.open(item.url)
            }
        }
    }

    private func updateNavigationItems() {
        notify(.history)
    }

    /// The folder Open in New Tab and Open in New Window open: the one folder selected, or with the sidebar focused its
    /// selected folder (B-TREE-155).
    private var selectedFolder: URL? {
        if focusedPane == .tree { return sidebar.selectedTreeTargetPath.map { URL(fileURLWithPath: $0) } }
        let items = browser.selectedItems
        guard items.count == 1 else { return nil }
        return FolderLoader.folderTarget(of: items[0])
    }

    /// The folder selected in the file list, if it is the one item selected and a folder.
    private var selectedContentFolder: URL? {
        let items = browser.selectedItems
        guard items.count == 1 else { return nil }
        return FolderLoader.folderTarget(of: items[0])
    }

    /// The pane that last had the keyboard (`lastExplorerFocusPaneRef`).
    private func noteFocusedPane() {
        if let pane = focusedPane { lastFocusedPane = pane }
    }

    /// What the command rules look at of the selection in the file list.
    private var commandEntries: [CommandEntry] {
        browser.selectedItems.map {
            CommandEntry(path: $0.url.path, kind: $0.opensAsFolder ? .directory : .file)
        }
    }

    /// The folder File ▸ Add to Favorites acts on (`resolveFavoriteTargetPath`).
    var favoriteTargetPath: String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return CommandAvailability.favoriteTargetPath(
            .init(
                currentPath: folder.path, selectedPathsInViewOrder: selectedPaths, activeContentEntries: commandEntries,
                selectedTreeTargetPath: sidebar.selectedTreeTargetPath, isSearchMode: searchRootPath != nil,
                trashPath: FavoriteLabel.trashPath(homePath: home), focusedPane: commandPane))
    }

    private var commandPane: FTFoundation.FocusedPane? {
        switch focusedPane {
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
            self.go(to: url, open: open)
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
        browser.show(FolderListing(folder: folder, items: []), selecting: [])
        sidebar.focusTree()
        notify(.selection)
    }

    // MARK: Menu state

    /// The commands whose availability the tab knows of itself: history and tabs.
    private static let tabCommands: [RendererCommand] = [
        .goBack, .goForward, .goEnclosingFolder, .selectNextTab, .selectPreviousTab, .moveTabToNewWindow,
    ]

    /// What the application menu shows of this tab.
    var menuState: ApplicationMenuState {
        let context = CommandAvailabilityContext(
            currentPath: folder.path, canGoBack: !backStack.isEmpty, canGoForward: !forwardStack.isEmpty,
            tabCount: group?.tabs.count ?? 1, homePath: FileManager.default.homeDirectoryForCurrentUser.path)
        let panels = group?.session.panels
        var state = ApplicationMenuState.build(
            viewMode: viewMode, sortBy: sortBy, foldersFirst: foldersFirst, hiddenFilesShown: includeHidden,
            folderTreeOpen: panels?.folderTreeOpen ?? true, infoPanelOpen: panels?.propertiesOpen ?? false,
            infoRowOpen: panels?.detailRowOpen ?? false,
            favoriteIsSet: favoriteTargetPath.map { sidebar.isFavorite($0) } ?? false, textEditing: false
        ) { CommandAvailability.canRun($0, context) }
        state.disabledCommands = state.disabledCommands.filter(Self.tabCommands.contains)
        return state
    }

    // MARK: Actions

    @objc func goBack(_ sender: Any?) {
        guard let target = backStack.last else { return }
        go(to: target, history: .back)
    }

    @objc func goForward(_ sender: Any?) {
        guard let target = forwardStack.last else { return }
        go(to: target, history: .forward)
    }

    @objc func goToEnclosingFolder(_ sender: Any?) {
        guard folder.comparablePath != "/" else { return }
        go(to: folder.deletingLastPathComponent())
    }

    @objc func goToPlace(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        go(to: url)
    }

    @objc func openSelection(_ sender: Any?) {
        open(browser.selectedItems)
    }

    @objc func showAsIcons(_ sender: Any?) { setMode(.icons) }

    @objc func showAsList(_ sender: Any?) { setMode(.details) }

    @objc private func searchChanged(_ sender: NSSearchField) {
        browser.setFilter(sender.stringValue)
    }

    /// The toolbar's search field: what it holds narrows the list (the spike's filter; searching is P5-07's).
    private var searchField: ToolbarSearchField? {
        (workspace.toolbar.slotViews[ToolbarItemID.search.rawValue]?.content as? ToolbarSearchSlot)?.field
    }

    private func connectSearchField() {
        searchField?.target = self
        searchField?.action = #selector(searchChanged(_:))
    }

    /// The tab bar's "+" button, and New Tab: a tab on this folder.
    override func newWindowForTab(_ sender: Any?) {
        group?.openNewTab(from: self)
    }

    private func setMode(_ mode: ExplorerViewMode) {
        viewMode = mode
        browser.setMode(mode == .icons ? .icons : .list)
        notify(.view)
        group?.tabChanged(self)
    }

    static func sortKey(_ sortBy: SortByPreference) -> String {
        switch sortBy {
        case .name: "name"
        case .modified: "modified"
        case .size: "size"
        case .kind: "kind"
        }
    }

    /// The sort commands: the field already in use reverses the direction; another sorts by it, ascending.
    private func sort(by field: SortByPreference) {
        if field == sortBy {
            sortDirection = sortDirection == .asc ? .desc : .asc
        } else {
            sortBy = field
            sortDirection = .asc
        }
        browser.setSort(key: Self.sortKey(sortBy), ascending: sortDirection == .asc)
        notify(.view)
        group?.tabChanged(self)
    }

    /// A column header changed the sort.
    private func sortChangedInList(_ sort: NSSortDescriptor) {
        guard let key = sort.key, let field = SortByPreference(rawValue: key) else { return }
        sortBy = field
        sortDirection = sort.ascending ? .asc : .desc
        notify(.view)
        group?.tabChanged(self)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(goBack(_:)): return !backStack.isEmpty
        case #selector(goForward(_:)): return !forwardStack.isEmpty
        case #selector(goToEnclosingFolder(_:)): return folder.comparablePath != "/"
        case #selector(openSelection(_:)): return !browser.selectedItems.isEmpty
        case #selector(showAsIcons(_:)):
            menuItem.state = browser.mode == .icons ? .on : .off
            return true
        case #selector(showAsList(_:)):
            menuItem.state = browser.mode == .list ? .on : .off
            return true
        default: return true
        }
    }

    // MARK: Customize Toolbar

    /// Edits the toolbar in place (View ▸ Customize Toolbar…, View Options, the toolbar's right-click).
    func beginCustomizingToolbar() {
        guard customizer == nil else { return }
        AppMenuPresenter.shared.close()
        let customizer = ToolbarCustomizer(toolbar: workspace.toolbar)
        customizer.onCommit = { [weak self] items in
            self?.updatePreferences(["topToolbarItems": .array(items.map { .string($0.rawValue) })])
        }
        customizer.onFinish = { [weak self] in self?.finishCustomizingToolbar() }
        self.customizer = customizer
        customizer.begin()
        workspace.setCustomizing(customizer.panel)
        workspace.needsLayout = true
    }

    func finishCustomizingToolbar() {
        guard let customizer else { return }
        self.customizer = nil
        customizer.end()
        workspace.setCustomizing(nil)
        window?.makeFirstResponder(nil)
    }

    // MARK: Window events

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        group?.shouldCloseTab(self) ?? true
    }

    func windowWillClose(_ notification: Notification) {
        finishCustomizingToolbar()
        group?.tabWillClose(self)
        if let window { WindowEventRouting.forget(window) }
        onClose?()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        ensureLoaded()
        group?.tabBecameKey(self)
    }

    func windowDidResignKey(_ notification: Notification) {
        // The window going to the back ends a drag; a window of an app in the background has no focus to lose.
        if NSApp.isActive { customizer?.cancelDrag() }
    }

    func windowDidMove(_ notification: Notification) {
        group?.tabBoundsChanged(self)
    }

    func windowDidResize(_ notification: Notification) {
        group?.tabBoundsChanged(self)
        if let customizer { workspace.setCustomizing(customizer.panel) }
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
    }

    /// A preference change from any window (`onPreferencesChanged`): the keys the whole app shares.
    /// What Copy or Cut put on the app's clipboard changed (P5-08 calls this from the shared clipboard).
    func clipboardChanged() {
        notify(.clipboard)
    }

    func preferencesChanged(_ change: PreferencesChange) {
        sidebar.applyPreferences()
        notify(.preferences)
        if let customizer { customizer.refreshPanel() }
    }
}

extension MainWindowController: ExplorerWindowHandle {
    /// Carries out a menu command in this tab, or in its explorer window.
    func perform(_ command: RendererCommand) {
        // While the toolbar is customized the window waits, as under a sheet: only editing still works.
        if customizer != nil, MenuCommandRouter.nativeEditSelector(command) == nil, command != .customizeToolbar {
            return
        }
        let fileManager = FileManager.default
        func place(_ url: URL?) {
            if let url { go(to: url) }
        }
        switch command {
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
            if focusedPane == .tree { _ = sidebar.openSelection() } else { openSelection(nil) }
        case .viewAsIcons: setMode(.icons)
        case .viewAsDetails: setMode(.details)
        case .viewAsList: setMode(.list)
        case .sortByName: sort(by: .name)
        case .sortByKind: sort(by: .kind)
        case .sortByModified: sort(by: .modified)
        case .sortBySize: sort(by: .size)
        case .toggleFoldersFirst:
            foldersFirst.toggle()
            notify(.view)
            group?.tabChanged(self)
        case .toggleHiddenFiles:
            includeHidden.toggle()
            sidebar.hiddenFilesChanged(includeHidden)
            notify(.view)
            group?.tabChanged(self)
        case .refreshOrApplySearchSort: reload()
        case .customizeToolbar: beginCustomizingToolbar()
        case .goDocuments: place(fileManager.urls(for: .documentDirectory, in: .userDomainMask).first)
        case .goDesktop: place(fileManager.urls(for: .desktopDirectory, in: .userDomainMask).first)
        case .goDownloads: place(fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first)
        case .goHomeRootTree: sidebar.rootTree(at: fileManager.homeDirectoryForCurrentUser.path)
        case .goLibrary: place(fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first)
        // Macintosh HD and the Trash act exactly as a click on their Locations rows.
        case .goMacintoshHD: sidebar.openLocation("/")
        case .goApplications: place(fileManager.urls(for: .applicationDirectory, in: .localDomainMask).first)
        case .goTrash: sidebar.openLocation(fileManager.homeDirectoryForCurrentUser.path + "/.Trash")
        case .rootTreeAtSelection:
            if let target = sidebar.rootTreeTarget(
                focusedPane: focusedPane, lastFocusedPane: lastFocusedPane,
                selectedContentFolder: selectedContentFolder?.path, currentPath: folder.path)
            {
                sidebar.rootTree(at: target)
            }
        case .toggleFavorite:
            if let target = favoriteTargetPath { sidebar.toggleFavorite(target) }
        case .focusTreePane: sidebar.focusTree()
        case .ejectVolume:
            if let target = ejectTargetPath { ejectCoordinator.requestEject(path: target) }
        case .newTab: group?.openNewTab(from: self)
        case .closeTab: group?.closeTab(self)
        case .reopenClosedTab: group?.reopenClosedTab(from: self)
        case .duplicateTab: group?.duplicateTab(self)
        case .selectNextTab: group?.selectAdjacentTab(from: self, .next)
        case .selectPreviousTab: group?.selectAdjacentTab(from: self, .previous)
        case .openSelectionInNewTab:
            if let target = selectedFolder { group?.openTab(path: target.path, from: self) }
        case .newWindow: group?.openNewWindow(from: self, path: nil)
        case .openSelectionInNewWindow:
            if let target = selectedFolder { group?.openNewWindow(from: self, path: target.path) }
        case .moveTabToNewWindow: group?.moveTabToNewWindow(self)
        case .mergeAllWindows: group?.mergeAllWindows(into: self)
        case .toggleFolderTree: updatePanels { $0.folderTreeOpen.toggle() }
        case .toggleInfoPanel: updatePanels { $0.propertiesOpen.toggle() }
        case .toggleInfoRow: updatePanels { $0.detailRowOpen.toggle() }
        case .focusContentPane: window?.makeFirstResponder(browser.view.subviews.first)
        default:
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
        workspace.show(folderTree: panels.folderTreeOpen, infoPanel: panels.propertiesOpen)
        browser.setInfoRowOpen(panels.detailRowOpen)
        if !workspace.isReady { workspace.becomeReady() }
        notify(.panels)
    }
}

extension MainWindowController: ExplorerWindowContext {
    var currentFolder: URL { folder }

    func navigate(to url: URL, target: NavigationTarget) {
        switch target {
        case .push: go(to: url)
        case .newTab: group?.openTab(path: url.path, from: self)
        case .newWindow: group?.openNewWindow(from: self, path: url.path)
        }
    }

    var historyPaths: [String] { (backStack + [folder] + forwardStack.reversed()).map(\.path) }
    var historyIndex: Int { backStack.count }
    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    func goToHistoryIndex(_ index: Int) {
        let paths = historyPaths
        guard paths.indices.contains(index), index != historyIndex else { return }
        go(to: URL(fileURLWithPath: paths[index]), history: .jump(paths: paths, index: index))
    }

    func canPerform(_ command: RendererCommand) -> Bool {
        // Customizing the toolbar is a sheet over the window (`sheetOpen`): the commands wait for it to end.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let context = CommandAvailabilityContext(
            shortcutContext: ShortcutContext(
                focusedPane: commandPane, locationSheetOpen: customizer != nil,
                selectedTreeTargetKind: sidebar.selectedTreeTargetKind),
            currentPath: folder.path, selectedPathsInViewOrder: selectedPaths, activeContentEntries: commandEntries,
            selectedTreeTargetPath: sidebar.selectedTreeTargetPath, isSearchMode: searchRootPath != nil,
            canGoBack: canGoBack, canGoForward: canGoForward, tabCount: group?.tabs.count ?? 1,
            trashPath: FavoriteLabel.trashPath(homePath: home), homePath: home, ejectTargetPath: ejectTargetPath)
        return CommandAvailability.canRun(command, context)
    }

    var selectedPaths: [String] { browser.selectedItems.map(\.url.path) }

    var focusedPane: ExplorerPane? {
        guard let responder = window?.firstResponder as? NSView else { return nil }
        if responder.isDescendant(of: browser.view) { return .content }
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
