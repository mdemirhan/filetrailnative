// A search's conditions typed in its text: the walk gets the text to find and the conditions apart, a condition alone
// is a search, a condition's word still being typed searches nothing new, and the folders the results are in are
// offered after `skip:`.
import FTFileSystem
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTAppKit

@MainActor
@Suite struct SearchConditionSessionTests {
    let engine = FakeSearchEngine()
    let host = FakeSearchHost()
    let timers = ManualTimers()

    private func session() -> SearchSession {
        let made = SearchSession(preferences: .defaults(), includeHidden: false, engine: engine, timers: timers)
        made.host = host
        return made
    }

    @Test func theWalkGetsTheTextAndTheConditionsApart() {
        let search = session()
        search.submit("report kind:pdf q3")
        #expect(engine.starts.last?.query == "report q3")
        #expect(engine.starts.last?.conditions == [.kind([.pdf])])
        #expect(search.conditions == [.kind([.pdf])])
        // The field keeps the text as typed.
        #expect(search.committedQuery == "report kind:pdf q3")
    }

    @Test func aConditionAloneIsASearch() {
        let search = session()
        search.submit("kind:pdf")
        #expect(engine.starts.last?.query == "")
        #expect(engine.starts.last?.conditions == [.kind([.pdf])])
        #expect(search.isSearchMode)
    }

    // Searched as it is typed: a finished condition is searched however short the text.
    @Test func aConditionIsSearchedAsItIsTyped() {
        let search = session()
        search.updateDraft("size:>10mb")
        timers.advance(1)
        #expect(
            engine.starts.last?.conditions == [
                .size(SearchSizeRule(comparison: .larger, value: 10, unit: .megabytes))
            ])
    }

    // A condition's word being typed keeps what is on screen and starts nothing.
    @Test func anUnfinishedWordSearchesNothingNew() {
        let search = session()
        search.submit("report")
        search.updateDraft("report kind:pd")
        timers.advance(1)
        #expect(engine.starts.count == 1)
        #expect(search.isSearchMode)
        // On its own, it neither searches nor ends the search there is.
        search.updateDraft("kind:")
        timers.advance(1)
        #expect(engine.starts.count == 1)
        #expect(search.hasCachedSearch)
    }

    // A changed condition searches again: the results can't be narrowed from what another condition found.
    @Test func aChangedConditionIsNoRefinement() {
        let search = session()
        engine.finds = { _ in (["a.pdf"], true, false) }
        search.submit("report kind:pdf")
        search.submit("report kind:picture")
        #expect(engine.starts.count == 2)
        #expect(engine.starts.last?.conditions == [.kind([.picture])])
    }

    @Test func clearingTheSearchClearsItsConditions() {
        let search = session()
        search.submit("report kind:pdf")
        search.clearCommittedSearch()
        #expect(search.conditions.isEmpty)
        #expect(!search.hasCachedSearch)
    }

    // What the walk's conditions read is passed on while the search runs, for the status bar.
    @Test func itemsReadStartAtNoneForEachSearch() {
        let search = session()
        engine.finds = { _ in (["a.pdf"], true, false) }
        search.submit("size:>10mb")
        #expect(search.isRunning)
        #expect(search.itemsRead == 0)
    }

    // `skip:` offers the folders the results are in, those holding the most first.
    @Test func skipOffersTheFoldersPassed() {
        func item(_ parent: String, _ name: String) -> SearchResultItem {
            SearchResultItem(
                path: "/r/\(parent)/\(name)", name: name, fileExtension: "", kind: .file, isHidden: false,
                parentPath: "/r/\(parent)", relativeParentPath: parent)
        }
        let results = [
            item("app/node_modules/a", "x"), item("app/node_modules/b", "y"), item("app/build", "z"),
            item(".", "top"),
        ]
        #expect(TabSearch.folderNames(in: results) == ["app", "node_modules", "a", "b", "build"])
    }
}
