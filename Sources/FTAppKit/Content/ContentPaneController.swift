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
    /// The ring of a pane that takes a drop into the folder on screen (P5-08).
    let dropRing = PaneDropRingView()
    /// What has been typed to narrow the list, floating over its foot.
    let filterPill = ListFilterPillView()
    var topInset = 0.0 {
        didSet { needsLayout = true }
    }
    var backgroundMenu: () -> NSMenu? = { nil }
    var backgroundDrop: (([URL], NSDragOperation) -> Bool)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(stateView)
        addSubview(filterPill)
        addSubview(dropRing)
        setAccessibilityIdentifier("content")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        paneView?.frame = bounds
        stateView.frame = NSRect(x: 0, y: topInset, width: bounds.width, height: max(0, bounds.height - topInset))
        (paneView as? RowsBelowCard)?.roomAboveRows = stateView.roomAboveRows(width: bounds.width)
        dropRing.frame = bounds
        layoutFilterPill()
    }

    /// `.list-filter-pill`: centered, 14 above the foot of the list.
    func layoutFilterPill() {
        guard !filterPill.isHidden else { return }
        let size = filterPill.fittingSize(in: bounds.width)
        filterPill.frame = NSRect(
            x: (bounds.width - size.width) / 2,
            y: bounds.height - CGFloat(SelectionLayout.FilterPill.bottom) - size.height, width: size.width,
            height: size.height)
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
    /// The items on the clipboard the rows mark, and the drop target a drag is over (P5-08).
    var clipboardMarks: ClipboardMarks?
    var dropTarget: (path: String, state: DropTargetState)?
    var onSearchSubfolders: (() -> Void)?
    /// The keys of the commands, as Settings has them (the window wires its own).
    var shortcutsProvider: () -> ResolvedShortcuts = { ShortcutCommands.defaultResolved }
    /// Return with an item selected (Open or Rename, as the Return key setting says), Tab, and a command the window runs
    /// for a key the menu does not listen for.
    var onReturn: (() -> Void)?
    var onSwitchPane: (() -> Void)?
    var onCommand: ((ShortcutCommandID) -> Bool)?
    /// A name was typed into the rename field: the window carries the rename out (and answers with `finishRename` or
    /// `refuseRename`).
    var onRenameSubmit: ((_ path: String, _ name: String) -> Void)?
    /// A rename began or ended (the folder watch holds outside changes while one is under way, B-SEL-139).
    var onRenameStateChanged: (() -> Void)?
    /// The rename's item left the list while a refusal was showing: the refusal is said some other way (B-SEL-140).
    var onRenameLost: ((_ path: String, _ refusal: String?) -> Void)?
    /// The selection, its details or a folder size changed: the Info views describe it again (P5-06).
    var onDetailsChanged: (() -> Void)?
    /// A List header asked for the search results to be ordered by a column (P5-07).
    var onSearchSort: ((SearchResultsSortByPreference) -> Void)?
    var onSearchSortSet: ((SearchResultsSortByPreference, SortDirectionPreference) -> Void)?
    /// The text narrowing the list changed (typed into the results, or cleared): the results bar's field mirrors it.
    var onFilterChanged: ((String) -> Void)?

    // MARK: State

    let folderSizes: WindowFolderSizes
    private(set) var mode: ExplorerViewMode
    private(set) var folderPath = ""
    private(set) var listed: [DirectoryEntry] = []
    private(set) var entries: [DirectoryEntry] = []
    private(set) var selection = ContentSelection.empty
    private(set) var loadState = ContentLoadState.idle
    /// A Go To that couldn't read its folder (`directoryError` over the folder still shown): the error card shows over
    /// the items until the next folder is read.
    private(set) var readError: String?
    private(set) var hiddenItemCount = 0
    private(set) var sortBy = SortByPreference.name
    private(set) var sortDirection = SortDirectionPreference.asc
    private(set) var foldersFirst = true
    private(set) var includeHidden = false
    private(set) var columnState = ListColumnState.standard
    private(set) var listFilter = ListFilterTyping()
    /// The filter typed matches nothing: the state says so in place of the view.
    private var nothingMatches = false
    var filter: String { listFilter.query }
    private(set) var inlineRename: InlineRenameState?
    private var renameSessions = 0
    private(set) var entryPaths: [String] = []
    private var positionsCache: [String: Int]?
    private var metadata: [String: EntryMetadata] = [:]
    private var metadataInflight = Set<String>()
    /// Items that changed on disk: they keep what is shown until their details are read again.
    private(set) var staleMetadata = Set<String>()
    private var metadataQueue: [String] = []
    private var metadataFlushQueued = false
    private var showsLoading = false
    private var loadingTimer: DispatchWorkItem?
    private var windowActive = true
    /// The listed entries by path, made when a selection or a lookup needs it (not for every folder opened).
    private var rowsCache: [String: DirectoryEntry]?
    private var rowsByPath: [String: DirectoryEntry] {
        if let rowsCache { return rowsCache }
        let made = Dictionary(listed.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        rowsCache = made
        return made
    }
    private var barScaleCache: (listedCount: Int, version: Int, scale: Int64?)?
    /// While search results show (P5-07): what is shown in place of the folder, and the folder as it was, which comes
    /// back when the results are put away.
    private(set) var searchDisplay: ContentSearchDisplay?
    private(set) var search: ContentSearchContext?
    private var keptFolder: KeptFolder?

    private struct KeptFolder {
        var listed: [DirectoryEntry]
        var loadState: ContentLoadState
        var hiddenItemCount: Int
        var metadata: [String: EntryMetadata]
        var staleMetadata: Set<String>
        var scroll: (top: Double, left: Double)
    }
    private var observation: AppearanceModel.Observation?
    private var windowObservers: [any NSObjectProtocol] = []

    private(set) var pane: (any FolderPane)?
    let container = ContentContainerView()
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

    /// The Info Row slides open or closed (220 ms) unless the window is only being restored.
    func setInfoRowOpen(_ open: Bool, animated: Bool = false) {
        shell.infoRow.setOpen(open, animated: animated && shell.window != nil)
        shell.needsLayout = true
    }

    override func loadView() {
        shell.list = container
        container.backgroundMenu = { [weak self] in self?.contextMenu(for: nil) }
        container.backgroundDrop = { [weak self] urls, allowed in
            self?.dragHooks.acceptDrop?(urls, nil, allowed) ?? false
        }
        container.stateView.onOpenPrivacySettings = { [weak self] in self?.loaders.openPrivacySettings() }
        // The pill's ✕ brings the list back as Esc does; the list keeps the keyboard (`onClearFilter`).
        container.filterPill.onClear = { [weak self] in self?.clearFilter() }
        container.stateView.onSearchSubfolders = onSearchSubfolders
        shell.onMovedToWindow = { [weak self] window in self?.observeWindow(window) }
        loaders.iconStore()?.preloadGenericIcons()
        // The date formatters take a few milliseconds to make: they are made off the main thread, before a row needs them.
        Task.detached(priority: .utility) {
            _ = DateText.shared
            _ = ISODate.parse("2026-01-01T00:00:00.000Z")
        }
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
                // The window weakly: the center holds this block until the pane goes, and the pane may outlive it.
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) {
                    [weak self, weak window] _ in
                    MainActor.assumeIsolated {
                        guard let self, let window else { return }
                        self.windowActive = window.isKeyWindow
                        self.pane?.refreshLook()
                        // Only coming back: the dates of a window just left are as current as they were.
                        if window.isKeyWindow { RelativeClock.shared.windowStateDidChange() }
                    }
                })
        }
    }

    private func lookChanged() {
        pane?.refreshLook()
        updateFilterPill()
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
        next.showNothingMatches(nothingMatches)
        container.topInset = nothingMatches ? 0 : next.contentTopInset
        next.view.frame = container.bounds
    }

    // MARK: A folder

    /// A folder is being read. Its predecessor stays on screen until it arrives; with nothing on screen the loading
    /// card shows after 400 ms.
    func beginLoading(quiet: Bool) {
        // The message goes as the read starts, not when it ends (B-NAV-113).
        let messageWent = !quiet && readError != nil
        defer { if messageWent { refreshState() } }
        if !quiet { readError = nil }
        guard !quiet, searchDisplay == nil else { return }
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

    /// A Go To that couldn't be read: the folder on screen stays, with "Couldn’t open this folder" and `message` over
    /// it (B-NAV-110).
    func showReadError(_ message: String) {
        cancelLoading()
        readError = message
        refreshState()
    }

    /// The folder on screen as it looks now: what is selected and where the list is scrolled, for Back and Forward to
    /// show it that way again (`captureFolderView`).
    func captureFolderView() -> FolderViewMemory? {
        guard !folderPath.isEmpty, loadState != .idle else { return nil }
        let position = pane?.scrollPosition ?? (top: 0.0, left: 0.0)
        return FolderViewMemory(selection: selection, scrollTop: position.top, scrollLeft: position.left)
    }

    /// Shows a folder that was read. `selecting` is what to select (those that exist); `keepingScroll` for the same
    /// folder read again; `restoring` is how the folder looked when it was left (Back, Forward): its selection, trimmed
    /// to what is still there, and its scroll position.
    func show(
        folder path: String, entries newEntries: [DirectoryEntry], selecting paths: [String]?, keepingScroll: Bool,
        changedPaths: [String]? = nil, restoring memory: FolderViewMemory? = nil
    ) {
        readError = nil
        // The folder read again under search results (hidden files, a change on disk) waits for them to close.
        if searchDisplay != nil, var kept = keptFolder, path == folderPath {
            kept.listed = newEntries
            kept.loadState = .loaded
            if changedPaths == nil { kept.staleMetadata = Set(kept.metadata.keys) }
            keptFolder = kept
            return
        }
        loadingTimer?.cancel()
        showsLoading = false
        let sameFolder = path == folderPath
        if !sameFolder {
            listFilter.clear()
            metadata = [:]
            staleMetadata = []
            metadataInflight = []
            metadataQueue = []
            hiddenItemCount = 0
        } else if let changedPaths {
            // The items that changed have their details read again (B-NAV-134).
            staleMetadata.formUnion(changedPaths.filter { metadata[$0] != nil })
        } else {
            staleMetadata = Set(metadata.keys)
        }
        folderPath = path
        loadState = .loaded
        // The same listing read again as it was keeps what is on screen as it is (B-NAV-133).
        let kept =
            sameFolder
            ? DirectoryListingDiff.keepUnchanged(shown: listed, next: newEntries, path: \.path) : nil
        let unchanged = kept?.isUnchanged == true
        let previousPaths = entryPaths
        listed = newEntries
        rowsCache = nil
        reorder()
        // Nil keeps the selection that still exists (a quiet read); a list of paths is the new selection.
        if let memory {
            // Back and Forward restore the exact selection, checked against the listing read now: what is gone drops,
            // and no gap is kept (B-NAV-048, B-NAV-049).
            var restored = memory.selection.sanitized(entryPaths: entryPaths)
            restored.gapIndex = nil
            setSelection(restored, notify: true)
        } else if let paths {
            let lookup = paths.isEmpty ? [:] : rowsByPath
            setSelection(ContentSelection.of(paths.filter { lookup[$0] != nil }), notify: true)
        } else {
            resanitizeSelection(previousPaths: previousPaths)
        }
        closeRenameIfItemLeft()
        if let kept, !unchanged, keepingScroll, inlineRename == nil, previousPaths == entryPaths {
            // The same rows in the same order: only the rows of the items that changed are drawn again.
            pane?.reloadRows(paths: Set(kept.changedPaths))
        } else if !unchanged || !keepingScroll {
            pane?.reload(scrollToTop: !keepingScroll)
        } else {
            pane?.refresh(paths: changedPaths.map(Set.init))
        }
        pane?.syncSelection()
        if let memory { pane?.scrollPosition = (memory.scrollTop, memory.scrollLeft) }
        refreshState()
        updateStatus()
        if listed.isEmpty, !includeHidden, !folderPath.isEmpty { loadHiddenCount() }
    }

    /// A folder that could not be read: its error shows, and nothing is selected (B-VIEW-064).
    func showError(folder path: String, message: String) {
        if searchDisplay != nil, var kept = keptFolder, path == folderPath {
            kept.listed = []
            kept.loadState = .failed(message: message)
            keptFolder = kept
            return
        }
        loadingTimer?.cancel()
        showsLoading = false
        readError = nil
        if path != folderPath { listFilter.clear() }
        folderPath = path
        listed = []
        entries = []
        entryPaths = []
        positionsCache = nil
        rowsCache = nil
        metadata = [:]
        loadState = .failed(message: message)
        setSelection(.empty, notify: true)
        closeRenameIfItemLeft()
        pane?.reload(scrollToTop: true)
        refreshState()
        updateStatus()
    }

    /// With no folder at all (B-NAV-117).
    func showNoFolder() {
        folderPath = ""
        readError = nil
        metadata = [:]
        staleMetadata = []
        metadataInflight = []
        metadataQueue = []
        listed = []
        entries = []
        entryPaths = []
        positionsCache = nil
        loadState = .idle
        setSelection(.empty, notify: true)
        closeRenameIfItemLeft()
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

    /// Sets the whole filter text at once (the toolbar's field, until the search is its own); the selection stays.
    func setFilter(_ text: String) {
        guard text != filter else { return }
        listFilter.set(text, at: ProcessInfo.processInfo.systemUptime)
        refilter(previousPaths: entryPaths)
    }

    /// Esc, the ✕, or leaving the folder: the whole list returns and the selection is kept, so something found by
    /// filtering can then be seen among its neighbours.
    func clearFilter() {
        guard !filter.isEmpty else { return }
        let previous = entryPaths
        listFilter.clear()
        onFilterChanged?(filter)
        refilter(previousPaths: previous)
    }

    private func refilter(previousPaths: [String]) {
        reorder()
        resanitizeSelection(previousPaths: previousPaths)
        pane?.reload(scrollToTop: false)
        pane?.syncSelection()
        refreshState()
        updateStatus()
    }

    /// A key typed into the list: the text narrows it and selects the first name that starts with it, otherwise the
    /// first match (`applyListFilter`); Backspace takes a character back; Esc brings the list back.
    func applyFilterKey(_ key: ListFilterKey) {
        let now = ProcessInfo.processInfo.systemUptime
        switch key {
        case .clear:
            clearFilter()
            return
        case .type(let text):
            listFilter.type(text, at: now)
        case .erase:
            listFilter.eraseCharacter(at: now)
        }
        onFilterChanged?(filter)
        reorder()
        pane?.reload(scrollToTop: false)
        refreshState()
        guard !filter.isEmpty else {
            pane?.syncSelection()
            updateStatus()
            return
        }
        let match = ListFilter.selection(in: entries, query: filter)
        setSelection(match.map { ContentSelection.single($0.path) } ?? .empty, notify: true)
        pane?.syncSelection()
        updateStatus()
    }

    private func reorder() {
        if let searchDisplay {
            // Results narrow by name or by the folder they are in; their order is the search's own.
            let filtered = ListFilter.filterSearchResults(searchDisplay.results, query: filter)
            entries = filter.isEmpty ? listed : filtered.map(SearchResults.entry)
            entryPaths = entries.map(\.path)
            positionsCache = nil
            barScaleCache = nil
            updateFilterPill()
            return
        }
        let contents = FolderContents(path: folderPath, listed: listed, filter: filter)
        let sizes = folderSizes
        entries = contents.shown(
            sortBy: sortBy, direction: sortDirection, foldersFirst: foldersFirst
        ) { sizes.readySize($0) }
        entryPaths = entries.map(\.path)
        positionsCache = nil
        barScaleCache = nil
        updateFilterPill()
    }

    private func updateFilterPill() {
        // Search results are narrowed in the results bar's own field.
        container.filterPill.show(
            query: searchDisplay == nil ? filter : "", shown: entries.count, total: listed.count, theme: theme)
        container.layoutFilterPill()
    }

    private func refreshState() {
        var kind: ContentStateKind
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
        if let readError {
            kind =
                FolderReadFailure.isTrashRefused(path: folderPath, message: readError, homePath: loaders.homePath)
                ? .fullDiskAccess : .error(message: readError)
        }
        if let searchDisplay {
            kind =
                SearchResultsState.make(
                    isRunning: searchDisplay.isRunning, shownCount: entries.count, totalCount: listed.count,
                    error: searchDisplay.error, errorIsQuiet: searchDisplay.errorIsQuiet, filterQuery: filter
                ).map { .search($0) } ?? .none
        }
        container.stateView.onSearchSubfolders = onSearchSubfolders
        // A filter nothing matches is said in place of the whole view, the List's column header too (ContentPane.tsx
        // renders it instead of the view).
        if case .noMatches = kind { nothingMatches = true } else { nothingMatches = false }
        pane?.showNothingMatches(nothingMatches)
        container.topInset = nothingMatches ? 0 : pane?.contentTopInset ?? 0
        if container.stateView.kind != kind {
            container.stateView.show(kind, theme: theme)
            container.needsLayout = true
        }
    }

    // MARK: Selection

    var selectedEntries: [DirectoryEntry] { selection.paths.compactMap { rowsByPath[$0] } }
    var selectedItems: [DirectoryEntry] { selectedEntries }

    func position(of path: String?) -> Int? {
        guard let path else { return nil }
        if let positionsCache { return positionsCache[path] }
        var made: [String: Int] = [:]
        made.reserveCapacity(entryPaths.count)
        for (index, entryPath) in entryPaths.enumerated() where made[entryPath] == nil { made[entryPath] = index }
        positionsCache = made
        return made[path]
    }

    private func setSelection(_ next: ContentSelection, notify: Bool) {
        guard next != selection else { return }
        selection = next
        pane?.syncSelection()
        updateStatus()
        if notify { onSelectionChanged?(next) }
    }

    /// Whenever the visible entries change (a folder, a sort, a filter), every selected path that is no longer in the
    /// list is dropped, and a selection whose items all left keeps their place for the arrow keys. A renamed, pasted or
    /// new item outside the filter is selected on purpose, and is kept (B-SEL-024 to B-SEL-028).
    private func resanitizeSelection(previousPaths: [String]) {
        guard !selection.isEmpty || selection.gapIndex != nil else { return }
        if let lead = selection.leadPath, position(of: lead) == nil, rowsByPath[lead] != nil { return }
        setSelection(selection.sanitized(entryPaths: entryPaths, previousPaths: previousPaths), notify: true)
    }

    /// Selects the paths that are listed; the view keeps their lead in view (`RevealKeeper`). An item the filter hides is shown: the filter is
    /// cleared (B-SEL-080).
    func select(paths: [String]) {
        let existing = paths.filter { rowsByPath[$0] != nil }
        let selecting = ContentSelection.of(existing)
        if let lead = selecting.leadPath, position(of: lead) == nil, !filter.isEmpty {
            listFilter.clear()
            reorder()
            pane?.reload(scrollToTop: false)
            refreshState()
        }
        setSelection(selecting, notify: true)
        pane?.syncSelection()
    }

    /// The pane reports a selection from a click, a key or the marquee: the lead is brought into view when it changes.
    func selectionChanged(_ selection: ContentSelection) {
        setSelection(selection, notify: true)
    }

    /// ⌘A with the list focused: every entry on screen (only the matching ones while a filter is typed).
    func selectAllEntries() {
        selectionChanged(.all(entryPaths: entryPaths))
    }

    /// Focuses the view of the folder.
    func focusList() {
        if let focus = pane?.focusView { view.window?.makeFirstResponder(focus) }
    }

    var focusView: NSView? { pane?.focusView }

    // MARK: Keys

    var shortcuts: ResolvedShortcuts { shortcutsProvider() }

    func pressedReturn() { onReturn?() }

    func switchPane() { onSwitchPane?() }

    func runCommand(_ command: ShortcutCommandID) -> Bool { onCommand?(command) ?? false }

    // MARK: Rename

    /// Starts renaming the item in its row. The item is shown first: one the filter hides clears the filter
    /// (B-SEL-124). Whether the item is listed.
    @discardableResult
    func beginRename(path: String) -> Bool {
        guard rowsByPath[path] != nil else { return false }
        if position(of: path) == nil, !filter.isEmpty {
            listFilter.clear()
            reorder()
            pane?.reload(scrollToTop: false)
            refreshState()
        }
        renameSessions += 1
        inlineRename = InlineRenameState(path: path, error: nil, refusalCount: 0, sessionID: renameSessions)
        pane?.syncRename()
        onRenameStateChanged?()
        return true
    }

    func renameSubmitted(_ name: String) {
        guard let rename = inlineRename else { return }
        onRenameSubmit?(rename.path, name)
    }

    func renameCancelled() { endRename() }

    /// The name was refused: the field stays open with the reason under it.
    func refuseRename(_ message: String) {
        guard var rename = inlineRename else { return }
        rename.error = message
        rename.refusalCount += 1
        inlineRename = rename
        pane?.syncRename()
    }

    /// The rename is over (done, cancelled, or its item left).
    func endRename() {
        guard inlineRename != nil else { return }
        inlineRename = nil
        pane?.syncRename()
        refreshRows()
        onRenameStateChanged?()
    }

    private func refreshRows() {
        pane?.refresh(paths: nil)
    }

    /// A rename field whose item has left the list (another folder opened, the item removed) closes; a refusal it was
    /// showing is said in a dialog so it is not lost (B-SEL-140).
    private func closeRenameIfItemLeft() {
        guard let rename = inlineRename, rowsByPath[rename.path] == nil else { return }
        let refusal = rename.error
        endRename()
        onRenameLost?(rename.path, refusal)
    }

    // MARK: Search results

    /// Shows search results in place of the folder (P5-07), or shows them again as they changed. The folder is kept
    /// as it was, to come back when they are put away. A new query or root starts the list at the top and drops the
    /// filter and the details read so far; the selection is the search session's to apply.
    func showSearch(_ display: ContentSearchDisplay) {
        let entering = searchDisplay == nil
        let newList = entering || searchDisplay?.viewKey != display.viewKey
        if entering {
            loadingTimer?.cancel()
            showsLoading = false
            keptFolder = KeptFolder(
                listed: listed, loadState: loadState == .loading ? stateBeforeLoading : loadState,
                hiddenItemCount: hiddenItemCount, metadata: metadata, staleMetadata: staleMetadata,
                scroll: pane?.scrollPosition ?? (0, 0))
        }
        if newList {
            if !filter.isEmpty {
                listFilter.clear()
                onFilterChanged?(filter)
            }
            metadata = [:]
            staleMetadata = []
            metadataInflight = []
            metadataQueue = []
        }
        searchDisplay = display
        search = ContentSearchContext(
            display: display, requestSort: { [weak self] key in self?.onSearchSort?(key) },
            setSort: { [weak self] key, direction in self?.onSearchSortSet?(key, direction) })
        loadState = .loaded
        let previousPaths = entryPaths
        listed = display.results.map(SearchResults.entry)
        rowsCache = nil
        reorder()
        // The views see the results' columns and order.
        if newList || previousPaths != entryPaths {
            selection = selection.sanitized(entryPaths: entryPaths)
            pane?.reload(scrollToTop: newList)
        } else {
            pane?.refreshLook()
        }
        pane?.syncSelection()
        refreshState()
        updateStatus()
    }

    /// The results are put away: the folder comes back as it was, scrolled where it was.
    func endSearch() {
        guard searchDisplay != nil else { return }
        let kept = keptFolder
        searchDisplay = nil
        search = nil
        keptFolder = nil
        if !filter.isEmpty {
            listFilter.clear()
            onFilterChanged?(filter)
        }
        listed = kept?.listed ?? []
        loadState = kept?.loadState ?? .idle
        hiddenItemCount = kept?.hiddenItemCount ?? 0
        metadata = kept?.metadata ?? [:]
        staleMetadata = kept?.staleMetadata ?? []
        metadataInflight = []
        metadataQueue = []
        rowsCache = nil
        reorder()
        selection = selection.sanitized(entryPaths: entryPaths)
        pane?.reload(scrollToTop: false)
        if let scroll = kept?.scroll { pane?.scrollPosition = scroll }
        pane?.syncSelection()
        refreshState()
        updateStatus()
    }

    /// The results bar's filter field: every change selects one result, the first whose name starts with the text,
    /// else the first match (`setListFilter`).
    func setSearchFilter(_ text: String) {
        guard text != filter else { return }
        listFilter.set(text, at: ProcessInfo.processInfo.systemUptime)
        reorder()
        pane?.reload(scrollToTop: false)
        refreshState()
        let match = ListFilter.selection(in: entries, query: filter)
        setSelection(match.map { ContentSelection.single($0.path) } ?? .empty, notify: true)
        pane?.syncSelection()
        updateStatus()
    }

    /// Applies a selection to the list on screen (`applyContentSelection`), bringing its lead into view.
    func applySelection(_ next: ContentSelection) {
        setSelection(next, notify: true)
        pane?.syncSelection()
    }

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
        guard sortBy == .size, searchDisplay == nil else { return nil }
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

    func clipboardMark(for path: String) -> ContentClipboardMark? {
        clipboardMarks?.mark(for: path).map { $0.isCut ? .cut : .copy }
    }

    /// The columns and the density, from the preferences.
    func setColumns(_ state: ListColumnState) {
        guard state != columnState else { return }
        columnState = state
        pane?.columnsChanged()
    }

    // MARK: Details of the rows on screen

    /// Whether the details of rows asked for are still being read.
    var isReadingDetails: Bool { !metadataInflight.isEmpty }

    func requestMetadata(for paths: [String]) {
        for path in paths
        where (metadata[path] == nil || staleMetadata.contains(path)) && !metadataInflight.contains(path) {
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
        guard searchDisplay != nil else {
            readMetadata(in: folderPath, batch)
            return
        }
        // Results are spread over many folders: one batch per folder (`directory:getMetadataBatch`), each shown as it
        // comes, so a slow folder keeps only its own rows waiting (`loadSearchResultMetadata`).
        var byFolder: [String: [String]] = [:]
        var order: [String] = []
        for path in batch {
            let parent = NodePath.dirname(path)
            if byFolder[parent] == nil { order.append(parent) }
            byFolder[parent, default: []].append(path)
        }
        for parent in order { readMetadata(in: parent, byFolder[parent] ?? []) }
    }

    private func readMetadata(in folder: String, _ paths: [String]) {
        let listKey = searchDisplay?.viewKey ?? folderPath
        Task { @MainActor [weak self] in
            guard let self else { return }
            let items = await self.loaders.metadata(folder, paths)
            for path in paths { self.metadataInflight.remove(path) }
            guard listKey == (self.searchDisplay?.viewKey ?? self.folderPath) else { return }
            for item in items {
                self.metadata[item.path] = item
                self.staleMetadata.remove(item.path)
            }
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
        if selection.isEmpty, searchDisplay != nil {
            size = nil
        } else if selection.isEmpty {
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
        if let searchDisplay {
            status.stringValue = StatusSummary.search(
                isSearching: searchDisplay.isRunning, shown: entries.count, totalCount: listed.count,
                selectedCount: selection.paths.count, selectionSize: size)
        } else {
            status.stringValue = StatusSummary.content(
                itemCount: listed.count, shownCount: filter.isEmpty ? nil : entries.count,
                selectedCount: selection.paths.count,
                size: size)
        }
        shell.pathBarRow.needsLayout = true
        onDetailsChanged?()
    }
}
