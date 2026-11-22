import AppKit
import FTFileSystem
import FTFoundation

/// One tab's search on screen: its session, the toolbar field that drives it, the results bar, and the content pane
/// showing the results in the tab's search view.
@MainActor
final class TabSearch: NSObject, SearchSessionHost, NSSearchFieldDelegate {
    private unowned let tab: MainWindowController
    /// The pane whose folder it searches and whose list shows its results.
    private unowned let pane: BrowserPane
    let session: SearchSession
    let header = SearchHeaderView()
    /// Whether the content pane shows the results now.
    private(set) var showsResults = false
    private var field: ToolbarSearchField? { tab.searchField }

    init(pane: BrowserPane, engine: any SearchEngine = SearchRuntime.shared) {
        tab = pane.tab
        self.pane = pane
        // The pane's own order and options: what it was given, or the app's, those chosen last in any pane.
        session = SearchSession(
            preferences: pane.shownPreferences(tab.preferences), includeHidden: pane.includeHidden, engine: engine)
        super.init()
        session.host = self
        header.showOptions(changed: changedOptions)
        header.onScopeChange = { [weak self] path in self?.session.changeRoot(path) }
        header.onFilterChange = { [weak self] text in
            guard let self else { return }
            self.pane.content.setSearchFilter(text)
            // A filter emptied shows the mode the next one starts with.
            self.header.showFilterMode(self.pane.content.filterMode)
        }
        header.onToggleFilterMode = { [weak self] in self?.pane.content.onToggleFilterMode?() }
        header.onFocusResults = { [weak self] in self?.pane.content.focusList() }
        header.onSwitchPane = { [weak self] in self?.pane.content.switchPane() }
        header.onOptions = { [weak self] in self?.openOptionsFromBar() }
        header.onStop = { [weak self] in self?.session.stop() }
        header.onDone = { [weak self] in self?.done() }
        header.onSearchAgain = { [weak self] in self?.session.rerun() }
        header.searchAgainShortcut = { [weak self] in
            self.flatMap { ShortcutDisplay(shortcuts: $0.pane.content.shortcuts).written(.refreshOrApplySearchSort) }
        }
        header.onHeightChange = { [weak self] in self?.layoutHeader() }
        let content = pane.content
        content.onSearchSort = { [weak self] key in self?.sortByColumn(key) }
        content.onSearchSortSet = { [weak self] key, direction in
            self?.session.setSort(key, direction)
            self?.saveSort()
        }
        content.onFilterChanged = { [weak self] text in
            guard let self, self.showsResults else { return }
            self.header.showFilterMode(self.pane.content.filterMode)
            guard self.header.filter.text != text else { return }
            self.header.filter.text = text
        }
    }

    /// Connects the toolbar's field, and Esc in the results.
    func connect(_ field: ToolbarSearchField?) {
        if escapeInterceptor == nil, let window = tab.window {
            escapeInterceptor = WindowEventRouting.add(window) { [weak self] event in
                self?.escapeInResults(event) ?? false
            }
        }
        guard let field else { return }
        field.delegate = self
        field.target = nil
        field.action = nil
        field.onFocus = { [weak self] in self?.fieldFocused() }
        field.onOptions = { [weak self] fromKeyboard in self?.openOptions(fromKeyboard: fromKeyboard) }
        field.onClear = { [weak self] in self?.clearPressed() }
        if field.stringValue != session.draftQuery { field.stringValue = session.draftQuery }
        showOptionMarks()
    }

    private var escapeInterceptor: Int?
    /// Whether the window asks this search about Esc.
    var listensForEscape: Bool { escapeInterceptor != nil }

    /// The pane was closed: the window no longer asks it about Esc.
    func disconnect() {
        guard let id = escapeInterceptor else { return }
        escapeInterceptor = nil
        if let window = tab.window { WindowEventRouting.remove(id, from: window) }
    }

    /// The toolbar's field shows this search: its pane is the one the tab has active. The other pane's search goes on
    /// without writing to the field.
    private var drivesField: Bool { tab.activePane === pane }

    /// Esc in the results, with no filter to clear first, puts them away and leaves the keyboard in the list.
    /// Keys of a text field (a rename, the filter field) are left alone.
    private func escapeInResults(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.keyCode == 53,
            event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty, session.isSearchMode
        else { return false }
        let content = pane.content
        guard content.filter.isEmpty, content.inlineRename == nil, let focus = content.focusView,
            tab.window?.firstResponder === focus
        else { return false }
        session.hideResults()
        content.focusList()
        return true
    }

    // MARK: SearchSessionHost

    var searchCurrentPath: String { pane.shownFolderPath }
    var searchIncludeHidden: Bool { pane.includeHidden }
    var searchFolderEntryPaths: [String] { pane.content.listed.map(\.path) }

    func searchSessionChanged(_ change: SearchSession.Change) {
        if change.contains(.draft), drivesField, let field, field.stringValue != session.draftQuery {
            field.stringValue = session.draftQuery
        }
        if !change.isDisjoint(with: [.results, .status, .visibility]) { refreshDisplay(change) }
        if change.contains(.options) { showOptionMarks() }
        if change.contains(.status), !session.isRunning, session.selectFirstResultWhenDone {
            selectFirstResultWhenDone()
        }
        pane.searchRootPath = session.isSearchMode ? session.rootPath : nil
        tab.searchStateChanged(in: pane)
        if session.isSearchMode { observeWrites() }
    }

    private var writesToken: ExplorerWindowObservation?

    /// The pane's results, shown or put away, change only after a write started in this tab that acted on them
    /// (`SearchAfterWrite`): nothing is searched again.
    private func observeWrites() {
        guard writesToken == nil, let group = tab.group, let writes = AppWriteOperations.current else { return }
        writesToken = writes.session(for: group).observe { [weak self] event in
            guard let self, case .ended(let ended, let inTabOnScreen) = event, inTabOnScreen,
                let result = ended.result, self.tab.group?.selected === self.tab
            else { return }
            self.applyWrite(SearchAfterWrite(result, homePath: Self.homePath))
        }
    }

    /// `write` changes the results when it acted on them, and the selection on screen follows what it renamed.
    func applyWrite(_ write: SearchAfterWrite) {
        guard session.hasCachedSearch, write.actsOn(session.resultPaths) else { return }
        let selecting = showsResults ? SearchSession.selection(pane.content.selection, after: write.renamed) : nil
        session.applyWrite(write)
        if let selecting, showsResults, selecting != pane.content.selection {
            pane.content.applySelection(selecting.sanitized(entryPaths: pane.content.entries.map(\.path)))
        }
    }

    func applySearchSelection(_ selection: ContentSelection) {
        pane.content.applySelection(selection)
    }

    func focusContentPaneForSearch() {
        pane.content.focusList()
    }

    var searchResultsFilter: String { showsResults ? pane.content.filter : "" }

    var searchResultsFilterMode: NameMatchMode { pane.content.filterMode }

    var searchResultsScroll: (top: Double, left: Double)? { showsResults ? pane.content.pane?.scrollPosition : nil }

    func restoreSearchResultsView(filter: String, mode: NameMatchMode, scroll: (top: Double, left: Double)?) {
        pane.content.restoreSearchView(filter: filter, mode: mode, scroll: scroll)
        header.filter.text = pane.content.filter
        header.showFilterMode(pane.content.filterMode)
    }

    // MARK: Showing the results

    /// The content pane follows the session: the results in the tab's search view, with the search's columns, the
    /// results bar above them; or the folder again.
    private func refreshDisplay(_ change: SearchSession.Change) {
        let content = pane.content
        guard session.isSearchMode else {
            guard showsResults else { return }
            showsResults = false
            content.endSearch()
            content.contentShell.searchHeader = nil
            // The folder's view, where one covers it, shows again.
            content.setMode(pane.shownMode)
            pane.refreshColumns()
            pane.folderViewChanged()
            return
        }
        let opening = !showsResults
        if opening {
            showsResults = true
            content.setMode(pane.searchViewMode)
            content.contentShell.searchHeader = header
            // Results are no folder: the folder view's symbol goes while they show.
            pane.folderViewChanged()
        }
        pane.refreshColumns()
        let rootPath = session.rootPath
        let disk = tab.services.startupDisk.name
        content.showSearch(
            ContentSearchDisplay(
                rootPath: rootPath, viewKey: "search:\(rootPath):\(session.committedQuery)", run: session.runNumber,
                results: session.shownResults, sortBy: session.sortBy, sortDirection: session.sortDirection,
                highlight: session.highlightPattern, isRunning: session.isRunning, error: session.error,
                errorIsQuiet: session.errorIsQuiet, unreadableFolders: session.unreadableFolders,
                startupDiskName: disk))
        // Results opened start in the mode new views start with; results brought back are given theirs after.
        if opening { content.setViewFilterMode(tab.preferences.listFilterMatch) }
        header.show(
            scopes: SearchBarText.scopeOptions(
                currentPath: pane.shownFolderPath, homePath: Self.homePath, startupDiskName: disk),
            rootPath: rootPath, isRunning: session.isRunning, truncated: session.truncated,
            mayBeMissingItems: session.mayBeMissingItems, filterText: content.filter)
        header.showFilterMode(content.filterMode)
        layoutHeader()
    }

    private func layoutHeader() {
        let shell = pane.content.contentShell
        shell.searchHeaderHeight = header.height
        shell.needsLayout = true
    }

    private static let homePath = DiskPath.home.string

    /// The columns of search results' List view, Name then those chosen for results, with their own widths, and the
    /// results' own sizes: `preferences` with the pane's laid over them.
    func columnState(_ preferences: AppPreferences) -> ListColumnState {
        var state = ListColumnState(preferences: preferences)
        state.columns = DetailsColumns.visible(
            visibility: preferences.searchColumns, order: preferences.searchColumnOrder)
        state.widths = DetailsColumns.widths(preferences.searchColumnWidths)
        state.iconSizes = preferences.searchIconSizes
        state.compactListWidths = preferences.searchCompactListWidths
        state.previewCounts = preferences.searchPreviewCounts
        return state
    }

    // MARK: The field

    /// The field took the keyboard: in the folder it was made from, the cached search comes back.
    private func fieldFocused() {
        session.showCachedResults(fromField: true)
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field else { return }
        session.updateDraft(field.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        // An open options menu is the system's, which has the keys first.
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            submit()
            return true
        case #selector(NSResponder.moveDown(_:)):
            // ↓ goes into the results, selecting the first if nothing is.
            guard session.isSearchMode else { return true }
            dismissField()
            selectFirstResultIfNone()
            return true
        case #selector(NSResponder.insertTab(_:)):
            // ⇥ goes on to the ✕ and the buttons after the field.
            guard let field else { return false }
            ToolbarKeyboard.move(from: field, backward: false)
            return true
        case #selector(NSResponder.insertBacktab(_:)):
            // ⇧⇥ goes back to the options button, which comes before the field.
            guard let field, field.optionsButton.takeKeyboard() else { return false }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            // Esc ends search mode, or forgets a draft that was not searched yet.
            if session.isSearchMode {
                session.hideResults()
            } else {
                session.abandonDraft()
            }
            dismissField()
            return true
        default:
            return false
        }
    }

    /// Return: what is on screen and final has its first result selected at once; anything else, once
    /// the search has finished.
    private func submit() {
        let text = field?.stringValue ?? session.draftQuery
        let onScreen = session.submit(text)
        // The list takes the keyboard every time, also after an empty field put the search away.
        dismissField()
        guard session.isSearchMode else { return }
        if onScreen {
            selectFirstResultIfNone()
        } else {
            session.selectFirstResultWhenDone = true
            if !session.isRunning { selectFirstResultWhenDone() }
        }
    }

    /// The field lets go of the keyboard, which goes to the results.
    private func dismissField() {
        AppMenuPresenter.shared.close()
        tab.explorerToolbar.endSearch()
        pane.content.focusList()
    }

    private func selectFirstResultIfNone() {
        let content = pane.content
        guard session.isSearchMode, content.selection.isEmpty, let first = content.entryPaths.first else { return }
        content.applySelection(.single(first))
    }

    /// The search sent with Return has finished: its first result is selected, if the results still show, the list has
    /// the keyboard and nothing is selected.
    private func selectFirstResultWhenDone() {
        session.selectFirstResultWhenDone = false
        guard session.isSearchMode, tab.focusedPane == .content else { return }
        selectFirstResultIfNone()
    }

    /// The ✕: the draft and the cached search go, and the field keeps the keyboard.
    private func clearPressed() {
        session.abandonDraft()
        session.clearCommittedSearch()
        if let field { tab.window?.makeFirstResponder(field) }
    }

    /// Done: the results close and the list has the keyboard.
    private func done() {
        AppMenuPresenter.shared.close()
        session.hideResults()
        pane.content.focusList()
    }

    // MARK: ⌘F, ⇧⌘F

    /// The field takes the keyboard with its text selected. Text typed into the folder list goes into
    /// it, and is searched at once, with the caret after it so typing goes on.
    func focusField() {
        let content = pane.content
        let typed = content.filter
        let carried = !session.isSearchMode && !typed.isEmpty
        if carried {
            content.clearFilter()
            session.setDraft(typed)
            session.startSearch(typed, rootPath: pane.shownFolderPath, live: true)
        } else {
            session.showCachedResults(fromField: true)
        }
        guard let field, let window = tab.window else { return }
        tab.explorerToolbar.beginSearch()
        if !field.isActive { window.makeFirstResponder(field) }
        if carried {
            field.currentEditor()?.selectedRange = NSRange(location: field.stringValue.utf16.count, length: 0)
        } else {
            field.currentEditor()?.selectAll(nil)
        }
    }

    /// Show Last Search Results.
    func showLastResults() {
        session.showCachedResults(focusPane: true)
    }

    // MARK: Sort

    /// View ▸ Sort By over the results: a field as a click on its column's title would order them, the same one again
    /// turning the order around.
    func sort(by key: SearchResultsSortByPreference) { sortByColumn(key) }

    private func sortByColumn(_ key: SearchResultsSortByPreference) {
        session.sortByColumn(key)
        saveSort()
    }

    /// The results' order is the pane's, saved with it, and what a pane with none to copy starts with.
    private func saveSort() {
        let (sortBy, direction) = (session.sortBy, session.sortDirection)
        pane.changeOwnSettings {
            $0.searchResultsSortBy = sortBy
            $0.searchResultsSortDirection = direction
        }
        tab.group?.tabChanged(tab)
    }

    // MARK: The options menu

    private enum Option {
        case matchScope, patternMode, recursive, skipGitFolders, skipGitIgnored
    }

    /// The option chosen in the menu is the pane's, saved with it, and what a pane with none to copy starts with; no
    /// other pane's search changes with it. Only that option goes to the app's: the others may have been chosen since
    /// in another pane, and this one's would take them back.
    private func save(_ option: Option) {
        let search = session
        pane.changeOwnSettings {
            switch option {
            case .matchScope: $0.searchMatchScope = search.matchScope
            case .patternMode: $0.searchPatternMode = search.patternMode
            case .recursive: $0.searchRecursive = search.recursive
            case .skipGitFolders: $0.searchSkipGitFolders = search.skipGitFolders
            case .skipGitIgnored: $0.searchSkipGitIgnored = search.skipGitIgnored
            }
        }
        tab.group?.tabChanged(tab)
    }

    /// The options that differ from the defaults, by the menu's names.
    var changedOptions: [String] {
        let search = session
        return SearchBarText.changedOptions(
            matchScope: search.matchScope, patternMode: search.patternMode, recursive: search.recursive,
            skipGitFolders: search.skipGitFolders, skipGitIgnored: search.skipGitIgnored)
    }

    /// The bar's Options, and the toolbar's magnifier while this search drives the field, say whether an option differs
    /// from the defaults.
    func showOptionMarks() {
        let changed = changedOptions
        header.showOptions(changed: changed)
        if drivesField { field?.showOptions(changed: changed) }
    }

    /// The bar's Options: the same menu as the magnifier's, under the button. The keyboard stays where it is.
    func openOptionsFromBar() {
        let presenter = AppMenuPresenter.shared
        let button = header.optionsButton
        if presenter.isOpen(from: button) {
            presenter.close()
            return
        }
        let menu = AppMenu(
            items: optionItems(), identifier: "searchOptionsMenu", rowIdentifier: "searchOptionsMenu.item")
        presenter.drop(menu, from: button)
    }

    /// The magnifier: the options as a menu with checkmarks. Opened with the mouse, the keyboard stays in the field;
    /// from the keyboard (Return or Space on the button), the first item is marked.
    func openOptions(fromKeyboard: Bool = false) {
        guard let field else { return }
        let presenter = AppMenuPresenter.shared
        if presenter.isOpen(from: field.optionsButton) {
            presenter.close()
            return
        }
        if !field.isActive { tab.window?.makeFirstResponder(field) }
        let items = optionItems()
        let menu = AppMenu(items: items, identifier: "searchOptionsMenu", rowIdentifier: "searchOptionsMenu.item")
        if fromKeyboard { menu.markedIndex = items.firstIndex { $0.kind == .item } }
        field.optionsOpen = true
        presenter.drop(menu, from: field, owner: field.optionsButton) { [weak field] in field?.optionsOpen = false }
    }

    private func optionItems() -> [AppMenuItem] {
        let search = session
        func item(
            _ title: String, _ checked: Bool, _ option: Option, _ apply: @escaping () -> Void
        ) -> AppMenuItem {
            AppMenuItem(title: title, checked: checked) { [weak self] in
                apply()
                self?.save(option)
            }
        }
        return [
            .heading("Match"),
            item("Name", search.matchScope == .name, .matchScope) { search.setMatchScope(.name) },
            item("Full Path", search.matchScope == .path, .matchScope) { search.setMatchScope(.path) },
            .separator,
            .heading("Match As"),
            item(SearchPatternModePreference.text.label, search.patternMode == .text, .patternMode) {
                search.setPatternMode(.text)
            },
            item(SearchPatternModePreference.glob.label, search.patternMode == .glob, .patternMode) {
                search.setPatternMode(.glob)
            },
            item(SearchPatternModePreference.regex.label, search.patternMode == .regex, .patternMode) {
                search.setPatternMode(.regex)
            },
            .separator,
            item("Search Subfolders", search.recursive, .recursive) { search.setRecursive(!search.recursive) },
            .separator,
            item("Skip .git Folders", search.skipGitFolders, .skipGitFolders) {
                search.setSkipGitFolders(!search.skipGitFolders)
            },
            item("Skip Files Ignored by Git", search.skipGitIgnored, .skipGitIgnored) {
                search.setSkipGitIgnored(!search.skipGitIgnored)
            },
        ]
    }
}
