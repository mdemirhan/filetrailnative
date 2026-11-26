import AppKit
import FTFoundation

/// What the menu is built with; it is built again when any of it changes.
struct ApplicationMenuOptions {
    /// The keys of every command, as chosen in Settings → Shortcuts.
    var shortcuts: ShortcutBindings = ShortcutCommands.defaultBindings
    /// The text editor chosen in Settings → Files, which File names.
    var textEditorName: String?
    /// What Return does in the list, chosen in Settings → Files: while it renames, Rename shows ↩.
    var returnKeyAction: ReturnKeyAction = .rename
    /// What the startup disk is called, which Go names.
    var startupDiskName = VolumePaths.defaultStartupDiskName
    /// The tab views and window views Layout lists, each in its order.
    var tabViews: [SavedViewMenuEntry] = []
    var windowViews: [SavedViewMenuEntry] = []
    /// The files of the Templates folder File ▸ New File lists, by name in order.
    var templates: [String] = []
}

/// A tab view or a window view as Layout lists it.
struct SavedViewMenuEntry: Equatable {
    var id: String
    var name: String
}

/// The menu bar and where its parts are.
struct BuiltApplicationMenu {
    let menu: NSMenu
    let servicesMenu: NSMenu
    let windowsMenu: NSMenu
    let helpMenu: NSMenu
    /// Every item that has an id, which is how the states find them.
    let itemsByID: [String: NSMenuItem]
}

/// The name the menus use for the app: the bundle's is not it while the app runs unbundled.
let applicationMenuName = "File Trail"

@MainActor
enum ApplicationMenuBuilder {
    /// Ids of the items that are not a window's command (`AppCommand`).
    static let aboutItemID = "about"
    static let settingsItemID = "settings"
    /// View ▸ Command Palette…, which the menu opens itself rather than the window.
    static let commandPaletteItemID = ShortcutCommandID.showCommandPalette.rawValue

    static func build(target: MenuCommandRouter, options: ApplicationMenuOptions = .init()) -> BuiltApplicationMenu {
        let context = Context(target: target, options: options)
        let main = ApplicationMainMenu(title: "")
        main.autoenablesItems = true

        let servicesMenu = NSMenu(title: "Services")
        context.addSubmenu(to: main, title: applicationMenuName) { menu in
            menu.addItem(context.plain("About \(applicationMenuName)", id: aboutItemID))
            menu.addItem(.separator())
            menu.addItem(context.plain("Settings…", id: settingsItemID, fixed: .settings))
            menu.addItem(.separator())
            menu.addItem(context.command(.emptyTrash, "Empty Trash…"))
            menu.addItem(.separator())
            let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
            services.submenu = servicesMenu
            menu.addItem(services)
            menu.addItem(.separator())
            menu.addItem(context.native("Hide \(applicationMenuName)", #selector(NSApplication.hide(_:)), .hide))
            menu.addItem(
                context.native("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), .hideOthers))
            menu.addItem(context.native("Show All", #selector(NSApplication.unhideAllApplications(_:)), nil))
            menu.addItem(.separator())
            menu.addItem(context.native("Quit \(applicationMenuName)", #selector(NSApplication.terminate(_:)), .quit))
        }

        context.addSubmenu(to: main, title: "File") { menu in
            menu.addItem(context.command(.newWindow, "New Window"))
            menu.addItem(context.command(.newTab, "New Tab"))
            // The system tab bar has no menu of the app's, so the File menu has it.
            menu.addItem(context.command(.duplicateTab, "Duplicate Tab"))
            menu.addItem(context.command(.newFolder, "New Folder"))
            menu.addItem(context.command(.newFolderWithSelection, "New Folder with Selection"))
            let newFile = NSMenuItem(title: "New File", action: nil, keyEquivalent: "")
            newFile.submenu = context.newFileMenu()
            menu.addItem(newFile)
            menu.addItem(context.command(.saveAsTemplate, "Save as Template"))
            menu.addItem(.separator())
            // Opening and looking: what changes nothing of the items.
            menu.addItem(context.command(.openSelection, "Open"))
            // The apps that can open the selected items, as Finder's File menu and the right-click menu have it.
            let openWith = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
            openWith.submenu = MenuBarOpenWith.shared.makeMenu()
            menu.addItem(openWith)
            // The file's text in this pane, to read or edit: the viewer holds the rest of what it does.
            menu.addItem(context.command(.viewFile, "Open in Viewer"))
            menu.addItem(context.command(.openSelectionInNewTab, "Open in New Tab"))
            menu.addItem(context.command(.openSelectionInNewWindow, "Open in New Window"))
            menu.addItem(context.command(.openSelectionInOtherPane, "Open in Other Pane"))
            let editor = MenuName.shortened(options.textEditorName ?? "Text Editor")
            menu.addItem(context.command(.editSelection, "Edit in \(editor)"))
            menu.addItem(context.command(.quickLookSelection, "Quick Look"))
            menu.addItem(context.command(.calculateSize, "Calculate Size"))
            // Search results only, as Finder's Show in Enclosing Folder.
            menu.addItem(context.command(.revealInFolder, "Reveal in Folder"))
            // A symbolic link's or an alias's original, selected in its folder, as Finder's.
            menu.addItem(context.command(.showOriginal, MakeAlias.showOriginalLabel))
            menu.addItem(.separator())
            // What changes the items, then makes or reads archives and images, in the order of the right-click menu.
            menu.addItem(context.command(.renameSelection, "Rename"))
            menu.addItem(context.command(.duplicateSelection, "Duplicate"))
            menu.addItem(context.command(.makeAlias, MakeAlias.commandLabel))
            menu.addItem(context.command(.moveSelection, "Move to…"))
            menu.addItem(.separator())
            // Names what it makes a zip of once the menu is synced: Compress “Photos”, Compress 3 Items.
            menu.addItem(context.command(.compressSelection, "Compress"))
            menu.addItem(context.command(.extractSelection, "Extract"))
            menu.addItem(context.command(.extractSelectionTo, "Extract To…"))
            // "Convert 3 Images…" for the images selected.
            menu.addItem(context.command(.convertImages, ConvertImagesText.commandLabel))
            menu.addItem(.separator())
            // The tag colors and Tags…, where the right-click menu has them.
            menu.addItem(context.view(MenuBarTagColors.shared.makeItem()))
            menu.addItem(context.command(.editTags, "Tags…"))
            menu.addItem(.separator())
            // What hands the items to something else.
            menu.addItem(context.command(.shareSelection, "Share…"))
            // "Remove from Favorites" while the folder is one.
            menu.addItem(context.command(.toggleFavorite, "Add to Favorites"))
            menu.addItem(context.command(.openInTerminal, "Open in Terminal"))
            menu.addItem(context.command(.showInFinder, "Show in Finder"))
            menu.addItem(.separator())
            // Delete Immediately, for what is in the Trash, is the item ⌥ shows in Move to Trash's place, as in Finder.
            for item in context.alternatePair(
                .trashSelection, "Move to Trash", .deleteImmediately, "Delete Immediately…")
            {
                menu.addItem(item)
            }
            // The disk selected in the sidebar, as Finder's File ▸ Eject.
            menu.addItem(context.command(.ejectVolume, "Eject"))
            menu.addItem(.separator())
            menu.addItem(context.command(.reopenClosedTab, "Reopen Closed Tab"))
            // Closes the pane it is in while the tab shows two, the tab otherwise, and the window on its last tab.
            // Close Tab, with ⌥, closes the tab with both its panes.
            for item in context.closeItems() { menu.addItem(item) }
            menu.addItem(context.native("Close Window", #selector(NSWindow.performClose(_:)), .closeWindow))
        }

        context.addSubmenu(to: main, title: "Edit") { menu in
            // Undo and Redo are commands, not the standard actions: the window decides whether a text field or the
            // files are undone. Once the menu is synced they say what the files' would do, or plain "Undo" and "Redo"
            // while a text field or another window has the keyboard.
            menu.addItem(context.command(.undo, "Undo", fixed: .undo))
            menu.addItem(context.command(.redo, "Redo", fixed: .redo))
            menu.addItem(.separator())
            // Cut, Copy, Paste and Select All together, as in every app; Deselect All (Finder's, which shows with ⌥)
            // and Invert Selection after Select All, as items of their own.
            menu.addItem(context.command(.editCut, "Cut", fixed: .cut))
            menu.addItem(context.command(.editCopy, "Copy", fixed: .copy))
            menu.addItem(context.command(.editPaste, "Paste", fixed: .paste))
            // Finder's ⌥⌘V, where Finder shows it with ⌥: every item moves, whatever it was put on for. An item of
            // its own, as one only ⌥ shows is hard to find.
            menu.addItem(context.command(.moveItemsHere, "Move Items Here"))
            menu.addItem(context.command(.editSelectAll, "Select All", fixed: .selectAll))
            menu.addItem(context.command(.deselectAll, "Deselect All"))
            menu.addItem(context.command(.invertSelection, "Invert Selection"))
            menu.addItem(.separator())
            // What goes to and comes from the system's clipboard. After Copy and Paste, as AppKit lets an item with ⇧
            // take the press of the same key without it.
            menu.addItem(context.command(.copyPath, "Copy Path"))
            // Names what it would copy once the menu is synced: "Copy Image", "Copy Text".
            menu.addItem(context.command(.copyContents, CopyContents.commandLabel))
            // Names what it would write once the menu is synced: "Paste Image as File", "Paste Text as File".
            menu.addItem(context.command(.pasteAsFile, PasteAsFile.commandLabel))
            menu.addItem(.separator())
            // F5 and F6 by default, which the window takes: the menu shows a key only if one with ⌘ is chosen.
            menu.addItem(context.command(.copyToOtherPane, "Copy to Other Pane"))
            menu.addItem(context.command(.moveToOtherPane, "Move to Other Pane"))
            menu.addItem(.separator())
            // Gathering on the clipboard from several folders, each item to be copied or moved.
            menu.addItem(context.command(.addToCopied, "Add to Copied Items"))
            menu.addItem(context.command(.addToCut, "Add to Cut Items"))
            menu.addItem(context.command(.removeFromClipboard, "Remove from Clipboard"))
            menu.addItem(context.command(.showClipboard, "Show Clipboard"))
            menu.addItem(context.command(.clearClipboard, "Clear Clipboard"))
            menu.addItem(.separator())
            menu.addItem(context.command(.focusFileSearch, "Find Files…"))
            menu.addItem(context.command(.showLastSearchResults, "Show Last Search Results"))
            menu.addItem(context.command(.advancedSearch, "Advanced Search…"))
            menu.addItem(context.command(.clearSearchConditions, "Clear Search Conditions"))
        }

        context.addSubmenu(to: main, title: "View") { menu in
            menu.addItem(context.command(.viewAsIcons, "as Icons"))
            menu.addItem(context.command(.viewAsDetails, "as List"))
            menu.addItem(context.command(.viewAsList, "as Compact List"))
            menu.addItem(context.command(.viewAsPreviews, "as Previews"))
            // Previews at a count, from any view, each with a key of its own once one is chosen in Settings.
            let showPreviews = NSMenuItem(title: "Show Previews", action: nil, keyEquivalent: "")
            let previewsMenu = NSMenu(title: "Show Previews")
            previewsMenu.addItem(context.command(.showPreviews9, "9 at a Time"))
            previewsMenu.addItem(context.command(.showPreviews4, "4 at a Time"))
            previewsMenu.addItem(context.command(.showPreviews2, "2 at a Time"))
            previewsMenu.addItem(context.command(.showPreviews1, "1 at a Time"))
            showPreviews.submenu = previewsMenu
            menu.addItem(showPreviews)
            menu.addItem(.separator())
            // Named for the view on screen once the menu is synced: "Make Icons Bigger", "Make Columns Wider"; "Zoom In"
            // while the pane shows a file.
            menu.addItem(context.command(.increaseSize, "Make Bigger"))
            menu.addItem(context.command(.decreaseSize, "Make Smaller"))
            menu.addItem(context.command(.resetSize, "Default Size"))
            menu.addItem(context.command(.zoomToFit, "Zoom to Fit"))
            menu.addItem(.separator())
            // Above Sort By, as in Finder's View Options: None, the fields in the columns' order, Folder for search
            // results, then the groups' direction.
            let groupBy = NSMenuItem(title: "Group By", action: nil, keyEquivalent: "")
            let groupMenu = NSMenu(title: "Group By")
            groupMenu.addItem(context.command(.groupByNone, "None"))
            groupMenu.addItem(.separator())
            for field in GroupByPreference.menuOrder {
                groupMenu.addItem(context.command(field.command, field.title))
            }
            groupMenu.addItem(context.command(.groupByFolder, "Folder"))
            groupMenu.addItem(.separator())
            groupMenu.addItem(context.command(.reverseGroupOrder, "Reverse Group Order"))
            groupBy.submenu = groupMenu
            menu.addItem(groupBy)
            let sortBy = NSMenuItem(title: "Sort By", action: nil, keyEquivalent: "")
            let sortMenu = NSMenu(title: "Sort By")
            // The columns' order, as every list of them has it.
            sortMenu.addItem(context.command(.sortByName, "Name"))
            // Search results only: dimmed while a folder shows, as Group By ▸ Folder is.
            sortMenu.addItem(context.command(.sortByFolder, "Folder"))
            sortMenu.addItem(context.command(.sortByModified, "Date Modified"))
            sortMenu.addItem(context.command(.sortByCreated, "Date Created"))
            sortMenu.addItem(context.command(.sortByLastOpened, "Date Last Opened"))
            sortMenu.addItem(context.command(.sortByAdded, "Date Added"))
            sortMenu.addItem(context.command(.sortBySize, "Size"))
            sortMenu.addItem(context.command(.sortByKind, "Kind"))
            sortMenu.addItem(context.command(.sortByTags, "Tags"))
            sortBy.submenu = sortMenu
            menu.addItem(sortBy)
            menu.addItem(context.command(.toggleFoldersFirst, "Folders First"))
            menu.addItem(context.command(.toggleHiddenFiles, "Hidden Files"))
            // The List's columns, as the header's right-click menu lists them; Name is always there.
            let columns = NSMenuItem(title: "Columns", action: nil, keyEquivalent: "")
            let columnsMenu = NSMenu(title: "Columns")
            // Search results' own: dimmed while a folder shows, as Sort By ▸ Folder is.
            columnsMenu.addItem(context.command(.showFolderColumn, "Folder"))
            for key in OptionalDetailColumnKey.menuOrder {
                columnsMenu.addItem(
                    context.command(key.columnCommand, DetailColumnKey(rawValue: key.rawValue)?.label ?? ""))
            }
            columns.submenu = columnsMenu
            menu.addItem(columns)
            menu.addItem(.separator())
            menu.addItem(context.command(.togglePinFilter, "Pin Filter"))
            menu.addItem(context.command(.refreshOrApplySearchSort, "Refresh"))
            menu.addItem(.separator())
            // "Show Folder Tree" while the tree is hidden.
            menu.addItem(context.command(.toggleFolderTree, "Hide Folder Tree"))
            menu.addItem(context.command(.toggleInfoPanel, "Info Panel"))
            menu.addItem(context.command(.toggleInfoRow, "Info Row"))
            menu.addItem(.separator())
            menu.addItem(context.command(.toggleTwoPanes, "Two Panes"))
            menu.addItem(context.command(.duplicatePane, "Duplicate Pane"))
            menu.addItem(context.command(.swapPanes, "Swap Panes"))
            menu.addItem(context.command(.equalizePanes, "Make Panes Equal Width"))
            menu.addItem(.separator())
            menu.addItem(context.command(.customizeToolbar, "Customize Toolbar…"))
            menu.addItem(context.plain("Command Palette…", id: commandPaletteItemID, chosen: .showCommandPalette))
            // No Zoom In, Zoom Out or Actual Size of the whole window, and no hidden full screen item: AppKit adds its
            // own Enter Full Screen to this menu, with ⌃⌘F.
        }

        // A folder's own view, a tab's and a window's, each saved by name; the list's right-click menu has the folder's.
        context.addSubmenu(to: main, title: "Layout") { menu in
            menu.addItem(.sectionHeader(title: "Folder View"))
            menu.addItem(context.command(.rememberFolderView, "Remember View for This Folder"))
            menu.addItem(context.command(.updateFolderView, "Update Folder View"))
            menu.addItem(context.command(.revertFolderView, "Revert to Saved View"))
            menu.addItem(context.command(.folderViewOptions, "Folder View Options…"))
            menu.addItem(context.command(.resetFolderView, "Reset Folder View"))
            menu.addItem(context.command(.manageFolderViews, "Manage Folder Views…"))
            menu.addItem(.separator())
            context.addTabViews(to: menu)
            menu.addItem(.separator())
            context.addWindowViews(to: menu)
        }

        context.addSubmenu(to: main, title: "Go") { menu in
            menu.addItem(context.command(.goBack, "Back"))
            menu.addItem(context.command(.goForward, "Forward"))
            menu.addItem(context.command(.goEnclosingFolder, "Enclosing Folder"))
            menu.addItem(.separator())
            // Finder's places, in Finder's order, and the Trash of the sidebar's Locations.
            menu.addItem(context.command(.goDocuments, "Documents"))
            menu.addItem(context.command(.goDesktop, "Desktop"))
            menu.addItem(context.command(.goDownloads, "Downloads"))
            menu.addItem(context.command(.goHomeRootTree, "Home"))
            menu.addItem(context.command(.goLibrary, "Library"))
            menu.addItem(context.command(.goMacintoshHD, MenuName.shortened(options.startupDiskName)))
            menu.addItem(context.command(.goApplications, "Applications"))
            menu.addItem(context.command(.goTrash, "Trash"))
            menu.addItem(.separator())
            menu.addItem(context.command(.openLocationSheet, "Go to Folder…"))
            menu.addItem(context.command(.goToPage, "Go to Page…"))
            menu.addItem(.separator())
            menu.addItem(context.command(.showFolderInOtherPane, "Show This Folder in Other Pane"))
            menu.addItem(context.command(.goToOtherPaneFolder, "Go to Other Pane’s Folder"))
            menu.addItem(.separator())
            menu.addItem(context.command(.rootTreeAtSelection, "Use as Tree Root"))
        }

        let windowsMenu = context.addSubmenu(to: main, title: "Window") { menu in
            menu.addItem(context.native("Minimize", #selector(NSWindow.performMiniaturize(_:)), .minimize))
            menu.addItem(context.native("Zoom", #selector(NSWindow.performZoom(_:)), nil))
            menu.addItem(.separator())
            menu.addItem(context.command(.selectPreviousTab, "Show Previous Tab"))
            menu.addItem(context.command(.selectNextTab, "Show Next Tab"))
            menu.addItem(context.command(.moveTabToNewWindow, "Move Tab to New Window"))
            menu.addItem(context.command(.mergeAllWindows, "Merge All Windows"))
            menu.addItem(.separator())
            // Tab does it too, from a pane's list; the menu can't show Tab.
            menu.addItem(context.command(.switchToOtherPane, "Switch to Other Pane"))
            menu.addItem(.separator())
            menu.addItem(context.native("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)), nil))
        }

        let helpMenu = context.addSubmenu(to: main, title: "Help") { menu in
            menu.addItem(context.command(.openHelp, "\(applicationMenuName) Help"))
            menu.addItem(context.command(.openKeyboardShortcuts, "Keyboard Shortcuts"))
        }

        return BuiltApplicationMenu(
            menu: main, servicesMenu: servicesMenu, windowsMenu: windowsMenu, helpMenu: helpMenu,
            itemsByID: context.itemsByID)
    }

    /// Whether a window view's item for this window can be the one ⌥ shows in place of its item: macOS swaps two items
    /// only when their keys differ by ⌥ alone, or neither has one. Otherwise both show, each with its own key.
    nonisolated static func pairs(_ key: MenuKeyEquivalent?, _ inThisWindow: MenuKeyEquivalent?) -> Bool {
        switch (key, inThisWindow) {
        case (nil, nil): true
        case (let key?, let other?):
            !key.modifiers.contains(.option) && other.key == key.key && other.modifiers == key.modifiers.union(.option)
        default: false
        }
    }

    // MARK: Items

    private final class Context {
        let target: MenuCommandRouter
        let options: ApplicationMenuOptions
        var itemsByID: [String: NSMenuItem] = [:]

        init(target: MenuCommandRouter, options: ApplicationMenuOptions) {
            self.target = target
            self.options = options
        }

        @discardableResult
        func addSubmenu(to main: NSMenu, title: String, _ fill: (NSMenu) -> Void) -> NSMenu {
            let submenu = NSMenu(title: title)
            fill(submenu)
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = submenu
            main.addItem(item)
            return submenu
        }

        /// The key a command never gives up: shared with text fields, or macOS's own.
        private func fixedKey(_ id: ShortcutCommandID) -> MenuKeyEquivalent? {
            ShortcutCommands.defaultBindings[id]?.first.flatMap(MenuKeyEquivalent.parse)
        }

        /// The menu shows and listens for a command's first key that has ⌘ or ⌃. A key without either (Space for
        /// Quick Look, F2 for Rename) is handled by the window: as a menu key it would be taken from text fields and
        /// dialogs.
        private func chosenKey(_ id: ShortcutCommandID) -> MenuKeyEquivalent? {
            Shortcuts.menuShortcut(options.shortcuts[id] ?? []).flatMap(MenuKeyEquivalent.parse)
        }

        /// A command's key without ⌘ or ⌃ (F2 for Rename, F5 and F6 for the other pane), which the window handles:
        /// the item shows it, and the menu bar never takes it (`ApplicationMainMenu`), so a text field keeps it.
        private func windowKey(_ id: ShortcutCommandID) -> MenuKeyEquivalent? {
            // Return before Rename's own keys while it renames, as Help, Settings and the right-click menu show it.
            if id == .renameSelection, options.returnKeyAction == .rename {
                return MenuKeyEquivalent(key: "\r", modifiers: [])
            }
            guard let first = options.shortcuts[id]?.first, !first.contains("Cmd"), !first.contains("Ctrl") else {
                return nil
            }
            return MenuKeyEquivalent.parse(first)
        }

        private func apply(_ key: MenuKeyEquivalent?, to item: NSMenuItem) {
            guard let key else { return }
            item.keyEquivalent = key.key
            item.keyEquivalentModifierMask = key.modifiers
        }

        /// A command item. Its id is the command, which is how the states find it.
        func command(
            _ type: AppCommand, _ title: String, fixed: ShortcutCommandID? = nil
        ) -> NSMenuItem {
            let item = NSMenuItem(
                title: title, action: #selector(MenuCommandRouter.chooseMenuItem(_:)), keyEquivalent: "")
            item.target = target
            item.identifier = NSUserInterfaceItemIdentifier(type.rawValue)
            // A command the app never rebinds has its default key; the others have the one chosen in Settings.
            if let fixed {
                apply(fixedKey(fixed), to: item)
            } else if let shortcutID = ShortcutCommandID(rawValue: type.rawValue) {
                apply(chosenKey(shortcutID) ?? windowKey(shortcutID), to: item)
            }
            register(item, id: type.rawValue)
            return item
        }

        /// An item that is a view of its own (the File menu's tag colors), kept by its id.
        func view(_ item: NSMenuItem) -> NSMenuItem {
            if let id = item.identifier?.rawValue { register(item, id: id) }
            return item
        }

        /// File ▸ Close Pane, and Close Tab in its place while ⌥ is held, when their keys differ by ⌥ alone.
        func closeItems() -> [NSMenuItem] {
            alternatePair(.closePane, "Close Tab", .closeTab, "Close Tab")
        }

        /// An item and the one ⌥ shows in its place, while their keys differ by ⌥ alone; both show otherwise.
        func alternatePair(
            _ first: AppCommand, _ firstTitle: String, _ second: AppCommand, _ secondTitle: String
        ) -> [NSMenuItem] {
            let shown = command(first, firstTitle)
            let alternate = command(second, secondTitle)
            let firstKey = ShortcutCommandID(rawValue: first.rawValue).flatMap(chosenKey)
            let secondKey = ShortcutCommandID(rawValue: second.rawValue).flatMap(chosenKey)
            if ApplicationMenuBuilder.pairs(firstKey, secondKey) {
                if firstKey == nil {
                    shown.keyEquivalentModifierMask = []
                    alternate.keyEquivalentModifierMask = .option
                }
                alternate.isAlternate = true
            }
            return [shown, alternate]
        }

        /// Layout's Tab Views: Save, the first five tab views with their keys, the rest in More Tab Views, and Manage.
        func addTabViews(to menu: NSMenu) {
            menu.addItem(.sectionHeader(title: "Tab Views"))
            menu.addItem(command(.saveTabView, "Save Tab View\u{2026}"))
            addSavedViews(options.tabViews, more: "More Tab Views", to: menu) { entry, index, menu in
                let item = savedViewItem(ApplicationMenu.tabViewItemID(entry.id), MenuName.shortened(entry.name))
                if TabViews.slotCommands.indices.contains(index) {
                    apply(chosenKey(TabViews.slotCommands[index]), to: item)
                }
                menu.addItem(item)
            }
            menu.addItem(plain("Manage Tab Views\u{2026}", id: ApplicationMenu.manageTabViewsItemID))
        }

        /// Layout's Window Views: Save, the first five window views with their keys, the rest in More Window Views,
        /// and Manage. Each window view has an item for opening it in place of this window, which ⌥ shows in its
        /// place while their keys differ by ⌥ alone.
        func addWindowViews(to menu: NSMenu) {
            menu.addItem(.sectionHeader(title: "Window Views"))
            menu.addItem(command(.saveWindowView, "Save Window View\u{2026}"))
            addSavedViews(options.windowViews, more: "More Window Views", to: menu) { entry, index, menu in
                let keyed = WindowViews.slotCommands.indices.contains(index)
                let key = keyed ? chosenKey(WindowViews.slotCommands[index]) : nil
                let hereKey = keyed ? chosenKey(WindowViews.inThisWindowSlotCommands[index]) : nil
                let name = MenuName.shortened(entry.name)
                let open = savedViewItem(ApplicationMenu.windowViewItemID(entry.id), name)
                let here = savedViewItem(
                    ApplicationMenu.windowViewItemID(entry.id, inThisWindow: true), "\(name) in This Window")
                apply(key, to: open)
                apply(hereKey, to: here)
                if ApplicationMenuBuilder.pairs(key, hereKey) {
                    if key == nil {
                        open.keyEquivalentModifierMask = []
                        here.keyEquivalentModifierMask = .option
                    }
                    here.isAlternate = true
                }
                menu.addItem(open)
                menu.addItem(here)
            }
            menu.addItem(plain("Manage Window Views\u{2026}", id: ApplicationMenu.manageWindowViewsItemID))
        }

        /// The saved views in the list's order: the first `ApplicationMenu.savedViewsShown`, the ones that can have
        /// keys, in `menu`; the rest in a submenu titled `more`, so the menu keeps its length however many are kept.
        private func addSavedViews(
            _ entries: [SavedViewMenuEntry], more: String, to menu: NSMenu,
            _ add: (SavedViewMenuEntry, Int, NSMenu) -> Void
        ) {
            let shown = ApplicationMenu.savedViewsShown
            for (index, entry) in entries.prefix(shown).enumerated() { add(entry, index, menu) }
            guard entries.count > shown else { return }
            _ = addSubmenu(to: menu, title: more) { submenu in
                for (index, entry) in entries.enumerated().dropFirst(shown) { add(entry, index, submenu) }
            }
        }

        /// File ▸ New File: an empty text file, a copy of each file of the Templates folder, and the folder itself.
        func newFileMenu() -> NSMenu {
            let menu = NSMenu(title: "New File")
            menu.addItem(command(.newTextFile, "Text File"))
            if !options.templates.isEmpty { menu.addItem(.separator()) }
            for name in options.templates {
                let id = ApplicationMenu.templateItemID(name)
                let item = NSMenuItem(
                    title: MenuName.shortened(name), action: #selector(MenuCommandRouter.chooseMenuItem(_:)),
                    keyEquivalent: "")
                item.target = target
                item.identifier = NSUserInterfaceItemIdentifier(id)
                register(item, id: id)
                menu.addItem(item)
            }
            menu.addItem(.separator())
            menu.addItem(command(.openTemplatesFolder, "Open Templates Folder"))
            return menu
        }

        private func savedViewItem(_ id: String, _ title: String) -> NSMenuItem {
            let item = NSMenuItem(
                title: title, action: #selector(MenuCommandRouter.chooseMenuItem(_:)), keyEquivalent: "")
            item.target = target
            item.identifier = NSUserInterfaceItemIdentifier(id)
            register(item, id: id)
            return item
        }

        /// An item that is not a window's command and has its own handler (About, Settings, the command palette), with
        /// its fixed key or the one chosen in Settings.
        func plain(
            _ title: String, id: String, fixed: ShortcutCommandID? = nil, chosen: ShortcutCommandID? = nil
        ) -> NSMenuItem {
            let item = NSMenuItem(
                title: title, action: #selector(MenuCommandRouter.chooseMenuItem(_:)), keyEquivalent: "")
            item.target = target
            item.identifier = NSUserInterfaceItemIdentifier(id)
            if let fixed { apply(fixedKey(fixed), to: item) }
            if let chosen { apply(chosenKey(chosen), to: item) }
            register(item, id: id)
            return item
        }

        /// A standard item: AppKit finds its target in the responder chain and validates it.
        func native(_ title: String, _ action: Selector, _ fixed: ShortcutCommandID?) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            if let fixed { apply(fixedKey(fixed), to: item) }
            return item
        }

        private func register(_ item: NSMenuItem, id: String) {
            precondition(itemsByID[id] == nil, "duplicate menu item id \(id)")
            itemsByID[id] = item
        }
    }
}

/// The menu bar. It takes only keys with ⌘ or ⌃: an item may show a key without them (F2, F5) that the window handles,
/// as the menu would take it from a text field or a dialog before they see it.
final class ApplicationMainMenu: NSMenu {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard !event.modifierFlags.intersection([.command, .control]).isEmpty else { return false }
        return super.performKeyEquivalent(with: event)
    }
}
