// Checks a tab view's Search Results: kept whole where checked and never apart, read back as written, and left out of
// a pane that shows the viewer; and a pane's own settings written to the app's only where they changed
import Foundation
import Testing

@testable import FTFoundation

struct SearchResultsKeepsTests {
    private static var results: SearchResultsKeeps {
        var preferences = AppPreferences.defaults()
        preferences.searchResultsSortBy = .size
        preferences.searchResultsSortDirection = .desc
        preferences.searchColumns[.size] = false
        return SearchResultsKeeps(preferences, view: .icons, groupBy: .kind, groupReversed: true)
    }

    @Test func theDraftStartsFromThePaneAndKeepsItOnlyWhereChecked() {
        var tab = TabViewDraftTests.tab(["/a"])
        tab.panes[0].searchResults = Self.results
        var draft = TabViewDraft(tab: tab, columnWidth: 1009)
        #expect(!draft.active.keepsSearchResults)
        #expect(draft.active.searchResults == Self.results)
        #expect(draft.keeps.pane?.searchResults == nil)
        draft.active.keepsSearchResults = true
        #expect(draft.keeps.pane?.searchResults == Self.results)
        #expect(SavedViewText.parts(draft.keeps).contains("search results in Icons, by size, grouped by kind"))
        draft.reset()
        #expect(!draft.active.keepsSearchResults)
    }

    @Test func aTabViewBeingEditedShowsWhatItKeeps() {
        let saved = TabView(
            id: "t", name: "Saved", keeps: TabViewKeeps(panes: 1, pane: PaneKeeps(searchResults: Self.results)))
        let draft = TabViewDraft(tab: TabViewDraftTests.tab(["/a"]), columnWidth: 1009, editing: saved)
        #expect(draft.active.keepsSearchResults && draft.active.searchResults == Self.results)
        #expect(draft.keeps == saved.keeps)
    }

    @Test func itIsReadBackAsWrittenAndAViewerKeepsNone() throws {
        let keeps = PaneKeeps(searchResults: Self.results)
        let read = try JSONDecoder().decode(PaneKeeps.self, from: JSONEncoder().encode(keeps))
        #expect(read == keeps)
        #expect(!keeps.isEmpty)
        #expect(PaneKeeps(viewer: PaneViewer(), searchResults: Self.results).searchResults == nil)
    }

    @Test func groupsResultsDontHaveAreNotKept() {
        let results = SearchResultsKeeps(AppPreferences.defaults(), view: .details, groupBy: .none, groupReversed: true)
        #expect(results.groupBy == .none && !results.groupReversed)
    }

    @Test func aPanesChangeGoesToTheAppsOnlyWhereItChanged() {
        var app = AppPreferences.defaults()
        let before = PaneViewSizes(app)
        var after = before
        after.searchRecursive.toggle()
        after.detailColumns[.size].toggle()
        // Set elsewhere meanwhile: stays.
        app.searchColumns[.kind].toggle()
        app.iconSizes[.standard] = 96
        let written = after.changes(from: before, appliedTo: app)
        #expect(written.searchRecursive == after.searchRecursive)
        #expect(written.detailColumns == after.detailColumns)
        #expect(written.searchColumns == app.searchColumns)
        #expect(written.iconSizes == app.iconSizes)
    }
}
