// Port of a tab of apps/desktop/src/renderer/hooks/useExplorerTabs.ts: one tab of an explorer window, as a native window tab
import AppKit
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

extension NSToolbarItem.Identifier {
    static let navigation = Self("navigation")
    static let viewMode = Self("viewMode")
    static let search = Self("search")
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
final class MainWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate,
    NSMenuItemValidation
{
    enum HistoryMove {
        case push, back, forward, none
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
    /// How the tab shows its folder, kept between launches with its folder.
    private(set) var treeRootPath: String
    private(set) var favoritePath: String?
    private(set) var viewMode: ExplorerViewMode
    private(set) var searchViewMode: ExplorerViewMode
    private(set) var sortBy: SortByPreference
    private(set) var sortDirection: SortDirectionPreference
    private(set) var includeHidden: Bool
    private(set) var foldersFirst: Bool
    private(set) var favoritesExpanded: Bool
    private(set) var locationsExpanded: Bool

    var onClose: (() -> Void)?
    /// Called once, after the first folder has been drawn (used by the launch benchmark).
    var onFirstDraw: (() -> Void)?
    /// Called once the tab has shown its first folder, or found it can't.
    var onReady: (() -> Void)?

    private let sidebar = SidebarViewController()
    private let browser = BrowserViewController()
    private var backStack: [URL] = []
    private var forwardStack: [URL] = []
    private var navigationToken = 0
    /// A tab brought back, or merged in, waits unread until it is first shown.
    private(set) var loaded = false
    /// The tab was sent to another folder while in the background (its folder moved, or its disk went): the folder
    /// is read when the tab is next shown.
    private(set) var stale = false

    private var backItem: NSToolbarItem?
    private var forwardItem: NSToolbarItem?
    private var viewModeItem: NSToolbarItemGroup?
    private var searchItem: NSSearchToolbarItem?

    /// A tab on `tab`'s folder, with `history` (none: just the folder). It reads its folder when it is first shown,
    /// or at once with `loadNow`.
    init(tab: StartupTab, history: (paths: [String], index: Int)? = nil, frame: NSRect? = nil, loadNow: Bool = true) {
        windowID = Self.nextWindowID
        Self.nextWindowID += 1
        folder = URL(fileURLWithPath: tab.path)
        treeRootPath = tab.rootPath
        favoritePath = tab.favoritePath
        viewMode = tab.viewMode
        searchViewMode = tab.searchViewMode
        sortBy = tab.sortBy
        sortDirection = tab.sortDirection
        includeHidden = tab.includeHidden
        foldersFirst = tab.foldersFirst
        favoritesExpanded = tab.favoritesExpanded
        locationsExpanded = tab.locationsExpanded
        if let history, history.paths.indices.contains(history.index) {
            backStack = history.paths[..<history.index].map { URL(fileURLWithPath: $0) }
            forwardStack = history.paths[(history.index + 1)...].reversed().map { URL(fileURLWithPath: $0) }
        }
        let window = ExplorerTabWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultContentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.toolbarStyle = .unified
        window.tabbingIdentifier = "FileTrailBrowser"
        window.minSize = Self.minimumSize
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.explorerTab = self
        window.delegate = self

        let split = NSSplitViewController()
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = CGFloat(AppPreferenceLimits.treeWidthRange.lowerBound)
        sidebarItem.maximumThickness = CGFloat(AppPreferenceLimits.treeWidthRange.upperBound)
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(NSSplitViewItem(viewController: browser))
        window.contentViewController = split
        split.view.setAccessibilityIdentifier("window.content")
        if let frame {
            window.setFrame(frame, display: false)
        } else {
            window.setContentSize(Self.defaultContentSize)
            window.center()
        }

        let toolbar = NSToolbar(identifier: "Main")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        window.toolbar = toolbar

        sidebar.onSelect = { [weak self] url in self?.go(to: url) }
        browser.onOpen = { [weak self] items in self?.open(items) }
        browser.setMode(viewMode == .icons ? .icons : .list)
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
        treeRootPath = snapshot.treeRootPath
        let favoritePrefix = "favorite:"
        if let item = snapshot.selectedTreeItemID, item.hasPrefix(favoritePrefix) {
            favoritePath = String(item.dropFirst(favoritePrefix.count))
        } else {
            favoritePath = nil
        }
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

    func go(to url: URL, history: HistoryMove = .push) {
        Task { await navigate(to: url, history: history) }
    }

    /// Reads `url` off the main thread, then shows it. Returns nil when a later
    /// navigation replaced this one or the folder couldn't be read.
    @discardableResult
    func navigate(to url: URL, history: HistoryMove = .push) async -> NavigationTiming? {
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
            sidebar.select(folder)
            return nil
        }

        let previous = folder
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
        }
        folder = url
        if favoritePath != url.path { favoritePath = nil }

        // Coming back up to a parent selects the folder you came from, as Finder does.
        let cameFromChild = previous.deletingLastPathComponent().comparablePath == url.comparablePath
        updateTitle()
        searchItem?.searchField.stringValue = ""
        browser.show(listing, selecting: cameFromChild ? [previous] : [])
        sidebar.select(url)
        updateNavigationItems()
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
        backItem?.isEnabled = !backStack.isEmpty
        forwardItem?.isEnabled = !forwardStack.isEmpty
        viewModeItem?.selectedIndex = browser.mode.rawValue
    }

    /// The folder Open in New Tab and Open in New Window open: the one folder selected.
    private var selectedFolder: URL? {
        let items = browser.selectedItems
        guard items.count == 1 else { return nil }
        return FolderLoader.folderTarget(of: items[0])
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
            infoRowOpen: panels?.detailRowOpen ?? false, favoriteIsSet: false, textEditing: false
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

    @objc private func viewModeChanged(_ sender: NSToolbarItemGroup) {
        setMode(sender.selectedIndex == BrowserViewController.Mode.icons.rawValue ? .icons : .details)
    }

    @objc private func searchChanged(_ sender: NSSearchField) {
        browser.setFilter(sender.stringValue)
    }

    /// The tab bar's "+" button, and New Tab: a tab on this folder.
    override func newWindowForTab(_ sender: Any?) {
        group?.openNewTab(from: self)
    }

    /// Duplicate Tab (File menu): a copy of this tab, with its history, right after it.
    @objc func duplicateTab(_ sender: Any?) {
        group?.duplicateTab(self)
    }

    private func setMode(_ mode: ExplorerViewMode) {
        viewMode = mode
        browser.setMode(mode == .icons ? .icons : .list)
        updateNavigationItems()
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

    // MARK: Window events

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        group?.shouldCloseTab(self) ?? true
    }

    func windowWillClose(_ notification: Notification) {
        group?.tabWillClose(self)
        onClose?()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        ensureLoaded()
        group?.tabBecameKey(self)
    }

    func windowDidMove(_ notification: Notification) {
        group?.tabBoundsChanged(self)
    }

    func windowDidResize(_ notification: Notification) {
        group?.tabBoundsChanged(self)
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

    // MARK: Toolbar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.sidebarTrackingSeparator, .navigation, .flexibleSpace, .viewMode, .search]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [.space, .toggleSidebar]
    }

    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case .navigation:
            let back = makeButton("back", label: "Back", symbol: "chevron.left", action: #selector(goBack(_:)))
            let forward = makeButton(
                "forward", label: "Forward", symbol: "chevron.right", action: #selector(goForward(_:)))
            let group = NSToolbarItemGroup(itemIdentifier: itemIdentifier)
            group.subitems = [back, forward]
            group.label = "Back/Forward"
            group.isNavigational = true
            backItem = back
            forwardItem = forward
            updateNavigationItems()
            return group
        case .viewMode:
            let images = ["square.grid.2x2", "list.bullet"].compactMap {
                NSImage(systemSymbolName: $0, accessibilityDescription: nil)
            }
            let group = NSToolbarItemGroup(
                itemIdentifier: itemIdentifier, images: images, selectionMode: .selectOne,
                labels: ["Icons", "List"], target: self, action: #selector(viewModeChanged(_:)))
            group.label = "View"
            group.selectedIndex = browser.mode.rawValue
            viewModeItem = group
            return group
        case .search:
            let item = NSSearchToolbarItem(itemIdentifier: itemIdentifier)
            item.searchField.target = self
            item.searchField.action = #selector(searchChanged(_:))
            item.searchField.sendsSearchStringImmediately = true
            item.searchField.setAccessibilityIdentifier("toolbar.search")
            searchItem = item
            return item
        default:
            return nil
        }
    }

    private func makeButton(_ id: String, label: String, symbol: String, action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: .init(id))
        item.label = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.target = self
        item.action = action
        item.isBordered = true
        item.autovalidates = false
        return item
    }
}

extension MainWindowController: ExplorerWindowHandle {
    /// Carries out a menu command in this tab, or in its explorer window.
    func perform(_ command: RendererCommand) {
        let fileManager = FileManager.default
        func place(_ url: URL?) {
            if let url { go(to: url) }
        }
        switch command {
        case .goBack: goBack(nil)
        case .goForward: goForward(nil)
        case .goEnclosingFolder: goToEnclosingFolder(nil)
        case .openSelection: openSelection(nil)
        case .viewAsIcons: setMode(.icons)
        case .viewAsDetails: setMode(.details)
        case .viewAsList: setMode(.list)
        case .goDocuments: place(fileManager.urls(for: .documentDirectory, in: .userDomainMask).first)
        case .goDesktop: place(fileManager.urls(for: .desktopDirectory, in: .userDomainMask).first)
        case .goDownloads: place(fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first)
        case .goHomeRootTree: place(fileManager.homeDirectoryForCurrentUser)
        case .goLibrary: place(fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first)
        case .goMacintoshHD: place(URL(fileURLWithPath: "/"))
        case .goApplications: place(fileManager.urls(for: .applicationDirectory, in: .localDomainMask).first)
        case .goTrash: place(fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".Trash"))
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
        case .toggleFolderTree: group?.session.update { $0.folderTreeOpen.toggle() }
        case .toggleInfoPanel: group?.session.update { $0.propertiesOpen.toggle() }
        case .toggleInfoRow: group?.session.update { $0.detailRowOpen.toggle() }
        default:
            if let selector = MenuCommandRouter.nativeEditSelector(command) {
                NSApp.sendAction(selector, to: nil, from: nil)
            }
        }
    }

    /// The panels the explorer window shows, as every one of its tabs shows them.
    func showPanels(_ panels: TabGroupSession.Panels) {
        guard let split = window?.contentViewController as? NSSplitViewController,
            let sidebarItem = split.splitViewItems.first
        else { return }
        if sidebarItem.isCollapsed == panels.folderTreeOpen {
            sidebarItem.isCollapsed = !panels.folderTreeOpen
        }
    }
}

extension Duration {
    var milliseconds: Double {
        Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
    }
}
