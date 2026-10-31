// Port of apps/desktop/src/renderer/hooks/useExplorerSearchController.ts and hooks/useSearchSession.ts: one tab's search
// session (query, scope, options, sort, results, both selections, job and cursor), and the background polling of
// hooks/useExplorerTabs.ts (pollBackgroundSearches)
import FTFileSystem
import FTFoundation
import Foundation

extension SearchResultItem: ListFilterSearchResult, SearchRefinementItem {}

/// What a session needs of its tab: the folder open there, whether it shows hidden files, the folder list's selection,
/// and the list to apply a selection to.
@MainActor
protocol SearchSessionHost: AnyObject {
    /// The folder open in the tab (`currentPath`).
    var searchCurrentPath: String { get }
    /// Whether the file list shows hidden files: search includes them exactly then.
    var searchIncludeHidden: Bool { get }
    /// The paths of the folder's entries, to clean a selection against when the folder list comes back.
    var searchFolderEntryPaths: [String] { get }
    /// The session changed: the tab shows it again.
    func searchSessionChanged(_ change: SearchSession.Change)
    /// `applyContentSelection`: the selection of the list now on screen (the results, or the folder).
    func applySearchSelection(_ selection: ContentSelection)
    /// `focusContentPane`.
    func focusContentPaneForSearch()
}

/// One tab's search. Only what the tab needs to show it is published; the rest is the controller's own bookkeeping.
/// While its tab is in the background the session keeps its search going, asking about it once a second.
@MainActor
final class SearchSession {
    /// What changed, for the tab to show it again.
    struct Change: OptionSet {
        let rawValue: Int
        /// The results shown: the found results, the committed query, the sort, the root.
        static let results = Change(rawValue: 1 << 0)
        /// Status, error, truncation.
        static let status = Change(rawValue: 1 << 1)
        /// Search mode began or ended.
        static let visibility = Change(rawValue: 1 << 2)
        /// The field's text.
        static let draft = Change(rawValue: 1 << 3)
        /// The five options.
        static let options = Change(rawValue: 1 << 4)
        static let all: Change = [.results, .status, .visibility, .draft, .options]
    }

    weak var host: (any SearchSessionHost)?
    /// What the searches run on, and the timers of typing and polling (a test puts its own in).
    var engine: any SearchEngine
    var timers: any TimerScheduling
    private let clock: () -> TimeInterval

    // MARK: Published state

    private(set) var draftQuery = ""
    private(set) var committedQuery = ""
    /// The text the running or finished walk was started with.
    private(set) var baseQuery = ""
    private(set) var rootPath = ""
    /// The folder the search was started from (`searchOriginPathRef`).
    private(set) var originPath = ""
    private(set) var patternMode: SearchPatternModePreference
    private(set) var matchScope: SearchMatchScopePreference
    private(set) var recursive: Bool
    private(set) var skipGitFolders: Bool
    private(set) var skipGitIgnored: Bool
    private(set) var sortBy: SearchResultsSortByPreference
    private(set) var sortDirection: SortDirectionPreference
    private(set) var resultsVisible = false
    /// As the walk found them, in arrival order.
    private(set) var results: [SearchResultItem] = []
    private(set) var status: TabSearchStatus = .idle
    private(set) var error: String?
    /// Started by typing: a pattern that does not parse yet is not shown as a failure.
    private(set) var startedLive = false
    private(set) var truncated = false
    /// How long the search took, for the log (never shown); nil for one that finished in the background.
    private(set) var elapsedMilliseconds: Double?

    // MARK: Bookkeeping

    private(set) var jobID: String?
    private(set) var cursor = 0
    /// Results kept from the previous search because they also match the new one; the new search finds them again,
    /// and they are not listed twice.
    private var keptResultPaths: Set<String> = []
    /// The results were put away while the search ran: it runs again when they are shown.
    private(set) var interrupted = false
    /// The hidden-files setting the results were found with.
    private var searchedHidden: Bool
    /// The folder list's selection, for when the search closes.
    private(set) var browseSelection = ContentSelection.empty
    /// The results' selection, for when they are shown again.
    private(set) var cachedSearchSelection = ContentSelection.empty
    /// Answers from searches that are no longer the one on screen are dropped by this counter.
    private(set) var sessionCounter = 0
    /// The place in the tab's history the results were left from by opening a folder (`searchReturnPlaceRef`): Back and
    /// Forward bring them back there.
    private(set) var returnPlace: NavigationHistory.Place?
    private var liveTimer: TimerToken?
    /// The text the live-search timer waits to search for.
    private(set) var pendingLiveQuery: String?
    private var pollTimer: TimerToken?
    private var startedAt: TimeInterval?
    /// The tab is in the background: its search is asked about once a second, and typing waits for it to come back.
    private(set) var isBackground = false
    /// The first answer after the tab came back: a search that finished meanwhile has no known duration.
    private var awaitingFirstUpdateAfterReturn = false
    /// Return asked for the first result to be selected once the search has finished (`selectFirstWhenDone`).
    var selectFirstResultWhenDone = false

    init(
        preferences: AppPreferences, includeHidden: Bool, engine: any SearchEngine = SearchRuntime.shared,
        timers: any TimerScheduling = TaskTimerScheduler(),
        clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.engine = engine
        self.timers = timers
        self.clock = clock
        patternMode = preferences.searchPatternMode
        matchScope = preferences.searchMatchScope
        recursive = preferences.searchRecursive
        skipGitFolders = preferences.searchSkipGitFolders
        skipGitIgnored = preferences.searchSkipGitIgnored
        sortBy = preferences.searchResultsSortBy
        sortDirection = preferences.searchResultsSortDirection
        searchedHidden = includeHidden
    }

    /// A new tab's session: nothing searched, with the options and sort of `other` (`createEmptySearchSession`).
    func takeOptions(of other: SearchSession) {
        patternMode = other.patternMode
        matchScope = other.matchScope
        recursive = other.recursive
        skipGitFolders = other.skipGitFolders
        skipGitIgnored = other.skipGitIgnored
        sortBy = other.sortBy
        sortDirection = other.sortDirection
    }

    // MARK: What the tab shows

    /// `hasCachedSearch`: a committed search exists, shown or not.
    var hasCachedSearch: Bool { !SearchTiming.trimmed(committedQuery).isEmpty }
    /// `isSearchMode`.
    var isSearchMode: Bool { resultsVisible && hasCachedSearch }
    var isRunning: Bool { status == .running }

    /// `refinedSearchResults` then `sortedSearchResults`: what the walk found, narrowed to the committed text when
    /// it has grown since the walk began, in the chosen order.
    var shownResults: [SearchResultItem] {
        if let cache = shownCache, cache.version == resultsVersion { return cache.items }
        // Narrowing keeps the order, so the sorted results are narrowed: the same list as sorting the narrowed ones.
        let sorted = sortedResults()
        let shown =
            baseQuery == committedQuery
            ? sorted
            : sorted.filter {
                SearchRefinement.matchesTextQuery($0, query: committedQuery, scope: refinementScope)
            }
        shownCache = (resultsVersion, shown)
        return shown
    }

    private var resultsVersion = 0
    private var shownCache: (version: Int, items: [SearchResultItem])?
    /// Bumped when the results are replaced rather than added to.
    private var resultsGeneration = 0
    private var sortedCache:
        (
            generation: Int, count: Int, sortBy: SearchResultsSortByPreference, direction: SortDirectionPreference,
            items: [SearchResultItem]
        )?

    /// Every result in the chosen order. Results stream in: a new batch is sorted on its own and merged in, which
    /// gives the order a sort of them all would (equal results keep the order they came in).
    private func sortedResults() -> [SearchResultItem] {
        if let cache = sortedCache, cache.generation == resultsGeneration, cache.sortBy == sortBy,
            cache.direction == sortDirection, cache.count <= results.count
        {
            if cache.count == results.count { return cache.items }
            let added = SearchResults.sort(Array(results[cache.count...]), by: sortBy, direction: sortDirection)
            let merged = merge(cache.items, added)
            sortedCache = (resultsGeneration, results.count, sortBy, sortDirection, merged)
            return merged
        }
        let sorted = SearchResults.sort(results, by: sortBy, direction: sortDirection)
        sortedCache = (resultsGeneration, results.count, sortBy, sortDirection, sorted)
        return sorted
    }

    private func merge(_ earlier: [SearchResultItem], _ later: [SearchResultItem]) -> [SearchResultItem] {
        let sign = sortDirection == .asc ? 1 : -1
        var merged: [SearchResultItem] = []
        merged.reserveCapacity(earlier.count + later.count)
        var left = 0
        var right = 0
        while left < earlier.count, right < later.count {
            // Ties go to the earlier result.
            if SearchResults.compare(later[right], earlier[left], by: sortBy) * sign < 0 {
                merged.append(later[right])
                right += 1
            } else {
                merged.append(earlier[left])
                left += 1
            }
        }
        merged += earlier[left...]
        merged += later[right...]
        return merged
    }

    private var refinementScope: SearchMatchScope { matchScope == .path ? .path : .name }

    /// `errorIsQuiet`: a pattern being typed that does not parse yet.
    var errorIsQuiet: Bool { startedLive && patternMode != .text }

    /// What a search matched in names, to mark it (`buildSearchHighlightPattern`).
    var highlightPattern: JSLegacyRegExp? {
        if let cache = highlightCache, cache.key == highlightKey { return cache.pattern }
        let pattern = SearchResults.highlightPattern(
            query: committedQuery, patternMode: patternMode, matchScope: matchScope)
        highlightCache = (highlightKey, pattern)
        return pattern
    }

    private var highlightKey: String { "\(patternMode.rawValue)\0\(matchScope.rawValue)\0\(committedQuery)" }
    private var highlightCache: (key: String, pattern: JSLegacyRegExp?)?

    private func resultsChanged() {
        resultsVersion += 1
    }

    // MARK: Selection

    /// The selection of the list on screen changed: it is the results' while they show, the folder's otherwise.
    func noteSelection(_ selection: ContentSelection) {
        if isSearchMode {
            cachedSearchSelection = selection
        } else {
            browseSelection = selection
        }
    }

    // MARK: Showing and hiding

    /// `showCachedSearchResults`: brings a cached search back, with its query in the field. From the field, only in
    /// the folder it was made from.
    func showCachedResults(focusPane: Bool = false, fromField: Bool = false) {
        guard hasCachedSearch, let host else { return }
        if fromField, originPath != host.searchCurrentPath { return }
        draftQuery = committedQuery
        if searchedHidden != host.searchIncludeHidden || interrupted {
            emit(.draft)
            startSearch(committedQuery, rootPath: rootPath.isEmpty ? host.searchCurrentPath : rootPath)
            if focusPane { host.focusContentPaneForSearch() }
            return
        }
        let wasVisible = resultsVisible
        resultsVisible = true
        emit(wasVisible ? .draft : [.draft, .visibility])
        let paths = shownResults.map(\.path)
        host.applySearchSelection(cachedSearchSelection.sanitized(entryPaths: paths))
        if focusPane { host.focusContentPaneForSearch() }
    }

    /// `hideSearchResults`: Esc, Done, opening a folder. The results stay cached; the field empties and the folder
    /// list's selection comes back. `returnPlace`: opening another folder left them there, and Back and Forward can
    /// bring them back; otherwise they were closed.
    func hideResults(returnPlace: NavigationHistory.Place? = nil) {
        cancelLiveSearch()
        self.returnPlace = returnPlace
        let restore = browseSelection
        draftQuery = ""
        let wasVisible = resultsVisible
        resultsVisible = false
        // A search whose results are put away stops walking the disk; it runs again when they are shown.
        var change: Change = wasVisible ? [.draft, .visibility] : .draft
        if jobID != nil {
            interrupted = true
            cancelActiveSearch()
            status = .cancelled
            change.insert(.status)
        }
        emit(change)
        guard let host else { return }
        host.applySearchSelection(restore.sanitized(entryPaths: host.searchFolderEntryPaths))
    }

    /// `applyEmptyDirectorySnapshot`: the tab let go of its folder. The results go, and a search still walking the disk
    /// stops as it does whenever they are put away; what is typed in the field stays.
    func putResultsAway() {
        guard resultsVisible else { return }
        resultsVisible = false
        var change: Change = .visibility
        if jobID != nil {
            interrupted = true
            cancelActiveSearch()
            status = .cancelled
            change.insert(.status)
        }
        emit(change)
    }

    /// `stopSearch`: Stop. The results found so far stay.
    func stop() {
        cancelLiveSearch()
        cancelActiveSearch()
        status = .cancelled
        error = nil
        emit(.status)
    }

    /// `clearCommittedSearch`: nothing is cached afterwards.
    func clearCommittedSearch() {
        cancelLiveSearch()
        interrupted = false
        cancelActiveSearch()
        sessionCounter += 1
        returnPlace = nil
        let wasVisible = resultsVisible
        let restore = browseSelection
        committedQuery = ""
        baseQuery = ""
        rootPath = ""
        results = []
        resultsGeneration += 1
        keptResultPaths = []
        resultsChanged()
        status = .idle
        error = nil
        truncated = false
        resultsVisible = false
        cachedSearchSelection = .empty
        emit(wasVisible ? [.results, .status, .visibility] : [.results, .status])
        guard let host else { return }
        host.applySearchSelection(restore.sanitized(entryPaths: host.searchFolderEntryPaths))
    }

    // MARK: Typing

    /// `updateSearchDraftQuery`: text that only narrows what the search covers is applied at once; anything else is
    /// searched once the keyboard rests; text too short shows the folder again.
    func updateDraft(_ text: String) {
        draftQuery = text
        cancelLiveSearch()
        let trimmed = SearchTiming.trimmed(text)
        if trimmed.utf16.count < SearchTiming.liveSearchMinLength {
            if hasCachedSearch { clearCommittedSearch() }
            return
        }
        if canRefine(trimmed) {
            refine(trimmed)
            return
        }
        scheduleLiveSearch(trimmed)
    }

    /// `submitSearch`: Return. Whether the results for the query were already on screen and final.
    @discardableResult
    func submit(_ text: String) -> Bool {
        cancelLiveSearch()
        let trimmed = SearchTiming.trimmed(text)
        let root = resolveRootPath()
        if !trimmed.isEmpty, resultsVisible, trimmed == committedQuery, root == rootPath {
            startedLive = false
            emit(.status)
            return status != .running
        }
        if canRefine(trimmed) {
            refine(trimmed)
            startedLive = false
            emit(.status)
            return status != .running
        }
        startSearch(trimmed, rootPath: root, keepMatching: true)
        return false
    }

    /// `abandonSearchDraft`: Esc before anything was searched.
    func abandonDraft() {
        cancelLiveSearch()
        draftQuery = ""
        emit(.draft)
    }

    /// The field shows `text` without it being typed (⌘F carries the list filter over).
    func setDraft(_ text: String) {
        draftQuery = text
        emit(.draft)
    }

    private func cancelLiveSearch() {
        liveTimer?.cancel()
        liveTimer = nil
        pendingLiveQuery = nil
    }

    private func scheduleLiveSearch(_ trimmed: String) {
        pendingLiveQuery = trimmed
        liveTimer = timers.schedule(after: SearchTiming.liveSearchDelay) { [weak self] in
            guard let self else { return }
            self.liveTimer = nil
            self.pendingLiveQuery = nil
            // The field may have been emptied or the folder left in the meantime.
            guard SearchTiming.trimmed(self.draftQuery) == trimmed else { return }
            self.startSearch(trimmed, rootPath: self.resolveRootPath(), live: true, keepMatching: true)
        }
    }

    /// `resolveSearchRootPath`: the scope of the search on screen while its folder is still open (so a widened scope
    /// survives further typing), otherwise the open folder.
    func resolveRootPath() -> String {
        let current = host?.searchCurrentPath ?? ""
        let continues = hasCachedSearch && resultsVisible && !rootPath.isEmpty && originPath == current
        return continues ? rootPath : current
    }

    /// `canRefineSearch`.
    private func canRefine(_ query: String) -> Bool {
        patternMode == .text && resultsVisible && (status == .running || status == .complete) && !truncated
            && resolveRootPath() == rootPath && SearchRefinement.isNarrower(base: baseQuery, next: query)
    }

    private func refine(_ query: String) {
        guard query != committedQuery else { return }
        committedQuery = query
        returnPlace = nil
        resultsChanged()
        cachedSearchSelection = .empty
        emit(.results)
        host?.applySearchSelection(.empty)
    }

    // MARK: Options, scope, sort

    func setPatternMode(_ value: SearchPatternModePreference) {
        patternMode = value
        optionChanged()
    }

    func setMatchScope(_ value: SearchMatchScopePreference) {
        matchScope = value
        optionChanged()
    }

    func setRecursive(_ value: Bool) {
        recursive = value
        optionChanged()
    }

    func setSkipGitFolders(_ value: Bool) {
        skipGitFolders = value
        optionChanged()
    }

    func setSkipGitIgnored(_ value: Bool) {
        skipGitIgnored = value
        optionChanged()
    }

    /// A Settings edit updates the live values of the keys it changed (`onRemotePatch`), without running anything
    /// again; the others keep what was chosen in the options menu.
    func applyDefaults(_ preferences: AppPreferences, keys: Set<String>) {
        if keys.contains("searchPatternMode") { patternMode = preferences.searchPatternMode }
        if keys.contains("searchMatchScope") { matchScope = preferences.searchMatchScope }
        if keys.contains("searchRecursive") { recursive = preferences.searchRecursive }
        if keys.contains("searchSkipGitFolders") { skipGitFolders = preferences.searchSkipGitFolders }
        if keys.contains("searchSkipGitIgnored") { skipGitIgnored = preferences.searchSkipGitIgnored }
        emit(.options)
    }

    /// Any option change with a committed search runs it again at once, without keeping old results.
    private func optionChanged() {
        emit(.options)
        guard hasCachedSearch else { return }
        startSearch(committedQuery, rootPath: rootPath.isEmpty ? (host?.searchCurrentPath ?? "") : rootPath)
    }

    /// `rerunSearch`: ⌘R in search mode, and after a write that changed what is on disk.
    func rerun() {
        guard hasCachedSearch else { return }
        startSearch(committedQuery, rootPath: rootPath.isEmpty ? (host?.searchCurrentPath ?? "") : rootPath)
    }

    /// `changeSearchRoot`: another scope in the results bar.
    func changeRoot(_ path: String) {
        guard hasCachedSearch, !path.isEmpty else { return }
        startSearch(committedQuery, rootPath: path)
    }

    /// `sortSearchResultsByColumn`: the active column flips direction; another starts ascending.
    func sortByColumn(_ value: SearchResultsSortByPreference) {
        if sortBy == value {
            sortDirection = sortDirection == .asc ? .desc : .asc
        } else {
            sortBy = value
            sortDirection = .asc
        }
        resultsChanged()
        emit(.results)
    }

    /// The order set from outside (a scenario's sort step).
    func setSort(_ value: SearchResultsSortByPreference, _ direction: SortDirectionPreference) {
        guard value != sortBy || direction != sortDirection else { return }
        sortBy = value
        sortDirection = direction
        resultsChanged()
        emit(.results)
    }

    /// The file list's hidden-files setting changed: results on screen found with the other setting are searched
    /// again; cached ones, the next time they show.
    func hiddenFilesChanged(_ includeHidden: Bool) {
        guard hasCachedSearch, resultsVisible, searchedHidden != includeHidden else { return }
        startSearch(committedQuery, rootPath: rootPath.isEmpty ? (host?.searchCurrentPath ?? "") : rootPath)
    }

    // MARK: Running

    /// `startSearch`.
    func startSearch(
        _ query: String, rootPath requestedRoot: String? = nil, live: Bool = false, keepMatching: Bool = false
    ) {
        guard let host else { return }
        let trimmed = SearchTiming.trimmed(query)
        let root = requestedRoot ?? host.searchCurrentPath
        cancelLiveSearch()
        if trimmed.isEmpty {
            clearCommittedSearch()
            return
        }
        if root.isEmpty { return }
        sessionCounter += 1
        cancelActiveSearch()
        let wasVisible = resultsVisible
        let kept =
            keepMatching && resultsVisible && patternMode == .text && root == rootPath
            ? SearchRefinement.keepMatching(results, previousQuery: baseQuery, query: trimmed, scope: refinementScope)
            : []
        keptResultPaths = Set(kept.map(\.path))
        results = kept
        resultsGeneration += 1
        committedQuery = trimmed
        baseQuery = trimmed
        resultsChanged()
        interrupted = false
        // The results left somewhere in the history are not these.
        returnPlace = nil
        rootPath = root
        resultsVisible = true
        originPath = host.searchCurrentPath
        startedLive = live
        status = .running
        error = nil
        truncated = false
        elapsedMilliseconds = nil
        startedAt = clock()
        searchedHidden = host.searchIncludeHidden
        cachedSearchSelection = .empty
        emit(wasVisible ? [.results, .status] : [.results, .status, .visibility])
        host.applySearchSelection(.empty)

        let counter = sessionCounter
        let request = SearchRequest(
            rootPath: root, query: trimmed, patternMode: patternMode, matchScope: matchScope, recursive: recursive,
            includeHidden: host.searchIncludeHidden, skipGitFolders: skipGitFolders, skipGitIgnored: skipGitIgnored)
        do {
            let started = try engine.start(request)
            guard counter == sessionCounter else {
                engine.cancel(jobID: started)
                return
            }
            jobID = started
            cursor = 0
            awaitingFirstUpdateAfterReturn = false
            status = .running
            poll(jobID: started, counter: counter)
        } catch {
            guard counter == sessionCounter else { return }
            jobID = nil
            clearPolling()
            status = .error
            self.error = String(describing: error)
            emit(.status)
        }
    }

    private func clearPolling() {
        pollTimer?.cancel()
        pollTimer = nil
    }

    private func cancelActiveSearch() {
        let active = jobID
        clearPolling()
        jobID = nil
        if let active { engine.cancel(jobID: active) }
    }

    /// `pollSearch`: asks about the search from the cursor, applies the answer, and asks again after the interval
    /// until the search is done.
    private func poll(jobID: String, counter: Int) {
        guard counter == sessionCounter, self.jobID == jobID else { return }
        let update: TabSearchUpdate
        do {
            update = try engine.update(jobID: jobID, cursor: cursor)
        } catch {
            self.jobID = nil
            clearPolling()
            status = .error
            self.error = String(describing: error)
            emit(.status)
            return
        }
        apply(update)
        guard self.jobID == jobID, !update.done else { return }
        let interval = isBackground ? SearchTiming.backgroundPollInterval : SearchTiming.pollInterval
        pollTimer = timers.schedule(after: interval) { [weak self] in
            self?.pollTimer = nil
            self?.poll(jobID: jobID, counter: counter)
        }
    }

    private func apply(_ update: TabSearchUpdate) {
        let newItems =
            keptResultPaths.isEmpty ? update.items : update.items.filter { !keptResultPaths.contains($0.path) }
        var change: Change = .status
        if !newItems.isEmpty {
            results = SearchResults.append(results, newItems)
            resultsChanged()
            change.insert(.results)
        }
        cursor = update.nextCursor
        // The search stopped at its limit while the text in the field is narrower than what it looked for: it may
        // have missed matches, so that text is looked for itself.
        if update.truncated, committedQuery != baseQuery {
            if !isBackground {
                emit(change)
                startSearch(committedQuery, rootPath: resolveRootPath(), live: true, keepMatching: true)
                return
            }
        }
        status = TabSearchStatus(update.status)
        error = update.error
        truncated = update.truncated
        let finishedAway = (awaitingFirstUpdateAfterReturn || isBackground) && update.done
        awaitingFirstUpdateAfterReturn = false
        if update.done {
            jobID = nil
            clearPolling()
            if finishedAway {
                elapsedMilliseconds = nil
            } else if let startedAt {
                elapsedMilliseconds = max(0, ((clock() - startedAt) * 1000).rounded())
            }
        }
        emit(change)
    }

    // MARK: The tab in the background

    /// The tab was left (`detachSearchSession`): typing waiting for its rest is held, and the search, still running,
    /// is asked about once a second.
    func enterBackground() {
        guard !isBackground else { return }
        isBackground = true
        // Selecting the first result once Return's search ends is forgotten with the tab (B-SRCH-014).
        selectFirstResultWhenDone = false
        let pending = pendingLiveQuery
        cancelLiveSearch()
        pendingLiveQuery = pending
        sessionCounter += 1
        clearPolling()
        if let jobID { schedulePoll(jobID: jobID, after: SearchTiming.backgroundPollInterval) }
    }

    /// The tab is shown again (`attachSearchSession`): what was being typed is searched as if just typed, and the
    /// search picks up from its cursor. A search whose walk stopped short in the background with narrower text, or
    /// found with the other hidden-files setting, runs again.
    func returnToForeground() {
        guard isBackground else { return }
        isBackground = false
        sessionCounter += 1
        clearPolling()
        awaitingFirstUpdateAfterReturn = jobID != nil
        if let pending = pendingLiveQuery {
            pendingLiveQuery = nil
            scheduleLiveSearch(pending)
        }
        if let jobID { poll(jobID: jobID, counter: sessionCounter) }
        let stoppedShort = jobID == nil && truncated && committedQuery != baseQuery
        let hidden = host?.searchIncludeHidden ?? searchedHidden
        if hasCachedSearch, resultsVisible, interrupted || stoppedShort || searchedHidden != hidden {
            rerun()
        }
    }

    private func schedulePoll(jobID: String, after delay: TimeInterval) {
        let counter = sessionCounter
        pollTimer = timers.schedule(after: delay) { [weak self] in
            self?.pollTimer = nil
            self?.poll(jobID: jobID, counter: counter)
        }
    }

    /// The tab closed, or the window did: the search stops.
    func close() {
        cancelLiveSearch()
        cancelActiveSearch()
        sessionCounter += 1
    }

    // MARK: Telling the tab

    private func emit(_ change: Change) {
        host?.searchSessionChanged(change)
    }
}
