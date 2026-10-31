// Generated once from SHORTCUT_COMMANDS in apps/desktop/src/shared/shortcuts.ts in the Electron app; now edited by hand.

public enum ShortcutGroup: String, CaseIterable, Sendable, Hashable {
    case navigation
    case tabs
    case files
    case search
    case view
    case standard

    /// SHORTCUT_GROUP_LABELS.
    public var label: String {
        switch self {
        case .navigation: "Navigation"
        case .tabs: "Windows and Tabs"
        case .files: "Files"
        case .search: "Search"
        case .view: "View"
        case .standard: "Standard"
        }
    }
}

/// The id of a command in the shortcut table; the raw value is the original's id.
public enum ShortcutCommandID: String, Codable, CaseIterable, Sendable, Hashable {
    case goBack
    case goForward
    case goEnclosingFolder
    case goHomeRootTree
    case goDocuments
    case goDesktop
    case goDownloads
    case goLibrary
    case goMacintoshHD
    case goApplications
    case goTrash
    case openLocationSheet
    case rootTreeAtSelection
    case refreshOrApplySearchSort
    case focusTreePane
    case focusContentPane
    case pageUp
    case pageDown
    case halfPageUp
    case halfPageDown
    case newWindow
    case newTab
    /// Not in the original's table: its Duplicate Tab is in the tab strip's menu only (DEVIATIONS D-001).
    case duplicateTab
    case closeTab
    case reopenClosedTab
    case selectNextTab
    case selectPreviousTab
    case openSelectionInNewTab
    case openSelectionInNewWindow
    case moveTabToNewWindow
    case mergeAllWindows
    case openSelection
    case openSelectedItem
    case editSelection
    case quickLookSelection
    case calculateSize
    case renameSelection
    case duplicateSelection
    case moveSelection
    case newFolder
    case trashSelection
    case ejectVolume
    case emptyTrash
    case copyPath
    case showClipboard
    case clearClipboard
    case openInTerminal
    case showInFinder
    case toggleFavorite
    case focusFileSearch
    case showLastSearchResults
    case revealInFolder
    case viewAsIcons
    case viewAsDetails
    case viewAsList
    case sortByName
    case sortByKind
    case sortByModified
    case sortBySize
    case toggleFoldersFirst
    case toggleHiddenFiles
    case toggleFolderTree
    case toggleInfoPanel
    case toggleInfoRow
    case customizeToolbar
    case openHelp
    case openKeyboardShortcuts
    case undo
    case redo
    case cut
    case copy
    case paste
    case selectAll
    case settings
    case closeWindow
    case minimize
    case fullScreen
    case hide
    case hideOthers
    case quit
}

extension ShortcutCommands {
    /// SHORTCUT_COMMANDS, in the original's order.
    public static let all: [ShortcutCommandDefinition] = [
        ShortcutCommandDefinition(
            id: .goBack, label: "Back", group: .navigation, defaults: ["Cmd+[", "Cmd+Left"], menuPath: "Go > Back"),
        ShortcutCommandDefinition(
            id: .goForward, label: "Forward", group: .navigation, defaults: ["Cmd+]", "Cmd+Right"],
            menuPath: "Go > Forward"),
        ShortcutCommandDefinition(
            id: .goEnclosingFolder, label: "Enclosing Folder", group: .navigation, defaults: ["Cmd+Up"],
            menuPath: "Go > Enclosing Folder"),
        ShortcutCommandDefinition(
            id: .goHomeRootTree, label: "Home", group: .navigation, defaults: ["Cmd+Shift+H"], menuPath: "Go > Home"),
        ShortcutCommandDefinition(
            id: .goDocuments, label: "Documents", group: .navigation, defaults: [], menuPath: "Go > Documents"),
        ShortcutCommandDefinition(
            id: .goDesktop, label: "Desktop", group: .navigation, defaults: [], menuPath: "Go > Desktop"),
        ShortcutCommandDefinition(
            id: .goDownloads, label: "Downloads", group: .navigation, defaults: [], menuPath: "Go > Downloads"),
        ShortcutCommandDefinition(
            id: .goLibrary, label: "Library", group: .navigation, defaults: [], menuPath: "Go > Library"),
        ShortcutCommandDefinition(
            id: .goMacintoshHD, label: "Macintosh HD", group: .navigation, defaults: [], menuPath: "Go > Macintosh HD"),
        ShortcutCommandDefinition(
            id: .goApplications, label: "Applications", group: .navigation, defaults: [], menuPath: "Go > Applications"),
        ShortcutCommandDefinition(
            id: .goTrash, label: "Trash", group: .navigation, defaults: [], menuPath: "Go > Trash"),
        ShortcutCommandDefinition(
            id: .openLocationSheet, label: "Go to Folder…", group: .navigation, defaults: ["Cmd+K", "Cmd+Shift+G"],
            menuPath: "Go > Go to Folder…"),
        ShortcutCommandDefinition(
            id: .rootTreeAtSelection, label: "Use as Tree Root", group: .navigation, defaults: ["Cmd+Shift+R"],
            menuPath: "Go > Use as Tree Root"),
        ShortcutCommandDefinition(
            id: .refreshOrApplySearchSort, label: "Refresh", group: .navigation, defaults: ["Cmd+R"],
            menuPath: "View > Refresh"),
        ShortcutCommandDefinition(id: .focusTreePane, label: "Focus Folder Tree", group: .navigation, defaults: []),
        ShortcutCommandDefinition(id: .focusContentPane, label: "Focus File List", group: .navigation, defaults: []),
        ShortcutCommandDefinition(id: .pageUp, label: "Move One Page Up", group: .navigation, defaults: ["PageUp"]),
        ShortcutCommandDefinition(
            id: .pageDown, label: "Move One Page Down", group: .navigation, defaults: ["PageDown"]),
        ShortcutCommandDefinition(
            id: .halfPageUp, label: "Move Half a Page Up", group: .navigation, defaults: ["Ctrl+U"]),
        ShortcutCommandDefinition(
            id: .halfPageDown, label: "Move Half a Page Down", group: .navigation, defaults: ["Ctrl+D"]),
        ShortcutCommandDefinition(
            id: .newWindow, label: "New Window", group: .tabs, defaults: ["Cmd+N"], menuPath: "File > New Window"),
        ShortcutCommandDefinition(
            id: .newTab, label: "New Tab", group: .tabs, defaults: ["Cmd+T"], menuPath: "File > New Tab"),
        ShortcutCommandDefinition(
            id: .duplicateTab, label: "Duplicate Tab", group: .tabs, defaults: [], menuPath: "File > Duplicate Tab"),
        ShortcutCommandDefinition(
            id: .closeTab, label: "Close Tab", group: .tabs, defaults: ["Cmd+W"], menuPath: "File > Close Tab"),
        ShortcutCommandDefinition(
            id: .reopenClosedTab, label: "Reopen Closed Tab", group: .tabs, defaults: ["Cmd+Shift+T"],
            menuPath: "File > Reopen Closed Tab"),
        ShortcutCommandDefinition(
            id: .selectNextTab, label: "Show Next Tab", group: .tabs, defaults: ["Ctrl+Tab", "Cmd+Shift+]"],
            menuPath: "Window > Show Next Tab"),
        ShortcutCommandDefinition(
            id: .selectPreviousTab, label: "Show Previous Tab", group: .tabs,
            defaults: ["Ctrl+Shift+Tab", "Cmd+Shift+["], menuPath: "Window > Show Previous Tab"),
        ShortcutCommandDefinition(
            id: .openSelectionInNewTab, label: "Open in New Tab", group: .tabs, defaults: [],
            menuPath: "File > Open in New Tab"),
        ShortcutCommandDefinition(
            id: .openSelectionInNewWindow, label: "Open in New Window", group: .tabs, defaults: [],
            menuPath: "File > Open in New Window"),
        ShortcutCommandDefinition(
            id: .moveTabToNewWindow, label: "Move Tab to New Window", group: .tabs, defaults: [],
            menuPath: "Window > Move Tab to New Window"),
        ShortcutCommandDefinition(
            id: .mergeAllWindows, label: "Merge All Windows", group: .tabs, defaults: [],
            menuPath: "Window > Merge All Windows"),
        ShortcutCommandDefinition(
            id: .openSelection, label: "Open", group: .files, defaults: ["Cmd+O"], menuPath: "File > Open"),
        ShortcutCommandDefinition(
            id: .openSelectedItem, label: "Open Selected Item", group: .files, defaults: ["Cmd+Down"]),
        ShortcutCommandDefinition(
            id: .editSelection, label: "Edit in Text Editor", group: .files, defaults: ["Cmd+Shift+E"],
            menuPath: "File > Edit in Text Editor"),
        ShortcutCommandDefinition(
            id: .quickLookSelection, label: "Quick Look", group: .files, defaults: ["Space"],
            menuPath: "File > Quick Look"),
        ShortcutCommandDefinition(
            id: .calculateSize, label: "Calculate Size", group: .files, defaults: [], menuPath: "File > Calculate Size"),
        ShortcutCommandDefinition(
            id: .renameSelection, label: "Rename", group: .files, defaults: ["F2"], menuPath: "File > Rename"),
        ShortcutCommandDefinition(
            id: .duplicateSelection, label: "Duplicate", group: .files, defaults: ["Cmd+D"],
            menuPath: "File > Duplicate"),
        ShortcutCommandDefinition(
            id: .moveSelection, label: "Move to…", group: .files, defaults: ["Cmd+Shift+M"], menuPath: "File > Move to…"
        ),
        ShortcutCommandDefinition(
            id: .newFolder, label: "New Folder", group: .files, defaults: ["Cmd+Shift+N"], menuPath: "File > New Folder"
        ),
        ShortcutCommandDefinition(
            id: .trashSelection, label: "Move to Trash", group: .files, defaults: ["Cmd+Backspace"],
            menuPath: "File > Move to Trash"),
        ShortcutCommandDefinition(
            id: .ejectVolume, label: "Eject", group: .files, defaults: ["Cmd+E"], menuPath: "File > Eject"),
        ShortcutCommandDefinition(
            id: .emptyTrash, label: "Empty Trash…", group: .files, defaults: ["Cmd+Shift+Backspace"],
            menuPath: "File Trail > Empty Trash…"),
        ShortcutCommandDefinition(
            id: .copyPath, label: "Copy Path", group: .files, defaults: ["Cmd+Option+C"], menuPath: "Edit > Copy Path"),
        ShortcutCommandDefinition(
            id: .showClipboard, label: "Show Clipboard", group: .files, defaults: [], menuPath: "Edit > Show Clipboard"),
        ShortcutCommandDefinition(
            id: .clearClipboard, label: "Clear Clipboard", group: .files, defaults: [],
            menuPath: "Edit > Clear Clipboard"),
        ShortcutCommandDefinition(
            id: .openInTerminal, label: "Open in Terminal", group: .files, defaults: ["Cmd+Option+T"],
            menuPath: "File > Open in Terminal"),
        ShortcutCommandDefinition(
            id: .showInFinder, label: "Show in Finder", group: .files, defaults: [], menuPath: "File > Show in Finder"),
        ShortcutCommandDefinition(
            id: .toggleFavorite, label: "Add to Favorites", group: .files, defaults: [],
            menuPath: "File > Add to Favorites"),
        ShortcutCommandDefinition(
            id: .focusFileSearch, label: "Find Files…", group: .search, defaults: ["Cmd+F"],
            menuPath: "Edit > Find Files…"),
        ShortcutCommandDefinition(
            id: .showLastSearchResults, label: "Show Last Search Results", group: .search, defaults: ["Cmd+Shift+F"],
            menuPath: "Edit > Show Last Search Results"),
        ShortcutCommandDefinition(
            id: .revealInFolder, label: "Reveal in Folder", group: .search, defaults: [],
            menuPath: "File > Reveal in Folder"),
        ShortcutCommandDefinition(
            id: .viewAsIcons, label: "View as Icons", group: .view, defaults: ["Cmd+1"], menuPath: "View > as Icons"),
        ShortcutCommandDefinition(
            id: .viewAsDetails, label: "View as List", group: .view, defaults: ["Cmd+2"], menuPath: "View > as List"),
        ShortcutCommandDefinition(
            id: .viewAsList, label: "View as Compact List", group: .view, defaults: ["Cmd+3"],
            menuPath: "View > as Compact List"),
        ShortcutCommandDefinition(
            id: .sortByName, label: "Sort by Name", group: .view, defaults: [], menuPath: "View > Sort By > Name"),
        ShortcutCommandDefinition(
            id: .sortByKind, label: "Sort by Kind", group: .view, defaults: [], menuPath: "View > Sort By > Kind"),
        ShortcutCommandDefinition(
            id: .sortByModified, label: "Sort by Date Modified", group: .view, defaults: [],
            menuPath: "View > Sort By > Date Modified"),
        ShortcutCommandDefinition(
            id: .sortBySize, label: "Sort by Size", group: .view, defaults: [], menuPath: "View > Sort By > Size"),
        ShortcutCommandDefinition(
            id: .toggleFoldersFirst, label: "Folders First", group: .view, defaults: [],
            menuPath: "View > Folders First"),
        ShortcutCommandDefinition(
            id: .toggleHiddenFiles, label: "Hidden Files", group: .view, defaults: ["Cmd+Shift+."],
            menuPath: "View > Hidden Files"),
        ShortcutCommandDefinition(
            id: .toggleFolderTree, label: "Folder Tree", group: .view, defaults: ["Ctrl+Cmd+S"],
            menuPath: "View > Hide Folder Tree"),
        ShortcutCommandDefinition(
            id: .toggleInfoPanel, label: "Info Panel", group: .view, defaults: ["Cmd+I"], menuPath: "View > Info Panel"),
        ShortcutCommandDefinition(
            id: .toggleInfoRow, label: "Info Row", group: .view, defaults: ["Cmd+Shift+I"], menuPath: "View > Info Row"),
        ShortcutCommandDefinition(
            id: .customizeToolbar, label: "Customize Toolbar…", group: .view, defaults: [],
            menuPath: "View > Customize Toolbar…"),
        ShortcutCommandDefinition(
            id: .openHelp, label: "File Trail Help", group: .view, defaults: ["?"], menuPath: "Help > File Trail Help"),
        ShortcutCommandDefinition(
            id: .openKeyboardShortcuts, label: "Keyboard Shortcuts", group: .view, defaults: [],
            menuPath: "Help > Keyboard Shortcuts"),
        ShortcutCommandDefinition(id: .undo, label: "Undo", group: .standard, defaults: ["Cmd+Z"], fixed: true),
        ShortcutCommandDefinition(id: .redo, label: "Redo", group: .standard, defaults: ["Cmd+Shift+Z"], fixed: true),
        ShortcutCommandDefinition(id: .cut, label: "Cut", group: .standard, defaults: ["Cmd+X"], fixed: true),
        ShortcutCommandDefinition(id: .copy, label: "Copy", group: .standard, defaults: ["Cmd+C"], fixed: true),
        ShortcutCommandDefinition(id: .paste, label: "Paste", group: .standard, defaults: ["Cmd+V"], fixed: true),
        ShortcutCommandDefinition(
            id: .selectAll, label: "Select All", group: .standard, defaults: ["Cmd+A"], fixed: true),
        ShortcutCommandDefinition(
            id: .settings, label: "Settings…", group: .standard, defaults: ["Cmd+,"], fixed: true),
        ShortcutCommandDefinition(
            id: .closeWindow, label: "Close Window", group: .standard, defaults: ["Cmd+Shift+W"], fixed: true),
        ShortcutCommandDefinition(id: .minimize, label: "Minimize", group: .standard, defaults: ["Cmd+M"], fixed: true),
        ShortcutCommandDefinition(
            id: .fullScreen, label: "Enter Full Screen", group: .standard, defaults: ["Ctrl+Cmd+F"], fixed: true),
        ShortcutCommandDefinition(
            id: .hide, label: "Hide File Trail", group: .standard, defaults: ["Cmd+H"], fixed: true),
        ShortcutCommandDefinition(
            id: .hideOthers, label: "Hide Others", group: .standard, defaults: ["Cmd+Option+H"], fixed: true),
        ShortcutCommandDefinition(
            id: .quit, label: "Quit File Trail", group: .standard, defaults: ["Cmd+Q"], fixed: true),
    ]
}
