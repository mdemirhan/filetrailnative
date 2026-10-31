// Generated once from apps/desktop/src/shared/toolbarItems.ts in the Electron app; now edited by hand.

/// The icon a toolbar item draws (`ToolbarIconName`).
public enum ToolbarIconName: String, CaseIterable, Sendable, Hashable {
    case back
    case forward
    case up
    case location
    case hidden
    case hiddenShown
    case refresh
    case icons
    case list
    case details
    case drawer
    case sidebar
    case edit
    case chevron
    case open
    case theme
    case close
    case sortAsc
    case sortDesc
    case help
    case settings
    case search
    case trash
    case infoRow
    case foldersFirst
    case copy
    case cut
    case paste
    case clear
    case stop
    case move
    case duplicate
    case newFolder
    case terminal
    case copyPath
    case rename
    case separatorVertical
    case more
    case overflow
    case sort
    case title
    case newTab
    case quickLook
    case showInFinder
    case revealInFolder
    case calculateSize
}

public enum ToolbarItemKind: String, Sendable, Hashable {
    case button, toggle, menu, composite, separator
}

/// The items of the toolbar over the file list; the raw value is what is saved in the toolbar's order.
public enum ToolbarItemID: String, Codable, CaseIterable, Sendable, Hashable {
    case back
    case forward
    case up
    case refresh
    case topSeparator
    case view
    case sort
    case title
    case clipboard
    case viewOptions
    case search
    case goToFolder
    case foldersFirst
    case hidden
    case folderTree
    case infoPanel
    case infoRow
    case newTab
    case openSelection
    case quickLook
    case editSelection
    case moveSelection
    case renameSelection
    case duplicateSelection
    case newFolder
    case trashSelection
    case copySelection
    case cutSelection
    case pasteSelection
    case openInTerminal
    case showInFinder
    case revealInFolder
    case calculateSize
    case copyPath
    case theme
    case settings
    case help
}

extension ToolbarItems {
    /// TOOLBAR_ITEM_DEFINITIONS, in the original's order.
    public static let definitions: [ToolbarItemDefinition] = [
        ToolbarItemDefinition(id: .back, label: "Back", icon: .back, kind: .button, shortcutCommand: .goBack),
        ToolbarItemDefinition(
            id: .forward, label: "Forward", icon: .forward, kind: .button, shortcutCommand: .goForward),
        ToolbarItemDefinition(
            id: .up, label: "Enclosing Folder", icon: .up, kind: .button, shortcutCommand: .goEnclosingFolder),
        ToolbarItemDefinition(
            id: .refresh, label: "Refresh", icon: .refresh, kind: .button, commandType: .refreshOrApplySearchSort,
            shortcutCommand: .refreshOrApplySearchSort),
        ToolbarItemDefinition(
            id: .topSeparator, label: "Space", icon: .separatorVertical, kind: .separator, allowDuplicates: true),
        ToolbarItemDefinition(id: .view, label: "View Mode", icon: .list, kind: .composite),
        ToolbarItemDefinition(id: .sort, label: "Sort", icon: .sort, kind: .composite),
        ToolbarItemDefinition(id: .title, label: "Title", icon: .title, kind: .composite, topRequired: true),
        ToolbarItemDefinition(id: .clipboard, label: "Clipboard", icon: .copy, kind: .menu, topRequired: true),
        ToolbarItemDefinition(id: .viewOptions, label: "View Options", icon: .more, kind: .menu, topRequired: true),
        ToolbarItemDefinition(id: .search, label: "Search", icon: .search, kind: .composite, topRequired: true),
        ToolbarItemDefinition(
            id: .goToFolder, label: "Go To", icon: .location, kind: .button, commandType: .openLocationSheet,
            shortcutCommand: .openLocationSheet),
        ToolbarItemDefinition(
            id: .foldersFirst, label: "Folders First", icon: .foldersFirst, kind: .toggle,
            shortcutCommand: .toggleFoldersFirst),
        ToolbarItemDefinition(
            id: .hidden, label: "Hidden Files", icon: .hidden, kind: .toggle, shortcutCommand: .toggleHiddenFiles),
        ToolbarItemDefinition(
            id: .folderTree, label: "Folder Tree", icon: .sidebar, kind: .toggle, commandType: .toggleFolderTree,
            shortcutCommand: .toggleFolderTree),
        ToolbarItemDefinition(
            id: .infoPanel, label: "Info Panel", icon: .drawer, kind: .toggle, commandType: .toggleInfoPanel,
            shortcutCommand: .toggleInfoPanel),
        ToolbarItemDefinition(
            id: .infoRow, label: "Info Row", icon: .infoRow, kind: .toggle, commandType: .toggleInfoRow,
            shortcutCommand: .toggleInfoRow),
        ToolbarItemDefinition(
            id: .newTab, label: "New Tab", icon: .newTab, kind: .button, commandType: .newTab, shortcutCommand: .newTab),
        ToolbarItemDefinition(
            id: .openSelection, label: "Open", icon: .open, kind: .button, commandType: .openSelection,
            shortcutCommand: .openSelection),
        ToolbarItemDefinition(
            id: .quickLook, label: "Quick Look", icon: .quickLook, kind: .button, commandType: .quickLookSelection,
            shortcutCommand: .quickLookSelection),
        ToolbarItemDefinition(
            id: .editSelection, label: "Edit", icon: .edit, kind: .button, commandType: .editSelection,
            shortcutCommand: .editSelection, tooltipLabel: "Edit in Text Editor"),
        ToolbarItemDefinition(
            id: .moveSelection, label: "Move To", icon: .move, kind: .button, commandType: .moveSelection,
            shortcutCommand: .moveSelection),
        ToolbarItemDefinition(
            id: .renameSelection, label: "Rename", icon: .rename, kind: .button, commandType: .renameSelection,
            shortcutCommand: .renameSelection),
        ToolbarItemDefinition(
            id: .duplicateSelection, label: "Duplicate", icon: .duplicate, kind: .button,
            commandType: .duplicateSelection, shortcutCommand: .duplicateSelection),
        ToolbarItemDefinition(
            id: .newFolder, label: "New Folder", icon: .newFolder, kind: .button, commandType: .newFolder,
            shortcutCommand: .newFolder),
        ToolbarItemDefinition(
            id: .trashSelection, label: "Move to Trash", icon: .trash, kind: .button, commandType: .trashSelection,
            shortcutCommand: .trashSelection),
        ToolbarItemDefinition(
            id: .copySelection, label: "Copy", icon: .copy, kind: .button, commandType: .copySelection,
            shortcutCommand: .copy),
        ToolbarItemDefinition(
            id: .cutSelection, label: "Cut", icon: .cut, kind: .button, commandType: .cutSelection,
            shortcutCommand: .cut),
        ToolbarItemDefinition(
            id: .pasteSelection, label: "Paste", icon: .paste, kind: .button, commandType: .pasteSelection,
            shortcutCommand: .paste),
        ToolbarItemDefinition(
            id: .openInTerminal, label: "Open in Terminal", icon: .terminal, kind: .button,
            commandType: .openInTerminal, shortcutCommand: .openInTerminal),
        ToolbarItemDefinition(
            id: .showInFinder, label: "Show in Finder", icon: .showInFinder, kind: .button, commandType: .showInFinder,
            shortcutCommand: .showInFinder),
        ToolbarItemDefinition(
            id: .revealInFolder, label: "Reveal in Folder", icon: .revealInFolder, kind: .button,
            commandType: .revealInFolder, shortcutCommand: .revealInFolder),
        ToolbarItemDefinition(
            id: .calculateSize, label: "Calculate Size", icon: .calculateSize, kind: .button,
            commandType: .calculateSize, shortcutCommand: .calculateSize),
        ToolbarItemDefinition(
            id: .copyPath, label: "Copy Path", icon: .copyPath, kind: .button, commandType: .copyPath,
            shortcutCommand: .copyPath),
        ToolbarItemDefinition(id: .theme, label: "Theme", icon: .theme, kind: .menu),
        ToolbarItemDefinition(
            id: .settings, label: "Settings", icon: .settings, kind: .button, commandType: .openSettings,
            shortcutCommand: .settings),
        ToolbarItemDefinition(
            id: .help, label: "Help", icon: .help, kind: .button, commandType: .openHelp, shortcutCommand: .openHelp,
            tooltipLabel: "File Trail Help"),
    ]

    /// DEFAULT_TOP_TOOLBAR_ITEMS.
    public static let defaultTopItems: [ToolbarItemID] = [
        .folderTree,
        .topSeparator,
        .back,
        .forward,
        .title,
        .clipboard,
        .view,
        .sort,
        .search,
        .viewOptions,
        .infoPanel,
    ]

    /// The order the items are offered in while the toolbar is customized (TOP_TOOLBAR_PALETTE_ORDER).
    static let paletteOrder: [ToolbarItemID] = [
        .topSeparator,
        .back,
        .forward,
        .up,
        .goToFolder,
        .revealInFolder,
        .refresh,
        .newTab,
        .view,
        .sort,
        .foldersFirst,
        .hidden,
        .folderTree,
        .infoPanel,
        .infoRow,
        .calculateSize,
        .openSelection,
        .quickLook,
        .editSelection,
        .copySelection,
        .cutSelection,
        .pasteSelection,
        .renameSelection,
        .moveSelection,
        .duplicateSelection,
        .newFolder,
        .trashSelection,
        .openInTerminal,
        .showInFinder,
        .copyPath,
        .theme,
        .settings,
        .help,
    ]
}
