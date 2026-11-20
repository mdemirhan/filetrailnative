// The entries and their details, the order, the folder sizes and size bars, and the selection
import AppKit
import FTFileSystem
import FTFoundation

/// The part of the window's services the pane reads from.
struct ContentLoaders {
    /// Until the window wires its own.
    static let placeholder = ContentLoaders(
        metadata: { _, _, _ in [] }, hiddenCount: { _ in 0 }, iconStore: { nil },
        homePath: FileManager.default.homeDirectoryForCurrentUser.path, openPrivacySettings: {})

    /// The details of items in the folder. `listedAdded` has the Date Added the folder read gave each of them that came
    /// from a listing; the others are asked for theirs.
    var metadata:
        @MainActor (_ folder: String, _ paths: [String], _ listedAdded: [String: Int64?]) async -> [EntryMetadata]
    /// How many items a folder has with hidden files shown.
    var hiddenCount: @MainActor (_ folder: String) async -> Int
    var iconStore: @MainActor () -> FileIconStore?
    var homePath: String
    var openPrivacySettings: @MainActor () -> Void
    /// The value of a field for each of the paths, in their order: what search results ordered or grouped by a date,
    /// the size or the tags read for every result.
    var values: @MainActor (_ paths: [String], _ field: ItemValueField) async -> [ItemValue] = { paths, _ in
        paths.map { _ in .number(nil) }
    }
    /// The colors of items' Finder tags.
    var tagColors: @MainActor (_ paths: [String]) async -> [String: [FinderTagColor]] = { paths in
        await BlockingWork.run(qos: .utility) {
            Dictionary(uniqueKeysWithValues: paths.map { ($0, FinderTags.colors($0)) })
        }
    }
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
    /// The ring of a pane that takes a drop into the folder on screen.
    let dropRing = PaneDropRingView()
    /// What has been typed to narrow the list, in a bar across its foot.
    let filterBar = ListFilterBarView()
    var topInset = 0.0 {
        didSet { needsLayout = true }
    }
    var backgroundMenu: () -> NSMenu? = { nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(stateView)
        addSubview(filterBar)
        addSubview(dropRing)
        setAccessibilityIdentifier("content")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        layoutFilterBar()
        (paneView as? RowsBelowCard)?.roomAboveRows = stateView.roomAboveRows(width: bounds.width)
        dropRing.frame = bounds
    }

    /// The view and the states end above the filter bar while it shows, so nothing in the list is under it. Done at
    /// once when a filter comes or goes, so the selection is brought into view in the list's new height.
    func layoutFilterBar() {
        let bar = filterBar.isShowingFilter ? min(bounds.height, CGFloat(ListFilterBarView.height)) : 0
        let above = max(0, bounds.height - bar)
        paneView?.frame = NSRect(x: 0, y: 0, width: bounds.width, height: above)
        stateView.frame = NSRect(x: 0, y: topInset, width: bounds.width, height: max(0, above - topInset))
        filterBar.frame = NSRect(x: 0, y: above, width: bounds.width, height: bar)
    }

    override func menu(for event: NSEvent) -> NSMenu? { backgroundMenu() }
}

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
    /// The List header's right-click menu, for the column clicked (nil: between columns).
    var onHeaderMenu: ((DetailColumn?) -> NSMenu?)?
    var onColumnMoved: ((DetailColumn, DetailColumn?) -> Void)?
    var onCompactListWidthChanged: ((Density, Int) -> Void)?
    var onIconSizeChanged: ((Density, Int) -> Void)?
    var onPreviewCountChanged: ((Density, Int) -> Void)?
    /// The keys the size slider's tooltip names, as chosen in Settings.
    var sizeShortcuts = ShortcutDisplay.defaults {
        didSet { if sizeShortcuts != oldValue { syncSizeSlider() } }
    }
    /// The menu for a right-click on items or on the background.
    var contextMenuProvider: (([DirectoryEntry]?) -> NSMenu?)?
    var dragHooks = ContentDragHooks()
    /// The items on the clipboard the rows mark, and the drop target a drag is over.
    var clipboardMarks: ClipboardMarks?
    var dropTarget: (path: String, state: DropTargetState)?
    var onSearchSubfolders: (() -> Void)?
    /// The filter bar's other mode was chosen: that way of matching is wanted in this view.
    var onToggleFilterMode: (() -> Void)?
    /// The keys of the commands, as Settings has them (the window wires its own).
    var shortcutsProvider: () -> ResolvedShortcuts = { ShortcutCommands.defaultResolved }
    /// Return with an item selected (Open or Rename, as the Return key setting says), Tab, and a command the window runs
    /// for a key the menu does not listen for.
    var onReturn: (() -> Void)?
    var onSwitchPane: (() -> Void)?
    var onCommand: ((ShortcutCommandID) -> Bool)?
    /// A name was typed into the rename field: the window carries the rename out (and answers with `endRename` or
    /// `refuseRename`).
    var onRenameSubmit: ((_ path: String, _ name: String) -> Void)?
    /// A rename began or ended (the folder watch holds outside changes while one is under way).
    var onRenameStateChanged: (() -> Void)?
    /// The rename's item left the list while a refusal was showing: the refusal is said some other way.
    var onRenameLost: ((_ path: String, _ refusal: String?) -> Void)?
    /// The selection, its details or a folder size changed: the Info views describe it again.
    var onDetailsChanged: (() -> Void)?
    /// A List header asked for the search results to be ordered by a column.
    var onSearchSort: ((SearchResultsSortByPreference) -> Void)?
    var onSearchSortSet: ((SearchResultsSortByPreference, SortDirectionPreference) -> Void)?
    /// The text narrowing the list changed (typed into the results, or cleared): the results bar's field mirrors it.
    var onFilterChanged: ((String) -> Void)?
    /// The filter was typed, cleared, pinned or unpinned: Pin Filter follows.
    var onFilterStateChanged: (() -> Void)?

    // MARK: State

    let folderSizes: WindowFolderSizes
    private(set) var mode: ExplorerViewMode
    private(set) var folderPath = ""
    private(set) var listed: [DirectoryEntry] = [] {
        didSet {
            sourceVersion &+= 1
            // Names and, over search results, the folders they are in: no more than the list holds.
            foldedNames.limit = max(Self.foldedNamesFloor, listed.count * 2)
        }
    }
    private(set) var entries: [DirectoryEntry] = []
    private(set) var selection = ContentSelection.empty
    /// What the pane shows in place of items: `loading` while a read is under way, otherwise what the last one
    /// settled on.
    var loadState: ContentLoadState { loading == nil ? settled : .loading }
    /// What the last read settled on, kept while the next one is under way: a read that opens nothing goes back to it.
    private var settled = ContentLoadState.idle
    /// A read under way that isn't quiet. With nothing on screen the loading card shows after a moment.
    private var loading: Loading?

    private struct Loading {
        var cardShown = false
        var timer: TimerToken?
    }
    /// What waits out the Loading… delay; tests move it by hand.
    var timers: any TimerScheduling = TaskTimerScheduler()
    /// A Go To that couldn't read its folder (`directoryError` over the folder still shown): the error card shows over
    /// the items until the next folder is read.
    private(set) var readError: FolderReadError?
    private(set) var hiddenItemCount = 0
    private(set) var sortBy = SortByPreference.name
    private(set) var sortDirection = SortDirectionPreference.asc
    private(set) var foldersFirst = true
    /// What the folder's items are grouped by, and search results by (View ▸ Group By).
    private(set) var groupBy = GroupByPreference.none
    private(set) var searchGroupBy = GroupByPreference.none
    /// The groups in the reverse of their order (View ▸ Group By ▸ Reverse Group Order), the folder's and the results'.
    private(set) var groupReversed = false
    private(set) var searchGroupReversed = false
    /// Whether the groups on screen are reversed: search results' own while they show.
    var activeGroupReversed: Bool { searchDisplay != nil ? searchGroupReversed : groupReversed }
    /// What the list on screen is grouped by: search results' own while they show.
    var activeGroupBy: GroupByPreference { searchDisplay != nil ? searchGroupBy : groupBy }
    /// The groups shown, in order, each with where its items are in `entries`; none while nothing is grouped.
    private(set) var groups: [ShownGroup] = []
    private var dayObserver: (any NSObjectProtocol)?
    /// The day the date groups count from; tests move it.
    var now: () -> Date = { AppClock.now }
    /// What search results are ordered or grouped by and don't carry, read for every result while it is needed.
    private(set) var searchValues = SearchValues(read: { paths, _ in paths.map { _ in .number(nil) } })
    private(set) var includeHidden = false
    private(set) var columnState = ListColumnState.standard
    private(set) var listFilter = ListFilterTyping()
    /// The view's own mode, which its next filter starts in, and the mode of the filter typed now. A view takes the
    /// mode new views start with when it opens (a pane, a tab, a window, the results of a new search); after that only
    /// its own Fuzzy and Contains change it, never the setting or another view.
    private(set) var viewFilterMode = NameMatchMode.fuzzy
    private var typedFilterMode = NameMatchMode.fuzzy
    /// The typed filter's mode, or with none typed the view's.
    var filterMode: NameMatchMode { filter.isEmpty ? viewFilterMode : typedFilterMode }
    /// The filter as it finds names, and the marks it gave names, kept until the text or the mode changes.
    private var filterMatcher: NameMatcher?
    private var filterMarks: [StoredName: [HighlightRange]] = [:]
    /// The filter typed matches nothing: the state says so in place of the view.
    private var nothingMatches = false
    var filter: String { listFilter.query }
    /// The filter pinned to the pane: it holds through Esc, other folders and searches, shows every folder, and turns
    /// typing into type-to-select.
    private(set) var pinnedFilter: PinnedListFilter?
    private var typedToSelect = ListTypeToSelect()
    private(set) var inlineRename: InlineRenameState?
    /// Counted for the whole app, not per tab: the drafts of renames are kept by this number, and a rename left open in
    /// one tab must not lend what was typed to another tab's.
    private static var renameSessions = 0
    private(set) var entryPaths: [String] = []
    private var positionsCache: [String: Int]?
    /// The details of the rows asked for. They start over with another folder or other search results.
    private var details = PathReadCache<EntryMetadata>()
    /// Items that changed on disk: they keep what is shown until their details are read again.
    var staleMetadata: Set<String> { details.stale }
    /// Details asked for and not sent yet: they go together, a batch per folder, once the rows have all asked.
    private var metadataQueue: [String] = []
    /// The Date Added of the folder's rows asked for by their entries, as their listing gave it, until they are read:
    /// so the rows on screen are not looked up among all of the folder's.
    private var queuedAdded: [String: Int64?] = [:]
    private var metadataFlushQueued = false
    /// The Finder tags of the rows on screen. They start over with another folder.
    private var tags = PathReadCache<[FinderTagColor]>()
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
    /// The order on screen just before a write or a drag took items away. Their sizes are forgotten first, and a size
    /// order puts a folder without one at the end, so where a selected one stood is counted in this order instead.
    /// Used once, by the selection letting go of what left, and dropped when the selection changes.
    private var orderBeforeRemoval: [String]?
    /// While search results show: what is shown in place of the folder, and the folder as it was, which comes
    /// back when the results are put away.
    private(set) var searchDisplay: ContentSearchDisplay? {
        didSet { sourceVersion &+= 1 }
    }
    /// Counts the changes to what the filter looks through (the folder's items, the search's results), so a narrowing
    /// filter knows whether what it kept still stands.
    private var sourceVersion = 0
    /// What the filter kept last: for the text, mode and source it was made from. Text that only grows narrows these.
    private var lastFiltered: (text: String, mode: NameMatchMode, version: Int, results: [SearchResultItem]?)?
    /// The names beyond ASCII the filter folded, for the folder or search results on screen: let go of with them.
    let foldedNames = FoldedNameCache(limit: ContentPaneController.foldedNamesFloor)
    private static let foldedNamesFloor = 1_000
    private(set) var search: ContentSearchContext?
    private var keptFolder: KeptFolder?

    private struct KeptFolder {
        var filterMode: NameMatchMode
        var listed: [DirectoryEntry]
        var loadState: ContentLoadState
        var hiddenItemCount: Int
        var details: PathReadCache<EntryMetadata>
        var scroll: (top: Double, left: Double)
    }
    private var observation: AppearanceModel.Observation?
    private var windowObservers: [any NSObjectProtocol] = []

    private(set) var pane: (any FolderPane)?
    let container = ContentContainerView()
    private let shell = ContentPaneView()
    private var status: NSTextField { shell.pathBarRow.status }

    var theme: Theme { AppearanceModel.shared.theme }
    var iconStore: FileIconStore? { loaders.iconStore() }

    init(mode: ExplorerViewMode = .details, folderSizes: WindowFolderSizes, loaders: ContentLoaders) {
        self.mode = mode
        self.folderSizes = folderSizes
        self.loaders = loaders
        super.init(nibName: nil, bundle: nil)
        folderSizes.observe(self) { [weak self] in self?.folderSizesChanged() }
        searchValues = SearchValues(read: { [weak self] paths, field in
            await self?.loaders.values(paths, field) ?? []
        })
        searchValues.changed = { [weak self] in self?.searchValuesArrived() }
        // The date groups change at midnight; the system says so after a sleep or a clock change too.
        dayObserver = NotificationCenter.default.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main)
        {
            [weak self] _ in
            MainActor.assumeIsolated { self?.dayChanged() }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    isolated deinit {
        for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
        if let dayObserver { NotificationCenter.default.removeObserver(dayObserver) }
        loading?.timer?.cancel()
    }

    // MARK: View

    /// The rows of the content pane: the search header, the list, the Info Row and the path bar row.
    var contentShell: ContentPaneView { shell }

    /// The Info Row slides open or closed (220 ms) unless the window is only being restored.
    func setInfoRowOpen(_ open: Bool, animated: Bool = false) {
        shell.infoRow.setOpen(open, animated: animated && shell.window != nil)
        shell.needsLayout = true
    }

    override func loadView() {
        shell.list = container
        container.backgroundMenu = { [weak self] in self?.contextMenu(for: nil) }
        container.stateView.onOpenPrivacySettings = { [weak self] in self?.loaders.openPrivacySettings() }
        // The bar's ✕ brings the list back as Esc does, a pinned filter too; the list keeps the keyboard.
        container.filterBar.onFocusList = { [weak self] in self?.focusList() }
        container.filterBar.onClear = { [weak self] in self?.removeFilter() }
        container.filterBar.onTogglePin = { [weak self] in self?.togglePin() }
        container.filterBar.onToggleMode = { [weak self] in self?.onToggleFilterMode?() }
        container.stateView.onSearchSubfolders = onSearchSubfolders
        shell.onMovedToWindow = { [weak self] window in self?.observeWindow(window) }
        shell.pathBarRow.onSizeSlide = { [weak self] value, done in self?.sizeSlid(to: value, save: done) }
        // The date formatters take a few milliseconds to make: they are made off the main thread, before a row needs them.
        Task.detached(priority: .utility) {
            _ = DateText.shared
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
        updateFilterBar()
        refreshState()
    }

    // MARK: Views by mode

    func setMode(_ newMode: ExplorerViewMode) {
        guard newMode != mode || pane == nil else { return }
        mode = newMode
        installPane()
        // The new view starts at the top and then brings the selection's lead into view.
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
        syncSizeSlider()
    }

    // MARK: A folder

    /// A folder is being read. Its predecessor stays on screen until it arrives; with nothing on screen the loading
    /// card shows after 400 ms.
    func beginLoading(quiet: Bool) {
        // The message goes as the read starts, not when it ends.
        let messageWent = !quiet && readError != nil
        defer { if messageWent { refreshState() } }
        if !quiet { readError = nil }
        guard !quiet, searchDisplay == nil else { return }
        loading?.timer?.cancel()
        loading = Loading()
        guard listed.isEmpty else { return }
        loading?.timer = timers.schedule(after: ContentStateText.loadingDelayMilliseconds / 1000) { [weak self] in
            guard let self, self.loading != nil else { return }
            self.loading?.cardShown = true
            self.refreshState()
        }
    }

    /// A navigation that opens nothing (the folder is gone): the listing in front stays as it was.
    func cancelLoading() {
        endLoading()
        refreshState()
    }

    private func endLoading() {
        loading?.timer?.cancel()
        loading = nil
    }

    /// The read ended with `state`.
    private func settle(_ state: ContentLoadState) {
        endLoading()
        settled = state
    }

    /// A Go To that couldn't be read: the folder on screen stays, with "Couldn’t open this folder" and the error's
    /// message over it, whether or not a read was begun for it.
    func showReadError(_ error: FolderReadError) {
        endLoading()
        readError = error
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
        if path != folderPath {
            tags.startOver()
        } else {
            tags.markChanged(changedPaths)
        }
        // The folder read again under search results (hidden files, a change on disk) waits for them to close.
        if searchDisplay != nil, var kept = keptFolder, path == folderPath {
            kept.listed = newEntries
            kept.loadState = .loaded
            // What changed meanwhile is read again once the results close (nil: everything).
            kept.details.markChanged(changedPaths)
            keptFolder = kept
            return
        }
        endLoading()
        let sameFolder = path == folderPath
        if !sameFolder {
            listFilter.clear()
            startDetailsOver()
            hiddenItemCount = 0
        } else {
            // The items that changed have their details read again, and those being read are read once more after.
            details.markChanged(changedPaths)
        }
        folderPath = path
        settle(.loaded)
        // The same listing read again as it was keeps what is on screen as it is.
        let kept =
            sameFolder
            ? DirectoryListingDiff.keepUnchanged(shown: listed, next: newEntries, path: \.path) : nil
        let unchanged = kept?.isUnchanged == true
        // A folder's own icon can change with nothing else about it: it is drawn again, as the others' can't.
        let changedSet = changedPaths.map(Set.init)
        let customIconsChanged =
            sameFolder
            ? newEntries.filter { $0.hasCustomIcon == true && changedSet?.contains($0.path) != false } : []
        for entry in customIconsChanged { iconStore?.forget(IconRequest(entry: entry.iconEntry)) }
        let customIconPaths = Set(customIconsChanged.map(\.path))
        let previousPaths = entryPaths
        let groupsBefore = groups
        let orderBefore = takeOrderBeforeRemoval()
        listed = newEntries
        rowsCache = nil
        queuedAdded = [:]
        reorder()
        // Nil keeps the selection that still exists (a quiet read); a list of paths is the new selection.
        if let memory {
            // Back and Forward restore the exact selection, checked against the listing read now: what is gone drops,
            // and no gap is kept.
            var restored = memory.selection.sanitized(entryPaths: entryPaths)
            restored.gapIndex = nil
            setSelection(restored, notify: true)
        } else if let paths {
            let lookup = paths.isEmpty ? [:] : rowsByPath
            setSelection(ContentSelection.of(paths.filter { lookup[$0] != nil }), notify: true)
        } else {
            resanitizeSelection(previousPaths: sameFolder ? orderBefore ?? previousPaths : previousPaths)
        }
        closeRenameIfItemLeft()
        // Other groups are another order, whose rows are all drawn again.
        let regrouped = groups != groupsBefore
        if let kept, !unchanged, keepingScroll, inlineRename == nil, previousPaths == entryPaths, !regrouped {
            // The same rows in the same order: only the rows of the items that changed are drawn again.
            let reloaded = Set(kept.changedPaths).union(customIconPaths)
            pane?.reloadRows(paths: reloaded)
            filesChanged(changedPaths, besides: reloaded)
        } else if !unchanged || !keepingScroll || regrouped {
            // Every row drawn again, as a new listing: each preview is checked against its file again.
            // The same folder in another order (a sort, Folders First, hidden files) starts at its top, and the List
            // stays where it was scrolled sideways: the column whose header was clicked stays in view.
            let keptLeft = sameFolder && !keepingScroll && pane is ListViewController ? pane?.scrollPosition.left : nil
            pane?.reload(scrollToTop: !keepingScroll)
            if let keptLeft, let top = pane?.scrollPosition.top { pane?.scrollPosition = (top, keptLeft) }
        } else {
            pane?.refresh(paths: changedPaths.map(Set.init))
            if !customIconPaths.isEmpty { pane?.reloadRows(paths: customIconPaths) }
            filesChanged(changedPaths, besides: customIconPaths)
        }
        pane?.syncSelection()
        if let memory { pane?.scrollPosition = (memory.scrollTop, memory.scrollLeft) }
        refreshState()
        updateStatus()
        if listed.isEmpty, !includeHidden, !folderPath.isEmpty { loadHiddenCount() }
    }

    /// The items a change on disk named (nil: any) may have new content though their entries are as they were: their
    /// previews are checked again, but for the rows of `reloaded`, drawn again already.
    private func filesChanged(_ changedPaths: [String]?, besides reloaded: Set<String>) {
        guard let changedPaths else {
            pane?.filesChanged(paths: nil)
            return
        }
        let files = Set(changedPaths).subtracting(reloaded)
        if !files.isEmpty { pane?.filesChanged(paths: files) }
    }

    /// A folder that could not be read: its error shows, and nothing is selected.
    func showError(folder path: String, error: FolderReadError) {
        if searchDisplay != nil, var kept = keptFolder, path == folderPath {
            kept.listed = []
            kept.loadState = .failed(error)
            keptFolder = kept
            return
        }
        endLoading()
        readError = nil
        if path != folderPath { listFilter.clear() }
        folderPath = path
        listed = []
        entries = []
        entryPaths = []
        positionsCache = nil
        rowsCache = nil
        startDetailsOver()
        settle(.failed(error))
        setSelection(.empty, notify: true)
        closeRenameIfItemLeft()
        pane?.reload(scrollToTop: true)
        refreshState()
        updateStatus()
    }

    /// With no folder at all.
    func showNoFolder() {
        folderPath = ""
        readError = nil
        // Nothing of the folder stays, as for another folder: its tags, filter and hidden count, and its rows.
        tags.startOver()
        listFilter.clear()
        hiddenItemCount = 0
        startDetailsOver()
        listed = []
        rowsCache = nil
        entries = []
        entryPaths = []
        positionsCache = nil
        settle(.idle)
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
    func setView(
        sortBy: SortByPreference, direction: SortDirectionPreference, foldersFirst: Bool, includeHidden: Bool,
        groupBy: GroupByPreference = .none, groupReversed: Bool = false
    ) {
        self.sortBy = sortBy
        sortDirection = direction
        self.foldersFirst = foldersFirst
        self.includeHidden = includeHidden
        // The folder is read again for other groups, with the values they need.
        self.groupBy = groupBy
        // The same groups the other way round need no read: they are put in order again at once.
        if groupReversed != self.groupReversed {
            self.groupReversed = groupReversed
            if searchDisplay == nil, !listed.isEmpty { regroup() }
        }
        barScaleCache = nil
        pane?.refreshLook()
    }

    /// Sets the whole filter text at once, with its mode (a tab started from this one); the selection stays.
    func setFilter(_ text: String, mode: NameMatchMode? = nil) {
        guard text != filter || (mode != nil && mode != filterMode) else { return }
        startFilter(mode, ifEmpty: false)
        listFilter.set(text, at: ProcessInfo.processInfo.systemUptime)
        filterChanged(.kept(previousPaths: entryPaths))
    }

    /// A filter starting from nothing takes the default mode, or the one it is given.
    private func startFilter(_ mode: NameMatchMode? = nil, ifEmpty: Bool = true) {
        if !ifEmpty || filter.isEmpty { typedFilterMode = mode ?? viewFilterMode }
    }

    /// Esc, the ✕, or leaving the folder: the whole list returns and the selection is kept, so something found by
    /// filtering can then be seen among its neighbours.
    func clearFilter() {
        guard !filter.isEmpty else { return }
        let previous = entryPaths
        listFilter.clear()
        filterChanged(.kept(previousPaths: previous))
    }

    // MARK: Pinned filter

    /// Whether View ▸ Pin Filter can act: a filter typed in a folder can be pinned, and a pinned one unpinned.
    var canTogglePin: Bool { pinnedFilter != nil || (!filter.isEmpty && searchDisplay == nil) }

    /// View ▸ Pin Filter and the filter bar's pin: the filter typed in the folder is pinned, or the pinned one goes back to
    /// being typed text.
    func togglePin() {
        if pinnedFilter != nil { unpinFilter() } else { pinFilter() }
    }

    /// The typed filter becomes the pane's pinned one: it now leaves folders alone, and typing selects names.
    func pinFilter() {
        guard pinnedFilter == nil, !filter.isEmpty, searchDisplay == nil else { return }
        let previous = entryPaths
        pinnedFilter = PinnedListFilter(query: filter, mode: filterMode)
        listFilter.clear()
        typedToSelect.clear()
        filterChanged(.kept(previousPaths: previous))
    }

    /// The pinned filter goes back to being typed text, to be edited or cleared, in a folder; over search results it
    /// is let go of, as their own field holds what is typed there.
    func unpinFilter() {
        guard let pin = pinnedFilter else { return }
        let previous = entryPaths
        pinnedFilter = nil
        typedToSelect.clear()
        if searchDisplay == nil {
            typedFilterMode = pin.mode
            listFilter.set(pin.query, at: ProcessInfo.processInfo.systemUptime)
        }
        filterChanged(.keptWhereShown(previousPaths: previous))
    }

    /// The filter bar's ✕: the filter goes, pinned or typed.
    func removeFilter() {
        guard pinnedFilter != nil || !filter.isEmpty else { return }
        let previous = entryPaths
        pinnedFilter = nil
        typedToSelect.clear()
        listFilter.clear()
        filterChanged(.kept(previousPaths: previous))
    }

    /// A pane started from another (Duplicate Tab, a tab moved to another window) takes its pinned filter.
    func setPinnedFilter(_ pin: PinnedListFilter?) {
        guard pin != pinnedFilter else { return }
        let previous = entryPaths
        pinnedFilter = pin
        typedToSelect.clear()
        filterChanged(.kept(previousPaths: previous))
    }

    /// An item a filter hides is to be shown (Reveal, Go To a file, a paste, a rename): what hides it goes, and only
    /// that. The pin goes when the pin is what hides the item, and a toast says so; the typed filter (the results'
    /// own, over search results) is cleared when it hides the item.
    private func showHidden(_ path: String) {
        guard position(of: path) == nil, let entry = rowsByPath[path], !filter.isEmpty || pinnedFilter != nil
        else { return }
        var dropped: PinnedListFilter?
        if let pin = pinnedFilter,
            ListFilter.filterPinned([entry], pin: pin, isFolder: \.isDirectoryLike, cache: foldedNames).isEmpty
        {
            dropped = pin
            pinnedFilter = nil
            typedToSelect.clear()
            // Whether the typed filter hides it too shows once the pin is gone.
            if !filter.isEmpty { reorder() }
        }
        if !filter.isEmpty, dropped == nil || position(of: path) == nil { listFilter.clear() }
        filterChanged(.untouched)
        if let dropped {
            _ = NotificationOverlay.push(
                .info, title: "The filter “\(dropped.query)” is no longer pinned, to show an item it hid",
                in: view.window)
        }
    }

    func typeToSelect(_ text: String?) {
        guard let text else {
            typedToSelect.clear()
            return
        }
        let query = typedToSelect.type(text, at: ProcessInfo.processInfo.systemUptime)
        guard let match = ListTypeToSelect.match(in: entries, query: query, cache: foldedNames) else { return }
        setSelection(.single(match.path), notify: true)
        pane?.syncSelection()
    }

    /// What becomes of the selection when the filter changes.
    private enum SelectionAfterFilter {
        /// Kept, without what is no longer listed; `previousPaths` is the order the items that left stood in.
        case kept(previousPaths: [String])
        /// Kept as far as it still shows: the chip switched the mode, or the filter was unpinned, which can hide an
        /// item selected by hand.
        case keptWhereShown(previousPaths: [String])
        /// The name the text fits best, as typing selects; kept when the text is empty.
        case bestMatch
        /// Left as it is: whoever changed the filter sets it next.
        case untouched
    }

    /// The filter's text, its mode or the pin changed, whatever changed it: the list is narrowed again and drawn, and
    /// the results bar's field and Pin Filter are told, so neither is left showing what was.
    private func filterChanged(_ after: SelectionAfterFilter) {
        onFilterChanged?(filter)
        reorder()
        if case .kept(let previousPaths) = after { resanitizeSelection(previousPaths: previousPaths) }
        // What the filter comes to hide leaves the selection: nothing unseen is left for Return, ⌘⌫ or a drag to
        // act on.
        if case .keptWhereShown(let previousPaths) = after {
            resanitizeSelection(previousPaths: previousPaths, keepingHidden: false)
        }
        pane?.reload(scrollToTop: false)
        if case .bestMatch = after, !filter.isEmpty {
            let match = ListFilter.selection(in: entries, query: filter, mode: filterMode, cache: foldedNames)
            setSelection(match.map { ContentSelection.single($0.path) } ?? .empty, notify: true)
        }
        pane?.syncSelection()
        refreshState()
        updateStatus()
        onFilterStateChanged?()
    }

    /// A key typed into the list: the text narrows it and selects the first name that starts with it, otherwise the
    /// first match; Backspace takes a character back; Esc brings the list back.
    func applyFilterKey(_ key: ListFilterKey) {
        let now = ProcessInfo.processInfo.systemUptime
        switch key {
        case .clear:
            clearFilter()
            return
        case .type(let text):
            startFilter()
            listFilter.type(text, at: now)
        case .erase:
            listFilter.eraseCharacter(at: now)
        case .eraseWord:
            listFilter.eraseWord(at: now)
        }
        filterChanged(.bestMatch)
    }

    /// The mode the view starts in, as it opens: a filter already typed keeps its own.
    /// The mode of the folder's own view, which the pane is saved with: while search results show, the one the folder
    /// comes back in.
    var folderFilterMode: NameMatchMode { keptFolder?.filterMode ?? viewFilterMode }

    func setViewFilterMode(_ mode: NameMatchMode) {
        viewFilterMode = mode
    }

    /// The other mode, from the filter bar or a chip: the view takes it, and the typed filter switches to it and
    /// narrows the list again, the selection kept. Returns the mode, which the caller makes the one new views start
    /// with; other views keep theirs.
    func toggleFilterMode() -> NameMatchMode {
        let next = filterMode.toggled
        viewFilterMode = next
        guard !filter.isEmpty else { return next }
        typedFilterMode = next
        filterChanged(.keptWhereShown(previousPaths: entryPaths))
        return next
    }

    /// The letters to mark in a name: what the filter matched while one is typed, otherwise what the search matched.
    /// Over search results a name the filter didn't match (its folder did) keeps the search's marks.
    func nameMarks(_ name: String) -> [HighlightRange] {
        if let filterMatcher {
            let key = StoredName(name)
            let found = filterMarks[key] ?? filterMatcher.marks(in: name)
            if filterMarks.count >= 10_000 { filterMarks.removeAll(keepingCapacity: true) }
            filterMarks[key] = found
            if !found.isEmpty { return found }
        }
        return search?.match(in: name).map { [$0] } ?? []
    }

    /// The filter's matcher for the text and mode now (the pinned filter's while none is typed), its marks forgotten
    /// when either changed.
    private func refreshFilterMatcher() {
        let matcher =
            filter.isEmpty
            ? pinnedFilter.flatMap { NameMatcher($0.query, mode: $0.mode) } : NameMatcher(filter, mode: filterMode)
        if matcher?.text != filterMatcher?.text || matcher?.mode != filterMatcher?.mode { filterMarks.removeAll() }
        filterMatcher = matcher
    }

    private func reorder() {
        refreshFilterMatcher()
        // Text that only grew, in the same mode over the same items, finds among what it kept before.
        let narrowing =
            lastFiltered.map {
                $0.mode == filterMode && $0.version == sourceVersion && ListFilter.narrows($0.text, to: filter)
            } ?? false
        if let searchDisplay {
            // Results narrow by name or by the folder they are in; their order is the search's own.
            let pool = narrowing ? lastFiltered?.results ?? searchDisplay.results : searchDisplay.results
            let filtered = ListFilter.filterSearchResults(pool, query: filter, mode: filterMode, cache: foldedNames)
            lastFiltered = filter.isEmpty ? nil : (filter, filterMode, sourceVersion, filtered)
            entries = filter.isEmpty ? listed : filtered.map(SearchResults.entry)
            applyPin()
            orderByValues(searchDisplay)
            applyGroups()
            entryPaths = entries.map(\.path)
            positionsCache = nil
            barScaleCache = nil
            updateFilterBar()
            return
        }
        var contents = FolderContents(path: folderPath, listed: listed, filter: filter, filterMode: filterMode)
        contents.candidates = narrowing ? entries : nil
        contents.foldedNames = foldedNames
        lastFiltered = filter.isEmpty ? nil : (filter, filterMode, sourceVersion, nil)
        let sizes = folderSizes
        entries = contents.shown(
            sortBy: sortBy, direction: sortDirection, foldersFirst: foldersFirst
        ) { sizes.readySize($0) }
        applyPin()
        applyGroups()
        entryPaths = entries.map(\.path)
        positionsCache = nil
        barScaleCache = nil
        updateFilterBar()
    }

    /// Search results ordered by a date or the size: by the values read for them, in the order's direction, those not
    /// read yet or without one last either way; among the same value, as the search ordered them (by name).
    private func orderByValues(_ display: ContentSearchDisplay) {
        guard let field = display.sortBy.valueField else { return }
        let ascending = display.sortDirection == .asc
        let values = entries.map { searchValues.value(field, of: $0.path)?.number }
        let positions = entries.indices.sorted { left, right in
            switch (values[left], values[right]) {
            case (let l?, let r?) where l != r: return ascending ? l < r : l > r
            case (.some, nil): return true
            case (nil, .some): return false
            default: return left < right
            }
        }
        entries = positions.map { entries[$0] }
    }

    /// What search results' order and groups need read for every result: the field of an order by a date or the
    /// size, and of groups by a date, the size or the tags. Nothing for a folder, or for search results ordered and
    /// grouped by what they carry.
    var searchFieldsNeeded: Set<ItemValueField> {
        guard let searchDisplay else { return [] }
        return Set([searchDisplay.sortBy.valueField, searchGroupBy.valueField].compactMap { $0 })
    }

    /// The results' order or groups need values not read yet: they are read, and those no longer needed go.
    private func readSearchValues() {
        searchValues.need(searchFieldsNeeded, paths: listed.map(\.path))
    }

    /// A batch of values came in: the results are ordered and grouped again with them, where the list is scrolled.
    private func searchValuesArrived() {
        guard searchDisplay != nil else { return }
        let before = entryPaths
        let groupsBefore = groups
        reorder()
        guard entryPaths != before || groups != groupsBefore else { return }
        resanitizeSelection(previousPaths: before)
        pane?.reload(scrollToTop: false)
        pane?.syncSelection()
        updateStatus()
    }

    /// The entries in their groups: each group's items together, in the order shown, the groups in their order.
    private func applyGroups() {
        let by = activeGroupBy
        guard by != .none, !entries.isEmpty else {
            groups = []
            return
        }
        let spans = EntryGroups.make(
            keys: groupKeys(entries, by: by), groupBy: by, foldersFirst: searchDisplay == nil && foldersFirst,
            reversed: activeGroupReversed)
        var ordered: [DirectoryEntry] = []
        ordered.reserveCapacity(entries.count)
        var shown: [ShownGroup] = []
        for span in spans {
            let start = ordered.count
            for position in span.positions { ordered.append(entries[position]) }
            shown.append(ShownGroup(group: span.group, range: start..<ordered.count))
        }
        entries = ordered
        groups = shown
    }

    /// The group of each entry: by its name, its kind, the date or the size or the tag its listing read, or the
    /// folder a search result is in.
    private func groupKeys(_ shown: [DirectoryEntry], by: GroupByPreference) -> [EntryGroupKey] {
        switch by {
        case .none:
            return []
        case .name:
            return shown.map { NameGroups.key(name: $0.name) }
        case .kind:
            var kinds = KindGroupCache()
            return shown.map { kinds.group(fileExtension: $0.fileExtension, isFolder: $0.isDirectoryLike).key }
        case .modified, .created, .added, .lastOpened:
            let dates = DateGroups(now: now())
            let missing =
                by == .lastOpened ? "Never Opened" : by == .added ? "No Date Added" : "No Date"
            // A search result's date is the one read for it; a folder's item's, its listing's.
            if searchDisplay != nil, let field = by.valueField {
                return shown.map {
                    dates.key(milliseconds: searchValues.value(field, of: $0.path)?.number, missing: missing)
                }
            }
            return shown.map { dates.key(milliseconds: $0.groupTimeMs, missing: missing) }
        case .size:
            if searchDisplay != nil {
                return shown.map { SizeGroups.key(bytes: searchValues.value(.size, of: $0.path)?.number) }
            }
            let sizes = folderSizes
            return shown.map {
                SizeGroups.key(bytes: FolderContents.sizeBytes(of: $0) { sizes.readySize($0) })
            }
        case .tags:
            if searchDisplay != nil {
                return shown.map { TagGroups.key(firstTag: searchValues.value(.tags, of: $0.path)?.text) }
            }
            return shown.map { TagGroups.key(firstTag: $0.firstTag) }
        case .folder:
            guard let search, let root = searchDisplay?.rootPath else {
                return shown.map { _ in FolderGroups.key(label: "", parent: "", isSearchedFolder: true) }
            }
            return shown.map {
                let parent = NodePath.dirname($0.path)
                return FolderGroups.key(
                    label: search.folderLabel($0.path), parent: parent, isSearchedFolder: parent == root)
            }
        }
    }

    // MARK: Groups

    /// The groups made again over the same items (the day changed, search results grouped otherwise): every row is
    /// drawn again where the list is scrolled.
    private func regroup() {
        let previousPaths = entryPaths
        reorder()
        resanitizeSelection(previousPaths: previousPaths)
        pane?.reload(scrollToTop: false)
        pane?.syncSelection()
        refreshState()
        updateStatus()
    }

    /// Midnight: the date groups move on a day, Today's items into Yesterday.
    private func dayChanged() {
        guard activeGroupBy.isDate, !groups.isEmpty else { return }
        regroup()
    }

    /// Search results' groups the other way round, or back.
    func setSearchGroupReversed(_ reversed: Bool) {
        guard reversed != searchGroupReversed else { return }
        searchGroupReversed = reversed
        if searchDisplay != nil { regroup() }
    }

    /// Search results' Group By: they are grouped again at once, as they carry what their groups need.
    func setSearchGroupBy(_ by: GroupByPreference) {
        guard by != searchGroupBy else { return }
        searchGroupBy = by
        guard searchDisplay != nil else { return }
        readSearchValues()
        regroup()
    }

    /// The pinned filter keeps the folders and the files it matches of what the typed filter left.
    private func applyPin() {
        guard pinnedFilter != nil else { return }
        entries = ListFilter.filterPinned(entries, pin: pinnedFilter, isFolder: \.isDirectoryLike, cache: foldedNames)
    }

    private func updateFilterBar() {
        // Search results are narrowed in the results bar's own field; a pinned filter shows over them too.
        if let pinnedFilter {
            container.filterBar.show(
                query: pinnedFilter.query, mode: pinnedFilter.mode, shown: entries.count, total: listed.count,
                theme: theme, pinned: true)
        } else {
            container.filterBar.show(
                query: searchDisplay == nil ? filter : "", mode: filterMode, shown: entries.count,
                total: listed.count, theme: theme)
        }
        container.layoutFilterBar()
    }

    private func refreshState() {
        var kind: ContentStateKind
        switch loadState {
        case .idle:
            kind = .empty(text: ContentStateText.noFolder)
        case .loading:
            kind = entries.isEmpty && loading?.cardShown == true ? .loading : .none
        case .failed(let error):
            kind =
                FolderReadFailure.isTrashRefused(path: folderPath, error: error, homePath: loaders.homePath)
                ? .fullDiskAccess : .error(message: error.message)
        case .loaded:
            if listed.isEmpty {
                kind = .empty(text: ContentStateText.empty(path: folderPath, hiddenItemCount: hiddenItemCount))
            } else if entries.isEmpty, let query = filter.isEmpty ? pinnedFilter?.query : filter {
                kind = .noMatches(query: query)
            } else {
                kind = .none
            }
        }
        if let readError {
            kind =
                FolderReadFailure.isTrashRefused(path: folderPath, error: readError, homePath: loaders.homePath)
                ? .fullDiskAccess : .error(message: readError.message)
        }
        if let searchDisplay {
            kind =
                SearchResultsState.make(
                    isRunning: searchDisplay.isRunning, shownCount: entries.count, totalCount: listed.count,
                    error: searchDisplay.error, errorIsQuiet: searchDisplay.errorIsQuiet, filterQuery: filter
                ).map { .search($0) } ?? .none
        }
        container.stateView.onSearchSubfolders = onSearchSubfolders
        // A filter nothing matches is said in place of the whole view, the List's column header too.
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

    /// The listed entry at `path`, shown or left out by the filter.
    func listedEntry(at path: String) -> DirectoryEntry? { rowsByPath[path] }

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
        orderBeforeRemoval = nil
        selection = next
        pane?.syncSelection()
        updateStatus()
        if notify { onSelectionChanged?(next) }
    }

    /// Whenever the visible entries change (a folder, a sort, a filter), every selected path that is no longer in the
    /// list is dropped, and a selection whose items all left keeps their place for the arrow keys. A renamed, pasted or
    /// new item outside the filter is selected on purpose, and is kept (`keepingHidden`); one the filter itself came
    /// to hide, by another mode or by being unpinned, is not.
    private func resanitizeSelection(previousPaths: [String], keepingHidden: Bool = true) {
        guard !selection.isEmpty || selection.gapIndex != nil else { return }
        if keepingHidden, let lead = selection.leadPath, position(of: lead) == nil, rowsByPath[lead] != nil { return }
        setSelection(selection.sanitized(entryPaths: entryPaths, previousPaths: previousPaths), notify: true)
    }

    /// Items a write took away leave the selection before the read that follows it comes in, keeping their place for the
    /// arrow keys. Selected items the filter hides stay.
    func dropFromSelection(_ paths: [String]) {
        let left = Set(paths)
        guard selection.paths.contains(where: left.contains) else { return }
        let order = takeOrderBeforeRemoval() ?? entryPaths
        let listed = order + selection.paths.filter { position(of: $0) == nil }
        let staying = listed.filter { !left.contains($0) }
        setSelection(selection.sanitized(entryPaths: staying, previousPaths: order), notify: true)
    }

    /// Called just before the sizes of what a write or a drag took away are forgotten: the order on screen is kept for
    /// where the selected items that left stood.
    func keepOrderBeforeRemoval() {
        orderBeforeRemoval = selection.isEmpty ? nil : entryPaths
    }

    /// The order kept before a removal, when the list still holds the same items and was only sorted again since.
    private func takeOrderBeforeRemoval() -> [String]? {
        guard let order = orderBeforeRemoval else { return nil }
        orderBeforeRemoval = nil
        guard order.count == entryPaths.count, Set(order) == Set(entryPaths) else { return nil }
        return order
    }

    /// Selects the paths that are listed; the view keeps their lead in view (`RevealKeeper`). A lead a filter hides is
    /// shown: the filter that hides it goes (`showHidden`).
    func select(paths: [String]) {
        let existing = paths.filter { rowsByPath[$0] != nil }
        let selecting = ContentSelection.of(existing)
        // Every one a filter hides is shown, not only the lead: one left hidden would stay selected unseen, and be
        // deleted or moved with the others.
        for path in existing where position(of: path) == nil { showHidden(path) }
        setSelection(selecting, notify: true)
        pane?.syncSelection()
    }

    /// The pane reports a selection from a click, a key or the marquee: the lead is brought into view when it changes.
    func selectionChanged(_ selection: ContentSelection) {
        restoredScroll = nil
        setSelection(selection, notify: true)
    }

    /// ⌘A with the list focused: every entry on screen (only the matching ones while a filter is typed).
    func selectAllEntries() {
        selectionChanged(.all(entryPaths: entryPaths))
    }

    /// Edit ▸ Deselect All.
    func deselectAllEntries() {
        selectionChanged(.empty)
    }

    /// Edit ▸ Invert Selection: every entry on screen that isn't selected, and none of those that are, nor any a
    /// filter hides.
    func invertSelection() {
        selectionChanged(selection.inverted(entryPaths: entryPaths))
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

    /// Starts renaming the item in its row. The item is shown first: the filter that hides it goes (`showHidden`).
    /// Whether the item is listed.
    @discardableResult
    func beginRename(path: String) -> Bool {
        guard rowsByPath[path] != nil else { return false }
        showHidden(path)
        Self.renameSessions += 1
        inlineRename = InlineRenameState(path: path, error: nil, refusalCount: 0, sessionID: Self.renameSessions)
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
    /// showing is said in a dialog so it is not lost.
    private func closeRenameIfItemLeft() {
        guard let rename = inlineRename, rowsByPath[rename.path] == nil else { return }
        let refusal = rename.error
        endRename()
        onRenameLost?(rename.path, refusal)
    }

    // MARK: Search results

    /// Shows search results in place of the folder, or shows them again as they changed. The folder is kept
    /// as it was, to come back when they are put away. A new query or root starts the list at the top and drops the
    /// filter and the details read so far; the selection is the search session's to apply.
    func showSearch(_ display: ContentSearchDisplay) {
        let entering = searchDisplay == nil
        let newList = entering || searchDisplay?.viewKey != display.viewKey
        if newList { restoredScroll = nil }
        if entering {
            endLoading()
            keptFolder = KeptFolder(
                filterMode: viewFilterMode, listed: listed, loadState: settled,
                hiddenItemCount: hiddenItemCount, details: details,
                scroll: pane?.scrollPosition ?? (0, 0))
        }
        // Run again, the search finds the files as they are now: the dates, sizes and tags read for the last run go.
        if newList || searchDisplay?.run != display.run { searchValues.reset() }
        if newList {
            if !filter.isEmpty {
                listFilter.clear()
                onFilterChanged?(filter)
            }
            startDetailsOver()
        }
        searchDisplay = display
        search = ContentSearchContext(
            display: display, requestSort: { [weak self] key in self?.onSearchSort?(key) },
            setSort: { [weak self] key, direction in self?.onSearchSortSet?(key, direction) })
        settle(.loaded)
        let previousPaths = entryPaths
        let groupsBefore = groups
        listed = display.results.map(SearchResults.entry)
        rowsCache = nil
        reorder()
        readSearchValues()
        // The views see the results' columns and order.
        if newList || previousPaths != entryPaths || groups != groupsBefore {
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
        restoredScroll = nil
        searchValues.reset()
        searchDisplay = nil
        search = nil
        keptFolder = nil
        if !filter.isEmpty {
            listFilter.clear()
            onFilterChanged?(filter)
        }
        // The folder's view comes back in its own mode, whatever the results' was.
        if let kept { viewFilterMode = kept.filterMode }
        listed = kept?.listed ?? []
        settle(kept?.loadState ?? .idle)
        hiddenItemCount = kept?.hiddenItemCount ?? 0
        startDetailsOver(keeping: kept?.details)
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
    /// else the first match. Emptied, it brings every result back and keeps the selection, as Esc does in a folder, so a
    /// result the filter hid comes back selected.
    func setSearchFilter(_ text: String) {
        guard text != filter else { return }
        startFilter()
        listFilter.set(text, at: ProcessInfo.processInfo.systemUptime)
        filterChanged(.bestMatch)
    }

    /// The results come back as they were left: narrowed by the filter's text in its own mode and scrolled where they
    /// were. The selection is left to whoever brings them back, and the list stays scrolled where it was when that
    /// selection is applied, also when its lead was out of view.
    func restoreSearchView(filter text: String, mode: NameMatchMode, scroll: (top: Double, left: Double)?) {
        guard searchDisplay != nil else { return }
        viewFilterMode = mode
        if text != filter || (!text.isEmpty && mode != filterMode) {
            startFilter(mode, ifEmpty: false)
            listFilter.set(text, at: ProcessInfo.processInfo.systemUptime)
            filterChanged(.untouched)
        }
        guard let scroll else { return }
        view.layoutSubtreeIfNeeded()
        pane?.scrollPosition = scroll
        restoredScroll = scroll
    }

    /// Where results that came back were scrolled, until their selection is applied: selecting brings the lead into
    /// view, and the list is then put back where it was.
    private var restoredScroll: (top: Double, left: Double)?

    /// Applies a selection to the list on screen, bringing its lead into view; results just brought back stay
    /// scrolled where they were left.
    func applySelection(_ next: ContentSelection) {
        setSelection(next, notify: true)
        pane?.syncSelection()
        if let scroll = restoredScroll {
            restoredScroll = nil
            pane?.scrollPosition = scroll
        }
    }

    // MARK: Host

    var paneHasKeyboard: Bool { pane?.hasKeyboard ?? false }
    /// The keyboard is in this pane: its list has it (or a dialog keeps the list's focused look), or a field in the pane
    /// does, as a name being renamed.
    var keyboardIsInPane: Bool {
        if paneHasKeyboard { return true }
        let responder = view.window?.firstResponder
        // A field's keyboard is its editor's.
        let field = (responder as? NSTextView)?.delegate as? NSView ?? responder as? NSView
        return field?.isDescendant(of: view) ?? false
    }
    var windowIsActive: Bool {
        guard let window = view.window else { return windowActive }
        #if DEBUG
            // A capture run may not be the app in front, so no window is key: the window then counts as in front,
            // and another window being key still makes this one inactive.
            if Self.isAutomated, NSApp.keyWindow == nil { return true }
        #endif
        return window.isKeyWindow
    }

    private static let isAutomated = CommandLine.arguments.contains("--automation")

    func metadata(for path: String) -> EntryMetadata? { details[path] }

    func folderSizeEntry(_ path: String) -> FolderSizeEntry { folderSizes.entry(path) }

    /// Bars show only while the folder is sorted by size; the largest size among all of its entries, not
    /// only those on screen.
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

    func headerMenu(for column: DetailColumn?) -> NSMenu? { onHeaderMenu?(column) }

    /// Size All Columns to Fit, from the header's menu.
    func fitAllColumns() { (pane as? ListViewController)?.fitAllColumns() }

    func columnMoved(_ column: DetailColumn, before: DetailColumn?) { onColumnMoved?(column, before) }

    /// The status bar's slider set the Compact List's column width: the columns follow it while it moves, and the
    /// width is saved once it is let go (or set by a click or a key).
    func compactListWidthChanged(_ width: Double, save: Bool) {
        let density = columnState.density
        let clamped = AppPreferenceLimits.clampPaneWidth(width, AppPreferenceLimits.compactListWidthRange)
        shell.pathBarRow.sizeValue = clamped
        if clamped != columnState.compactListWidths[density] {
            columnState.compactListWidths[density] = clamped
            pane?.columnsChanged()
        }
        if save { onCompactListWidthChanged?(density, clamped) }
    }

    /// The status bar's slider set the Icons view's icon size, in steps of 8 points: the icons follow it while it
    /// moves, and the size is saved once it is let go (or set by a click or a key).
    func iconSizeChanged(_ size: Double, save: Bool) {
        let density = columnState.density
        let stepped = AppPreferenceLimits.clampIconSize(size)
        shell.pathBarRow.sizeValue = stepped
        if stepped != columnState.iconSizes[density] {
            columnState.iconSizes[density] = stepped
            pane?.columnsChanged()
        }
        if save {
            syncSizeSlider()
            onIconSizeChanged?(density, stepped)
        }
    }

    /// The status bar's slider set how many previews fill the pane, at one of its four stops (`PreviewGrid.counts`):
    /// the previews follow it while it moves, and the count is saved once it is let go (or set by a click or a key).
    func previewStopChanged(_ stop: Double, save: Bool) {
        let density = columnState.density
        let index = min(PreviewGrid.counts.count - 1, max(0, Int(stop.rounded())))
        let count = PreviewGrid.counts[index]
        shell.pathBarRow.sizeValue = count
        if count != columnState.previewCounts[density] {
            columnState.previewCounts[density] = count
            pane?.columnsChanged()
        }
        if save {
            syncSizeSlider()
            onPreviewCountChanged?(density, count)
        }
    }

    /// How many previews the pane shows at a time in Previews, at the density on screen.
    var previewCount: Int { PreviewGrid.valid(columnState.previewCounts[columnState.density]) }

    /// View ▸ Show Previews: the pane shows `count` previews at a time in Previews, saved as the slider's count is.
    /// The window switches the pane to Previews after, so a pane in another view lays them out once, at this count.
    /// In Previews already, the selected item comes on screen wherever the pane was scrolled to: these commands
    /// show that item at a size, where the slider and Make Bigger keep the pane's place.
    func showPreviews(count: Int) {
        let density = columnState.density
        if count != columnState.previewCounts[density] {
            columnState.previewCounts[density] = count
            if mode == .previews {
                if let previews = pane as? PreviewsViewController {
                    previews.countChanged(showsSelected: true)
                } else {
                    pane?.columnsChanged()
                }
            }
        }
        if mode == .previews { (pane as? ItemGridPane)?.revealLead() }
        syncSizeSlider()
        onPreviewCountChanged?(density, count)
    }

    /// The size shows over the status text for a moment, as it does after Make Bigger.
    func flashViewSize() {
        guard viewSize != nil else { return }
        shell.pathBarRow.flashSizeValue()
    }

    /// The size of the view on screen, which View ▸ Make Bigger, Make Smaller and Default Size change; nil in the List.
    var viewSize: ViewSize? {
        ViewSize.of(
            mode, density: columnState.density, iconSizes: columnState.iconSizes,
            compactListWidths: columnState.compactListWidths, previewCounts: columnState.previewCounts)
    }

    /// View ▸ Make Bigger, Make Smaller or Default Size: the icons or the columns go a step bigger or smaller, or back
    /// to their default, and are saved. The slider follows, and the size shows over the status text as it does while
    /// the slider moves, even when it is already at its end.
    func stepViewSize(_ change: ViewSize.Change) {
        guard let size = viewSize else { return }
        let next = Double(size.stepped(change))
        switch mode {
        case .icons: iconSizeChanged(next, save: true)
        case .list: compactListWidthChanged(next, save: true)
        case .previews: previewStopChanged(next, save: true)
        case .details: return
        }
        syncSizeSlider()
        shell.pathBarRow.flashSizeValue()
    }

    private func sizeSlid(to value: Double, save: Bool) {
        switch mode {
        case .icons: iconSizeChanged(value, save: save)
        case .list: compactListWidthChanged(value, save: save)
        case .previews: previewStopChanged(value, save: save)
        case .details: break
        }
    }

    /// The slider shows the icon size in the Icons view and the column width in the Compact List, for the density on
    /// screen; the List has none.
    private func syncSizeSlider() {
        let bar = shell.pathBarRow
        let slider = bar.sizeSlider
        let density = columnState.density
        if mode != .previews {
            slider.numberOfTickMarks = 0
            slider.allowsTickMarkValuesOnly = false
            bar.sizeText = { "\($0) pt" }
        }
        switch mode {
        case .icons:
            let range = AppPreferenceLimits.iconSizeRange
            slider.minValue = Double(range.lowerBound)
            slider.maxValue = Double(range.upperBound)
            slider.doubleValue = Double(columnState.iconSizes[density])
            bar.sizeValue = columnState.iconSizes[density]
            slider.toolTip = Tooltips.sizeSliderTooltip(.icons, shortcuts: sizeShortcuts)
            bar.showsSizeSlider = true
        case .list:
            let range = AppPreferenceLimits.compactListWidthRange
            slider.minValue = Double(range.lowerBound)
            slider.maxValue = Double(range.upperBound)
            slider.doubleValue = Double(columnState.compactListWidths[density])
            bar.sizeValue = columnState.compactListWidths[density]
            slider.toolTip = Tooltips.sizeSliderTooltip(.list, shortcuts: sizeShortcuts)
            bar.showsSizeSlider = true
        case .previews:
            // Four stops, from nine previews at a time to one.
            slider.minValue = 0
            slider.maxValue = Double(PreviewGrid.counts.count - 1)
            slider.numberOfTickMarks = PreviewGrid.counts.count
            slider.allowsTickMarkValuesOnly = true
            slider.doubleValue = Double(PreviewGrid.index(of: columnState.previewCounts[density]))
            bar.sizeText = PreviewGrid.label
            bar.sizeValue = PreviewGrid.valid(columnState.previewCounts[density])
            slider.toolTip = Tooltips.sizeSliderTooltip(.previews, shortcuts: sizeShortcuts)
            bar.showsSizeSlider = true
        case .details:
            bar.showsSizeSlider = false
        }
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
        syncSizeSlider()
    }

    // MARK: Details of the rows on screen

    /// Whether the details of rows asked for are still being read.
    var isReadingDetails: Bool { details.isReading }

    /// Another folder or other search results: nothing is known of the new rows, or what `kept` knew.
    /// Another folder or other search results: what was read of the items before goes, and the names the filter
    /// folded with it.
    private func startDetailsOver(keeping kept: PathReadCache<EntryMetadata>? = nil) {
        details.startOver(keeping: kept)
        metadataQueue = []
        queuedAdded = [:]
        foldedNames.removeAll()
    }

    func requestMetadata(for entries: [DirectoryEntry]) {
        // Search results came from no folder read, and are asked for their own date.
        if searchDisplay == nil {
            for entry in entries { queuedAdded.updateValue(entry.addedMs, forKey: entry.path) }
        }
        requestMetadata(for: entries.map(\.path))
    }

    func requestMetadata(for paths: [String]) {
        metadataQueue += details.begin(paths)
        guard !metadataQueue.isEmpty, !metadataFlushQueued else { return }
        metadataFlushQueued = true
        Task { @MainActor [weak self] in self?.flushMetadata() }
    }

    private func flushMetadata() {
        metadataFlushQueued = false
        let batch = metadataQueue
        metadataQueue = []
        guard !batch.isEmpty else { return }
        // Search results are spread over many folders, and the Trash over the disks: one batch per folder, each shown
        // as it comes, so a slow folder keeps only its own rows waiting.
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
        let listKey = listKey
        let generation = details.generation
        // A folder's rows have their Date Added from the folder read, the one the folder is sorted by; search
        // results came from no folder read.
        var listedAdded: [String: Int64?] = [:]
        if searchDisplay == nil {
            // A row asked for by its path alone (read again after it changed) is found among the folder's rows.
            var rows: [String: DirectoryEntry]?
            for path in paths {
                if let added = queuedAdded.removeValue(forKey: path) {
                    listedAdded.updateValue(added, forKey: path)
                } else {
                    if rows == nil { rows = rowsByPath }
                    if let row = rows?[path] { listedAdded.updateValue(row.addedMs, forKey: path) }
                }
            }
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let items = await self.loaders.metadata(folder, paths, listedAdded)
            let belongs = listKey == self.listKey
            let answers = Dictionary(items.map { ($0.path, $0) }) { $1 }
            let known = paths.filter { self.details[$0] != nil }
            guard let readAgain = self.details.finish(paths, from: generation, answers: belongs ? answers : nil),
                belongs
            else { return }
            // The rows that changed: those read, and those found gone that showed details from before. Nothing found
            // for a row that showed none (the folder is gone) changes no row.
            let changed = Set(answers.keys).union(known.filter { self.details[$0] == nil })
            if !changed.isEmpty { self.pane?.refresh(paths: changed) }
            self.updateStatus()
            if !readAgain.isEmpty { self.requestMetadata(for: readAgain) }
        }
    }

    // MARK: Finder tags

    /// What is listed: the search results shown, or the folder. An answer read for another list doesn't count.
    private var listKey: String { searchDisplay?.viewKey ?? folderPath }

    /// What was read for the item on screen, unless it changed since and its listing read it again; then what the
    /// listing read, which an item with a colored tag has from its first frame.
    func tagColors(for entry: DirectoryEntry) -> [FinderTagColor] {
        if let read = tags[entry.path], !tags.stale.contains(entry.path) { return read }
        return entry.tagColors ?? tags[entry.path] ?? []
    }

    /// Tags are read for the items on screen in every view, which draw them: reading them for a whole folder would
    /// cost a call per item for what is rarely there.
    func requestTags(for paths: [String]) {
        let wanted = tags.begin(paths)
        guard !wanted.isEmpty else { return }
        let listKey = listKey
        let generation = tags.generation
        Task { @MainActor [weak self] in
            guard let self else { return }
            let colors = await self.loaders.tagColors(wanted)
            let belongs = listKey == self.listKey
            guard let readAgain = self.tags.finish(wanted, from: generation, answers: belongs ? colors : nil), belongs
            else { return }
            self.pane?.refresh(paths: Set(wanted))
            if !readAgain.isEmpty { self.requestTags(for: readAgain) }
        }
    }

    /// This window changed the items' tags: they are read again now, before the change on disk is heard of.
    func tagsChanged(_ paths: [String]) {
        tags.markChanged(paths)
        requestTags(for: paths)
    }

    // MARK: Folder sizes

    private func folderSizesChanged() {
        barScaleCache = nil
        if sortBy == .size || (groupBy == .size && searchDisplay == nil), !listed.isEmpty {
            // The list is ordered, and grouped, again as each folder size arrives.
            let before = entries.map(\.path)
            let groupsBefore = groups
            reorder()
            if entries.map(\.path) != before || groups != groupsBefore {
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

    /// "240 items", "3 of 240 items" while a typed or a pinned filter hides some, "2 of 240 selected", then " · size".
    func updateStatus() {
        let size: StatusSize?
        if selection.isEmpty, searchDisplay != nil {
            size = nil
        } else if selection.isEmpty {
            // A folder's size says nothing of a Trash that also lists what is on other disks.
            let listsOtherFolders =
                Paths.isTrashFolder(folderPath, homePath: loaders.homePath)
                && listed.contains { NodePath.dirname($0.path) != folderPath }
            size =
                folderPath.isEmpty || listsOtherFolders ? nil : StatusSummary.folderSize(folderSizes.entry(folderPath))
        } else {
            let items = selectedEntries.map {
                SelectionItem(path: $0.path, isFolderSizeEligible: $0.isFolderSizeEligible)
            }
            let summary = SelectionSizing.summarize(
                items,
                fileSize: { [weak self] path in
                    guard let self else { return nil }
                    return self.details[path]?.sizeBytes ?? self.rowsByPath[path]?.sizeBytes
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
                itemCount: listed.count, shownCount: filter.isEmpty && pinnedFilter == nil ? nil : entries.count,
                selectedCount: selection.paths.count,
                size: size)
        }
        shell.pathBarRow.needsLayout = true
        onDetailsChanged?()
    }
}
