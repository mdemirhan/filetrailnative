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

        /// A folder that is not there is told of, unless the window is only looking for the nearest one that is.
        var alertsWhenGone: Bool {
            if case .none = self { return false }
            return true
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
    let content: ContentPaneController
    /// What this window knows of folder sizes (`useFolderSizeCache`).
    let folderSizes: WindowFolderSizes
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
    private var isNavigating = false
    private var pendingChange: PendingChange?
    private var quietReadInFlight = false
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
        let sizes = FolderSizeService.shared.sizes(for: windowID)
        folderSizes = sizes
        content = ContentPaneController(mode: tab.viewMode, folderSizes: sizes, loaders: .placeholder)
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
        workspace.sidebarCell.content = sidebar.view
        workspace.mainCell.content = content.view
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

        sidebar.onSelect = { [weak self] url in self?.go(to: url) }
        wireContent()
        workspace.toolbar.attach(self)
        connectSearchField()
        #if DEBUG
            AutomationLayoutPrefs.registerOnce()
            AutomationContentPrefs.registerOnce()
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

    /// Reads the folder on screen again, quietly: something changed in it. `changedPaths` are the items the change
    /// touched (nil: anything in it may have).
    func reload(changedPaths: [String]? = nil) {
        guard loaded else { return }
        pendingChange = PendingChange.merging(pendingChange, changedPaths)
        flushPendingChange()
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
        var changedPaths: Set<String>?

        @MainActor static func merging(_ pending: PendingChange?, _ paths: [String]?) -> PendingChange {
            guard let pending else { return PendingChange(changedPaths: paths.map(Set.init)) }
            guard let existing = pending.changedPaths, let paths else { return PendingChange(changedPaths: nil) }
            let union = existing.union(paths)
            return PendingChange(changedPaths: union.count > FolderWatches.maxChangedPaths ? nil : union)
        }
    }

    private func flushPendingChange() {
        guard let pending = pendingChange, !folderChangesHeld, !quietReadInFlight else { return }
        // A folder still being opened is tried again shortly (B-VIEW-189).
        if isNavigating {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.retryDelay) { [weak self] in
                MainActor.assumeIsolated { self?.flushPendingChange() }
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
        guard url == folder, !isNavigating else { return }
        switch result.snapshot {
        case .success(let snapshot):
            content.show(
                folder: url.path, entries: snapshot.entries, selecting: nil, keepingScroll: true,
                changedPaths: changedPaths)
            notify(.folder)
        case .failure(let error):
            if FolderReadFailure.isGone(error) {
                await openNearestExistingFolder(above: url)
            } else {
                content.showError(folder: url.path, message: FolderReadFailure.message(error))
            }
        }
    }

    /// The folder on screen is gone: the nearest folder above it that still exists is opened in its place, and the
    /// selection is not carried over (B-VIEW-194).
    private func openNearestExistingFolder(above url: URL) async {
        var candidate = url
        while candidate.path != "/" {
            candidate = candidate.deletingLastPathComponent()
            if await navigate(to: candidate, history: .none) != nil { return }
        }
    }

    private static let retryDelay = 0.25

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

    /// Reads `url`, then shows it. Returns nil when a later navigation replaced this one or the folder is gone.
    /// The listing in front stays on screen until the new one arrives (B-NAV-113).
    @discardableResult
    func navigate(to url: URL, history: HistoryMove = .push) async -> NavigationTiming? {
        self.loaded = true
        navigationToken += 1
        let token = navigationToken
        isNavigating = true
        defer { if token == navigationToken { isNavigating = false } }
        let clock = ContinuousClock()
        let started = clock.now
        content.beginLoading(quiet: false)
        let read = await readFolder(url)
        guard token == navigationToken else { return nil }
        let readAt = clock.now

        let previous = folder
        var entries: [DirectoryEntry] = []
        switch read.snapshot {
        case .success(let snapshot):
            entries = snapshot.entries
        case .failure(let error):
            if FolderReadFailure.isGone(error) {
                // A folder that is not there opens nothing (`persistOnError: "unlessGone"`).
                content.cancelLoading()
                if history.alertsWhenGone, let window {
                    NSAlert(error: error).beginSheetModal(for: window, completionHandler: nil)
                }
                sidebar.select(folder)
                return nil
            }
        }

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
        if favoritePath != url.path { favoritePath = nil }

        // Coming back up to a parent selects the folder you came from, as Finder does.
        let cameFromChild = previous.deletingLastPathComponent().comparablePath == url.comparablePath
        updateTitle()
        searchField?.stringValue = ""
        switch read.snapshot {
        case .success:
            content.show(
                folder: url.path, entries: entries, selecting: cameFromChild ? [previous.path] : [],
                keepingScroll: false)
        case .failure(let error):
            content.showError(folder: url.path, message: FolderReadFailure.message(error))
        }
        sidebar.select(url)
        updateNavigationItems()
        notify(.folder)
        window?.contentView?.layoutSubtreeIfNeeded()
        window?.displayIfNeeded()
        if let callback = onFirstDraw {
            onFirstDraw = nil
            callback()
        }
        group?.tabChanged(self)

        let timing = NavigationTiming(
            folder: url, itemCount: entries.count, read: read.duration, load: readAt - started,
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

    /// Opens items: a folder in place (or in a new tab with command), the rest with the system.
    private func open(_ entries: [DirectoryEntry], inNewTab: Bool = false) {
        if entries.count == 1, entries[0].isDirectoryLike, !inNewTab {
            go(to: entries[0].url)
            return
        }
        for entry in entries {
            if entry.isDirectoryLike {
                group?.openTab(path: entry.path, from: self)
            } else {
                NSWorkspace.shared.open(entry.url)
            }
        }
    }

    private func updateNavigationItems() {
        notify(.history)
    }

    /// The folder Open in New Tab and Open in New Window open: the one folder selected.
    private var selectedFolder: URL? {
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
        content.onSelectionChanged = { [weak self] _ in self?.notify(.selection) }
        content.onColumnWidthsChanged = { [weak self] widths in self?.saveColumnWidths(widths) }
        content.setView(
            sortBy: sortBy, direction: sortDirection, foldersFirst: foldersFirst, includeHidden: includeHidden)
        content.setColumns(ListColumnState(preferences: preferences))
        content.setMode(viewMode)
    }

    /// The widths the List keeps are the window's own (`detailColumnWidths` is a window session key).
    private func saveColumnWidths(_ widths: [DetailColumn: Double]) {
        func width(_ column: DetailColumn) -> JSONNode {
            .number(DetailsColumns.clamp(widths[column] ?? 0, column: column, search: false))
        }
        updatePreferences([
            "detailColumnWidths": .object([
                "name": width(.name), "modified": width(.modified), "size": width(.size), "kind": width(.kind),
                "created": width(.created), "permissions": width(.permissions),
            ])
        ])
    }

    /// The columns and the density again, from the preferences (Settings changed them, or a scenario did).
    func refreshColumns() {
        content.setColumns(ListColumnState(preferences: preferences))
    }

    /// Refresh: the caches of the listing are let go of, and the folder is read again with the selection kept
    /// (B-NAV-124).
    func refresh() {
        services.directoryService.cache.clear()
        reload()
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
        open(content.selectedEntries)
    }

    @objc func showAsIcons(_ sender: Any?) { setMode(.icons) }

    @objc func showAsList(_ sender: Any?) { setMode(.details) }

    @objc private func searchChanged(_ sender: NSSearchField) {
        content.setFilter(sender.stringValue)
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
        content.setMode(mode)
        notify(.view)
        group?.tabChanged(self)
    }

    /// The sort commands and the column headers (`handleSortChange`): the field already in use reverses the direction;
    /// another sorts by it, descending for Date Modified and Size and ascending for Name and Kind.
    private func sort(by field: SortByPreference) {
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
        guard loaded else { return }
        Task { await navigate(to: folder, history: .none) }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(goBack(_:)): return !backStack.isEmpty
        case #selector(goForward(_:)): return !forwardStack.isEmpty
        case #selector(goToEnclosingFolder(_:)): return folder.comparablePath != "/"
        case #selector(openSelection(_:)): return !content.selectedEntries.isEmpty
        case #selector(showAsIcons(_:)):
            menuItem.state = viewMode == .icons ? .on : .off
            return true
        case #selector(showAsList(_:)):
            menuItem.state = viewMode == .details ? .on : .off
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
        FolderSizeService.shared.forget(windowID: windowID)
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
        refreshColumns()
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
        case .goEnclosingFolder: goToEnclosingFolder(nil)
        case .openSelection: openSelection(nil)
        case .viewAsIcons: setMode(.icons)
        case .viewAsDetails: setMode(.details)
        case .viewAsList: setMode(.list)
        case .sortByName: sort(by: .name)
        case .sortByKind: sort(by: .kind)
        case .sortByModified: sort(by: .modified)
        case .sortBySize: sort(by: .size)
        case .toggleFoldersFirst:
            foldersFirst.toggle()
            viewChanged()
        case .toggleHiddenFiles:
            includeHidden.toggle()
            viewChanged()
        case .refreshOrApplySearchSort: refresh()
        case .customizeToolbar: beginCustomizingToolbar()
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
        case .toggleFolderTree: updatePanels { $0.folderTreeOpen.toggle() }
        case .toggleInfoPanel: updatePanels { $0.propertiesOpen.toggle() }
        case .toggleInfoRow: updatePanels { $0.detailRowOpen.toggle() }
        case .focusContentPane: content.focusList()
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
        content.setInfoRowOpen(panels.detailRowOpen)
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
        let context = CommandAvailabilityContext(
            shortcutContext: ShortcutContext(locationSheetOpen: customizer != nil), currentPath: folder.path,
            selectedPathsInViewOrder: selectedPaths, isSearchMode: searchRootPath != nil, canGoBack: canGoBack,
            canGoForward: canGoForward, tabCount: group?.tabs.count ?? 1,
            homePath: FileManager.default.homeDirectoryForCurrentUser.path)
        return CommandAvailability.canRun(command, context)
    }

    var selectedPaths: [String] { content.selection.paths }

    var focusedPane: ExplorerPane? {
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
