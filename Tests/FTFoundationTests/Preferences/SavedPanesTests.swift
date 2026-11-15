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
}
