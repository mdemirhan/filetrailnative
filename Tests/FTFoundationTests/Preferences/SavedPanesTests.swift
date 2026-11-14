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
}
