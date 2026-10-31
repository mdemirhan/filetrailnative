// Port of the search wiring of apps/desktop/src/renderer/App.tsx (the field's handlers :2690-2760, ⌘F :2091-2108,
// selecting the first result :2050-2088, the results' columns :579-597, the search bar's props :2455-2553) and of
// components/ExplorerWorkspace.tsx (the search shell, :1319-1400) and SearchOptionsMenu.tsx
import AppKit
import FTFileSystem
import FTFoundation

/// One tab's search on screen: its session, the toolbar field that drives it, the results bar, and the content pane
/// showing the results in the tab's search view.
@MainActor
final class TabSearch: NSObject, SearchSessionHost, NSSearchFieldDelegate {
    private unowned let tab: MainWindowController
    let session: SearchSession
    let header = SearchHeaderView()
    /// Whether the content pane shows the results now.
    private(set) var showsResults = false
    private var field: ToolbarSearchField? { tab.searchField }

    init(tab: MainWindowController, engine: any SearchEngine = SearchRuntime.shared) {
        self.tab = tab
        session = SearchSession(preferences: tab.preferences, includeHidden: tab.includeHidden, engine: engine)
        super.init()
        session.host = self
        header.onScopeChange = { [weak self] path in self?.session.changeRoot(path) }
        header.onFilterChange = { [weak self] text in self?.tab.content.setSearchFilter(text) }
        header.onFocusResults = { [weak self] in self?.tab.content.focusList() }
        header.onSwitchPane = { [weak self] in self?.tab.content.switchPane() }
        header.onStop = { [weak self] in self?.session.stop() }
        header.onDone = { [weak self] in self?.done() }
        header.onHeightChange = { [weak self] in self?.layoutHeader() }
        let content = tab.content
        content.onSearchSort = { [weak self] key in self?.sortByColumn(key) }
        content.onSearchSortSet = { [weak self] key, direction in
            self?.session.setSort(key, direction)
            self?.saveSort()
        }
        content.onFilterChanged = { [weak self] text in
            guard let self, self.showsResults, self.header.filter.text != text else { return }
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
    }

    private var escapeInterceptor: Int?

    /// Esc in the results, with no filter to clear first, puts them away and leaves the keyboard in the list
    /// (B-SRCH-062). Keys of a text field (a rename, the filter field) are left alone.
    private func escapeInResults(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.keyCode == 53,
            event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty, session.isSearchMode
        else { return false }
        let content = tab.content
        guard content.filter.isEmpty, content.inlineRename == nil, let focus = content.focusView,
            tab.window?.firstResponder === focus
        else { return false }
        session.hideResults()
        content.focusList()
        return true
    }

    // MARK: SearchSessionHost

    var searchCurrentPath: String { tab.shownFolderPath }
    var searchIncludeHidden: Bool { tab.includeHidden }
    var searchFolderEntryPaths: [String] { tab.content.listed.map(\.path) }

    func searchSessionChanged(_ change: SearchSession.Change) {
        if change.contains(.draft), let field, field.stringValue != session.draftQuery {
            field.stringValue = session.draftQuery
        }
        if !change.isDisjoint(with: [.results, .status, .visibility]) { refreshDisplay(change) }
        if change.contains(.status), !session.isRunning, session.selectFirstResultWhenDone {
            selectFirstResultWhenDone()
        }
        tab.searchRootPath = session.isSearchMode ? session.rootPath : nil
        tab.searchStateChanged()
        if session.isSearchMode { observeWrites() }
    }

    private var writesToken: ExplorerWindowObservation?

    /// Search results on screen stay there after a write that changed at least one item: they are found again, so
    /// they show what is on disk. So do those a move was dragged out of, put away before it ended (B-SRCH-141).
    private func observeWrites() {
        guard writesToken == nil, let group = tab.group, let writes = AppWriteOperations.current else { return }
        let writeSession = writes.session(for: group)
        writesToken = writeSession.observe { [weak self, weak writeSession] event in
            guard let self, case .ended(let ended, let inTabOnScreen) = event, inTabOnScreen,
                let result = ended.result, result.summary.completedItemCount > 0,
                self.tab.group?.selected === self.tab,
                self.session.isSearchMode || writeSession?.isMoveFromSearchResults(ended.operationId) == true
            else { return }
            self.session.rerun()
        }
    }

    func applySearchSelection(_ selection: ContentSelection) {
        tab.content.applySelection(selection)
    }

    func focusContentPaneForSearch() {
        tab.content.focusList()
    }

    // MARK: Showing the results

    /// The content pane follows the session: the results in the tab's search view, with the search's columns, the
    /// results bar above them; or the folder again.
    private func refreshDisplay(_ change: SearchSession.Change) {
        let content = tab.content
        guard session.isSearchMode else {
            guard showsResults else { return }
            showsResults = false
            content.endSearch()
            content.contentShell.searchHeader = nil
            content.setMode(tab.viewMode)
            tab.refreshColumns()
            return
        }
        if !showsResults {
            showsResults = true
            content.setMode(tab.searchViewMode)
            content.contentShell.searchHeader = header
        }
        tab.refreshColumns()
        let rootPath = session.rootPath
        content.showSearch(
            ContentSearchDisplay(
                rootPath: rootPath, viewKey: "search:\(rootPath):\(session.committedQuery)",
                results: session.shownResults, sortBy: session.sortBy, sortDirection: session.sortDirection,
                highlight: session.highlightPattern, isRunning: session.isRunning, error: session.error,
                errorIsQuiet: session.errorIsQuiet))
        header.show(
            scopes: SearchBarText.scopeOptions(currentPath: tab.shownFolderPath, homePath: Self.homePath),
            rootPath: rootPath, isRunning: session.isRunning, truncated: session.truncated, filterText: content.filter)
        layoutHeader()
    }

    private func layoutHeader() {
        let shell = tab.content.contentShell
        shell.searchHeaderHeight = header.height
        shell.needsLayout = true
    }

    private static let homePath = FileManager.default.homeDirectoryForCurrentUser.path

    /// The columns of search results' List view: Name, then those chosen for results in Settings, with their own widths.
    func columnState(_ preferences: AppPreferences) -> ListColumnState {
        var state = ListColumnState(preferences: preferences)
        state.columns = DetailsColumns.visible(
            visibility: preferences.searchColumns, order: preferences.searchColumnOrder)
        state.widths = DetailsColumns.widths(preferences.searchColumnWidths)
        return state
    }

    // MARK: The field

    /// `onFocus`: the cached search comes back when the field is focused in the folder it was made from.
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

    /// Return (`submitSearch`): what is on screen and final has its first result selected at once; anything else, once
    /// the search has finished.
    private func submit() {
        let text = field?.stringValue ?? session.draftQuery
        let onScreen = session.submit(text)
        // The list takes the keyboard every time, also after an empty field put the search away (B-SRCH-011).
        dismissField()
        guard session.isSearchMode else { return }
        if onScreen {
            selectFirstResultIfNone()
        } else {
            session.selectFirstResultWhenDone = true
            if !session.isRunning { selectFirstResultWhenDone() }
        }
    }

    /// The field lets go of the keyboard, which goes to the results (`dismissFileSearch({ focusBelow: true })`).
    private func dismissField() {
        AppMenuPresenter.shared.close()
        tab.explorerToolbar.endSearch()
        tab.content.focusList()
    }

    private func selectFirstResultIfNone() {
        let content = tab.content
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
        tab.content.focusList()
    }

    // MARK: ⌘F, ⇧⌘F

    /// `focusFileSearch`: the field takes the keyboard with its text selected. Text typed into the folder list goes into
    /// it, and is searched at once.
    func focusField() {
        let content = tab.content
        let typed = content.filter
        if !session.isSearchMode, !typed.isEmpty {
            content.clearFilter()
            session.setDraft(typed)
            session.startSearch(typed, rootPath: tab.shownFolderPath, live: true)
        } else {
            session.showCachedResults(fromField: true)
        }
        guard let field, let window = tab.window else { return }
        tab.explorerToolbar.beginSearch()
        if !field.isActive { window.makeFirstResponder(field) }
        field.currentEditor()?.selectAll(nil)
    }

    /// Show Last Search Results.
    func showLastResults() {
        session.showCachedResults(focusPane: true)
    }

    // MARK: Sort

    private func sortByColumn(_ key: SearchResultsSortByPreference) {
        session.sortByColumn(key)
        saveSort()
    }

    /// The results' order is kept with the window, as the original's preference sync keeps it.
    private func saveSort() {
        tab.updatePreferences([
            "searchResultsSortBy": .string(session.sortBy.rawValue),
            "searchResultsSortDirection": .string(session.sortDirection.rawValue),
        ])
    }

    // MARK: The options menu

    /// The magnifier: the options as a menu with checkmarks. Opened with the mouse, the keyboard stays in the field;
    /// from the keyboard (Return or Space on the button), the first item is marked (B-SRCH-081).
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
        func item(_ title: String, _ checked: Bool, _ apply: @escaping () -> Void) -> AppMenuItem {
            AppMenuItem(title: title, checked: checked, action: apply)
        }
        return [
            .heading("Match"),
            item("Name", search.matchScope == .name) { search.setMatchScope(.name) },
            item("Full Path", search.matchScope == .path) { search.setMatchScope(.path) },
            .separator,
            .heading("Match As"),
            item(SearchPatternModePreference.text.label, search.patternMode == .text) { search.setPatternMode(.text) },
            item(SearchPatternModePreference.glob.label, search.patternMode == .glob) { search.setPatternMode(.glob) },
            item(SearchPatternModePreference.regex.label, search.patternMode == .regex) {
                search.setPatternMode(.regex)
            },
            .separator,
            item("Search Subfolders", search.recursive) { search.setRecursive(!search.recursive) },
            .separator,
            item("Skip .git Folders", search.skipGitFolders) { search.setSkipGitFolders(!search.skipGitFolders) },
            item("Skip Files Ignored by Git", search.skipGitIgnored) {
                search.setSkipGitIgnored(!search.skipGitIgnored)
            },
        ]
    }
}
