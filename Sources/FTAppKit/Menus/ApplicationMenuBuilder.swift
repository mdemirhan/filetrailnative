import AppKit
import FTFoundation

/// What the menu is built with; it is built again when any of it changes.
struct ApplicationMenuOptions {
    /// The keys of every command, as chosen in Settings → Shortcuts.
    var shortcuts: ShortcutBindings = ShortcutCommands.defaultBindings
    /// The text editor chosen in Settings → Files, which File names.
    var textEditorName: String?
    /// What the startup disk is called, which Go names.
    var startupDiskName = VolumePaths.defaultStartupDiskName
    /// The workspaces Window ▸ Workspaces lists, in order.
    var workspaces: [WorkspaceMenuEntry] = []
}

/// A workspace as Window ▸ Workspaces lists it.
struct WorkspaceMenuEntry: Equatable {
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
            // The system tab bar has no menu of the app's, so the File menu has it.
            menu.addItem(context.command(.duplicateTab, "Duplicate Tab"))
            menu.addItem(context.command(.newFolder, "New Folder"))
            menu.addItem(.separator())
            menu.addItem(context.command(.openSelection, "Open"))
            menu.addItem(context.command(.openSelectionInNewTab, "Open in New Tab"))
            menu.addItem(context.command(.openSelectionInNewWindow, "Open in New Window"))
            menu.addItem(context.command(.openSelectionInOtherPane, "Open in Other Pane"))
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
            // "Remove from Favorites" while the folder is one.
            menu.addItem(context.command(.toggleFavorite, "Add to Favorites"))
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
            // Undo and Redo are commands, not the standard actions: the window decides whether a text field or the
            // files are undone. Once the menu is synced they say what the files' would do, or plain "Undo" and "Redo"
            // while a text field or another window has the keyboard.
            menu.addItem(context.command(.undo, "Undo", fixed: .undo))
            menu.addItem(context.command(.redo, "Redo", fixed: .redo))
            menu.addItem(.separator())
            menu.addItem(context.command(.editCut, "Cut", fixed: .cut))
            menu.addItem(context.command(.editCopy, "Copy", fixed: .copy))
            menu.addItem(context.command(.editPaste, "Paste", fixed: .paste))
            // F5 and F6 by default, which the window takes: the menu shows a key only if one with ⌘ is chosen. After Cut
            // and Copy all the same, as AppKit lets an item with ⇧ take the press of the same key without it.
            menu.addItem(context.command(.copyToOtherPane, "Copy to Other Pane"))
            menu.addItem(context.command(.moveToOtherPane, "Move to Other Pane"))
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
            menu.addItem(context.command(.viewAsIcons, "as Icons"))
            menu.addItem(context.command(.viewAsDetails, "as List"))
            menu.addItem(context.command(.viewAsList, "as Compact List"))
            menu.addItem(context.command(.viewAsPreviews, "as Previews"))
            menu.addItem(.separator())
            // Named for the view on screen once the menu is synced: "Make Icons Bigger", "Make Columns Wider".
            menu.addItem(context.command(.increaseSize, "Make Bigger"))
            menu.addItem(context.command(.decreaseSize, "Make Smaller"))
            menu.addItem(context.command(.resetSize, "Default Size"))
            menu.addItem(.separator())
            let sortBy = NSMenuItem(title: "Sort By", action: nil, keyEquivalent: "")
            let sortMenu = NSMenu(title: "Sort By")
            sortMenu.addItem(context.command(.sortByName, "Name"))
            sortMenu.addItem(context.command(.sortByKind, "Kind"))
            sortMenu.addItem(context.command(.sortByModified, "Date Modified"))
            sortMenu.addItem(context.command(.sortBySize, "Size"))
            sortBy.submenu = sortMenu
            menu.addItem(sortBy)
            menu.addItem(context.command(.toggleFoldersFirst, "Folders First"))
            menu.addItem(context.command(.toggleHiddenFiles, "Hidden Files"))
            menu.addItem(context.command(.togglePinFilter, "Pin Filter"))
            menu.addItem(context.command(.refreshOrApplySearchSort, "Refresh"))
            menu.addItem(.separator())
            // "Show Folder Tree" while the tree is hidden.
            menu.addItem(context.command(.toggleFolderTree, "Hide Folder Tree"))
            menu.addItem(context.command(.toggleInfoPanel, "Info Panel"))
            menu.addItem(context.command(.toggleInfoRow, "Info Row"))
            menu.addItem(.separator())
            menu.addItem(context.command(.toggleTwoPanes, "Two Panes"))
            menu.addItem(context.command(.swapPanes, "Swap Panes"))
            menu.addItem(context.command(.equalizePanes, "Make Panes Equal Width"))
            menu.addItem(.separator())
            menu.addItem(context.command(.customizeToolbar, "Customize Toolbar…"))
            // No Zoom In, Zoom Out or Actual Size of the whole window, and no hidden full screen item: AppKit adds its
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
            menu.addItem(context.command(.goMacintoshHD, options.startupDiskName))
            menu.addItem(context.command(.goApplications, "Applications"))
            menu.addItem(context.command(.goTrash, "Trash"))
            menu.addItem(.separator())
            menu.addItem(context.command(.openLocationSheet, "Go to Folder…"))
            menu.addItem(context.command(.showFolderInOtherPane, "Show This Folder in Other Pane"))
            menu.addItem(context.command(.goToOtherPaneFolder, "Go to Other Pane's Folder"))
            menu.addItem(.separator())
            menu.addItem(context.command(.rootTreeAtSelection, "Use as Tree Root"))
        }

        let windowsMenu = context.addSubmenu(to: main, title: "Window") { menu in
            menu.addItem(context.native("Minimize", #selector(NSWindow.performMiniaturize(_:)), .minimize))
            menu.addItem(context.native("Zoom", #selector(NSWindow.performZoom(_:)), nil))
            menu.addItem(.separator())
            menu.addItem(context.command(.selectPreviousTab, "Show Previous Tab"))
            menu.addItem(context.command(.selectNextTab, "Show Next Tab"))
            // Tab does it too, from a pane's list; the menu can't show Tab.
            menu.addItem(context.command(.switchToOtherPane, "Switch to Other Pane"))
            menu.addItem(context.command(.moveTabToNewWindow, "Move Tab to New Window"))
            menu.addItem(context.command(.mergeAllWindows, "Merge All Windows"))
            menu.addItem(.separator())
            let workspaces = NSMenuItem(title: "Workspaces", action: nil, keyEquivalent: "")
            workspaces.submenu = context.workspacesMenu()
            menu.addItem(workspaces)
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

    /// Whether a workspace's item for this window can be the one ⌥ shows in place of its item: macOS swaps two items
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
                apply(chosenKey(shortcutID), to: item)
            }
            register(item, id: type.rawValue)
            return item
        }

        /// Window ▸ Workspaces: saving and updating, the workspaces, the first five with their keys, and Manage. Each
        /// workspace has an item ⌥ shows in its place, which opens it in this window, with ⌥ added to its key.
        func workspacesMenu() -> NSMenu {
            let menu = NSMenu(title: "Workspaces")
            menu.addItem(command(.saveWorkspace, "Save Window as Workspace…"))
            menu.addItem(command(.updateWorkspace, "Update Workspace"))
            if !options.workspaces.isEmpty { menu.addItem(.separator()) }
            for (index, entry) in options.workspaces.enumerated() {
                let keyed = Workspaces.slotCommands.indices.contains(index)
                let key = keyed ? chosenKey(Workspaces.slotCommands[index]) : nil
                let hereKey = keyed ? chosenKey(Workspaces.inThisWindowSlotCommands[index]) : nil
                let open = workspaceItem(entry, inThisWindow: false)
                let here = workspaceItem(entry, inThisWindow: true)
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
            menu.addItem(.separator())
            menu.addItem(plain("Manage Workspaces…", id: ApplicationMenu.manageWorkspacesItemID))
            return menu
        }

        private func workspaceItem(_ entry: WorkspaceMenuEntry, inThisWindow: Bool) -> NSMenuItem {
            let id = ApplicationMenu.workspaceItemID(entry.id, inThisWindow: inThisWindow)
            let item = NSMenuItem(
                title: inThisWindow ? "\(entry.name) in This Window" : entry.name,
                action: #selector(MenuCommandRouter.chooseMenuItem(_:)), keyEquivalent: "")
            item.target = target
            item.identifier = NSUserInterfaceItemIdentifier(id)
            register(item, id: id)
            return item
        }

        /// An item that is not a window's command and has its own handler (About, Settings).
        func plain(_ title: String, id: String, fixed: ShortcutCommandID? = nil) -> NSMenuItem {
            let item = NSMenuItem(
                title: title, action: #selector(MenuCommandRouter.chooseMenuItem(_:)), keyEquivalent: "")
            item.target = target
            item.identifier = NSUserInterfaceItemIdentifier(id)
            if let fixed { apply(fixedKey(fixed), to: item) }
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
