import FTFileSystem
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

/// The fd runtime, answering from a table the test fills: what each query finds, and whether its search is still
/// running.
@MainActor
final class FakeSearchEngine: SearchEngine {
    struct Job {
        var request: SearchRequest
        var items: [SearchResultItem]
        var running: Bool
        var truncated = false
    }

    var finds: (SearchRequest) -> (names: [String], running: Bool, truncated: Bool) = { _ in ([], false, false) }
    private(set) var starts: [SearchRequest] = []
    private(set) var cancels: [String] = []
    private(set) var updates: [(jobID: String, cursor: Int)] = []
    private(set) var jobs: [String: Job] = [:]
    private var sequence = 0

    struct UnknownJob: Error {}

    func start(_ request: SearchRequest) throws -> String {
        sequence += 1
        let id = "search-\(sequence)"
        starts.append(request)
        let found = finds(request)
        let items = found.names.map {
            SearchResults.item(rootPath: request.rootPath, outputPath: request.rootPath + "/" + $0)
        }
        jobs[id] = Job(request: request, items: items, running: found.running, truncated: found.truncated)
        return id
    }

    /// The running search finds more, or ends.
    func progress(_ id: String, add names: [String] = [], finish: Bool = false, truncated: Bool = false) {
        guard var job = jobs[id] else { return }
        job.items += names.map {
            SearchResults.item(rootPath: job.request.rootPath, outputPath: job.request.rootPath + "/" + $0)
        }
        if finish { job.running = false }
        job.truncated = truncated
        jobs[id] = job
    }

    func update(jobID: String, cursor: Int) throws -> SearchUpdate {
        updates.append((jobID, cursor))
        guard let job = jobs[jobID] else { throw UnknownJob() }
        let start = max(0, min(cursor, job.items.count))
        let status: SearchJobStatus = job.running ? .running : (job.truncated ? .truncated : .complete)
        return SearchUpdate(
            jobId: jobID, status: status, items: Array(job.items[start...]), nextCursor: job.items.count,
            done: !job.running, truncated: job.truncated, error: nil)
    }

    func cancel(jobID: String) {
        cancels.append(jobID)
        jobs[jobID]?.running = false
    }

    var lastJobID: String { "search-\(sequence)" }
}

/// The tab around a session: its folder, hidden files, the folder's selection, and what the session asked of it.
@MainActor
final class FakeSearchHost: SearchSessionHost {
    var searchCurrentPath = "/demo"
    var searchIncludeHidden = false
    var searchFolderEntryPaths = ["/demo/a.txt", "/demo/b.txt"]
    /// What the results' filter holds; the results shown are all of them.
    var searchResultsFilter = ""
    var searchResultsFilterMode = NameMatchMode.fuzzy
    var searchResultsScroll: (top: Double, left: Double)?
    private(set) var restoredFilters: [String] = []
    private(set) var changes: [SearchSession.Change] = []
    private(set) var applied: [ContentSelection] = []
    private(set) var focusedPane = 0

    func searchSessionChanged(_ change: SearchSession.Change) { changes.append(change) }
    func applySearchSelection(_ selection: ContentSelection) { applied.append(selection) }
    func focusContentPaneForSearch() { focusedPane += 1 }
    func restoreSearchResultsView(filter: String, mode: NameMatchMode, scroll: (top: Double, left: Double)?) {
        restoredFilters.append(filter)
    }
}

@MainActor
@Suite struct SearchSessionTests {
    let engine = FakeSearchEngine()
    let host = FakeSearchHost()
    let timers = ManualTimers()

    private func session() -> SearchSession {
        let made = SearchSession(
            preferences: .defaults(), includeHidden: false, engine: engine, timers: timers)
        made.host = host
        return made
    }

    private func names(_ session: SearchSession) -> [String] { session.shownResults.map(\.name) }

    private func finding(_ table: [String: [String]], running: Bool = false) {
        engine.finds = { request in (table[request.query] ?? [], running, false) }
    }

    @Test func searchesAsYouTypeOnceTheKeyboardRestsFromTwoCharacters() {
        finding(["so": ["source.txt", "sonar.txt"]])
        let search = session()
        search.updateDraft("s")
        timers.advance(0.48)
        // One character never searches by itself.
        #expect(engine.starts.isEmpty)
        #expect(!search.isSearchMode)
        search.updateDraft("so")
        timers.advance(0.2)
        search.updateDraft(" so ")
        timers.advance(0.399)
        #expect(engine.starts.isEmpty)
        timers.advance(0.01)
        // A burst of keys makes one search, for the trimmed text, live and with the options of a fresh launch.
        #expect(engine.starts.count == 1)
        #expect(engine.starts[0].query == "so")
        #expect(engine.starts[0].rootPath == "/demo")
        #expect(engine.starts[0].patternMode == .text)
        #expect(search.startedLive)
        #expect(search.isSearchMode)
        #expect(Set(names(search)) == ["source.txt", "sonar.txt"])
        // The field keeps what was typed.
        #expect(search.draftQuery == " so ")
        // Return on what is on screen searches nothing new, and says the results are final.
        #expect(search.submit("so"))
        #expect(engine.starts.count == 1)
        #expect(!search.startedLive)
        // Return searches at once, whatever the length.
        search.submit("x")
        #expect(engine.starts.count == 2)
        #expect(engine.starts[1].query == "x")
        // Text too short clears the cached search, and the folder list comes back.
        search.updateDraft("s")
        #expect(!search.hasCachedSearch)
        #expect(!search.isSearchMode)
        #expect(search.draftQuery == "s")
    }

    @Test func narrowsWhatASearchFoundAsMoreIsTypedWithoutSearchingAgain() {
        finding(["so": ["source.txt", "sonar.txt", "soup.md"], "on": ["sonar.txt", "one.txt"]])
        let search = session()
        search.updateDraft("so")
        timers.advance(0.4)
        search.updateDraft("sou")
        #expect(engine.starts.count == 1)
        #expect(Set(names(search)) == ["source.txt", "soup.md"])
        search.updateDraft("soup")
        #expect(names(search) == ["soup.md"])
        search.updateDraft("soupx")
        #expect(names(search).isEmpty)
        #expect(search.isSearchMode)
        // Back to the base: everything found shows again.
        search.updateDraft("so")
        #expect(names(search).count == 3)
        #expect(engine.starts.count == 1)
        // Unrelated text is searched after the rest, and the old list goes.
        search.updateDraft("on")
        #expect(engine.starts.count == 1)
        timers.advance(0.4)
        #expect(engine.starts.count == 2)
        #expect(Set(names(search)) == ["sonar.txt", "one.txt"])
    }

    // Results found with other options than those set now (Settings changed them, which runs nothing again) are not
    // narrowed by more typing, and none of them is kept: the longer text is searched with the options set now.
    @Test(arguments: [false, true])
    func resultsFoundWithOtherOptionsAreSearchedAgainWhenMoreIsTyped(recursiveBefore: Bool) {
        engine.finds = { request in
            (request.recursive ? ["source.txt", "sub/sour.txt"] : ["source.txt"], false, false)
        }
        var before = AppPreferences.defaults()
        before.searchRecursive = recursiveBefore
        let search = SearchSession(
            preferences: before, includeHidden: false, engine: engine, timers: timers)
        search.host = host
        search.updateDraft("so")
        timers.advance(0.4)
        #expect(engine.starts.count == 1)
        var after = before
        after.searchRecursive = !recursiveBefore
        search.applyDefaults(after, keys: [.searchRecursive])
        #expect(engine.starts.count == 1)

        search.updateDraft("sou")
        timers.advance(0.4)

        #expect(engine.starts.count == 2)
        #expect(engine.starts.last?.recursive == !recursiveBefore)
        #expect(Set(names(search)) == (recursiveBefore ? ["source.txt"] : ["source.txt", "sour.txt"]))
    }

    @Test func neverShowsTheResultsOfOneSearchUnderTheTextOfAnother() {
        engine.finds = { request in request.query == "so" ? (["source.txt"], true, false) : ([], true, false) }
        let search = session()
        search.updateDraft("so")
        timers.advance(0.4)
        #expect(names(search) == ["source.txt"])
        search.updateDraft("xy")
        timers.advance(0.4)
        // The new search runs, has found nothing yet, and the old results are gone.
        #expect(search.isRunning)
        #expect(names(search).isEmpty)
        #expect(search.committedQuery == "xy")
        // The old search, still walking, was let go, and the new one was not.
        #expect(engine.cancels == ["search-1"])
        // Hiding a running search stops it, to run again when shown.
        search.hideResults()
        #expect(engine.cancels.contains(engine.lastJobID))
        #expect(search.status == .cancelled)
        #expect(search.interrupted)
        search.showCachedResults()
        #expect(engine.starts.count == 3)
    }

    @Test func searchesForTheLongerTextItselfWhenTheSearchItWouldNarrowStoppedAtItsLimit() {
        engine.finds = { request in
            request.query == "so" ? (["source.txt", "sonar.txt"], false, true) : (["soup.md"], false, false)
        }
        let search = session()
        search.updateDraft("so")
        timers.advance(0.4)
        #expect(search.truncated)
        search.updateDraft("sou")
        // Not refined: the walk stopped at its limit, so the longer text is searched for itself after the rest.
        #expect(engine.starts.count == 1)
        timers.advance(0.4)
        #expect(engine.starts.count == 2)
        #expect(engine.starts[1].query == "sou")
        // What was on screen and still matches stays; the new walk's own copy of it is not listed twice.
        #expect(Set(names(search)) == ["source.txt", "soup.md"])
    }

    @Test func aWalkThatStopsShortWhileNarrowerTextIsTypedIsSearchedAgain() {
        engine.finds = { request in (["source.txt"], request.query == "so", false) }
        let search = session()
        search.updateDraft("so")
        timers.advance(0.4)
        search.updateDraft("sou")
        #expect(search.committedQuery == "sou")
        #expect(search.baseQuery == "so")
        engine.progress("search-1", add: ["soup.md"], finish: true, truncated: true)
        timers.advance(0.12)
        #expect(engine.starts.count == 2)
        #expect(engine.starts[1].query == "sou")
    }

    // Other text typed while the walk stops short waits for its rest as usual: the walk isn't run again for the
    // narrower text in between, which would let the typed text go unsearched.
    @Test func textTypedWhileTheWalkStopsShortIsStillSearched() {
        engine.finds = { request in (["source.txt"], request.query == "so", false) }
        let search = session()
        search.updateDraft("so")
        timers.advance(0.4)
        search.updateDraft("sou")
        search.updateDraft("xy")
        engine.progress("search-1", add: ["soup.md"], finish: true, truncated: true)
        timers.advance(0.12)
        #expect(engine.starts.map(\.query) == ["so"])
        timers.advance(0.3)
        #expect(engine.starts.map(\.query) == ["so", "xy"])
        #expect(search.committedQuery == "xy")
    }

    // The same when the walk stopped short in the background: the text being typed is searched on return.
    @Test func textTypedBeforeTheTabWasLeftIsSearchedWhenTheWalkStoppedShortMeanwhile() {
        engine.finds = { request in (["source.txt"], request.query == "so", false) }
        let search = session()
        search.updateDraft("so")
        timers.advance(0.4)
        search.updateDraft("sou")
        search.updateDraft("xy")
        search.enterBackground()
        engine.progress("search-1", add: ["soup.md"], finish: true, truncated: true)
        timers.advance(1)
        search.returnToForeground()
        timers.advance(0.41)
        #expect(engine.starts.map(\.query) == ["so", "xy"])
        #expect(search.committedQuery == "xy")
    }

    @Test func forgetsTextTypedBeforeItIsSearchedWithEscapeOrTheClearButton() {
        finding(["so": ["source.txt"]])
        let search = session()
        search.updateDraft("so")
        search.abandonDraft()
        timers.advance(0.48)
        #expect(engine.starts.isEmpty)
        #expect(search.draftQuery.isEmpty)
        #expect(!search.isSearchMode)
        // The ✕: the draft and the committed search both go.
        search.updateDraft("so")
        timers.advance(0.4)
        #expect(search.isSearchMode)
        search.abandonDraft()
        search.clearCommittedSearch()
        #expect(!search.hasCachedSearch)
        #expect(search.draftQuery.isEmpty)
        #expect(search.status == nil)
        #expect(host.applied.last == .empty)
    }

    @Test func escapeHidesResultsClearsTheFieldAndTheCachedResultsComeBackWithTheirQuery() {
        finding(["so": ["source.txt", "sonar.txt"]])
        let search = session()
        // The folder's selection, noted while the folder list shows.
        search.noteSelection(.single("/demo/a.txt"))
        search.updateDraft("so")
        timers.advance(0.4)
        search.noteSelection(.single("/demo/source.txt"))
        search.hideResults()
        #expect(!search.isSearchMode)
        #expect(search.hasCachedSearch)
        #expect(search.draftQuery.isEmpty)
        // The folder's selection comes back, cleaned against the folder.
        #expect(host.applied.last == .single("/demo/a.txt"))
        // Focusing the field in the same folder brings the results back with their query and selection.
        search.showCachedResults(fromField: true)
        #expect(search.isSearchMode)
        #expect(search.draftQuery == "so")
        #expect(host.applied.last == .single("/demo/source.txt"))
        #expect(engine.starts.count == 1)
        // In another folder the field stays empty, ready to search there; ⇧⌘F still shows them.
        search.hideResults()
        host.searchCurrentPath = "/elsewhere"
        search.showCachedResults(fromField: true)
        #expect(!search.isSearchMode)
        search.showCachedResults(focusPane: true)
        #expect(search.isSearchMode)
        #expect(search.rootPath == "/demo")
        #expect(host.focusedPane == 1)
    }

    @Test func optionsAndScopesRunTheSearchAgainWithoutKeepingResults() {
        finding(["so": ["source.txt"]])
        let search = session()
        search.setPatternMode(.glob)
        #expect(engine.starts.isEmpty)
        search.updateDraft("so")
        timers.advance(0.4)
        #expect(engine.starts[0].patternMode == .glob)
        search.setMatchScope(.path)
        #expect(engine.starts.count == 2)
        #expect(engine.starts[1].matchScope == .path)
        search.changeRoot("/Users/demo")
        #expect(engine.starts.count == 3)
        #expect(engine.starts[2].rootPath == "/Users/demo")
        // A widened scope survives further typing in the same folder.
        #expect(search.resolveRootPath() == "/Users/demo")
        host.searchCurrentPath = "/other"
        #expect(search.resolveRootPath() == "/other")
        search.setRecursive(false)
        search.setSkipGitFolders(false)
        search.setSkipGitIgnored(true)
        #expect(engine.starts.last?.recursive == false)
        #expect(engine.starts.last?.skipGitFolders == false)
        #expect(engine.starts.last?.skipGitIgnored == true)
        #expect(engine.starts.last?.rootPath == "/Users/demo")
    }

    @Test func headersSortTheResultsTheSameColumnFlipsADifferentOneStartsAscending() {
        finding(["a": ["b/zeta.txt", "a/alpha.md", "c/mid.txt"]])
        let search = session()
        search.submit("a")
        // Default: by folder (path), ascending.
        #expect(names(search) == ["alpha.md", "zeta.txt", "mid.txt"])
        search.sortByColumn(.name)
        #expect(names(search) == ["alpha.md", "mid.txt", "zeta.txt"])
        search.sortByColumn(.name)
        #expect(names(search) == ["zeta.txt", "mid.txt", "alpha.md"])
        search.sortByColumn(.kind)
        #expect(search.sortDirection == .asc)
    }

    @Test func aBackgroundTabsSearchKeepsRunningAndSaysWhenItHasFinished() {
        finding(["so": []], running: true)
        let search = session()
        search.updateDraft("so")
        timers.advance(0.4)
        #expect(search.isRunning)
        search.enterBackground()
        let before = engine.updates.count
        engine.progress("search-1", add: ["source.txt", "sonar.txt"], finish: true)
        // Asked once a second while in the background.
        timers.advance(0.9)
        #expect(engine.updates.count == before)
        timers.advance(0.1)
        #expect(engine.updates.count == before + 1)
        #expect(search.status == .complete)
        // Nothing is left to ask about once it ended.
        timers.advance(2)
        #expect(engine.updates.count == before + 1)
        // Its tab shows its results on return, with nothing cancelled.
        search.returnToForeground()
        #expect(Set(names(search)) == ["source.txt", "sonar.txt"])
        #expect(engine.cancels.isEmpty)
        #expect(engine.starts.count == 1)
    }

    // An answer on its way when the tab is left is not lost. The session stays with its tab, so the answer
    // is applied when it comes, and the search need not run again.
    @Test func anAnswerOnItsWayWhenTheTabIsLeftIsKept() {
        finding(["so": ["source.txt"]], running: true)
        let search = session()
        search.updateDraft("so")
        timers.advance(0.4)
        engine.progress("search-1", add: ["sonar.txt"], finish: true)
        search.enterBackground()
        search.returnToForeground()
        #expect(Set(names(search)) == ["source.txt", "sonar.txt"])
        #expect(search.status == .complete)
        #expect(engine.starts.count == 1)
    }

    @Test func whatWasBeingTypedWhenTheTabWasLeftIsSearchedOnceItIsBack() {
        finding(["so": ["source.txt"]])
        let search = session()
        search.updateDraft("so")
        timers.advance(0.2)
        search.enterBackground()
        timers.advance(1)
        #expect(engine.starts.isEmpty)
        search.returnToForeground()
        timers.advance(0.39)
        #expect(engine.starts.isEmpty)
        timers.advance(0.02)
        #expect(engine.starts.count == 1)
        #expect(names(search) == ["source.txt"])
    }

    @Test func resultsFoundWithTheOtherHiddenFilesSettingAreSearchedAgain() {
        finding(["so": ["source.txt"]])
        let search = session()
        search.submit("so")
        host.searchIncludeHidden = true
        search.hiddenFilesChanged(true)
        #expect(engine.starts.count == 2)
        #expect(engine.starts[1].includeHidden)
        // A tab that comes back after the setting changed runs its search again.
        search.enterBackground()
        host.searchIncludeHidden = false
        search.returnToForeground()
        #expect(engine.starts.count == 3)
    }

    @Test func stopKeepsWhatWasFoundAndLongerTextIsSearchedAfresh() {
        finding(["so": ["source.txt"]], running: true)
        let search = session()
        search.updateDraft("so")
        timers.advance(0.4)
        search.stop()
        #expect(search.status == .cancelled)
        #expect(names(search) == ["source.txt"])
        search.updateDraft("sou")
        #expect(search.committedQuery == "so")
        timers.advance(0.4)
        #expect(engine.starts.count == 2)
    }

    @Test func aPatternThatDoesNotParseWhileTypedIsQuietUntilReturn() {
        let search = session()
        search.setPatternMode(.regex)
        search.updateDraft("a(")
        timers.advance(0.4)
        #expect(search.errorIsQuiet)
        search.submit("a(")
        #expect(!search.errorIsQuiet)
        search.setPatternMode(.text)
        #expect(!search.errorIsQuiet)
    }

    // Results streaming in are shown in the order a sort of them all gives.
    @Test func resultsThatStreamInAreKeptInTheChosenOrder() {
        engine.finds = { _ in (["b/Same.txt", "a/same.txt", "c/zeta.md"], true, false) }
        let search = session()
        search.updateDraft("me")
        timers.advance(0.4)
        for batch in [["d/alpha.txt", "a/Same.txt"], ["b/same.TXT", "e/MID.md", "f/same.txt"], ["0/zz.txt"]] {
            engine.progress("search-1", add: batch)
            timers.advance(0.12)
            for sortBy in [SearchResultsSortByPreference.path, .name] {
                for direction in [SortDirectionPreference.asc, .desc] {
                    search.setSort(sortBy, direction)
                    #expect(search.shownResults == SearchResults.sort(search.results, by: sortBy, direction: direction))
                }
            }
        }
    }
}
