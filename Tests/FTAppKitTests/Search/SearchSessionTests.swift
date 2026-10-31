// Ports the search cases of apps/desktop/src/renderer/App.search.test.tsx and App.tabs.test.tsx (by feature row F-713,
// F-714, B-SRCH-001 to B-SRCH-169) over one tab's search session, a stand-in for the fd runtime and timers moved by hand
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

    func update(jobID: String, cursor: Int) throws -> TabSearchUpdate {
        updates.append((jobID, cursor))
        guard let job = jobs[jobID] else { throw UnknownJob() }
        let start = max(0, min(cursor, job.items.count))
        let status: SearchJobStatus = job.running ? .running : (job.truncated ? .truncated : .complete)
        return TabSearchUpdate(
            jobID: jobID, status: status, items: Array(job.items[start...]), nextCursor: job.items.count,
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
    private(set) var changes: [SearchSession.Change] = []
    private(set) var applied: [ContentSelection] = []
    private(set) var focusedPane = 0

    func searchSessionChanged(_ change: SearchSession.Change) { changes.append(change) }
    func applySearchSelection(_ selection: ContentSelection) { applied.append(selection) }
    func focusContentPaneForSearch() { focusedPane += 1 }
}

@MainActor
@Suite struct SearchSessionTests {
    let engine = FakeSearchEngine()
    let host = FakeSearchHost()
    let timers = ManualTimers()

    private func session() -> SearchSession {
        let made = SearchSession(
            preferences: .defaults(), includeHidden: false, engine: engine, timers: timers, clock: { 0 })
        made.host = host
        return made
    }

    private func names(_ session: SearchSession) -> [String] { session.shownResults.map(\.name) }

    private func finding(_ table: [String: [String]], running: Bool = false) {
        engine.finds = { request in (table[request.query] ?? [], running, false) }
    }

    // T-b49c92ba F-713
    // B-SRCH-001 B-SRCH-002 B-SRCH-003 B-SRCH-005 B-SRCH-006 B-SRCH-008 B-SRCH-010 B-SRCH-017 B-SRCH-019
    // B-SRCH-070 B-SRCH-132
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

    // T-06c0cfba
    // B-SRCH-020 B-SRCH-022 B-SRCH-023 B-SRCH-024 B-SRCH-025 B-SRCH-133
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

    // T-c68ee1c1
    // B-SRCH-035 B-SRCH-067 B-SRCH-074 B-SRCH-132
    @Test func neverShowsTheResultsOfOneSearchUnderTheTextOfAnother() {
        engine.finds = { request in request.query == "so" ? (["source.txt"], false, false) : ([], true, false) }
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
        // The old job was let go.
        #expect(engine.cancels.isEmpty || engine.cancels.allSatisfy { $0 != engine.lastJobID })
        // Hiding a running search stops it, to run again when shown.
        search.hideResults()
        #expect(engine.cancels.contains(engine.lastJobID))
        #expect(search.status == .cancelled)
        #expect(search.interrupted)
        search.showCachedResults()
        #expect(engine.starts.count == 3)
    }

    // T-40eae612
    // B-SRCH-005 B-SRCH-020 B-SRCH-030 B-SRCH-033
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

    // B-SRCH-019 B-SRCH-020 B-SRCH-031 B-SRCH-133
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

    // T-985cc237
    // B-SRCH-004 B-SRCH-051 B-SRCH-054 B-SRCH-055 B-SRCH-070
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
        #expect(search.status == .idle)
        #expect(host.applied.last == .empty)
    }

    // T-0d7af669 T-e6c30f5d
    // B-SEL-091 B-SRCH-041 B-SRCH-045 B-SRCH-046 B-SRCH-060 B-SRCH-064 B-SRCH-065 B-SRCH-066 B-SRCH-072
    // B-SRCH-073
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

    // B-SRCH-090 B-SRCH-097 T-73242d97
    // B-SRCH-006 B-SRCH-040 B-SRCH-041 B-SRCH-042
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

    // B-SRCH-104
    // T-78d2429c
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

    // T-c57f08a1 T-5e66d49e
    // B-SRCH-135 B-SRCH-159
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
        #expect(search.elapsedMilliseconds == nil)
        // Nothing is left to ask about once it ended.
        timers.advance(2)
        #expect(engine.updates.count == before + 1)
        // Its tab shows its results on return, with nothing cancelled.
        search.returnToForeground()
        #expect(Set(names(search)) == ["source.txt", "sonar.txt"])
        #expect(engine.cancels.isEmpty)
        #expect(engine.starts.count == 1)
    }

    // T-2fb3ea31: an answer on its way when the tab is left is not lost. The session stays with its tab, so the answer
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

    // T-f4af2113
    // B-SRCH-156
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

    // B-SRCH-139 B-SRCH-158
    // B-SRCH-006 B-SRCH-079 B-SRCH-132 T-548f7c9c
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

    // B-SRCH-125
    // B-SRCH-020
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

    // B-SRCH-129 F-754
    // B-SRCH-005 B-SRCH-008 T-d8e16e8e
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

    // B-SRCH-099 B-SRCH-100: results streaming in are shown in the order a sort of them all gives.
    // B-SRCH-133
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
