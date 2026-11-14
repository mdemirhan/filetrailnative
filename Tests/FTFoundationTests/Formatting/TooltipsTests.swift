import Testing

@testable import FTFoundation

struct TooltipsTests {
    @Test func writesACommandsNameAndThenItsShortcut() {
        #expect(Tooltips.format("Move to Trash", shortcutLabel: "⌘⌫") == "Move to Trash (⌘⌫)")
        #expect(Tooltips.format("Close Search Results", shortcutLabel: "Esc") == "Close Search Results (Esc)")
        #expect(Tooltips.format("Home") == "Home")
        #expect(Tooltips.format("Home", shortcutLabel: "") == "Home")
    }

    // The status bar's slider says what it sets and the keys that change it a step at a time; the List has none.
    @Test func namesTheSizeSlidersKeys() {
        #expect(Tooltips.sizeSliderTooltip(.icons) == "Icon Size (⌘+ bigger, ⌘- smaller, ⌘0 default)")
        #expect(Tooltips.sizeSliderTooltip(.list) == "Column Width (⌘+ wider, ⌘- narrower, ⌘0 default)")
        #expect(Tooltips.sizeSliderTooltip(.details) == nil)
        let none = ShortcutDisplay(
            shortcuts: ShortcutCommands.resolve(["increaseSize": [], "decreaseSize": [], "resetSize": []]))
        #expect(Tooltips.sizeSliderTooltip(.icons, shortcuts: none) == "Icon Size")
    }

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

    @Test func namesTheTextEditorInEditAsTheMenusDo() {
        #expect(
            Tooltips.toolbarItemLabel(itemID: .editSelection, state: ToolbarTooltipState(textEditorName: "Zed"))
                == "Edit in Zed")
        #expect(Tooltips.toolbarItemLabel(itemID: .editSelection) == "Edit in Text Editor")
        #expect(Tooltips.toolbarItemLabel(itemID: .back) == "Back")
        #expect(Tooltips.toolbarItemLabel(itemID: .help) == "File Trail Help")
    }

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

    @Test func namesToolbarButtonsAsTheMenusNameTheirCommands() throws {
        let expected: [String: String] = [
            "back": "Back (⌘[)", "forward": "Forward (⌘])", "up": "Enclosing Folder (⌘↑)",
            "refresh": "Refresh (⌘R)", "goToFolder": "Go To (⌘K)", "newTab": "New Tab (⌘T)",
            "openSelection": "Open (⌘O)", "quickLook": "Quick Look (⌘Y)",
            "editSelection": "Edit in Text Editor (⇧⌘E)", "moveSelection": "Move To (⇧⌘M)",
            "renameSelection": "Rename (↩)", "duplicateSelection": "Duplicate (⌘D)",
            "newFolder": "New Folder (⇧⌘N)", "trashSelection": "Move to Trash (⌘⌫)", "copySelection": "Copy (⌘C)",
            "cutSelection": "Cut (⌘X)", "pasteSelection": "Paste (⌘V)", "openInTerminal": "Open in Terminal (⌥⌘T)",
            // No key until one is chosen in Settings.
            "showInFinder": "Show in Finder", "revealInFolder": "Reveal in Folder",
            "calculateSize": "Calculate Size", "copyPath": "Copy Path (⌥⌘C)", "settings": "Settings (⌘,)",
            "help": "File Trail Help (?)",
        ]
        for (name, tooltip) in expected {
            let id = try #require(ToolbarItemID(rawValue: name))
            #expect(Tooltips.toolbarItemTooltip(itemID: id) == tooltip, "\(name)")
        }
    }

    // The commands Help's shortcut list documents; a tooltip must not promise a key for any other command.
    @Test func promisesNoShortcutThatHelpDoesNotList() {
        let documented: Set<String> = [
            "calculateSize", "clearClipboard", "closeTab", "closeWindow", "copy", "copyPath", "cut",
            "duplicateSelection", "editSelection", "ejectVolume", "emptyTrash", "focusContentPane", "focusFileSearch",
            "focusTreePane", "fullScreen", "goApplications", "goBack", "goDesktop", "goDocuments", "goDownloads",
            "goEnclosingFolder", "goForward", "goHomeRootTree", "goLibrary", "goMacintoshHD", "goTrash",
            "halfPageDown", "halfPageUp", "hide", "mergeAllWindows", "minimize", "moveSelection", "moveTabToNewWindow",
            "newFolder", "newTab", "newWindow", "openHelp", "openInTerminal", "openKeyboardShortcuts",
            "openLocationSheet", "openSelectedItem", "openSelection", "openSelectionInNewTab",
            "openSelectionInNewWindow", "pageDown", "pageUp", "paste", "pasteAsFile", "quickLookSelection", "redo",
            "refreshOrApplySearchSort", "renameSelection", "reopenClosedTab", "revealInFolder", "rootTreeAtSelection",
            "selectAll", "selectNextTab", "selectPreviousTab", "settings", "showClipboard", "showInFinder",
            "showLastSearchResults", "sortByKind", "sortByModified", "sortByName", "sortBySize", "toggleFavorite",
            "toggleFolderTree", "toggleFoldersFirst", "toggleHiddenFiles", "toggleInfoPanel", "toggleInfoRow",
            "toggleTwoPanes",
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

    @Test func tabLabels() {
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
