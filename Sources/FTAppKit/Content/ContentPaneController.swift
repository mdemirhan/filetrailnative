// Port of the content pane of apps/desktop/src/renderer/components/ContentPane.tsx (the shell and its states), with what
// App.tsx and useExplorerNavigationController.ts keep for it: the entries and their details, the order, the folder sizes
// and size bars, and the selection
import AppKit
import FTFileSystem
import FTFoundation

/// The part of the window's services the pane reads from.
struct ContentLoaders {
    /// Until the window wires its own.
    static let placeholder = ContentLoaders(
        metadata: { _, _ in [] }, hiddenCount: { _ in 0 }, iconStore: { nil },
        homePath: FileManager.default.homeDirectoryForCurrentUser.path, openPrivacySettings: {})

    /// The details of items in the folder.
    var metadata: @MainActor (_ folder: String, _ paths: [String]) async -> [EntryMetadata]
    /// How many items a folder has with hidden files shown.
    var hiddenCount: @MainActor (_ folder: String) async -> Int
    var iconStore: @MainActor () -> FileIconStore?
    var homePath: String
    var openPrivacySettings: @MainActor () -> Void
}

/// Holds the view of the folder, the states over it, and the background's menu and drops.
final class ContentContainerView: NSView {
    var paneView: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let paneView { addSubview(paneView, positioned: .below, relativeTo: stateView) }
            needsLayout = true
        }
    }
    let stateView = ContentStateView()
    var topInset = 0.0 {
        didSet { needsLayout = true }
    }
    var backgroundMenu: () -> NSMenu? = { nil }
    var backgroundDrop: (([URL], NSDragOperation) -> Bool)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(stateView)
        setAccessibilityIdentifier("content")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        paneView?.frame = bounds
        stateView.frame = NSRect(x: 0, y: topInset, width: bounds.width, height: max(0, bounds.height - topInset))
    }

    override func menu(for event: NSEvent) -> NSMenu? { backgroundMenu() }
}

#if DEBUG
    extension ContentContainerView: AutomationDropTarget {
        func automationDrop(_ items: [URL], at point: NSPoint, allowed: NSDragOperation) -> Bool {
            backgroundDrop?(items, allowed) ?? false
        }
    }
#endif

/// The content side of the window: the current view of the folder, the states, and the status line.
final class ContentPaneController: NSViewController, ContentPaneHost {
    // MARK: What the window wires

    var loaders: ContentLoaders
    /// Open the entries; `true` for a folder to open in a new tab.
    var onActivate: (([DirectoryEntry], Bool) -> Void)?
    var onSortRequested: ((SortByPreference) -> Void)?
    var onSortSetFromOutside: ((SortByPreference, Bool) -> Void)?
    var onSelectionChanged: ((ContentSelection) -> Void)?
    var onColumnWidthsChanged: (([DetailColumn: Double]) -> Void)?
    /// The menu for a right-click on items or on the background (P5-09).
    var contextMenuProvider: (([DirectoryEntry]?) -> NSMenu?)?
    var dragHooks = ContentDragHooks()
    var onSearchSubfolders: (() -> Void)?

    // MARK: State

    let folderSizes: WindowFolderSizes
    private(set) var mode: ExplorerViewMode
    private(set) var folderPath = ""
    private(set) var listed: [DirectoryEntry] = []
    private(set) var entries: [DirectoryEntry] = []
    private(set) var selection = ContentSelection.empty
    private(set) var loadState = ContentLoadState.idle
    private(set) var hiddenItemCount = 0
    private(set) var sortBy = SortByPreference.name
    private(set) var sortDirection = SortDirectionPreference.asc
    private(set) var foldersFirst = true
    private(set) var includeHidden = false
    private(set) var columnState = ListColumnState.standard
    private(set) var filter = ""
    private var metadata: [String: EntryMetadata] = [:]
    private var metadataInflight = Set<String>()
    private var metadataQueue: [String] = []
    private var metadataFlushQueued = false
    private var showsLoading = false
    private var loadingTimer: DispatchWorkItem?
    private var windowActive = true
    private var rowsByPath: [String: DirectoryEntry] = [:]
    private var barScaleCache: (listedCount: Int, version: Int, scale: Int64?)?
    private var observation: AppearanceModel.Observation?
    private var windowObservers: [any NSObjectProtocol] = []

    private var pane: (any FolderPane)?
    private let container = ContentContainerView()
    private let shell = ContentPaneView()
    private var status: NSTextField { shell.pathBarRow.status }

    var theme: Theme { AppearanceModel.shared.theme }
    var iconStore: FileIconStore? { loaders.iconStore() ?? Self.fallbackIcons }
    private static let fallbackIcons = FileIconStore()

    init(mode: ExplorerViewMode = .details, folderSizes: WindowFolderSizes, loaders: ContentLoaders) {
        self.mode = mode
        self.folderSizes = folderSizes
        self.loaders = loaders
        super.init(nibName: nil, bundle: nil)
        folderSizes.onChange = { [weak self] in self?.folderSizesChanged() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    isolated deinit {
        for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
        loadingTimer?.cancel()
    }

    // MARK: View

    /// The rows of the content pane (`.content-pane`): the search header (P5-07), the list, the Info Row and the path
    /// bar row (P5-06).
    var contentShell: ContentPaneView { shell }

    func setInfoRowOpen(_ open: Bool) {
        shell.infoRow.isOpen = open
        shell.needsLayout = true
    }

    override func loadView() {
        shell.list = container
        container.backgroundMenu = { [weak self] in self?.contextMenu(for: nil) }
        container.backgroundDrop = { [weak self] urls, allowed in
            self?.dragHooks.acceptDrop?(urls, nil, allowed) ?? false
        }
        container.stateView.onOpenPrivacySettings = { [weak self] in self?.loaders.openPrivacySettings() }
        container.stateView.onSearchSubfolders = onSearchSubfolders
        shell.onMovedToWindow = { [weak self] window in self?.observeWindow(window) }
        loaders.iconStore()?.preloadGenericIcons()
        view = shell
        installPane()
        observation = AppearanceModel.shared.observe { [weak self] _ in self?.lookChanged() }
    }

    private func observeWindow(_ window: NSWindow?) {
        for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
        windowObservers = []
        guard let window else { return }
        windowActive = window.isKeyWindow
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            windowObservers.append(
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.windowActive = window.isKeyWindow
                        self.pane?.refreshLook()
                        RelativeClock.shared.windowStateDidChange()
                    }
                })
        }
    }

    private func lookChanged() {
        pane?.refreshLook()
        refreshState()
    }

    // MARK: Views by mode

    func setMode(_ newMode: ExplorerViewMode) {
        guard newMode != mode || pane == nil else { return }
        mode = newMode
        installPane()
        // The new view starts at the top and then brings the selection's lead into view (B-VIEW-004).
        pane?.reload(scrollToTop: true)
        pane?.syncSelection()
        if let lead = selection.leadPath { pane?.reveal(paths: [lead]) }
        if let focus = pane?.focusView, view.window?.firstResponder == nil || hadKeyboard {
            view.window?.makeFirstResponder(focus)
        }
    }

    private var hadKeyboard = false

    private func installPane() {
        hadKeyboard = pane?.hasKeyboard ?? false
        if let old = pane {
            old.host = nil
            old.removeFromParent()
        }
        let next = ContentViewRegistry.make(mode)
        next.host = self
        addChild(next)
        pane = next
        container.paneView = next.view
        container.topInset = next.contentTopInset
        next.view.frame = container.bounds
    }

    // MARK: A folder

    /// A folder is being read. Its predecessor stays on screen until it arrives; with nothing on screen the loading
    /// card shows after 400 ms.
    func beginLoading(quiet: Bool) {
        guard !quiet else { return }
        if loadState != .loading { stateBeforeLoading = loadState }
        loadState = .loading
        loadingTimer?.cancel()
        showsLoading = false
        guard listed.isEmpty else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.loadState == .loading else { return }
                self.showsLoading = true
                self.refreshState()
            }
        }
        loadingTimer = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + ContentStateText.loadingDelayMilliseconds / 1000, execute: work)
    }

    /// A navigation that opens nothing (the folder is gone): the listing in front stays as it was.
    func cancelLoading() {
        loadingTimer?.cancel()
        showsLoading = false
        loadState = stateBeforeLoading
        refreshState()
    }

    private var stateBeforeLoading = ContentLoadState.idle

    /// Shows a folder that was read. `selecting` is what to select (those that exist); `keepingScroll` for the same
    /// folder read again.
    func show(
        folder path: String, entries newEntries: [DirectoryEntry], selecting paths: [String]?, keepingScroll: Bool,
        changedPaths: [String]? = nil
    ) {
        loadingTimer?.cancel()
        showsLoading = false
        let sameFolder = path == folderPath
        if !sameFolder {
            filter = ""
            metadata = [:]
            metadataInflight = []
            metadataQueue = []
            hiddenItemCount = 0
        } else if let changedPaths {
            // The items that changed have their details read again (B-NAV-134).
            for changed in changedPaths { metadata[changed] = nil }
        } else {
            metadata = [:]
        }
        folderPath = path
        loadState = .loaded
        // The same listing read again as it was keeps what is on screen as it is (B-NAV-133).
        let unchanged = sameFolder && newEntries == listed
        listed = newEntries
        rowsByPath = Dictionary(newEntries.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        reorder()
        let existing = Set(newEntries.map(\.path))
        // Nil keeps the selection that still exists (a quiet read); a list of paths is the new selection.
        if let paths {
            setSelection(ContentSelection.of(paths.filter { existing.contains($0) }), notify: true)
        } else {
            setSelection(selection.keeping(existing: existing), notify: true)
        }
        if !unchanged || !keepingScroll {
            pane?.reload(scrollToTop: !keepingScroll)
        } else {
            pane?.refresh(paths: changedPaths.map(Set.init))
        }
        pane?.syncSelection()
        if !selection.isEmpty, let paths, !paths.isEmpty { pane?.reveal(paths: selection.paths) }
        refreshState()
        updateStatus()
        if listed.isEmpty, !includeHidden, !folderPath.isEmpty { loadHiddenCount() }
    }

    /// A folder that could not be read: its error shows, and nothing is selected (B-VIEW-064).
    func showError(folder path: String, message: String) {
        loadingTimer?.cancel()
        showsLoading = false
        if path != folderPath { filter = "" }
        folderPath = path
        listed = []
        entries = []
        rowsByPath = [:]
        metadata = [:]
        loadState = .failed(message: message)
        setSelection(.empty, notify: true)
        pane?.reload(scrollToTop: true)
        refreshState()
        updateStatus()
    }

    /// With no folder at all (B-NAV-117).
    func showNoFolder() {
        folderPath = ""
        listed = []
        entries = []
        loadState = .idle
        setSelection(.empty, notify: true)
        pane?.reload(scrollToTop: true)
        refreshState()
        updateStatus()
    }

    private func loadHiddenCount() {
        let path = folderPath
        Task { @MainActor [weak self] in
            guard let self, let count = Optional(await self.loaders.hiddenCount(path)), path == self.folderPath,
                self.listed.isEmpty
            else { return }
            self.hiddenItemCount = count
            self.refreshState()
        }
    }

    // MARK: Order, filter and the states

    /// How the folder is ordered and shown. The window re-reads the folder for a new order; a size order is finished
    /// here, as folder sizes arrive.
    func setView(sortBy: SortByPreference, direction: SortDirectionPreference, foldersFirst: Bool, includeHidden: Bool)
    {
        self.sortBy = sortBy
        sortDirection = direction
        self.foldersFirst = foldersFirst
        self.includeHidden = includeHidden
        barScaleCache = nil
        pane?.refreshLook()
    }

    func setFilter(_ text: String) {
        guard text != filter else { return }
        filter = text
        reorder()
        let existing = Set(entries.map(\.path))
        setSelection(selection.keeping(existing: existing), notify: true)
        pane?.reload(scrollToTop: true)
        pane?.syncSelection()
        refreshState()
        updateStatus()
    }

    private func reorder() {
        let contents = FolderContents(path: folderPath, listed: listed, filter: filter)
        let sizes = folderSizes
        entries = contents.shown(
            sortBy: sortBy, direction: sortDirection, foldersFirst: foldersFirst
        ) { sizes.readySize($0) }
        barScaleCache = nil
    }

    private func refreshState() {
        let kind: ContentStateKind
        switch loadState {
        case .idle:
            kind = .empty(text: ContentStateText.noFolder)
        case .loading:
            kind = entries.isEmpty && showsLoading ? .loading : .none
        case .failed(let message):
            kind =
                FolderReadFailure.isTrashRefused(path: folderPath, message: message, homePath: loaders.homePath)
                ? .fullDiskAccess : .error(message: message)
        case .loaded:
            if listed.isEmpty {
                kind = .empty(text: ContentStateText.empty(path: folderPath, hiddenItemCount: hiddenItemCount))
            } else if entries.isEmpty, !filter.isEmpty {
                kind = .noMatches(query: filter)
            } else {
                kind = .none
            }
        }
        container.stateView.onSearchSubfolders = onSearchSubfolders
        container.topInset = pane?.contentTopInset ?? 0
        if container.stateView.kind != kind { container.stateView.show(kind, theme: theme) }
    }

    // MARK: Selection

    var selectedEntries: [DirectoryEntry] { selection.paths.compactMap { rowsByPath[$0] } }
    var selectedItems: [DirectoryEntry] { selectedEntries }

    private func setSelection(_ next: ContentSelection, notify: Bool) {
        guard next != selection else { return }
        selection = next
        updateStatus()
        if notify { onSelectionChanged?(next) }
    }

    /// Selects the paths that are listed, bringing them into view.
    func select(paths: [String]) {
        let existing = paths.filter { rowsByPath[$0] != nil }
        setSelection(ContentSelection.of(existing), notify: true)
        pane?.syncSelection()
        pane?.reveal(paths: existing)
    }

    func selectionChanged(_ selection: ContentSelection) {
        setSelection(selection, notify: true)
    }

    /// Focuses the view of the folder.
    func focusList() {
        if let focus = pane?.focusView { view.window?.makeFirstResponder(focus) }
    }

    var focusView: NSView? { pane?.focusView }

    // MARK: Host

    var paneHasKeyboard: Bool { pane?.hasKeyboard ?? false }
    var windowIsActive: Bool {
        guard let window = view.window else { return windowActive }
        #if DEBUG
            // A capture run may not be the app in front, so no window is key: the window then counts as in front,
            // as the original's does in its capture; another window being key still makes this one inactive.
            if Self.isAutomated, NSApp.keyWindow == nil { return true }
        #endif
        return window.isKeyWindow
    }

    private static let isAutomated = CommandLine.arguments.contains("--automation")

    func metadata(for path: String) -> EntryMetadata? { metadata[path] }

    func folderSizeEntry(_ path: String) -> FolderSizeEntry { folderSizes.entry(path) }

    /// Bars show only while the folder is sorted by size (B-INFO-175); the largest size among all of its entries, not
    /// only those on screen (B-INFO-176).
    var sizeBarScale: Int64? {
        guard sortBy == .size else { return nil }
        if let cache = barScaleCache, cache.listedCount == listed.count, cache.version == folderSizes.version {
            return cache.scale
        }
        let contents = FolderContents(path: folderPath, listed: listed)
        let sizes = folderSizes
        let scale = contents.largestSize { sizes.readySize($0) }
        barScaleCache = (listed.count, folderSizes.version, scale)
        return scale
    }

    func sizeBytes(of entry: DirectoryEntry) -> Int64? {
        FolderContents.sizeBytes(of: entry) { folderSizes.readySize($0) }
    }

    func activate(_ entries: [DirectoryEntry], newTab: Bool) {
        onActivate?(entries, newTab)
    }

    func requestSort(_ sortBy: SortByPreference) {
        onSortRequested?(sortBy)
    }

    func sortSetFromOutside(_ sortBy: SortByPreference, ascending: Bool) {
        onSortSetFromOutside?(sortBy, ascending)
    }

    func columnWidthsChanged(_ widths: [DetailColumn: Double]) {
        columnState.widths = widths
        pane?.columnsChanged()
        onColumnWidthsChanged?(widths)
    }

    func contextMenu(for entries: [DirectoryEntry]?) -> NSMenu? {
        contextMenuProvider?(entries)
    }

    /// The columns and the density, from the preferences.
    func setColumns(_ state: ListColumnState) {
        guard state != columnState else { return }
        columnState = state
        pane?.columnsChanged()
    }

    // MARK: Details of the rows on screen

    func requestMetadata(for paths: [String]) {
        for path in paths where metadata[path] == nil && !metadataInflight.contains(path) {
            metadataInflight.insert(path)
            metadataQueue.append(path)
        }
        guard !metadataQueue.isEmpty, !metadataFlushQueued else { return }
        metadataFlushQueued = true
        Task { @MainActor [weak self] in self?.flushMetadata() }
    }

    private func flushMetadata() {
        metadataFlushQueued = false
        let batch = metadataQueue
        metadataQueue = []
        guard !batch.isEmpty else { return }
        let folder = folderPath
        Task { @MainActor [weak self] in
            guard let self else { return }
            let items = await self.loaders.metadata(folder, batch)
            for path in batch { self.metadataInflight.remove(path) }
            guard folder == self.folderPath else { return }
            for item in items { self.metadata[item.path] = item }
            self.pane?.refresh(paths: Set(items.map(\.path)))
            self.updateStatus()
        }
    }

    // MARK: Folder sizes

    private func folderSizesChanged() {
        barScaleCache = nil
        if sortBy == .size, !listed.isEmpty {
            // The list is ordered again as each folder size arrives (B-INFO-181).
            let before = entries.map(\.path)
            reorder()
            if entries.map(\.path) != before {
                pane?.reload(scrollToTop: false)
                pane?.syncSelection()
                updateStatus()
                return
            }
        }
        pane?.refresh(paths: nil)
        updateStatus()
    }

    // MARK: Status

    /// "240 items", "3 of 240 items" while filtered, "2 of 240 selected", then " · size" (B-INFO status summary).
    func updateStatus() {
        let size: StatusSize?
        if selection.isEmpty {
            size = folderPath.isEmpty ? nil : StatusSummary.folderSize(folderSizes.entry(folderPath))
        } else {
            let items = selectedEntries.map {
                SelectionItem(path: $0.path, isFolderSizeEligible: $0.isFolderSizeEligible)
            }
            let summary = SelectionSizing.summarize(
                items,
                fileSize: { [weak self] path in
                    guard let self else { return nil }
                    return self.metadata[path]?.sizeBytes ?? self.rowsByPath[path]?.sizeBytes
                },
                folderSize: { [folderSizes] in folderSizes.entry($0) })
            size = StatusSummary.selectionSize(summary)
        }
        status.stringValue = StatusSummary.content(
            itemCount: listed.count, shownCount: filter.isEmpty ? nil : entries.count,
            selectedCount: selection.paths.count,
            size: size)
        shell.pathBarRow.needsLayout = true
    }
}
