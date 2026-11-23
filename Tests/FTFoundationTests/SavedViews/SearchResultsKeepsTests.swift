// Checks a tab view's Search View, how a pane shows search results: kept whole where checked and never apart, read back as written, and left out of
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
        #expect(SavedViewText.parts(draft.keeps).contains("search view: Icons, sorted by Size, grouped by Kind"))
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

    @Test func itIsReadBackAsWrittenAndKeptBesideAViewer() throws {
        let keeps = PaneKeeps(searchResults: Self.results)
        let read = try JSONDecoder().decode(PaneKeeps.self, from: JSONEncoder().encode(keeps))
        #expect(read == keeps)
        #expect(!keeps.isEmpty)
        // A pane that opens the viewer keeps its search view for the list behind it.
        #expect(PaneKeeps(opensViewer: true, searchResults: Self.results).searchResults == Self.results)
    }

    // A file changed by hand: each part is checked as a pane's own is, and the rest is kept.
    @Test func whatTheFileSaysWronglyIsCheckedPartByPart() throws {
        let json = """
            {"searchResults": {"view": "icons", "sortBy": "nope", "sortDirection": "desc", "groupBy": "kind",
                               "groupReversed": true, "columns": {"folder": false, "size": "yes"},
                               "columnOrder": ["size", "size", "nope", "folder"],
                               "columnWidths": {"name": 99999, "folder": 1},
                               "iconSizes": {"standard": 5000}, "previewCounts": {"standard": 7}}}
            """
        let read = try #require(try JSONDecoder().decode(PaneKeeps.self, from: Data(json.utf8)).searchResults)
        let defaults = SearchResultsKeeps.defaults
        #expect(read.view == .icons && read.sortBy == defaults.sortBy && read.sortDirection == .desc)
        #expect(read.groupBy == .kind && read.groupReversed)
        #expect(read.columns[.folder] == false && read.columns[.size] == defaults.columns[.size])
        #expect(read.columnOrder.prefix(2) == [.size, .folder])
        #expect(Set(read.columnOrder).count == OptionalSearchColumnKey.allCases.count)
        #expect(read.columnOrder.count == OptionalSearchColumnKey.allCases.count)
        #expect(read.columnWidths.name == SearchColumnKey.name.widthLimits.upperBound)
        #expect(read.columnWidths.folder == SearchColumnKey.folder.widthLimits.lowerBound)
        #expect(read.iconSizes.standard == AppPreferenceLimits.iconSizeRange.upperBound)
        #expect(read.iconSizes.finder == defaults.iconSizes.finder)
        #expect(read.compactListWidths == defaults.compactListWidths)
        #expect(PreviewGrid.valid(read: 7) == read.previewCounts.standard)
        // What is no record at all is not kept.
        let none = try JSONDecoder().decode(PaneKeeps.self, from: Data(#"{"searchResults": 3}"#.utf8))
        #expect(none.searchResults == nil)
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

    // A pane's Read or Edit starts at the app's, the one chosen last, and a change of it is the app's too; its Follow
    // starts on and is the pane's alone.
    @Test func aPanesReadOrEditIsTheAppsTooAndItsFollowItsOwn() {
        var app = AppPreferences.defaults()
        app.textViewerSettings.opensForEditing = true
        let before = PaneViewSizes(app)
        #expect(before.viewerEditing && before.viewerFollows)
        var after = before
        after.viewerEditing = false
        after.viewerFollows = false
        let written = after.changes(from: before, appliedTo: app)
        #expect(!written.textViewerSettings.opensForEditing)
        #expect(written.textViewerSettings == AppPreferences.defaults().textViewerSettings)
        // Nothing changed of Read or Edit: the app's stays as another pane set it.
        var other = app
        other.textViewerSettings.opensForEditing = false
        var followOnly = before
        followOnly.viewerFollows = false
        #expect(!followOnly.changes(from: before, appliedTo: other).textViewerSettings.opensForEditing)
    }
}
