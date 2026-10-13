// Port of the wording cases of apps/desktop/src/renderer/lib/{tooltips,titleTooltips}.test.ts.
// The toolbar table, the shortcut table and the shortcut symbols belong to the commands package
// (P1-03); the cases that need them are ported when it lands.
import Testing

@testable import FTFoundation

struct TooltipsTests {
    // T-77685469 F-093
    @Test func writesACommandsNameAndThenItsShortcut() {
        #expect(Tooltips.format("Move to Trash", shortcutLabel: "⌘⌫") == "Move to Trash (⌘⌫)")
        #expect(Tooltips.format("Close Search Results", shortcutLabel: "Esc") == "Close Search Results (Esc)")
        #expect(Tooltips.format("Home") == "Home")
        #expect(Tooltips.format("Home", shortcutLabel: "") == "Home")
    }

    // F-093
    @Test func saysWhatAClickOnAnOnOffButtonWillDo() {
        let off = ToolbarTooltipState(
            foldersFirst: false, hiddenFilesShown: false, infoPanelOpen: false, infoRowOpen: false)
        let on = ToolbarTooltipState(foldersFirst: true, hiddenFilesShown: true, infoPanelOpen: true, infoRowOpen: true)
        func both(_ id: String) -> [String?] {
            [Tooltips.toolbarItemLabel(itemID: id, state: off), Tooltips.toolbarItemLabel(itemID: id, state: on)]
        }
        #expect(both("hidden") == ["Show Hidden Files", "Hide Hidden Files"])
        #expect(both("infoPanel") == ["Show Info Panel", "Hide Info Panel"])
        #expect(both("infoRow") == ["Show Info Row", "Hide Info Row"])
        #expect(both("foldersFirst") == ["List Folders First", "Mix Files and Folders"])
        // The folder tree is open unless it is said to be closed.
        #expect(Tooltips.toolbarItemLabel(itemID: "folderTree") == "Hide Folder Tree")
        #expect(
            Tooltips.toolbarItemLabel(itemID: "folderTree", state: ToolbarTooltipState(folderTreeOpen: false))
                == "Show Folder Tree")
    }

    // F-093
    @Test func namesTheTextEditorInEdit() {
        #expect(
            Tooltips.toolbarItemLabel(itemID: "editSelection", state: ToolbarTooltipState(textEditorName: "Zed"))
                == "Edit in Zed")
        // Without an editor the name is the table's ("Edit in Text Editor").
        #expect(Tooltips.toolbarItemLabel(itemID: "editSelection") == nil)
        #expect(Tooltips.toolbarItemLabel(itemID: "back") == nil)
    }

    // T-fba42efc
    @Test func placesTheTooltipUnderAControlFlipsAboveNearTheBottomAndStaysOnScreen() {
        let viewport = TitleTooltips.Size(width: 1000, height: 800)
        let bubble = TitleTooltips.Size(width: 80, height: 20)
        #expect(
            TitleTooltips.placement(
                anchor: .init(left: 300, top: 10, right: 330, bottom: 38, width: 30), bubble: bubble, viewport: viewport
            )
                == TitleTooltips.Placement(left: 275, top: 44))
        #expect(
            TitleTooltips.placement(
                anchor: .init(left: 40, top: 760, right: 70, bottom: 788, width: 30), bubble: bubble, viewport: viewport
            )
                == TitleTooltips.Placement(left: 15, top: 734))
        #expect(
            TitleTooltips.placement(
                anchor: .init(left: 980, top: 10, right: 998, bottom: 38, width: 18), bubble: bubble, viewport: viewport
            ).left == 914)
    }

    @Test func tabLabels() {
        // F-068
        #expect(
            TabText.describe(
                currentPath: "/", searchVisible: false, searchQuery: "", searchRootPath: "", searchRunning: false)
                == TabDescription(label: "Macintosh HD", tooltip: "/", kind: .folder, searching: false))
        #expect(
            TabText.describe(
                currentPath: "/Users/demo/Documents/", searchVisible: false, searchQuery: "", searchRootPath: "",
                searchRunning: false
            ).label
                == "Documents")
        #expect(
            TabText.describe(
                currentPath: "", searchVisible: false, searchQuery: "", searchRootPath: "", searchRunning: false
            ).label == "Favorites")
        #expect(
            TabText.describe(
                currentPath: "/a", searchVisible: true, searchQuery: " report ", searchRootPath: "/Users/demo",
                searchRunning: true)
                == TabDescription(
                    label: "“ report ” in demo", tooltip: "Searching /Users/demo", kind: .search, searching: true))
        // A blank query is no search; without a root the folder on screen is searched.
        #expect(
            TabText.describe(
                currentPath: "/a", searchVisible: true, searchQuery: "  ", searchRootPath: "/b", searchRunning: true
            ).kind == .folder)
        #expect(
            TabText.describe(
                currentPath: "/a", searchVisible: true, searchQuery: "x", searchRootPath: "", searchRunning: false
            ).tooltip == "Searching /a")
    }
}
