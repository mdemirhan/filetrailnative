// A saved tab's second pane, active pane and divider, as the sanitizer reads them
import Foundation
import Testing

@testable import FTFoundation

struct SavedPanesTests {
    private func tabs(_ json: String) throws -> [OpenTabPreference] {
        let node = try JSONDecoder().decode(JSONNode.self, from: Data(json.utf8))
        return PreferencesSanitizer.openTabs(
            node, includeHidden: false, foldersFirst: true, favoritesExpanded: true, locationsExpanded: true)
    }

    @Test func aTabSavedBeforePanesHasOnePane() throws {
        let read = try tabs(#"[{"path": "/Users/demo", "viewMode": "list", "activePane": 1, "paneSplit": 0.3}]"#)
        #expect(read.count == 1)
        #expect(read[0].secondPane == nil)
        #expect(read[0].activePane == nil)
        #expect(read[0].paneSplit == nil)
    }

    @Test func readsTheSecondPaneTheActivePaneAndTheDivider() throws {
        let read = try tabs(
            #"[{"path": "/Users/demo", "includeHidden": true, "secondPane": {"path": "/tmp", "viewMode": "icons", "sortBy": "size", "sortDirection": "desc"}, "activePane": 1, "paneSplit": 0.65}]"#
        )
        let second = try #require(read.first?.secondPane)
        #expect(second.path == "/tmp")
        #expect(second.viewMode == .icons)
        #expect(second.sortBy == .size)
        #expect(second.sortDirection == .desc)
        // What it doesn't say comes from the tab's first pane.
        #expect(second.includeHidden)
        #expect(second.searchViewMode == .details)
        #expect(read.first?.activePane == 1)
        #expect(read.first?.paneSplit == 0.65)
    }

    // Hidden Files is the tab's. A tab saved while each pane had its own takes its active pane's, in both panes.
    @Test func aTabSavedWithPanesThatDifferInHiddenFilesTakesItsActivePanes() throws {
        let read = try tabs(
            #"[{"path": "/a", "includeHidden": false, "secondPane": {"path": "/b", "includeHidden": true}, "activePane": 1}, {"path": "/c", "includeHidden": true, "secondPane": {"path": "/d", "includeHidden": false}}]"#
        )
        #expect(read[0].includeHidden && read[0].secondPane?.includeHidden == true)
        #expect(read[1].includeHidden && read[1].secondPane?.includeHidden == true)
    }

    // Each pane keeps how typing filters its folders. A file saved before that has none, and so has one naming a
    // mode this build doesn't know: the pane starts with the mode chosen last. What is read is written the same.
    @Test func readsEachPanesOwnFilterMode() throws {
        let read = try tabs(
            #"[{"path": "/a", "filterMode": "contains", "secondPane": {"path": "/b", "filterMode": "fuzzy"}}, {"path": "/c", "secondPane": {"path": "/d", "filterMode": "contains"}}, {"path": "/e", "filterMode": "soundsLike", "secondPane": {"path": "/f", "filterMode": 3}}]"#
        )
        #expect(read[0].filterMode == .contains && read[0].secondPane?.filterMode == .fuzzy)
        #expect(read[1].filterMode == nil && read[1].secondPane?.filterMode == .contains)
        #expect(read[2].filterMode == nil && read[2].secondPane?.filterMode == nil)
        let again = PreferencesSanitizer.openTabs(
            try JSONNode.of(read), includeHidden: false, foldersFirst: true, favoritesExpanded: true,
            locationsExpanded: true)
        #expect(again == read)
        // A window opened from a tab's active pane has a new pane: it carries no mode.
        #expect(read[0].activePaneAlone.filterMode == nil)
    }

    @Test func aDamagedDividerIsKeptInItsRangeAndAnUnknownActivePaneIsTheFirst() throws {
        let read = try tabs(
            #"[{"path": "/a", "secondPane": {"path": ""}, "activePane": 7, "paneSplit": 3}, {"path": "/b", "secondPane": {}, "paneSplit": -1}]"#
        )
        #expect(read.count == 2)
        #expect(read[0].secondPane?.path == nil)
        #expect(read[0].activePane == nil)
        #expect(read[0].paneSplit == 0.8)
        #expect(read[1].paneSplit == 0.2)
    }

    // Each pane keeps the sizes it shows its views at. A file saved before that has none, and the pane starts from
    // the app's; one it doesn't say is the size before any is set, and one out of range is brought into it.
    @Test func readsEachPanesOwnSizes() throws {
        let read = try tabs(
            #"[{"path": "/a", "viewSizes": {"iconSizes": {"standard": 96, "finder": 9999}, "previewCounts": {"standard": 9}}, "secondPane": {"path": "/b", "viewSizes": {"compactListWidths": {"standard": 400, "finder": 180}}}}, {"path": "/c"}]"#
        )
        let first = try #require(read[0].viewSizes)
        #expect(first.iconSizes == DensitySizes(standard: 96, finder: 128))
        #expect(first.previewCounts.standard == 9)
        #expect(first.previewCounts.finder == PreviewGrid.defaultCount)
        #expect(first.compactListWidths == .compactListDefaults)
        let second = try #require(read[0].secondPane?.viewSizes)
        #expect(second.compactListWidths == DensitySizes(standard: 400, finder: 180))
        #expect(second.iconSizes == .iconDefaults)
        #expect(read[1].viewSizes == nil)
        // Written and read again, they are what they were.
        let data = try JSONEncoder().encode(read)
        #expect(try JSONDecoder().decode([OpenTabPreference].self, from: data) == read)
    }

    // A new window starts from a tab's active pane alone: that pane's folder, view, order and sizes, and no second
    // pane.
    @Test func theActivePaneAloneIsWhatANewWindowStartsFrom() throws {
        let read = try tabs(
            #"[{"path": "/a", "viewMode": "list", "viewSizes": {"iconSizes": {"standard": 96}}, "secondPane": {"path": "/b", "viewMode": "icons", "sortBy": "size", "viewSizes": {"iconSizes": {"standard": 40}}}, "activePane": 1, "paneSplit": 0.4}]"#
        )
        let second = read[0].activePaneAlone
        #expect(second.path == "/b" && second.viewMode == .icons && second.sortBy == .size)
        #expect(second.viewSizes?.iconSizes.standard == 40)
        #expect(second.secondPane == nil && second.activePane == nil && second.paneSplit == nil)
        var first = read[0]
        first.activePane = nil
        #expect(first.activePaneAlone.path == "/a")
        #expect(first.activePaneAlone.viewSizes?.iconSizes.standard == 96)
        #expect(first.activePaneAlone.secondPane == nil)
    }

    // The List's column widths are kept with the pane's sizes, a folder's and search results' apart, each brought into
    // its range; a pane saved with sizes but none of the widths takes the ones it is given, its window's.
    @Test func readsEachPanesOwnColumnWidths() throws {
        let read = try tabs(
            #"[{"path": "/a", "viewSizes": {"detailColumnWidths": {"name": 9999, "size": 140}, "searchColumnWidths": {"folder": 5}}, "secondPane": {"path": "/b", "viewSizes": {"detailColumnWidths": {"name": 250}}}}]"#
        )
        let first = try #require(read[0].viewSizes)
        #expect(first.detailColumnWidths.name == 1000)
        #expect(first.detailColumnWidths.size == 140)
        #expect(first.detailColumnWidths.kind == DetailColumnWidths.defaults.kind)
        #expect(first.searchColumnWidths.folder == 80)
        #expect(first.searchColumnWidths.name == SearchColumnWidths.defaults.name)
        let second = try #require(read[0].secondPane?.viewSizes)
        #expect(second.detailColumnWidths.name == 250)
        #expect(second.searchColumnWidths == .defaults)
        let data = try JSONEncoder().encode(read)
        #expect(try JSONDecoder().decode([OpenTabPreference].self, from: data) == read)
    }

    // Each pane keeps what it groups folders by and search results by; a file saved before groups has none, and one
    // naming a grouping this build doesn't know, or one a folder or results can't use, reads as none. A new window
    // started from the second pane takes its groupings.
    @Test func readsEachPanesGroupings() throws {
        let read = try tabs(
            #"[{"path": "/a", "groupBy": "modified", "searchGroupBy": "folder", "groupReversed": true, "secondPane": {"path": "/b", "groupBy": "tags", "searchGroupBy": "kind", "searchGroupReversed": true}, "activePane": 1}, {"path": "/c"}, {"path": "/d", "groupBy": "folder", "searchGroupBy": "size"}, {"path": "/e", "groupBy": "colour"}]"#
        )
        #expect(read[0].groupBy == .modified && read[0].searchGroupBy == .folder)
        #expect(read[0].groupReversed == true && read[0].searchGroupReversed == nil)
        #expect(read[0].secondPane?.groupBy == .tags && read[0].secondPane?.searchGroupBy == .kind)
        #expect(read[1].groupBy == nil && read[1].searchGroupBy == nil)
        #expect(read[2].groupBy == nil && read[2].searchGroupBy == .size)
        #expect(read[3].groupBy == nil)
        let alone = read[0].activePaneAlone
        #expect(alone.groupBy == .tags && alone.searchGroupBy == .kind && alone.secondPane == nil)
        #expect(alone.searchGroupReversed == true && alone.groupReversed == nil)
        // A direction with nothing grouped is no direction.
        let ungrouped = OpenPanePreference(
            path: "/y", viewMode: .list, searchViewMode: .details, sortBy: .name, sortDirection: .asc,
            includeHidden: false, foldersFirst: true, groupReversed: true)
        #expect(ungrouped.groupReversed == nil)
        // None is saved as nothing, so a tab not grouped is written as before.
        let plain = OpenPanePreference(
            path: "/x", viewMode: .list, searchViewMode: .details, sortBy: .name, sortDirection: .asc,
            includeHidden: false, foldersFirst: true, groupBy: GroupByPreference.none)
        #expect(plain.groupBy == nil)
        let text = String(decoding: try JSONEncoder().encode(plain), as: UTF8.self)
        #expect(!text.contains("groupBy"))
    }
}
