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

        #expect(
            main.items.map(\.title) == ["File Trail", "File", "Edit", "View", "Layout", "Go", "Window", "Help"])
        #expect(
            titles(submenu(main, "File Trail")) == [
                "About File Trail", "-", "Settings…", "-", "Empty Trash…", "-", "Services", "-", "Hide File Trail",
                "Hide Others", "Show All", "-", "Quit File Trail",
            ])
        #expect(
            titles(submenu(main, "File")) == [
                "New Window", "New Tab", "Duplicate Tab", "New Folder", "New Folder with Selection", "New File",
                "Save as Template", "-",
                "Open", "Open With", "Open in Viewer", "Open in New Tab", "Open in New Window", "Open in Other Pane",
                "Edit in Text Editor", "Quick Look", "Calculate Size", "Reveal in Folder", "Show Original", "-",
                "Rename", "Duplicate", "Make Alias", "Move to…", "-",
                "Compress", "Extract", "Extract To…", "Convert Images…", "-",
                "Share…", "Add to Favorites", "Open in Terminal", "Show in Finder", "-",
                // Delete Immediately…, the item ⌥ shows in Move to Trash's place.
                "Move to Trash", "Delete Immediately…", "Eject", "-",
                "Reopen Closed Tab",
                // Close Pane until synced, then Close Tab, the item ⌥ shows in its place.
                "Close Tab", "Close Tab", "Close Window",
            ])
        #expect(
            titles(submenu(main, "Edit")) == [
                "Undo", "Redo", "-", "Cut", "Copy", "Paste", "Move Items Here", "Select All", "Deselect All",
                "Invert Selection", "-", "Copy Path", "Copy Contents", "Paste as File", "-", "Copy to Other Pane",
                "Move to Other Pane", "-", "Add to Copied Items", "Add to Cut Items", "Remove from Clipboard",
                "Show Clipboard", "Clear Clipboard", "-", "Find Files…", "Show Last Search Results",
            ])
        #expect(
            titles(submenu(main, "View")) == [
                "as Icons", "as List", "as Compact List", "as Previews", "Show Previews", "-", "Make Bigger",
                "Make Smaller",
                "Default Size", "Zoom to Fit", "-", "Group By", "Sort By", "Folders First", "Hidden Files", "Columns",
                "-",
                "Pin Filter", "Refresh",
                "-", "Hide Folder Tree", "Info Panel", "Info Row", "-", "Two Panes", "Duplicate Pane", "Swap Panes",
                "Make Panes Equal Width", "-", "Customize Toolbar…", "Command Palette…",
            ])
        #expect(
            titles(item(submenu(main, "View"), "Group By").submenu!) == [
                "None", "-", "Name", "Date Modified", "Date Created", "Date Last Opened", "Date Added", "Size", "Kind",
                "Tags", "Folder", "-", "Reverse Group Order",
            ])
        // Each kind under a heading of its own; the tab views and window views come between Save and Manage.
        #expect(
            titles(submenu(main, "Layout")) == [
                "Folder View", "Remember View for This Folder", "Update Folder View", "Revert to Saved View",
                "Folder View Options…", "Reset Folder View", "Manage Folder Views…", "-",
                "Tab Views", "Save Tab View…", "Manage Tab Views…", "-",
                "Window Views", "Save Window View…", "Manage Window Views…",
            ])
        let headings = submenu(main, "Layout").items.filter(\.isSectionHeader).map(\.title)
        #expect(headings == ["Folder View", "Tab Views", "Window Views"])
        #expect(
            titles(submenu(main, "Go")) == [
                "Back", "Forward", "Enclosing Folder", "-", "Documents", "Desktop",
                "Downloads", "Home", "Library",
                "Macintosh HD", "Applications", "Trash", "-", "Go to Folder…", "Go to Page…", "-",
                "Show This Folder in Other Pane",
                "Go to Other Pane's Folder", "-", "Use as Tree Root",
            ])
        #expect(
            titles(submenu(main, "Window")) == [
                "Minimize", "Zoom", "-", "Show Previous Tab", "Show Next Tab", "Move Tab to New Window",
                "Merge All Windows", "-", "Switch to Other Pane", "-", "Bring All to Front",
            ])
        #expect(titles(submenu(main, "Help")) == ["File Trail Help", "Keyboard Shortcuts"])
        // The system's own menus are the ones AppKit adds the services, the windows and the search field to.
        #expect(built.windowsMenu === submenu(main, "Window"))
        #expect(built.helpMenu === submenu(main, "Help"))
        #expect(built.servicesMenu === item(submenu(main, "File Trail"), "Services").submenu)
    }

    // The first five tab views, the ones that can have keys, are in the menu; the rest in More Tab Views.
    @Test func listsTheTabViewsTheFirstFiveWithTheirKeysAndTheRestInMore() {
        let entries = (1...7).map { SavedViewMenuEntry(id: "t\($0)", name: "Compare \($0)") }
        let (built, router) = build(.init(tabViews: entries))
        let menu = submenu(built.menu, "Layout")
        let shown = titles(menu)
        let start = shown.firstIndex(of: "Save Tab View…") ?? 0
        let expected: [String] =
            ["Save Tab View…"] + entries.prefix(5).map(\.name) + ["More Tab Views", "Manage Tab Views…"]
        #expect(Array(shown[start...(start + 7)]) == expected)
        let more = submenu(menu, "More Tab Views")
        #expect(titles(more) == ["Compare 6", "Compare 7"])
        #expect(item(more, "Compare 6").keyEquivalent == "")
        // Chosen there as in the menu: by the same item ids.
        #expect(item(more, "Compare 7").identifier?.rawValue == ApplicationMenu.tabViewItemID("t7"))
        #expect(item(more, "Compare 7").action == #selector(MenuCommandRouter.chooseMenuItem(_:)))
        // A tab isn't linked to the tab view it came from: none is checked.
        #expect(menu.items.allSatisfy { $0.state == .off })
        let first = item(menu, "Compare 1")
        #expect(first.keyEquivalent == "1")
        #expect(first.keyEquivalentModifierMask == [.option, .command])
        #expect(item(menu, "Compare 5").keyEquivalent == "5")
        var managed: [ViewsWindowPane] = []
        router.onManageViews = { managed.append($0) }
        router.choose(itemID: ApplicationMenu.manageTabViewsItemID)
        router.choose(itemID: ApplicationMenu.manageWindowViewsItemID)
        #expect(managed == [.tabViews, .windowViews])
    }

    @Test func listsTheWindowViewsTheFirstFiveWithTheirKeysEachWithAnItemForThisWindow() {
        let entries = (1...6).map { SavedViewMenuEntry(id: "w\($0)", name: "Work \($0)") }
        let (built, router) = build(.init(windowViews: entries))
        let menu = submenu(built.menu, "Layout")
        let shown = titles(menu)
        let start = shown.firstIndex(of: "Save Window View…") ?? 0
        let pairs: [String] = entries.prefix(5).flatMap { [$0.name, "\($0.name) in This Window"] }
        let expected: [String] = ["Save Window View…"] + pairs + ["More Window Views", "Manage Window Views…"]
        #expect(Array(shown[start...]) == expected)
        let more = submenu(menu, "More Window Views")
        #expect(titles(more) == ["Work 6", "Work 6 in This Window"])
        let first = item(menu, "Work 1")
        #expect(first.keyEquivalent == "1")
        #expect(first.keyEquivalentModifierMask == [.control, .command])
        // "In This Window" has no key to begin with: it can't be the item ⌥ shows in place of one that has, so both
        // show.
        let here = item(menu, "Work 1 in This Window")
        #expect(!here.isAlternate)
        #expect(here.keyEquivalent == "")
        #expect(item(menu, "Work 5").keyEquivalent == "5")
        // With no key either, ⌥ shows it in the item's place.
        #expect(item(more, "Work 6").keyEquivalent == "")
        #expect(item(more, "Work 6 in This Window").isAlternate)
        #expect(item(more, "Work 6 in This Window").keyEquivalentModifierMask == [.option])

        var opened: [String] = []
        router.onOpenWindowView = { id, _ in opened.append(id) }
        router.choose(itemID: ApplicationMenu.windowViewItemID("w2"))
        #expect(opened == ["w2"])
    }

    // Five or fewer: no More submenu.
    @Test func fiveSavedViewsNeedNoMore() {
        let entries = (1...5).map { SavedViewMenuEntry(id: "v\($0)", name: "View \($0)") }
        let (built, _) = build(.init(tabViews: entries, windowViews: entries))
        let shown = titles(submenu(built.menu, "Layout"))
        #expect(!shown.contains("More Tab Views") && !shown.contains("More Window Views"))
    }

    @Test func keysThatDontDifferByOptionAloneShowBothItemsEachWithItsKey() {
        let bindings = ShortcutCommands.resolve([
            "openWindowView1": ["Cmd+Option+F1"], "openWindowView1InThisWindow": ["Ctrl+Cmd+Option+F1"],
            "openWindowView2InThisWindow": ["Ctrl+Cmd+F1"],
            "openWindowView3InThisWindow": ["Ctrl+Cmd+Option+Shift+3"],
        ]).bindings
        let entries = (1...3).map { SavedViewMenuEntry(id: "w\($0)", name: "Work \($0)") }
        let (built, _) = build(.init(shortcuts: bindings, windowViews: entries))
        let menu = submenu(built.menu, "Layout")
        // Its key has ⌥ already: nothing can be ⌥ away from it.
        #expect(item(menu, "Work 1").keyEquivalentModifierMask == [.option, .command])
        #expect(!item(menu, "Work 1 in This Window").isAlternate)
        // Another key altogether.
        let second = item(menu, "Work 2 in This Window")
        #expect(!second.isAlternate)
        #expect(second.keyEquivalentModifierMask == [.control, .command])
        #expect(item(menu, "Work 2").keyEquivalent == "2")
        // ⌥ and more.
        #expect(!item(menu, "Work 3 in This Window").isAlternate)
    }

    @Test func aKeyGivenToInThisWindowPairsWhileTheyDifferByOptionAlone() {
        let bindings = ShortcutCommands.resolve(["openWindowView1InThisWindow": ["Ctrl+Cmd+Option+1"]]).bindings
        let (built, _) = build(
            .init(shortcuts: bindings, windowViews: [SavedViewMenuEntry(id: "w1", name: "Work 1")]))
        let menu = submenu(built.menu, "Layout")
        let here = item(menu, "Work 1 in This Window")
        #expect(here.isAlternate)
        #expect(here.keyEquivalent == item(menu, "Work 1").keyEquivalent)
        #expect(here.keyEquivalentModifierMask == [.control, .option, .command])
    }

    // Rename shows Return while Return renames, as Help and the right-click menu do, and F2 while Return opens; F5 and
    // F6 show beside Copy and Move to Other Pane. The menu bar never takes a key without ⌘ or ⌃: the window does, so a
    // text field or a dialog keeps it.
    @Test func showsTheWindowsOwnKeysAndNeverTakesThem() throws {
        let file = { (action: ReturnKeyAction) in submenu(self.build(.init(returnKeyAction: action)).0.menu, "File") }
        #expect(accelerator(item(file(.rename), "Rename")) == "Return")
        #expect(accelerator(item(file(.open), "Rename")) == "F2")
        let (built, _) = build()
        #expect(accelerator(item(submenu(built.menu, "Edit"), "Copy to Other Pane")) == "F5")
        for (key, code) in [("\r", UInt16(36)), (String(UnicodeScalar(UInt16(NSF5FunctionKey))!), UInt16(96))] {
            let event = try #require(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                    characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: code))
            #expect(!built.menu.performKeyEquivalent(with: event))
        }
    }

    // Delete Immediately is the item ⌥ shows in Move to Trash's place, as in Finder.
    @Test func deleteImmediatelyIsTheItemOptionShowsInMoveToTrashsPlace() {
        let file = submenu(build().0.menu, "File")
        let trash = item(file, "Move to Trash")
        let delete = item(file, "Delete Immediately…")
        #expect(!trash.isAlternate && delete.isAlternate)
        #expect(file.index(of: delete) == file.index(of: trash) + 1)
        #expect(accelerator(delete) == "Command+Alt+Backspace")
    }

    @Test func closeTabIsTheItemOptionShowsInClosePanesPlace() {
        let (built, _) = build()
        let file = submenu(built.menu, "File")
        let pane = flatten(file).first { $0.identifier?.rawValue == "closePane" }
        let tab = flatten(file).first { $0.identifier?.rawValue == "closeTab" }
        #expect(pane?.keyEquivalent == "w")
        #expect(pane?.keyEquivalentModifierMask == [.command])
        #expect(pane?.isAlternate == false)
        #expect(tab?.isAlternate == true)
        #expect(tab?.keyEquivalent == "w")
        #expect(tab?.keyEquivalentModifierMask == [.option, .command])
        // The alternate comes right after the item it stands in for.
        if let pane, let tab { #expect(file.index(of: tab) == file.index(of: pane) + 1) }
    }

    @Test func duplicatePaneIsAnItemOfItsOwnAfterTwoPanes() {
        let (built, _) = build()
        let view = submenu(built.menu, "View")
        let panes = flatten(view).first { $0.identifier?.rawValue == "toggleTwoPanes" }
        let duplicate = flatten(view).first { $0.identifier?.rawValue == "duplicatePane" }
        #expect(panes?.keyEquivalent == "\\")
        #expect(panes?.keyEquivalentModifierMask == [.command])
        #expect(duplicate?.isAlternate == false)
        #expect(duplicate?.keyEquivalent == "\\")
        #expect(duplicate?.keyEquivalentModifierMask == [.option, .command])
        if let panes, let duplicate { #expect(view.index(of: duplicate) == view.index(of: panes) + 1) }
    }

    @Test func closeTabGivenAnotherKeyShowsAsAnItemOfItsOwn() {
        let bindings = ShortcutCommands.resolve(["closeTab": ["Cmd+Shift+J"]]).bindings
        let (built, _) = build(.init(shortcuts: bindings))
        let tab = flatten(submenu(built.menu, "File")).first { $0.identifier?.rawValue == "closeTab" }
        #expect(tab?.isAlternate == false)
        #expect(tab?.keyEquivalent == "j")
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
            ("File", "New Folder with Selection", "Control+Command+N", .newFolderWithSelection),
            ("File", "Open", "Command+O", .openSelection),
            ("File", "Open in Viewer", "Command+Shift+E", .viewFile),
            ("File", "Open in New Tab", nil, .openSelectionInNewTab),
            ("File", "Open in New Window", nil, .openSelectionInNewWindow),
            ("File", "Quick Look", "Command+Y", .quickLookSelection),
            ("File", "Reveal in Folder", nil, .revealInFolder),
            ("File", "Show Original", nil, .showOriginal),
            ("File", "Calculate Size", nil, .calculateSize),
            // Return, while it renames, and F2 work from the window itself: the menu shows Return and never takes
            // it, so text fields and dialogs keep it.
            ("File", "Rename", "Return", .renameSelection),
            ("File", "Edit in Text Editor", "Command+E", .editSelection),
            ("File", "Duplicate", "Command+D", .duplicateSelection),
            ("File", "Make Alias", "Control+Command+A", .makeAlias),
            ("File", "Move to…", "Command+Shift+M", .moveSelection),
            ("File", "Add to Favorites", "Control+Command+T", .toggleFavorite),
            ("File", "Open in Terminal", "Command+Alt+T", .openInTerminal),
            ("File", "Show in Finder", nil, .showInFinder),
            ("File", "Move to Trash", "Command+Backspace", .trashSelection),
            ("File", "Delete Immediately…", "Command+Alt+Backspace", .deleteImmediately),
            ("File", "Reopen Closed Tab", "Command+Shift+T", .reopenClosedTab),
            // Close Pane, named Close Tab until the menu is synced with a tab of two panes.
            ("File", "Close Tab", "Command+W", .closePane),
            ("File", "Close Window", "Command+Shift+W", .closeTab),
            ("Edit", "Cut", "Command+X", .editCut),
            ("Edit", "Copy", "Command+C", .editCopy),
            ("Edit", "Paste", "Command+V", .editPaste),
            ("Edit", "Paste as File", "Command+Shift+V", .pasteAsFile),
            // The window's keys, shown and never taken by the menu.
            ("Edit", "Copy to Other Pane", "F5", .copyToOtherPane),
            ("Edit", "Move to Other Pane", "F6", .moveToOtherPane),
            ("Edit", "Copy Path", "Command+Alt+C", .copyPath),
            ("Edit", "Copy Contents", "Command+Shift+C", .copyContents),
            ("Edit", "Select All", "Command+A", .editSelectAll),
            ("Edit", "Deselect All", "Command+Alt+A", .deselectAll),
            ("Edit", "Invert Selection", nil, .invertSelection),
            ("Edit", "Find Files…", "Command+F", .focusFileSearch),
            ("Edit", "Show Last Search Results", "Command+Shift+F", .showLastSearchResults),
            ("View", "as Icons", "Command+1", .viewAsIcons),
            ("View", "as List", "Command+2", .viewAsDetails),
            ("View", "as Compact List", "Command+3", .viewAsList),
            // ⌘+ (⌘=, its other key, is the window's).
            ("View", "Make Bigger", "Command++", .increaseSize),
            ("View", "Make Smaller", "Command+-", .decreaseSize),
            ("View", "Default Size", "Command+0", .resetSize),
            ("View", "Zoom to Fit", "Command+9", .zoomToFit),
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
            ("Go", "Go to Page…", "Command+Alt+G", .goToPage),
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
            ("Name", .sortByName), ("Folder", .sortByFolder), ("Date Modified", .sortByModified),
            ("Date Created", .sortByCreated),
            ("Date Last Opened", .sortByLastOpened),
            ("Date Added", .sortByAdded), ("Size", .sortBySize), ("Kind", .sortByKind),
        ]
        #expect(titles(sortMenu) == expected.map(\.0))
        for (title, command) in expected {
            let found = item(sortMenu, title)
            #expect(found.identifier?.rawValue == command.rawValue)
            #expect(accelerator(found) == nil)
        }
    }

    @Test func showsPreviewsAtEachCountFromTheShowPreviewsSubmenuWithNoKeysUntilOneIsChosen() {
        let (built, _) = build()
        guard let previewsMenu = item(submenu(built.menu, "View"), "Show Previews").submenu else {
            Issue.record("Show Previews has no submenu")
            return
        }
        let expected: [(String, AppCommand)] = [
            ("9 at a Time", .showPreviews9), ("4 at a Time", .showPreviews4), ("2 at a Time", .showPreviews2),
            ("1 at a Time", .showPreviews1),
        ]
        #expect(titles(previewsMenu) == expected.map(\.0))
        for (title, command) in expected {
            let found = item(previewsMenu, title)
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
            guard let id = found.identifier?.rawValue, id != "about", id != "settings",
                id != ApplicationMenu.manageTabViewsItemID, id != ApplicationMenu.manageWindowViewsItemID,
                id != ApplicationMenuBuilder.commandPaletteItemID, ApplicationMenu.windowViewItem(id) == nil,
                ApplicationMenu.tabViewItem(id) == nil
            else { continue }
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
