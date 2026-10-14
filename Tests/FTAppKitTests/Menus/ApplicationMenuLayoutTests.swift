// Ports the layout cases of apps/desktop/src/main/appMenu.test.ts (createApplicationMenuTemplate)
import AppKit
import FTFoundation
import Testing

@testable import FTAppKit

@MainActor
@Suite struct ApplicationMenuLayoutTests {
    private func build(_ options: ApplicationMenuOptions = .init()) -> (BuiltApplicationMenu, MenuCommandRouter) {
        _ = NSApplication.shared
        let router = MenuCommandRouter()
        return (ApplicationMenuBuilder.build(target: router, options: options), router)
    }

    // T-b65028eb F-572 F-573 F-574 F-575 F-576 F-577 F-579 F-581 F-582 F-583 F-584 F-585 F-586 F-587 F-590 F-591 F-592 F-593
    // F-594 (Zoom In, Zoom Out and Actual Size are left out: DEVIATIONS D-005; macOS adds its own Enter Full Screen)
    @Test func laysTheMenusOutTheWayAMacAppDoes() {
        let (built, _) = build()
        let main = built.menu

        #expect(main.items.map(\.title) == ["File Trail", "File", "Edit", "View", "Go", "Window", "Help"])
        #expect(
            titles(submenu(main, "File Trail")) == [
                "About File Trail", "-", "Settings…", "-", "Empty Trash…", "-", "Services", "-", "Hide File Trail",
                "Hide Others", "Show All", "-", "Quit File Trail",
            ])
        #expect(
            titles(submenu(main, "File")) == [
                "New Window", "New Tab", "Duplicate Tab", "New Folder", "-", "Open", "Open in New Tab", "Open in New Window",
                "Edit in Text Editor", "Quick Look", "Reveal in Folder", "-", "Calculate Size", "-", "Rename",
                "Duplicate", "Move to…", "Add to Favorites", "Remove from Favorites", "-", "Open in Terminal",
                "Show in Finder", "-", "Move to Trash", "Eject", "-", "Reopen Closed Tab", "Close Tab", "Close Window",
            ])
        #expect(
            titles(submenu(main, "Edit")) == [
                // The files' Undo and Redo, each beside a text field's own.
                "Undo", "Undo", "Redo", "Redo", "-", "Cut", "Copy", "Paste", "Copy Path", "Select All", "-",
                "Show Clipboard", "Clear Clipboard", "-", "Find Files…", "Show Last Search Results",
            ])
        #expect(
            titles(submenu(main, "View")) == [
                "as Icons", "as List", "as Compact List", "-", "Sort By", "Folders First", "Hidden Files", "Refresh",
                "-", "Hide Folder Tree", "Show Folder Tree", "Info Panel", "Info Row", "-", "Customize Toolbar…",
            ])
        #expect(
            titles(submenu(main, "Go")) == [
                "Back", "Forward", "Enclosing Folder", "-", "Documents", "Desktop", "Downloads", "Home", "Library",
                "Macintosh HD", "Applications", "Trash", "-", "Go to Folder…", "-", "Use as Tree Root",
            ])
        #expect(
            titles(submenu(main, "Window")) == [
                "Minimize", "Zoom", "-", "Show Previous Tab", "Show Next Tab", "Move Tab to New Window",
                "Merge All Windows", "-", "Bring All to Front",
            ])
        #expect(titles(submenu(main, "Help")) == ["File Trail Help", "Keyboard Shortcuts"])
        // The system's own menus are the ones AppKit adds the services, the windows and the search field to.
        #expect(built.windowsMenu === submenu(main, "Window"))
        #expect(built.helpMenu === submenu(main, "Help"))
        #expect(built.servicesMenu === item(submenu(main, "File Trail"), "Services").submenu)
    }

    // T-15f24e5b F-574
    @Test func namesTheChosenTextEditorInFile() {
        let file = { (name: String?) in titles(submenu(self.build(.init(textEditorName: name)).0.menu, "File")) }
        #expect(file("Zed").contains("Edit in Zed"))
        #expect(file(nil).contains("Edit in Text Editor"))
    }

    // T-4478f617 F-572
    @Test func namesTheAppItselfRatherThanItsPackage() {
        let (built, _) = build()
        let appMenu = submenu(built.menu, "File Trail")

        #expect(item(appMenu, "About File Trail").title == "About File Trail")
        #expect(item(appMenu, "Hide File Trail").action == #selector(NSApplication.hide(_:)))
        #expect(item(appMenu, "Hide Others").action == #selector(NSApplication.hideOtherApplications(_:)))
        #expect(item(appMenu, "Show All").action == #selector(NSApplication.unhideAllApplications(_:)))
        #expect(item(appMenu, "Quit File Trail").action == #selector(NSApplication.terminate(_:)))
        #expect(accelerator(item(appMenu, "Hide File Trail")) == "Command+H")
        #expect(accelerator(item(appMenu, "Hide Others")) == "Command+Alt+H")
        #expect(accelerator(item(appMenu, "Quit File Trail")) == "Command+Q")
        #expect(accelerator(item(appMenu, "Settings…")) == "Command+,")
        #expect(accelerator(item(appMenu, "Empty Trash…")) == "Command+Shift+Backspace")
    }

    // T-ea45c4fc F-596 (the keys; the commands sent are checked in MenuCommandRouterTests)
    // covered-by-feature F-588 (zoom items: N/A, DEVIATIONS D-005)
    @Test func showsEachItemOnItsShortcut() {
        let (built, _) = build()
        let expected: [(String, String, String?, RendererCommand)] = [
            ("File", "New Window", "Command+N", .newWindow),
            ("File", "New Tab", "Command+T", .newTab),
            ("File", "Duplicate Tab", nil, .duplicateTab),
            ("File", "New Folder", "Command+Shift+N", .newFolder),
            ("File", "Open", "Command+O", .openSelection),
            ("File", "Open in New Tab", nil, .openSelectionInNewTab),
            ("File", "Open in New Window", nil, .openSelectionInNewWindow),
            ("File", "Edit in Text Editor", "Command+Shift+E", .editSelection),
            ("File", "Quick Look", nil, .quickLookSelection),
            ("File", "Reveal in Folder", nil, .revealInFolder),
            ("File", "Calculate Size", nil, .calculateSize),
            // Space and F2 work from the window itself: as menu shortcuts they would be taken from text fields and
            // dialogs.
            ("File", "Rename", nil, .renameSelection),
            ("File", "Duplicate", "Command+D", .duplicateSelection),
            ("File", "Move to…", "Command+Shift+M", .moveSelection),
            ("File", "Add to Favorites", nil, .toggleFavorite),
            ("File", "Remove from Favorites", nil, .toggleFavorite),
            ("File", "Open in Terminal", "Command+Alt+T", .openInTerminal),
            ("File", "Show in Finder", nil, .showInFinder),
            ("File", "Move to Trash", "Command+Backspace", .trashSelection),
            ("File", "Eject", "Command+E", .ejectVolume),
            ("File", "Reopen Closed Tab", "Command+Shift+T", .reopenClosedTab),
            ("File", "Close Tab", "Command+W", .closeTab),
            ("File", "Close Window", "Command+Shift+W", .closeTab),
            ("Edit", "Cut", "Command+X", .editCut),
            ("Edit", "Copy", "Command+C", .editCopy),
            ("Edit", "Paste", "Command+V", .editPaste),
            ("Edit", "Copy Path", "Command+Alt+C", .copyPath),
            ("Edit", "Select All", "Command+A", .editSelectAll),
            ("Edit", "Find Files…", "Command+F", .focusFileSearch),
            ("Edit", "Show Last Search Results", "Command+Shift+F", .showLastSearchResults),
            ("View", "as Icons", "Command+1", .viewAsIcons),
            ("View", "as List", "Command+2", .viewAsDetails),
            ("View", "as Compact List", "Command+3", .viewAsList),
            ("View", "Folders First", nil, .toggleFoldersFirst),
            ("View", "Hidden Files", "Command+Shift+.", .toggleHiddenFiles),
            ("View", "Info Panel", "Command+I", .toggleInfoPanel),
            ("View", "Info Row", "Command+Shift+I", .toggleInfoRow),
            ("View", "Refresh", "Command+R", .refreshOrApplySearchSort),
            ("Go", "Back", "Command+[", .goBack),
            ("Go", "Forward", "Command+]", .goForward),
            ("Go", "Enclosing Folder", "Command+Up", .goEnclosingFolder),
            ("Go", "Documents", nil, .goDocuments),
            ("Go", "Desktop", nil, .goDesktop),
            ("Go", "Downloads", nil, .goDownloads),
            ("Go", "Home", "Command+Shift+H", .goHomeRootTree),
            ("Go", "Library", nil, .goLibrary),
            ("Go", "Macintosh HD", nil, .goMacintoshHD),
            ("Go", "Applications", nil, .goApplications),
            ("Go", "Trash", nil, .goTrash),
            ("Go", "Go to Folder…", "Command+K", .openLocationSheet),
            ("Go", "Use as Tree Root", "Command+Shift+R", .rootTreeAtSelection),
            ("Window", "Show Previous Tab", "Control+Shift+Tab", .selectPreviousTab),
            ("Window", "Show Next Tab", "Control+Tab", .selectNextTab),
            ("Window", "Move Tab to New Window", nil, .moveTabToNewWindow),
            ("Window", "Merge All Windows", nil, .mergeAllWindows),
            ("Help", "File Trail Help", nil, .openHelp),
            ("Help", "Keyboard Shortcuts", nil, .openKeyboardShortcuts),
        ]
        for (menu, title, key, command) in expected {
            let found = item(submenu(built.menu, menu), title)
            #expect(accelerator(found) == key, "\(title)")
            if title != "Close Window" {
                #expect(found.identifier?.rawValue.hasPrefix(command.rawValue) == true, "\(title)")
            }
        }
    }

    // T-765afa44 F-584
    @Test func sortsFromTheSortBySubmenu() {
        let (built, _) = build()
        guard let sortMenu = item(submenu(built.menu, "View"), "Sort By").submenu else {
            Issue.record("Sort By has no submenu")
            return
        }
        let expected: [(String, RendererCommand)] = [
            ("Name", .sortByName), ("Kind", .sortByKind), ("Date Modified", .sortByModified), ("Size", .sortBySize),
        ]
        #expect(titles(sortMenu) == expected.map(\.0))
        for (title, command) in expected {
            let found = item(sortMenu, title)
            #expect(found.identifier?.rawValue == command.rawValue)
            #expect(built.radioItemIDs.contains(command.rawValue))
            #expect(accelerator(found) == nil)
        }
        #expect(built.radioItemIDs.contains("viewAsIcons"))
        #expect(!built.radioItemIDs.contains("toggleFoldersFirst"))
    }

    // T-1708e261 F-597
    @Test func givesEveryItemThatSendsACommandAnIDOfItsOwn() {
        let (built, _) = build()
        let items = flatten(built.menu)
        let ids = items.compactMap { $0.identifier?.rawValue }

        #expect(Set(ids).count == ids.count)
        for found in items where found.action == #selector(MenuCommandRouter.chooseMenuItem(_:)) {
            #expect(found.identifier != nil, "\(found.title)")
        }
    }

    // T-4eb643d8 F-598
    @Test func hasAStateForEveryItemOfTheMenuThatSendsACommand() {
        let (built, _) = build()
        let states = ApplicationMenu.itemStates(.initial, window: .init(explorerFocused: true))
        let stateIDs = Set(states.map(\.id))
        for found in flatten(built.menu) where found.action == #selector(MenuCommandRouter.chooseMenuItem(_:)) {
            guard let id = found.identifier?.rawValue, id != "about", id != "settings" else { continue }
            #expect(stateIDs.contains(id), "\(found.title)")
        }
    }

    // N/A T-22d10b77 Toggle Developer Tools has no native equivalent (F-914)

    // T-96221c32 F-572
    @Test func keepsSettingsOnItsFixedKey() {
        let (built, router) = build()
        let settings = item(submenu(built.menu, "File Trail"), "Settings…")
        #expect(accelerator(settings) == "Command+,")
        #expect(settings.target === router)
    }

    // T-a3d1eed6 F-596
    @Test func showsTheKeysChosenInSettingsAndLeavesAKeyWithoutCommandOrControlToTheWindow() {
        let bindings = ShortcutCommands.resolve([
            "newTab": ["Cmd+Option+N"], "duplicateSelection": [], "quickLookSelection": ["Space", "Cmd+Y"],
            "showInFinder": ["F5", "Ctrl+Shift+R"],
        ]).bindings
        let (built, _) = build(.init(shortcuts: bindings))
        let file = submenu(built.menu, "File")

        #expect(accelerator(item(file, "New Tab")) == "Command+Alt+N")
        #expect(accelerator(item(file, "Duplicate")) == nil)
        // The menu takes the first key it can listen for; Space and F5 stay with the window.
        #expect(accelerator(item(file, "Quick Look")) == "Command+Y")
        #expect(accelerator(item(file, "Show in Finder")) == "Control+Shift+R")
        // Commands that were left alone keep their keys, and Copy is never changed.
        #expect(accelerator(item(file, "New Folder")) == "Command+Shift+N")
        #expect(accelerator(item(submenu(built.menu, "Edit"), "Copy")) == "Command+C")
    }

    // F-579 F-580
    @Test func hasTheFilesAndATextFieldsUndoAndRedoOfWhichOneShowsAtATime() {
        let (built, _) = build(.init(undoLabels: (undo: "Undo Move of “a.txt”", redo: "Redo")))
        let edit = submenu(built.menu, "Edit")
        let undoItems = edit.items.filter { $0.title.hasPrefix("Undo") }

        #expect(undoItems.map(\.title) == ["Undo Move of “a.txt”", "Undo"])
        #expect(undoItems.map(\.isHidden) == [false, true])
        #expect(undoItems.map(accelerator) == ["Command+Z", "Command+Z"])
        #expect(edit.items.filter { $0.title == "Redo" }.map(accelerator) == ["Command+Shift+Z", "Command+Shift+Z"])
        #expect(built.itemsByID["undo:text"]?.isHidden == true)
        #expect(built.itemsByID["redo:text"]?.isHidden == true)
        #expect(built.itemsByID["toggleFavorite:remove"]?.isHidden == true)
        #expect(built.itemsByID["toggleFolderTree:show"]?.isHidden == true)
    }

    // F-586 F-589
    @Test func keepsTheFolderTreeKeyOnItsToggles() {
        let (built, _) = build()
        let view = submenu(built.menu, "View")
        #expect(accelerator(item(view, "Hide Folder Tree")) == "Control+Command+S")
        #expect(accelerator(item(view, "Show Folder Tree")) == "Control+Command+S")
    }

    // F-596
    @Test func keysOnlyComeFromTheShortcutTable() {
        #expect(MenuKeyEquivalent.parse("Cmd+Shift+G") == MenuKeyEquivalent(key: "g", modifiers: [.command, .shift]))
        #expect(MenuKeyEquivalent.parse("Ctrl+Tab") == MenuKeyEquivalent(key: "\t", modifiers: [.control]))
        #expect(MenuKeyEquivalent.parse("Cmd+Plus") == MenuKeyEquivalent(key: "+", modifiers: [.command]))
        #expect(MenuKeyEquivalent.parse("Cmd+Backspace")?.key == "\u{8}")
        #expect(MenuKeyEquivalent.parse("Cmd+F5")?.key == String(Character(UnicodeScalar(UInt32(NSF5FunctionKey))!)))
        #expect(MenuKeyEquivalent.parse("?") == nil)
    }
}
