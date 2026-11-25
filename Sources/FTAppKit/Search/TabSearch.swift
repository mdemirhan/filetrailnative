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
        field.onEditSearch = { [weak self] in self?.openEditSearch() }
        field.onEditorChange = { [weak self] in self?.fieldEditorChanged() }
        dropdown.view.onChoose = { [weak self] index in self?.chooseSuggestion(index) }
        dropdown.view.onHelp = { [weak self] in self?.openSyntaxHelp() }
        if field.stringValue != session.draftQuery { field.stringValue = session.draftQuery }
        showOptionMarks()
    }

    private var escapeInterceptor: Int?
    /// Whether the window asks this search about Esc.
    var listensForEscape: Bool { escapeInterceptor != nil }

    /// The pane was closed: the window no longer asks it about Esc.
    func disconnect() {
        dropdown.hide()
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
                errorIsQuiet: session.errorIsQuiet, itemsRead: session.itemsRead, startupDiskName: disk))
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
        // An open options menu is the system's, which has the keys first; then the list of what the word at the caret
        // can be.
        if dropdown.isShown, handleListKey(selector) { return true }
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
        // A word that can't be read is never searched without: the field keeps the keyboard, every such word is
        // marked, and the list says what is wrong with each and what would do.
        if !SearchQuery.problems(text).isEmpty, showProblems(in: text) { return }
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
        case matchScope, patternMode, recursive, skipGitFolders
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
            }
        }
        tab.group?.tabChanged(tab)
    }

    /// The options that differ from the defaults, by the menu's names.
    var changedOptions: [String] {
        let search = session
        return SearchBarText.changedOptions(
            matchScope: search.matchScope, patternMode: search.patternMode, recursive: search.recursive,
            skipGitFolders: search.skipGitFolders)
    }

    /// The bar's Options, and the toolbar's magnifier while this search drives the field, say whether an option differs
    /// from the defaults.
    func showOptionMarks() {
        let changed = changedOptions
        header.showOptions(changed: changed)
        if drivesField { field?.showOptions(changed: changed) }
    }

    /// The bar's Options: the same menu as the magnifier's, under the button. The keyboard stays where it is.
    // MARK: Conditions

    /// Finder's color tags, which `tag:` offers.
    static let colorTags = ["Red", "Orange", "Yellow", "Green", "Blue", "Purple", "Gray"]

    /// The list under the toolbar of what the word at the field's caret can be.
    let dropdown = SearchFieldDropdown()
    /// Esc closed the list for this text, or the field took the keyboard with it: the list waits for it to change.
    private var listClosedFor: String?
    /// The field had the keyboard when it last changed.
    private var fieldWasActive = false

    /// The field's text or caret changed, or it took or let go of the keyboard: the condition words are tinted and the
    /// list follows the word at the caret.
    /// The text whose words that can't be read Return showed, every one, until it changes.
    private var problemsShownFor: String?

    /// Shows what Return found wrong with `text`; false when the field hasn't the keyboard to show it in.
    private func showProblems(in text: String) -> Bool {
        guard let field, field.isActive, let editor = field.currentEditor() as? NSTextView,
            let list = SearchQuerySuggestions.problems(SearchQuery.problems(text))
        else { return false }
        problemsShownFor = text
        listClosedFor = nil
        SearchQueryTint.apply(to: editor, marksAll: true)
        dropdown.show(list, under: field)
        return true
    }

    func fieldEditorChanged() {
        guard drivesField, let field, field.isActive, let editor = field.currentEditor() as? NSTextView,
            tab.window?.attachedSheet == nil, DialogScrim.front(in: tab.window) == nil
        else {
            fieldWasActive = false
            dropdown.hide()
            return
        }
        let text = editor.string
        if problemsShownFor != nil, problemsShownFor != text { problemsShownFor = nil }
        SearchQueryTint.apply(to: editor, marksAll: problemsShownFor != nil)
        if problemsShownFor != nil { return }
        // Coming to the field, the list doesn't open on the word the caret lands on: it waits for typing. An empty field
        // lists every condition's word at once, to show what can be typed.
        if !fieldWasActive {
            fieldWasActive = true
            listClosedFor = text.allSatisfy(\.isWhitespace) ? nil : text
        }
        if listClosedFor != nil, listClosedFor != text { listClosedFor = nil }
        let selection = editor.selectedRange()
        guard listClosedFor == nil, selection.length == 0,
            let list = SearchQuerySuggestions.make(
                query: text, caret: selection.location, tags: Self.colorTags,
                folders: Self.folderNames(in: session.results), listsWordsForNewWord: true)
        else {
            dropdown.hide()
            return
        }
        dropdown.show(list, under: field)
    }

    /// The pane is no longer the one the field drives: its list goes, as nothing of this pane's would close it.
    func paneBecameInactive() {
        dropdown.hide()
    }

    /// ↑ ↓ move in the list, Tab takes the highlighted row, Return takes it unless it is the name itself, and Esc
    /// closes the list.
    private func handleListKey(_ selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            // While no row is highlighted the list is only an offer, and with results on screen ↓ goes into them, as
            // it does with no list: a word typed that could also be a condition ("doc", "red") doesn't take the key.
            // ↑ still goes into the list, and Tab takes its first row.
            if dropdown.view.highlighted < 0, session.isSearchMode {
                dropdown.hide()
                return false
            }
            dropdown.view.move(1)
            return true
        case #selector(NSResponder.moveUp(_:)):
            dropdown.view.move(-1)
            return true
        case #selector(NSResponder.insertTab(_:)):
            // With nothing highlighted, Tab completes the word being typed; at a new word, or one that reads as it is,
            // it moves on, as it does anywhere else.
            let list = dropdown.suggestions
            guard dropdown.view.highlighted >= 0 || (list?.range.length ?? 0 > 0 && list?.typedIsComplete == false)
            else {
                dropdown.hide()
                return false
            }
            chooseSuggestion(max(0, dropdown.view.highlighted))
            return true
        case #selector(NSResponder.insertNewline(_:)):
            // With no row highlighted, Return searches for the text as it is.
            guard dropdown.view.highlightedRow?.replacement != nil else {
                dropdown.hide()
                return false
            }
            chooseSuggestion(dropdown.view.highlighted)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            // In an empty field the list is only the words, shown unasked: Esc lets the field go, as it always has.
            // With text, it closes the list and the text stays.
            let empty = field?.stringValue.trimmingCharacters(in: .whitespaces).isEmpty ?? true
            listClosedFor = field?.stringValue
            dropdown.hide()
            return !empty
        default:
            return false
        }
    }

    /// Help, at Search: the words a search takes and how they combine. The list closes for it.
    func openSyntaxHelp() {
        dropdown.hide()
        listClosedFor = field?.stringValue
        (NSApp.delegate as? AppDelegate)?.pageWindows?.openHelp(topic: .search)
    }

    /// The list's row at `index` replaces the word at the caret, as typing it would: the field's text changes and is
    /// searched.
    func chooseSuggestion(_ index: Int) {
        guard let list = dropdown.suggestions, list.rows.indices.contains(index), list.rows[index].canBeChosen else {
            return
        }
        if list.rows[index].opensHelp {
            openSyntaxHelp()
            return
        }
        guard let replacement = list.rows[index].replacement else {
            listClosedFor = field?.stringValue
            dropdown.hide()
            return
        }
        guard let field, let editor = field.currentEditor() as? NSTextView else { return }
        editor.insertText(replacement, replacementRange: Self.range(list.range, taking: replacement, in: editor.string))
    }

    /// The text a row replaces: its word, and the space after it when the row brings one of its own, so a row taken
    /// in the middle of the text leaves one space and not two.
    static func range(_ range: NSRange, taking replacement: String, in text: String) -> NSRange {
        let text = text as NSString
        let end = NSMaxRange(range)
        guard replacement.hasSuffix(" "), end < text.length, text.character(at: end) == unichar(UInt8(ascii: " "))
        else { return range }
        return NSRange(location: range.location, length: range.length + 1)
    }

    /// A condition's word from the field's menu, typed after the word at the caret: its values are listed.
    func typeConditionWord(_ key: SearchQueryKey) {
        guard let field, let window = tab.window else { return }
        if !field.isActive {
            tab.explorerToolbar.beginSearch()
            if !field.isActive { window.makeFirstResponder(field) }
            field.currentEditor()?.selectedRange = NSRange(location: (field.stringValue as NSString).length, length: 0)
        }
        guard let editor = field.currentEditor() as? NSTextView else { return }
        let string = editor.string as NSString
        var location = editor.selectedRange().location
        while location < string.length, let scalar = Unicode.Scalar(string.character(at: location)),
            !CharacterSet.whitespaces.contains(scalar)
        {
            location += 1
        }
        let before = location > 0 ? Unicode.Scalar(string.character(at: location - 1)) : nil
        let space = before.map { !CharacterSet.whitespaces.contains($0) } ?? false
        editor.insertText((space ? " " : "") + key.word, replacementRange: NSRange(location: location, length: 0))
    }

    /// Edit Search: the search's text in the Edit Search box, over the window. Search there searches for it, as Return
    /// in the field does; Cancel leaves the search as it was. With nothing typed and no results shown, the pane's last
    /// search comes back first, text and results, as ⌘F brings it back: only in the folder it was made from.
    func openEditSearch() {
        guard let window = tab.window, DialogScrim.front(in: window) == nil, window.attachedSheet == nil else { return }
        AppMenuPresenter.shared.close()
        dropdown.hide()
        var text = field?.stringValue ?? session.draftQuery
        if !session.isSearchMode, text.allSatisfy(\.isWhitespace) {
            session.showCachedResults(fromField: true)
            text = session.draftQuery
        }
        let root = session.isSearchMode ? session.rootPath : pane.shownFolderPath
        let box = EditSearchBox(
            text: text,
            folderName: ExplorerTabs.folderDisplayName(
                root, homePath: tab.trashHomePath, startupDiskName: tab.services.startupDisk.name),
            nameVerb: session.patternMode == .text ? "contains" : "matches", tags: Self.colorTags,
            folders: { [weak self] in Self.folderNames(in: self?.session.results ?? []) })
        let scrim = DialogScrim(panel: box, placement: .sheet)
        scrim.onScrimPress = { [weak box] in box?.onClose() }
        box.onClose = { [weak scrim] in scrim?.dismiss() }
        box.onHelp = { (NSApp.delegate as? AppDelegate)?.pageWindows?.openHelp(topic: .search) }
        box.onSubmit = { [weak self, weak scrim] text in
            scrim?.dismiss()
            self?.searchFromEditor(text)
        }
        scrim.present(in: window)
        box.opened()
    }

    /// What the Edit Search box gives is searched for as Return in the field would: the field shows it, and the results
    /// take the keyboard.
    private func searchFromEditor(_ text: String) {
        session.setDraft(text)
        if drivesField, let field, field.stringValue != text { field.stringValue = text }
        submit()
    }

    /// The names of the folders the results are in, below the folder searched, those holding the most results first.
    static func folderNames(in results: [SearchResultItem]) -> [String] {
        var counts: [Substring: Int] = [:]
        for item in results where item.relativeParentPath != "." {
            for name in Set(item.relativeParentPath.split(separator: "/")) { counts[name, default: 0] += 1 }
        }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map { String($0.key) }
    }

    /// Clear Search Conditions: the condition words go from the text, and what is left is searched.
    func clearConditions() {
        let text = SearchQuery.removingConditions(from: field?.stringValue ?? session.draftQuery)
        // Through the field's editor while it is typed in, as typing would change it: ⌘Z brings the words back.
        if drivesField, let field, field.isActive, let editor = field.currentEditor() as? NSTextView,
            editor.string != text
        {
            editor.insertText(text, replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
        }
        session.setDraft(text)
        if drivesField, let field, field.stringValue != text { field.stringValue = text }
        session.submit(text)
    }

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
            .separator,
            .heading("Conditions"),
        ]
            + SearchQueryKey.menuOrder.map { key in
                AppMenuItem(title: key.title, detail: key == .is ? "is: · not:" : key.word) { [weak self] in
                    self?.typeConditionWord(key)
                }
            }
    }
}
