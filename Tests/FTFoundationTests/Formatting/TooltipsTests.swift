// Port of the wording cases of apps/desktop/src/renderer/lib/{tooltips,titleTooltips}.test.ts.
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

    // T-db1ba4f6 F-093
    @Test func saysWhatAClickOnAnOnOffButtonWillDo() {
        let off = ToolbarTooltipState(
            foldersFirst: false, hiddenFilesShown: false, infoPanelOpen: false, infoRowOpen: false)
        let on = ToolbarTooltipState(foldersFirst: true, hiddenFilesShown: true, infoPanelOpen: true, infoRowOpen: true)
        func both(_ id: ToolbarItemID) -> [String] {
            [Tooltips.toolbarItemTooltip(itemID: id, state: off), Tooltips.toolbarItemTooltip(itemID: id, state: on)]
        }
        #expect(both(.hidden) == ["Show Hidden Files (⇧⌘.)", "Hide Hidden Files (⇧⌘.)"])
        #expect(both(.infoPanel) == ["Show Info Panel (⌘I)", "Hide Info Panel (⌘I)"])
        #expect(both(.infoRow) == ["Show Info Row (⇧⌘I)", "Hide Info Row (⇧⌘I)"])
        #expect(both(.foldersFirst) == ["List Folders First", "Mix Files and Folders"])
        // The folder tree is open unless it is said to be closed.
        #expect(Tooltips.toolbarItemLabel(itemID: .folderTree) == "Hide Folder Tree")
        #expect(
            Tooltips.toolbarItemLabel(itemID: .folderTree, state: ToolbarTooltipState(folderTreeOpen: false))
                == "Show Folder Tree")
    }

    // T-5890f92a F-093
    @Test func namesTheTextEditorInEditAsTheMenusDo() {
        #expect(
            Tooltips.toolbarItemLabel(itemID: .editSelection, state: ToolbarTooltipState(textEditorName: "Zed"))
                == "Edit in Zed")
        #expect(Tooltips.toolbarItemLabel(itemID: .editSelection) == "Edit in Text Editor")
        #expect(Tooltips.toolbarItemLabel(itemID: .back) == "Back")
        #expect(Tooltips.toolbarItemLabel(itemID: .help) == "File Trail Help")
    }

    // T-32e945b7 F-093
    @Test func writesShortcutsInTheOrderMacOSDoes() {
        #expect(ShortcutLabels.format("Cmd+Shift+.") == "⇧⌘.")
        #expect(ShortcutLabels.format("Cmd+Option+T") == "⌥⌘T")
        #expect(ShortcutLabels.format("Ctrl+Cmd+F") == "⌃⌘F")
        #expect(ShortcutLabels.format("Cmd++") == "⌘+")
        #expect(ShortcutLabels.format("Return") == "↩")
        #expect(ShortcutLabels.format("Esc") == "Esc")
        #expect(ShortcutLabels.parts("Cmd+Shift+G") == ["⇧", "⌘", "G"])
        #expect(Tooltips.format("Move to Trash", shortcut: "Cmd+Backspace") == "Move to Trash (⌘⌫)")
        #expect(Tooltips.format("Close Search Results", shortcut: "Esc") == "Close Search Results (Esc)")
        #expect(Tooltips.format("Home", shortcut: nil) == "Home")
    }

    // T-760ee5f0 F-093
    // B-NAV-042
    @Test func namesToolbarButtonsAsTheMenusNameTheirCommands() {
        var tooltips: [String: String] = [:]
        for item in ToolbarItems.definitions where item.kind == .button {
            tooltips[item.id.rawValue] = Tooltips.toolbarItemTooltip(itemID: item.id)
        }
        #expect(
            tooltips == [
                "back": "Back (⌘[)", "forward": "Forward (⌘])", "up": "Enclosing Folder (⌘↑)",
                "refresh": "Refresh (⌘R)", "goToFolder": "Go To (⌘K)", "newTab": "New Tab (⌘T)",
                "openSelection": "Open (⌘O)", "quickLook": "Quick Look (Space)",
                "editSelection": "Edit in Text Editor (⇧⌘E)", "moveSelection": "Move To (⇧⌘M)",
                "renameSelection": "Rename (↩)", "duplicateSelection": "Duplicate (⌘D)",
                "newFolder": "New Folder (⇧⌘N)", "trashSelection": "Move to Trash (⌘⌫)", "copySelection": "Copy (⌘C)",
                "cutSelection": "Cut (⌘X)", "pasteSelection": "Paste (⌘V)", "openInTerminal": "Open in Terminal (⌥⌘T)",
                // No key until one is chosen in Settings.
                "showInFinder": "Show in Finder", "revealInFolder": "Reveal in Folder",
                "calculateSize": "Calculate Size", "copyPath": "Copy Path (⌥⌘C)", "settings": "Settings (⌘,)",
                "help": "File Trail Help (?)",
            ])
    }

    // T-e3148ee5 F-093
    // The commands Help's shortcut list documents (SHORTCUT_ITEMS in helpContent.ts, less the zoom commands, which
    // are dropped by D-005); a tooltip must not promise a key for any other command.
    @Test func promisesNoShortcutThatHelpDoesNotList() {
        let documented: Set<String> = [
            "calculateSize", "clearClipboard", "closeTab", "closeWindow", "copy", "copyPath", "cut",
            "duplicateSelection", "editSelection", "ejectVolume", "emptyTrash", "focusContentPane", "focusFileSearch",
            "focusTreePane", "fullScreen", "goApplications", "goBack", "goDesktop", "goDocuments", "goDownloads",
            "goEnclosingFolder", "goForward", "goHomeRootTree", "goLibrary", "goMacintoshHD", "goTrash",
            "halfPageDown", "halfPageUp", "hide", "mergeAllWindows", "minimize", "moveSelection", "moveTabToNewWindow",
            "newFolder", "newTab", "newWindow", "openHelp", "openInTerminal", "openKeyboardShortcuts",
            "openLocationSheet", "openSelectedItem", "openSelection", "openSelectionInNewTab",
            "openSelectionInNewWindow", "pageDown", "pageUp", "paste", "quickLookSelection", "redo",
            "refreshOrApplySearchSort", "renameSelection", "reopenClosedTab", "revealInFolder", "rootTreeAtSelection",
            "selectAll", "selectNextTab", "selectPreviousTab", "settings", "showClipboard", "showInFinder",
            "showLastSearchResults", "sortByKind", "sortByModified", "sortByName", "sortBySize", "toggleFavorite",
            "toggleFolderTree", "toggleFoldersFirst", "toggleHiddenFiles", "toggleInfoPanel", "toggleInfoRow",
            "trashSelection", "undo", "viewAsDetails", "viewAsIcons", "viewAsList",
        ]
        for item in ToolbarItems.definitions {
            guard let command = item.shortcutCommand else { continue }
            let shortcut = ShortcutDisplay.defaults.label(command)
            #expect(
                shortcut == nil || documented.contains(command.rawValue),
                "\(item.label): \(shortcut ?? "") is missing from Help")
        }
    }

    // T-82e83839 F-093
    // T-5c7904a9
    @Test func showsTheKeysChosenInSettingsAndNoneForACommandLeftWithoutOne() {
        let shortcuts = ShortcutDisplay(
            shortcuts: ShortcutCommands.resolve([
                "trashSelection": ["Cmd+Delete"], "refreshOrApplySearchSort": [],
                "toggleFoldersFirst": ["Cmd+Option+F"],
            ]),
            returnKeyAction: .open)
        func tooltip(_ id: ToolbarItemID) -> String { Tooltips.toolbarItemTooltip(itemID: id, shortcuts: shortcuts) }
        #expect(tooltip(.trashSelection) == "Move to Trash (⌘⌦)")
        #expect(tooltip(.refresh) == "Refresh")
        #expect(tooltip(.foldersFirst) == "List Folders First (⌥⌘F)")
        // Return opens, so Rename is left with the key it was given.
        #expect(tooltip(.renameSelection) == "Rename (F2)")
        #expect(tooltip(.copySelection) == "Copy (⌘C)")
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
