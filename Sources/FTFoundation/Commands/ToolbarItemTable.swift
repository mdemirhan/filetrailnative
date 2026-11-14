// The toolbar's table: each item's icon, label, command and tooltip, the items a new window starts with, and the
// order they are offered in while the toolbar is customized.

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
    case undoHistory
    case viewOptions
    case search
    case goToFolder
    case foldersFirst
    case hidden
    case folderTree
    case twoPanes
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
    case undo
    case redo
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
    /// Every toolbar item, in the table's order.
    public static let definitions: [ToolbarItemDefinition] = [
        ToolbarItemDefinition(id: .back, label: "Back", icon: .back, shortcutCommand: .goBack),
        ToolbarItemDefinition(
            id: .forward, label: "Forward", icon: .forward, shortcutCommand: .goForward),
        ToolbarItemDefinition(
            id: .up, label: "Enclosing Folder", icon: .up, shortcutCommand: .goEnclosingFolder),
        ToolbarItemDefinition(
            id: .refresh, label: "Refresh", icon: .refresh, commandType: .refreshOrApplySearchSort,
            shortcutCommand: .refreshOrApplySearchSort),
        ToolbarItemDefinition(
            id: .topSeparator, label: "Space", icon: nil, allowDuplicates: true),
        ToolbarItemDefinition(id: .view, label: "View Mode", icon: nil),
        ToolbarItemDefinition(id: .sort, label: "Sort", icon: .sortBy),
        ToolbarItemDefinition(id: .title, label: "Title", icon: nil, topRequired: true),
        ToolbarItemDefinition(id: .clipboard, label: "Clipboard", icon: .copy, highPriority: true),
        ToolbarItemDefinition(id: .undoHistory, label: "Undo History", icon: .undoHistory, highPriority: true),
        ToolbarItemDefinition(id: .viewOptions, label: "View Options", icon: .viewOptions, topRequired: true),
        ToolbarItemDefinition(id: .search, label: "Search", icon: .search, topRequired: true),
        ToolbarItemDefinition(
            id: .goToFolder, label: "Go To", icon: .goTo, commandType: .openLocationSheet,
            shortcutCommand: .openLocationSheet),
        ToolbarItemDefinition(
            id: .foldersFirst, label: "Folders First", icon: .foldersFirst,
            shortcutCommand: .toggleFoldersFirst),
        ToolbarItemDefinition(
            id: .hidden, label: "Hidden Files", icon: .hidden, shortcutCommand: .toggleHiddenFiles),
        ToolbarItemDefinition(
            id: .folderTree, label: "Folder Tree", icon: .folderTree, commandType: .toggleFolderTree,
            shortcutCommand: .toggleFolderTree),
        ToolbarItemDefinition(
            id: .twoPanes, label: "Two Panes", icon: .twoPanes, commandType: .toggleTwoPanes,
            shortcutCommand: .toggleTwoPanes),
        ToolbarItemDefinition(
            id: .infoPanel, label: "Info Panel", icon: .infoPanel, commandType: .toggleInfoPanel,
            shortcutCommand: .toggleInfoPanel),
        ToolbarItemDefinition(
            id: .infoRow, label: "Info Row", icon: .infoRow, commandType: .toggleInfoRow,
            shortcutCommand: .toggleInfoRow),
        ToolbarItemDefinition(
            id: .newTab, label: "New Tab", icon: .newTab, commandType: .newTab, shortcutCommand: .newTab),
        ToolbarItemDefinition(
            id: .openSelection, label: "Open", icon: .open, commandType: .openSelection,
            shortcutCommand: .openSelection),
        ToolbarItemDefinition(
            id: .quickLook, label: "Quick Look", icon: .quickLook, commandType: .quickLookSelection,
            shortcutCommand: .quickLookSelection),
        ToolbarItemDefinition(
            id: .editSelection, label: "Edit", icon: .edit, commandType: .editSelection,
            shortcutCommand: .editSelection, tooltipLabel: "Edit in Text Editor"),
        ToolbarItemDefinition(
            id: .moveSelection, label: "Move To", icon: .move, commandType: .moveSelection,
            shortcutCommand: .moveSelection),
        ToolbarItemDefinition(
            id: .renameSelection, label: "Rename", icon: .rename, commandType: .renameSelection,
            shortcutCommand: .renameSelection),
        ToolbarItemDefinition(
            id: .duplicateSelection, label: "Duplicate", icon: .duplicate,
            commandType: .duplicateSelection, shortcutCommand: .duplicateSelection),
        ToolbarItemDefinition(
            id: .newFolder, label: "New Folder", icon: .newFolder, commandType: .newFolder,
            shortcutCommand: .newFolder),
        ToolbarItemDefinition(
            id: .trashSelection, label: "Move to Trash", icon: .trash, commandType: .trashSelection,
            shortcutCommand: .trashSelection),
        ToolbarItemDefinition(
            id: .copySelection, label: "Copy", icon: .copy, commandType: .copySelection,
            shortcutCommand: .copy),
        ToolbarItemDefinition(
            id: .cutSelection, label: "Cut", icon: .cut, commandType: .cutSelection,
            shortcutCommand: .cut),
        ToolbarItemDefinition(
            id: .pasteSelection, label: "Paste", icon: .paste, commandType: .pasteSelection,
            shortcutCommand: .paste),
        ToolbarItemDefinition(id: .undo, label: "Undo", icon: .undo, commandType: .undo, shortcutCommand: .undo),
        ToolbarItemDefinition(id: .redo, label: "Redo", icon: .redo, commandType: .redo, shortcutCommand: .redo),
        ToolbarItemDefinition(
            id: .openInTerminal, label: "Open in Terminal", icon: .terminal,
            commandType: .openInTerminal, shortcutCommand: .openInTerminal),
        ToolbarItemDefinition(
            id: .showInFinder, label: "Show in Finder", icon: .showInFinder, commandType: .showInFinder,
            shortcutCommand: .showInFinder),
        ToolbarItemDefinition(
            id: .revealInFolder, label: "Reveal in Folder", icon: .revealInFolder,
            commandType: .revealInFolder, shortcutCommand: .revealInFolder),
        ToolbarItemDefinition(
            id: .calculateSize, label: "Calculate Size", icon: .calculateSize,
            commandType: .calculateSize, shortcutCommand: .calculateSize),
        ToolbarItemDefinition(
            id: .copyPath, label: "Copy Path", icon: .copyPath, commandType: .copyPath,
            shortcutCommand: .copyPath),
        ToolbarItemDefinition(id: .theme, label: "Theme", icon: .theme),
        ToolbarItemDefinition(
            id: .settings, label: "Settings", icon: .settings, commandType: .openSettings,
            shortcutCommand: .settings),
        ToolbarItemDefinition(
            id: .help, label: "Help", icon: .help, commandType: .openHelp, shortcutCommand: .openHelp,
            tooltipLabel: "File Trail Help"),
    ]

    /// The toolbar's items before it is customized. The Undo History button isn't one of them: it is there once it is
    /// added while customizing.
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
        .twoPanes,
        .infoPanel,
    ]

    /// The order the items are offered in while the toolbar is customized.
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
        .twoPanes,
        .infoPanel,
        .infoRow,
        .calculateSize,
        .openSelection,
        .quickLook,
        .editSelection,
        .clipboard,
        .copySelection,
        .cutSelection,
        .pasteSelection,
        .undoHistory,
        .undo,
        .redo,
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
