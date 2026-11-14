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

    // (Zoom In, Zoom Out and Actual Size are left out; macOS adds its own Enter Full Screen)
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
                "New Window", "New Tab", "Duplicate Tab", "New Folder", "-", "Open", "Open in New Tab",
                "Open in New Window", "Open in Other Pane", "Edit in Text Editor", "Quick Look", "Reveal in Folder",
                "-",
                "Calculate Size", "-", "Rename", "Duplicate", "Move to…", "Add to Favorites", "-",
                "Open in Terminal", "Show in Finder", "-", "Move to Trash", "Eject", "-", "Reopen Closed Tab",
                "Close Tab", "Close Window",
            ])
        #expect(
            titles(submenu(main, "Edit")) == [
                "Undo", "Redo", "-", "Cut", "Copy", "Paste", "Copy to Other Pane", "Move to Other Pane", "Copy Path",
                "Select All", "-",
                "Show Clipboard", "Clear Clipboard", "-", "Find Files…", "Show Last Search Results",
            ])
        #expect(
            titles(submenu(main, "View")) == [
                "as Icons", "as List", "as Compact List", "as Previews", "-", "Make Bigger", "Make Smaller",
                "Default Size", "-", "Sort By", "Folders First", "Hidden Files", "Pin Filter", "Refresh",
                "-", "Hide Folder Tree", "Info Panel", "Info Row", "-", "Two Panes", "Swap Panes",
                "Make Panes Equal Width", "-", "Customize Toolbar…",
            ])
        #expect(
            titles(submenu(main, "Go")) == [
                "Back", "Forward", "Enclosing Folder", "-", "Documents", "Desktop", "Downloads", "Home", "Library",
                "Macintosh HD", "Applications", "Trash", "-", "Go to Folder…", "Show This Folder in Other Pane",
                "Go to Other Pane's Folder", "-", "Use as Tree Root",
            ])
        #expect(
            titles(submenu(main, "Window")) == [
                "Minimize", "Zoom", "-", "Show Previous Tab", "Show Next Tab", "Switch to Other Pane",
                "Move Tab to New Window", "Merge All Windows", "-", "Bring All to Front",
            ])
        #expect(titles(submenu(main, "Help")) == ["File Trail Help", "Keyboard Shortcuts"])
        // The system's own menus are the ones AppKit adds the services, the windows and the search field to.
        #expect(built.windowsMenu === submenu(main, "Window"))
        #expect(built.helpMenu === submenu(main, "Help"))
        #expect(built.servicesMenu === item(submenu(main, "File Trail"), "Services").submenu)
    }

    @Test func namesTheChosenTextEditorInFile() {
        let file = { (name: String?) in titles(submenu(self.build(.init(textEditorName: name)).0.menu, "File")) }
        #expect(file("Zed").contains("Edit in Zed"))
        #expect(file(nil).contains("Edit in Text Editor"))
    }

    @Test func namesTheStartupDiskInGoByItsName() {
        let go = { (name: String) in titles(submenu(self.build(.init(startupDiskName: name)).0.menu, "Go")) }
        #expect(go("Data").contains("Data"))
        #expect(!go("Data").contains("Macintosh HD"))
        #expect(titles(submenu(build().0.menu, "Go")).contains("Macintosh HD"))
    }

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

    // (the keys; the commands sent are checked in MenuCommandRouterTests)
    @Test func showsEachItemOnItsShortcut() {
        let (built, _) = build()
        let expected: [(String, String, String?, AppCommand)] = [
            ("File", "New Window", "Command+N", .newWindow),
            ("File", "New Tab", "Command+T", .newTab),
            ("File", "Duplicate Tab", nil, .duplicateTab),
            ("File", "New Folder", "Command+Shift+N", .newFolder),
            ("File", "Open", "Command+O", .openSelection),
            ("File", "Open in New Tab", nil, .openSelectionInNewTab),
            ("File", "Open in New Window", nil, .openSelectionInNewWindow),
            ("File", "Edit in Text Editor", "Command+Shift+E", .editSelection),
            ("File", "Quick Look", "Command+Y", .quickLookSelection),
            ("File", "Reveal in Folder", nil, .revealInFolder),
            ("File", "Calculate Size", nil, .calculateSize),
            // Space and F2 work from the window itself: as menu shortcuts they would be taken from text fields and
            // dialogs.
            ("File", "Rename", nil, .renameSelection),
            ("File", "Duplicate", "Command+D", .duplicateSelection),
            ("File", "Move to…", "Command+Shift+M", .moveSelection),
            ("File", "Add to Favorites", nil, .toggleFavorite),
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
            // ⌘+ (⌘=, its other key, is the window's).
            ("View", "Make Bigger", "Command++", .increaseSize),
            ("View", "Make Smaller", "Command+-", .decreaseSize),
            ("View", "Default Size", "Command+0", .resetSize),
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
                #expect(found.identifier?.rawValue == command.rawValue, "\(title)")
            }
        }
    }

    @Test func sortsFromTheSortBySubmenu() {
        let (built, _) = build()
        guard let sortMenu = item(submenu(built.menu, "View"), "Sort By").submenu else {
            Issue.record("Sort By has no submenu")
            return
        }
        let expected: [(String, AppCommand)] = [
            ("Name", .sortByName), ("Kind", .sortByKind), ("Date Modified", .sortByModified), ("Size", .sortBySize),
        ]
        #expect(titles(sortMenu) == expected.map(\.0))
        for (title, command) in expected {
            let found = item(sortMenu, title)
            #expect(found.identifier?.rawValue == command.rawValue)
            #expect(accelerator(found) == nil)
        }
    }

    @Test func givesEveryItemThatSendsACommandAnIDOfItsOwn() {
        let (built, _) = build()
        let items = flatten(built.menu)
        let ids = items.compactMap { $0.identifier?.rawValue }

        #expect(Set(ids).count == ids.count)
        for found in items where found.action == #selector(MenuCommandRouter.chooseMenuItem(_:)) {
            #expect(found.identifier != nil, "\(found.title)")
        }
    }

    @Test func hasAStateForEveryItemOfTheMenuThatSendsACommand() {
        let (built, _) = build()
        let states = ApplicationMenu.itemStates(.initial, window: .init(explorerFocused: true))
        let stateIDs = Set(states.map(\.id))
        for found in flatten(built.menu) where found.action == #selector(MenuCommandRouter.chooseMenuItem(_:)) {
            guard let id = found.identifier?.rawValue, id != "about", id != "settings" else { continue }
            #expect(stateIDs.contains(id), "\(found.title)")
        }
    }

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

    // Undo and Redo, Favorites and the folder tree are one item each, whose title the sync sets; none is hidden.
    @Test func hasOneItemForEachCommandThatSaysTwoThings() {
        let bindings = ShortcutCommands.resolve(["toggleFavorite": ["Cmd+Shift+B"]]).bindings
        let (built, _) = build(.init(shortcuts: bindings))
        let items = flatten(built.menu)
        for (id, title, key) in [
            ("undo", "Undo", "Command+Z"), ("redo", "Redo", "Command+Shift+Z"),
            ("toggleFavorite", "Add to Favorites", "Command+Shift+B"),
            ("toggleFolderTree", "Hide Folder Tree", "Control+Command+S"),
        ] {
            let found = items.filter { $0.identifier?.rawValue.hasPrefix(id) == true }
            #expect(found.count == 1, "\(id)")
            #expect(found.first?.title == title)
            #expect(found.first.flatMap(accelerator) == key, "\(id)")
        }
        #expect(!items.contains { $0.isHidden })
    }

    /// Records the items chosen.
    private final class ChosenItems: NSObject {
        var ids: [String] = []
        @objc func choose(_ sender: NSMenuItem) { ids.append(sender.identifier?.rawValue ?? "") }
    }

    // ⌘+ is typed as ⇧⌘= on a US keyboard: the menu takes it, ⌘- and ⌘0, and leaves ⌘=, Make Bigger's other key, to
    // the window.
    @Test func theSizeItemsTakeTheirKeysAndLeaveCommandEqualsToTheWindow() throws {
        let (built, _) = build()
        let chosen = ChosenItems()
        for id in ["increaseSize", "decreaseSize", "resetSize"] {
            let item = try #require(built.itemsByID[id])
            item.target = chosen
            item.action = #selector(ChosenItems.choose(_:))
        }
        func press(_ code: UInt16, _ flags: CGEventFlags) throws -> Bool {
            built.menu.performKeyEquivalent(with: try systemKeyEvent(code, flags))
        }
        // The keys of =, - and 0.
        #expect(try press(24, [.maskCommand, .maskShift]))
        #expect(try press(27, [.maskCommand]))
        #expect(try press(29, [.maskCommand]))
        #expect(chosen.ids == ["increaseSize", "decreaseSize", "resetSize"])
        #expect(try !press(24, [.maskCommand]))
        #expect(chosen.ids.count == 3)
    }

    @Test func keysOnlyComeFromTheShortcutTable() {
        #expect(MenuKeyEquivalent.parse("Cmd+Shift+G") == MenuKeyEquivalent(key: "g", modifiers: [.command, .shift]))
        #expect(MenuKeyEquivalent.parse("Ctrl+Tab") == MenuKeyEquivalent(key: "\t", modifiers: [.control]))
        #expect(MenuKeyEquivalent.parse("Cmd+Plus") == MenuKeyEquivalent(key: "+", modifiers: [.command]))
        #expect(MenuKeyEquivalent.parse("Cmd+Backspace")?.key == "\u{8}")
        #expect(MenuKeyEquivalent.parse("Cmd+F5")?.key == String(Character(UnicodeScalar(UInt32(NSF5FunctionKey))!)))
        #expect(MenuKeyEquivalent.parse("?") == nil)
    }
}
