// Port of createApplicationMenuTemplate (apps/desktop/src/main/appMenu.ts), the layout and keys; View > Zoom is dropped (DEVIATIONS D-005)
import AppKit
import FTFoundation

/// What the menu is built with; it is built again when any of it changes.
struct ApplicationMenuOptions {
    /// The keys of every command, as chosen in Settings → Shortcuts.
    var shortcuts: ShortcutBindings = ShortcutCommands.defaultBindings
    /// The text editor chosen in Settings → Files, which File names.
    var textEditorName: String?
    /// What Undo and Redo say ("Undo Move of “a.txt”").
    var undoLabels: (undo: String, redo: String)?
}

/// The menu bar and where its parts are.
struct BuiltApplicationMenu {
    let menu: NSMenu
    let servicesMenu: NSMenu
    let windowsMenu: NSMenu
    let helpMenu: NSMenu
    /// Every item that has an id, which is how the states find them.
    let itemsByID: [String: NSMenuItem]
    /// The ids of the radio items; AppKit has no groups, so a group is the radio items of one menu.
    let radioItemIDs: Set<String>
}

/// The name the menus use for the app: the bundle's is not it while the app runs unbundled.
let applicationMenuName = "File Trail"

@MainActor
enum ApplicationMenuBuilder {
    /// Ids of the items that are not a renderer command.
    static let aboutItemID = "about"
    static let settingsItemID = "settings"

    static func build(target: MenuCommandRouter, options: ApplicationMenuOptions = .init()) -> BuiltApplicationMenu {
        let context = Context(target: target, options: options)
        let main = NSMenu(title: "")
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
            menu.addItem(context.command(.newFolder, "New Folder"))
            menu.addItem(.separator())
            menu.addItem(context.command(.openSelection, "Open"))
            menu.addItem(context.command(.openSelectionInNewTab, "Open in New Tab"))
            menu.addItem(context.command(.openSelectionInNewWindow, "Open in New Window"))
            menu.addItem(context.command(.editSelection, "Edit in \(options.textEditorName ?? "Text Editor")"))
            menu.addItem(context.command(.quickLookSelection, "Quick Look"))
            // Search results only, as Finder's Show in Enclosing Folder.
            menu.addItem(context.command(.revealInFolder, "Reveal in Folder"))
            menu.addItem(.separator())
            menu.addItem(context.command(.calculateSize, "Calculate Size"))
            menu.addItem(.separator())
            menu.addItem(context.command(.renameSelection, "Rename"))
            menu.addItem(context.command(.duplicateSelection, "Duplicate"))
            menu.addItem(context.command(.moveSelection, "Move to…"))
            menu.addItem(
                context.command(.toggleFavorite, "Add to Favorites", id: ApplicationMenu.favoriteAddItemID))
            menu.addItem(
                context.command(
                    .toggleFavorite, "Remove from Favorites", id: ApplicationMenu.favoriteRemoveItemID, hidden: true))
            menu.addItem(.separator())
            menu.addItem(context.command(.openInTerminal, "Open in Terminal"))
            menu.addItem(context.command(.showInFinder, "Show in Finder"))
            menu.addItem(.separator())
            menu.addItem(context.command(.trashSelection, "Move to Trash"))
            // The disk selected in the sidebar, as Finder's File ▸ Eject.
            menu.addItem(context.command(.ejectVolume, "Eject"))
            menu.addItem(.separator())
            menu.addItem(context.command(.reopenClosedTab, "Reopen Closed Tab"))
            // Closes the window when it has a single view.
            menu.addItem(context.command(.closeTab, "Close Tab"))
            menu.addItem(context.native("Close Window", #selector(NSWindow.performClose(_:)), .closeWindow))
        }

        context.addSubmenu(to: main, title: "Edit") { menu in
            // The files' Undo and Redo are commands, not the standard actions: the window decides whether a text
            // field or the files are undone. Each has a text field's own beside it, and one of the two shows at a
            // time; the hidden one's key does nothing.
            let undoLabel = options.undoLabels?.undo ?? "Undo"
            let redoLabel = options.undoLabels?.redo ?? "Redo"
            menu.addItem(context.command(.undo, undoLabel, fixed: .undo))
            menu.addItem(context.command(.undo, "Undo", id: ApplicationMenu.textUndoItemID, fixed: .undo, hidden: true))
            menu.addItem(context.command(.redo, redoLabel, fixed: .redo))
            menu.addItem(context.command(.redo, "Redo", id: ApplicationMenu.textRedoItemID, fixed: .redo, hidden: true))
            menu.addItem(.separator())
            menu.addItem(context.command(.editCut, "Cut", fixed: .cut))
            menu.addItem(context.command(.editCopy, "Copy", fixed: .copy))
            menu.addItem(context.command(.editPaste, "Paste", fixed: .paste))
            menu.addItem(context.command(.copyPath, "Copy Path"))
            menu.addItem(context.command(.editSelectAll, "Select All", fixed: .selectAll))
            menu.addItem(.separator())
            menu.addItem(context.command(.showClipboard, "Show Clipboard"))
            menu.addItem(context.command(.clearClipboard, "Clear Clipboard"))
            menu.addItem(.separator())
            menu.addItem(context.command(.focusFileSearch, "Find Files…"))
            menu.addItem(context.command(.showLastSearchResults, "Show Last Search Results"))
        }

        context.addSubmenu(to: main, title: "View") { menu in
            menu.addItem(context.command(.viewAsIcons, "as Icons", kind: .radio))
            menu.addItem(context.command(.viewAsDetails, "as List", kind: .radio))
            menu.addItem(context.command(.viewAsList, "as Compact List", kind: .radio))
            menu.addItem(.separator())
            let sortBy = NSMenuItem(title: "Sort By", action: nil, keyEquivalent: "")
            let sortMenu = NSMenu(title: "Sort By")
            sortMenu.addItem(context.command(.sortByName, "Name", kind: .radio))
            sortMenu.addItem(context.command(.sortByKind, "Kind", kind: .radio))
            sortMenu.addItem(context.command(.sortByModified, "Date Modified", kind: .radio))
            sortMenu.addItem(context.command(.sortBySize, "Size", kind: .radio))
            sortBy.submenu = sortMenu
            menu.addItem(sortBy)
            menu.addItem(context.command(.toggleFoldersFirst, "Folders First", kind: .checkbox))
            menu.addItem(context.command(.toggleHiddenFiles, "Hidden Files", kind: .checkbox))
            menu.addItem(context.command(.refreshOrApplySearchSort, "Refresh"))
            menu.addItem(.separator())
            menu.addItem(
                context.command(.toggleFolderTree, "Hide Folder Tree", id: ApplicationMenu.folderTreeHideItemID))
            menu.addItem(
                context.command(
                    .toggleFolderTree, "Show Folder Tree", id: ApplicationMenu.folderTreeShowItemID, hidden: true))
            menu.addItem(context.command(.toggleInfoPanel, "Info Panel", kind: .checkbox))
            menu.addItem(context.command(.toggleInfoRow, "Info Row", kind: .checkbox))
            menu.addItem(.separator())
            menu.addItem(context.command(.customizeToolbar, "Customize Toolbar…"))
            // No Zoom In, Zoom Out or Actual Size (DEVIATIONS D-005), and no hidden full screen item: AppKit adds its
            // own Enter Full Screen to this menu, with ⌃⌘F.
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
            menu.addItem(context.command(.goMacintoshHD, "Macintosh HD"))
            menu.addItem(context.command(.goApplications, "Applications"))
            menu.addItem(context.command(.goTrash, "Trash"))
            menu.addItem(.separator())
            menu.addItem(context.command(.openLocationSheet, "Go to Folder…"))
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
            menu.addItem(context.native("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)), nil))
        }

        let helpMenu = context.addSubmenu(to: main, title: "Help") { menu in
            menu.addItem(context.command(.openHelp, "\(applicationMenuName) Help"))
            menu.addItem(context.command(.openKeyboardShortcuts, "Keyboard Shortcuts"))
        }

        return BuiltApplicationMenu(
            menu: main, servicesMenu: servicesMenu, windowsMenu: windowsMenu, helpMenu: helpMenu,
            itemsByID: context.itemsByID, radioItemIDs: context.radioItemIDs)
    }

    // MARK: Items

    private final class Context {
        let target: MenuCommandRouter
        let options: ApplicationMenuOptions
        var itemsByID: [String: NSMenuItem] = [:]
        var radioItemIDs: Set<String> = []

        init(target: MenuCommandRouter, options: ApplicationMenuOptions) {
            self.target = target
            self.options = options
        }

        enum Kind { case normal, radio, checkbox }

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

        private func apply(_ key: MenuKeyEquivalent?, to item: NSMenuItem) {
            guard let key else { return }
            item.keyEquivalent = key.key
            item.keyEquivalentModifierMask = key.modifiers
        }

        /// A command item. Its id is the command, which is how the states find it.
        func command(
            _ type: RendererCommand, _ title: String, id: String? = nil, kind: Kind = .normal,
            fixed: ShortcutCommandID? = nil, hidden: Bool = false
        ) -> NSMenuItem {
            let item = NSMenuItem(
                title: title, action: #selector(MenuCommandRouter.chooseMenuItem(_:)), keyEquivalent: "")
            item.target = target
            let itemID = id ?? type.rawValue
            item.identifier = NSUserInterfaceItemIdentifier(itemID)
            // A command the app never rebinds has its default key; the others have the one chosen in Settings.
            if let fixed {
                apply(fixedKey(fixed), to: item)
            } else if let shortcutID = ShortcutCommandID(rawValue: type.rawValue) {
                apply(chosenKey(shortcutID), to: item)
            }
            item.isHidden = hidden
            register(item, id: itemID, kind: kind)
            return item
        }

        /// An item that is not a renderer command and has its own handler (About, Settings).
        func plain(_ title: String, id: String, fixed: ShortcutCommandID? = nil) -> NSMenuItem {
            let item = NSMenuItem(
                title: title, action: #selector(MenuCommandRouter.chooseMenuItem(_:)), keyEquivalent: "")
            item.target = target
            item.identifier = NSUserInterfaceItemIdentifier(id)
            if let fixed { apply(fixedKey(fixed), to: item) }
            register(item, id: id, kind: .normal)
            return item
        }

        /// A standard item: AppKit finds its target in the responder chain and validates it.
        func native(_ title: String, _ action: Selector, _ fixed: ShortcutCommandID?) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            if let fixed { apply(fixedKey(fixed), to: item) }
            return item
        }

        private func register(_ item: NSMenuItem, id: String, kind: Kind) {
            precondition(itemsByID[id] == nil, "duplicate menu item id \(id)")
            itemsByID[id] = item
            if kind == .radio { radioItemIDs.insert(id) }
        }
    }
}
