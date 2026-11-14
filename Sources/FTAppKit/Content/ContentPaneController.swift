// The entries and their details, the order, the folder sizes and size bars, and the selection
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
    /// The colors of items' Finder tags.
    var tagColors: @MainActor (_ paths: [String]) async -> [String: [FinderTagColor]] = { paths in
        await Task.detached(priority: .utility) {
            Dictionary(uniqueKeysWithValues: paths.map { ($0, FinderTags.colors($0)) })
        }.value
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
    /// What has been typed to narrow the list, floating over its foot.
    let filterPill = ListFilterPillView()
    var topInset = 0.0 {
        didSet { needsLayout = true }
    }
    var backgroundMenu: () -> NSMenu? = { nil }

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

    /// The filter pill: centered, 14 above the foot of the list.
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
    var onCompactListWidthChanged: ((Density, Int) -> Void)?
    var onIconSizeChanged: ((Density, Int) -> Void)?
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
    /// The filter pill's chip was pressed: the other way of matching is wanted (Settings → Browsing).
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
        didSet { sourceVersion &+= 1 }
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
    private(set) var includeHidden = false
    private(set) var columnState = ListColumnState.standard
    private(set) var listFilter = ListFilterTyping()
    /// How a filter starts finding names (Settings → Browsing), and how the one typed now does: a filter keeps the mode
    /// it started with, or that its chip gave it, whatever the setting says since.
    private(set) var defaultFilterMode = NameMatchMode.fuzzy
    private var typedFilterMode = NameMatchMode.fuzzy
    /// The typed filter's mode, or with none typed the one the next will start with.
    var filterMode: NameMatchMode { filter.isEmpty ? defaultFilterMode : typedFilterMode }
    /// The filter as it finds names, and the marks it gave names, kept until the text or the mode changes.
    private var filterMatcher: NameMatcher?
    private var filterMarks: [String: [HighlightRange]] = [:]
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
    private let foldedNames = FoldedNameCache()
    private(set) var search: ContentSearchContext?
    private var keptFolder: KeptFolder?

    private struct KeptFolder {
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
        folderSizes.onChange = { [weak self] in self?.folderSizesChanged() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    isolated deinit {
        for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
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
        // The pill's ✕ brings the list back as Esc does, a pinned filter too; the list keeps the keyboard.
        container.filterPill.onClear = { [weak self] in self?.removeFilter() }
        container.filterPill.onTogglePin = { [weak self] in self?.togglePin() }
        container.filterPill.onToggleMode = { [weak self] in self?.onToggleFilterMode?() }
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
        updateFilterPill()
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
        let orderBefore = takeOrderBeforeRemoval()
        listed = newEntries
        rowsCache = nil
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
        if let kept, !unchanged, keepingScroll, inlineRename == nil, previousPaths == entryPaths {
            // The same rows in the same order: only the rows of the items that changed are drawn again.
            pane?.reloadRows(paths: Set(kept.changedPaths).union(customIconPaths))
        } else if !unchanged || !keepingScroll {
            // The same folder in another order (a sort, Folders First, hidden files) starts at its top, and the List
            // stays where it was scrolled sideways: the column whose header was clicked stays in view.
            let keptLeft = sameFolder && !keepingScroll && pane is ListViewController ? pane?.scrollPosition.left : nil
            pane?.reload(scrollToTop: !keepingScroll)
            if let keptLeft, let top = pane?.scrollPosition.top { pane?.scrollPosition = (top, keptLeft) }
        } else {
            pane?.refresh(paths: changedPaths.map(Set.init))
            if !customIconPaths.isEmpty { pane?.reloadRows(paths: customIconPaths) }
        }
        pane?.syncSelection()
        if let memory { pane?.scrollPosition = (memory.scrollTop, memory.scrollLeft) }
        refreshState()
        updateStatus()
        if listed.isEmpty, !includeHidden, !folderPath.isEmpty { loadHiddenCount() }
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
    func setView(sortBy: SortByPreference, direction: SortDirectionPreference, foldersFirst: Bool, includeHidden: Bool)
    {
        self.sortBy = sortBy
        sortDirection = direction
        self.foldersFirst = foldersFirst
        self.includeHidden = includeHidden
        barScaleCache = nil
        pane?.refreshLook()
    }

    /// Sets the whole filter text at once, with its mode (a tab started from this one); the selection stays.
    func setFilter(_ text: String, mode: NameMatchMode? = nil) {
        guard text != filter || (mode != nil && mode != filterMode) else { return }
        startFilter(mode, ifEmpty: false)
        listFilter.set(text, at: ProcessInfo.processInfo.systemUptime)
        refilter(previousPaths: entryPaths)
    }

    /// A filter starting from nothing takes the default mode, or the one it is given.
    private func startFilter(_ mode: NameMatchMode? = nil, ifEmpty: Bool = true) {
        if !ifEmpty || filter.isEmpty { typedFilterMode = mode ?? defaultFilterMode }
    }

    /// Esc, the ✕, or leaving the folder: the whole list returns and the selection is kept, so something found by
    /// filtering can then be seen among its neighbours.
    func clearFilter() {
        guard !filter.isEmpty else { return }
        let previous = entryPaths
        listFilter.clear()
        onFilterChanged?(filter)
        refilter(previousPaths: previous)
        onFilterStateChanged?()
    }

    // MARK: Pinned filter

    /// Whether View ▸ Pin Filter can act: a filter typed in a folder can be pinned, and a pinned one unpinned.
    var canTogglePin: Bool { pinnedFilter != nil || (!filter.isEmpty && searchDisplay == nil) }

    /// View ▸ Pin Filter and the pill's pin: the filter typed in the folder is pinned, or the pinned one goes back to
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
        onFilterChanged?(filter)
        refilter(previousPaths: previous)
        onFilterStateChanged?()
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
            onFilterChanged?(filter)
        }
        refilter(previousPaths: previous)
        onFilterStateChanged?()
    }

    /// The pill's ✕: the filter goes, pinned or typed.
    func removeFilter() {
        guard pinnedFilter != nil || !filter.isEmpty else { return }
        let previous = entryPaths
        pinnedFilter = nil
        typedToSelect.clear()
        listFilter.clear()
        onFilterChanged?(filter)
        refilter(previousPaths: previous)
        onFilterStateChanged?()
    }

    /// A pane started from another (Duplicate Tab, a tab moved to another window) takes its pinned filter.
    func setPinnedFilter(_ pin: PinnedListFilter?) {
        guard pin != pinnedFilter else { return }
        let previous = entryPaths
        pinnedFilter = pin
        typedToSelect.clear()
        refilter(previousPaths: previous)
        onFilterStateChanged?()
    }

    /// An item the pinned filter hides is to be shown (Reveal, Go To a file, a paste, a rename): the pin goes, and a
    /// toast says so.
    private func dropPinToShowHidden() {
        guard let pin = pinnedFilter else { return }
        pinnedFilter = nil
        typedToSelect.clear()
        onFilterStateChanged?()
        _ = NotificationOverlay.push(
            .info, title: "The filter “\(pin.query)” is no longer pinned, to show an item it hid", in: view.window)
    }

    func typeToSelect(_ text: String?) {
        guard let text else {
            typedToSelect.clear()
            return
        }
        let query = typedToSelect.type(text, at: ProcessInfo.processInfo.systemUptime)
        guard let match = ListTypeToSelect.match(in: entries, query: query) else { return }
        setSelection(.single(match.path), notify: true)
        pane?.syncSelection()
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
        onFilterChanged?(filter)
        onFilterStateChanged?()
        reorder()
        pane?.reload(scrollToTop: false)
        refreshState()
        guard !filter.isEmpty else {
            pane?.syncSelection()
            updateStatus()
            return
        }
        let match = ListFilter.selection(in: entries, query: filter, mode: filterMode)
        setSelection(match.map { ContentSelection.single($0.path) } ?? .empty, notify: true)
        pane?.syncSelection()
        updateStatus()
    }

    /// Settings changed how a filter starts finding names. A filter already typed keeps its own mode.
    func setDefaultFilterMode(_ mode: NameMatchMode) {
        defaultFilterMode = mode
    }

    /// The chip: the typed filter switches to the other mode and narrows the list again, the selection kept. Returns
    /// the mode, which the caller makes the default for the filters to come.
    func toggleFilterMode() -> NameMatchMode {
        let next = filterMode.toggled
        guard !filter.isEmpty else { return next }
        typedFilterMode = next
        refilter(previousPaths: entryPaths)
        updateFilterPill()
        return next
    }

    /// The letters to mark in a name: what the filter matched while one is typed, otherwise what the search matched.
    /// Over search results a name the filter didn't match (its folder did) keeps the search's marks.
    func nameMarks(_ name: String) -> [HighlightRange] {
        if let filterMatcher {
            let found = filterMarks[name] ?? filterMatcher.marks(in: name)
            if filterMarks.count >= 10_000 { filterMarks.removeAll(keepingCapacity: true) }
            filterMarks[name] = found
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
            entryPaths = entries.map(\.path)
            positionsCache = nil
            barScaleCache = nil
            updateFilterPill()
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
        entryPaths = entries.map(\.path)
        positionsCache = nil
        barScaleCache = nil
        updateFilterPill()
    }

    /// The pinned filter keeps the folders and the files it matches of what the typed filter left.
    private func applyPin() {
        guard pinnedFilter != nil else { return }
        entries = ListFilter.filterPinned(entries, pin: pinnedFilter, isFolder: \.isDirectoryLike, cache: foldedNames)
    }

    private func updateFilterPill() {
        // Search results are narrowed in the results bar's own field; a pinned filter shows over them too.
        if let pinnedFilter {
            container.filterPill.show(
                query: pinnedFilter.query, mode: pinnedFilter.mode, shown: entries.count, total: listed.count,
                theme: theme, pinned: true)
        } else {
            container.filterPill.show(
                query: searchDisplay == nil ? filter : "", mode: filterMode, shown: entries.count,
                total: listed.count, theme: theme)
        }
        container.layoutFilterPill()
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
    /// new item outside the filter is selected on purpose, and is kept.
    private func resanitizeSelection(previousPaths: [String]) {
        guard !selection.isEmpty || selection.gapIndex != nil else { return }
        if let lead = selection.leadPath, position(of: lead) == nil, rowsByPath[lead] != nil { return }
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

    /// Selects the paths that are listed; the view keeps their lead in view (`RevealKeeper`). An item the filter hides is shown: the filter is
    /// cleared.
    func select(paths: [String]) {
        let existing = paths.filter { rowsByPath[$0] != nil }
        let selecting = ContentSelection.of(existing)
        if let lead = selecting.leadPath, position(of: lead) == nil, !filter.isEmpty || pinnedFilter != nil {
            dropPinToShowHidden()
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

    /// Starts renaming the item in its row. The item is shown first: one the filter hides clears the filter.
    /// Whether the item is listed.
    @discardableResult
    func beginRename(path: String) -> Bool {
        guard rowsByPath[path] != nil else { return false }
        if position(of: path) == nil, !filter.isEmpty || pinnedFilter != nil {
            dropPinToShowHidden()
            listFilter.clear()
            reorder()
            pane?.reload(scrollToTop: false)
            refreshState()
        }
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
        if entering {
            endLoading()
            keptFolder = KeptFolder(
                listed: listed, loadState: settled,
                hiddenItemCount: hiddenItemCount, details: details,
                scroll: pane?.scrollPosition ?? (0, 0))
        }
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
        reorder()
        pane?.reload(scrollToTop: false)
        refreshState()
        guard !filter.isEmpty else {
            pane?.syncSelection()
            updateStatus()
            return
        }
        let match = ListFilter.selection(in: entries, query: filter, mode: filterMode)
        setSelection(match.map { ContentSelection.single($0.path) } ?? .empty, notify: true)
        pane?.syncSelection()
        updateStatus()
    }

    /// The results come back as they were left: narrowed by the filter's text in its own mode and scrolled where they
    /// were. The selection is left to whoever brings them back.
    func restoreSearchView(filter text: String, mode: NameMatchMode, scroll: (top: Double, left: Double)?) {
        guard searchDisplay != nil else { return }
        if text != filter || (!text.isEmpty && mode != filterMode) {
            startFilter(mode, ifEmpty: false)
            listFilter.set(text, at: ProcessInfo.processInfo.systemUptime)
            onFilterChanged?(filter)
            reorder()
            pane?.reload(scrollToTop: false)
            refreshState()
            updateStatus()
        }
        guard let scroll else { return }
        view.layoutSubtreeIfNeeded()
        pane?.scrollPosition = scroll
    }

    /// Applies a selection to the list on screen, bringing its lead into view.
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

    /// The size of the view on screen, which View ▸ Make Bigger, Make Smaller and Default Size change; nil in the List.
    var viewSize: ViewSize? {
        ViewSize.of(
            mode, density: columnState.density, iconSizes: columnState.iconSizes,
            compactListWidths: columnState.compactListWidths)
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
        case .details: return
        }
        syncSizeSlider()
        shell.pathBarRow.flashSizeValue()
    }

    private func sizeSlid(to value: Double, save: Bool) {
        switch mode {
        case .icons: iconSizeChanged(value, save: save)
        case .list: compactListWidthChanged(value, save: save)
        case .details: break
        }
    }

    /// The slider shows the icon size in the Icons view and the column width in the Compact List, for the density on
    /// screen; the List has none.
    private func syncSizeSlider() {
        let bar = shell.pathBarRow
        let slider = bar.sizeSlider
        let density = columnState.density
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
    private func startDetailsOver(keeping kept: PathReadCache<EntryMetadata>? = nil) {
        details.startOver(keeping: kept)
        metadataQueue = []
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
        Task { @MainActor [weak self] in
            guard let self else { return }
            let items = await self.loaders.metadata(folder, paths)
            let belongs = listKey == self.listKey
            let answers = Dictionary(items.map { ($0.path, $0) }) { $1 }
            guard let readAgain = self.details.finish(paths, from: generation, answers: belongs ? answers : nil),
                belongs
            else { return }
            // Nothing found (the folder is gone): no row changed, and drawing them again would ask again.
            if !answers.isEmpty { self.pane?.refresh(paths: Set(answers.keys)) }
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
        if sortBy == .size, !listed.isEmpty {
            // The list is ordered again as each folder size arrives.
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

    /// "240 items", "3 of 240 items" while filtered, "2 of 240 selected", then " · size".
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
                itemCount: listed.count, shownCount: filter.isEmpty ? nil : entries.count,
                selectedCount: selection.paths.count,
                size: size)
        }
        shell.pathBarRow.needsLayout = true
        onDetailsChanged?()
    }
}
