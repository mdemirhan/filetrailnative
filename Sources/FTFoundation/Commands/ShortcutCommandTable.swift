// The table of keyboard shortcuts: the groups Settings and Help list commands under, and every command with its
// default keys.

public enum ShortcutGroup: String, CaseIterable, Sendable, Hashable {
    case navigation
    case tabs
    case files
    case search
    case view
    case viewer
    case standard

    /// The heading the group's commands are listed under in Settings and Help.
    public var label: String {
        switch self {
        case .navigation: "Navigation"
        case .tabs: "Windows, Tabs and Panes"
        case .files: "Files"
        case .search: "Search"
        case .view: "View"
        case .viewer: "Viewer"
        case .standard: "Standard"
        }
    }
}

/// The id of a command in the shortcut table; the raw value is its id.
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
    case duplicateTab
    case closePane
    case closeTab
    case reopenClosedTab
    case selectNextTab
    case selectPreviousTab
    case openSelectionInNewTab
    case openSelectionInNewWindow
    case moveTabToNewWindow
    case mergeAllWindows
    case saveWorkspace
    case openWorkspace1
    case openWorkspace2
    case openWorkspace3
    case openWorkspace4
    case openWorkspace5
    case openWorkspace1InThisWindow
    case openWorkspace2InThisWindow
    case openWorkspace3InThisWindow
    case openWorkspace4InThisWindow
    case openWorkspace5InThisWindow
    case toggleTwoPanes
    case duplicatePane
    case switchToOtherPane
    case openSelectionInOtherPane
    case copyToOtherPane
    case moveToOtherPane
    case swapPanes
    case showFolderInOtherPane
    case goToOtherPaneFolder
    case equalizePanes
    case openSelection
    case openSelectedItem
    case editSelection
    case quickLookSelection
    case viewFile
    case deselectAll
    case invertSelection
    case calculateSize
    case renameSelection
    case duplicateSelection
    case makeAlias
    case showOriginal
    case convertImages
    case moveSelection
    case compressSelection
    case extractSelection
    case extractSelectionTo
    case newFolder
    case newFolderWithSelection
    case newTextFile
    case openTemplatesFolder
    case saveAsTemplate
    case pasteAsFile
    case trashSelection
    case deleteImmediately
    case ejectVolume
    case emptyTrash
    case copyPath
    case copyContents
    case shareSelection
    case addToCopied
    case addToCut
    case moveItemsHere
    case removeFromClipboard
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
    case viewAsPreviews
    case showPreviews9
    case showPreviews4
    case showPreviews2
    case showPreviews1
    case increaseSize
    case decreaseSize
    case resetSize
    case groupByNone
    case groupByName
    case groupByModified
    case groupByCreated
    case groupByLastOpened
    case groupByAdded
    case groupBySize
    case groupByKind
    case groupByTags
    case groupByFolder
    case reverseGroupOrder
    case sortByName
    case sortByKind
    case sortByModified
    case sortByCreated
    case sortByAdded
    case sortByLastOpened
    case sortBySize
    case toggleFoldersFirst
    case toggleHiddenFiles
    case showModifiedColumn
    case showSizeColumn
    case showKindColumn
    case showCreatedColumn
    case showAddedColumn
    case showLastOpenedColumn
    case showPermissionsColumn
    case rememberFolderView
    case updateFolderView
    case revertFolderView
    case folderViewOptions
    case resetFolderView
    case manageFolderViews
    case togglePinFilter
    case toggleFolderTree
    case toggleInfoPanel
    case toggleInfoRow
    case customizeToolbar
    case showCommandPalette
    case openHelp
    case openKeyboardShortcuts
    case saveViewerFile
    case nextViewerFile
    case previousViewerFile
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
    /// Every shortcut command, in the table's order.
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
            id: .closePane, label: "Close Pane", group: .tabs, defaults: ["Cmd+W"], menuPath: "File > Close Pane"),
        // The item ⌥ shows in Close Pane's place: the whole tab at once, both its panes.
        ShortcutCommandDefinition(
            id: .closeTab, label: "Close Tab", group: .tabs, defaults: ["Cmd+Option+W"],
            menuPath: "File > Close Tab, with Option"),
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
            id: .saveWorkspace, label: "Save Window as Workspace…", group: .tabs, defaults: [],
            menuPath: "Window > Workspaces > Save Window as Workspace…"),
        // The first five workspaces in the list, whatever they are called.
        ShortcutCommandDefinition(
            id: .openWorkspace1, label: "Workspace 1", group: .tabs, defaults: ["Ctrl+Cmd+1"],
            menuPath: "Window > Workspaces"),
        ShortcutCommandDefinition(
            id: .openWorkspace2, label: "Workspace 2", group: .tabs, defaults: ["Ctrl+Cmd+2"],
            menuPath: "Window > Workspaces"),
        ShortcutCommandDefinition(
            id: .openWorkspace3, label: "Workspace 3", group: .tabs, defaults: ["Ctrl+Cmd+3"],
            menuPath: "Window > Workspaces"),
        ShortcutCommandDefinition(
            id: .openWorkspace4, label: "Workspace 4", group: .tabs, defaults: ["Ctrl+Cmd+4"],
            menuPath: "Window > Workspaces"),
        ShortcutCommandDefinition(
            id: .openWorkspace5, label: "Workspace 5", group: .tabs, defaults: ["Ctrl+Cmd+5"],
            menuPath: "Window > Workspaces"),
        // The same five in the window the menu acts on: the items ⌥ shows in their place.
        ShortcutCommandDefinition(
            id: .openWorkspace1InThisWindow, label: "Workspace 1 in This Window", group: .tabs,
            defaults: ["Ctrl+Cmd+Option+1"], menuPath: "Window > Workspaces, with Option"),
        ShortcutCommandDefinition(
            id: .openWorkspace2InThisWindow, label: "Workspace 2 in This Window", group: .tabs,
            defaults: ["Ctrl+Cmd+Option+2"], menuPath: "Window > Workspaces, with Option"),
        ShortcutCommandDefinition(
            id: .openWorkspace3InThisWindow, label: "Workspace 3 in This Window", group: .tabs,
            defaults: ["Ctrl+Cmd+Option+3"], menuPath: "Window > Workspaces, with Option"),
        ShortcutCommandDefinition(
            id: .openWorkspace4InThisWindow, label: "Workspace 4 in This Window", group: .tabs,
            defaults: ["Ctrl+Cmd+Option+4"], menuPath: "Window > Workspaces, with Option"),
        ShortcutCommandDefinition(
            id: .openWorkspace5InThisWindow, label: "Workspace 5 in This Window", group: .tabs,
            defaults: ["Ctrl+Cmd+Option+5"], menuPath: "Window > Workspaces, with Option"),
        ShortcutCommandDefinition(
            id: .toggleTwoPanes, label: "Two Panes", group: .tabs, defaults: ["Cmd+\\"],
            menuPath: "View > Two Panes"),
        ShortcutCommandDefinition(
            id: .duplicatePane, label: "Duplicate Pane", group: .tabs, defaults: ["Cmd+Option+\\"],
            menuPath: "View > Duplicate Pane"),
        ShortcutCommandDefinition(
            id: .switchToOtherPane, label: "Switch to Other Pane", group: .tabs, defaults: [],
            menuPath: "Window > Switch to Other Pane"),
        ShortcutCommandDefinition(
            id: .openSelectionInOtherPane, label: "Open in Other Pane", group: .tabs,
            defaults: ["Cmd+Option+Down", "Cmd+Option+E"],
            menuPath: "File > Open in Other Pane"),
        ShortcutCommandDefinition(
            id: .copyToOtherPane, label: "Copy to Other Pane", group: .tabs, defaults: ["F5"],
            menuPath: "Edit > Copy to Other Pane"),
        ShortcutCommandDefinition(
            id: .moveToOtherPane, label: "Move to Other Pane", group: .tabs, defaults: ["F6"],
            menuPath: "Edit > Move to Other Pane"),
        ShortcutCommandDefinition(
            id: .swapPanes, label: "Swap Panes", group: .tabs, defaults: ["Cmd+U"], menuPath: "View > Swap Panes"),
        ShortcutCommandDefinition(
            id: .showFolderInOtherPane, label: "Show This Folder in Other Pane", group: .tabs, defaults: [],
            menuPath: "Go > Show This Folder in Other Pane"),
        ShortcutCommandDefinition(
            id: .goToOtherPaneFolder, label: "Go to Other Pane's Folder", group: .tabs, defaults: [],
            menuPath: "Go > Go to Other Pane's Folder"),
        ShortcutCommandDefinition(
            id: .equalizePanes, label: "Make Panes Equal Width", group: .tabs, defaults: [],
            menuPath: "View > Make Panes Equal Width"),
        ShortcutCommandDefinition(
            id: .openSelection, label: "Open", group: .files, defaults: ["Cmd+O"], menuPath: "File > Open"),
        ShortcutCommandDefinition(
            id: .openSelectedItem, label: "Open Selected Item", group: .files, defaults: ["Cmd+Down"]),
        ShortcutCommandDefinition(
            id: .editSelection, label: "Edit in Text Editor", group: .files, defaults: ["Cmd+Shift+E"],
            menuPath: "File > Edit in Text Editor"),
        ShortcutCommandDefinition(
            id: .quickLookSelection, label: "Quick Look", group: .files, defaults: ["Cmd+Y", "Space"],
            menuPath: "File > Quick Look"),
        ShortcutCommandDefinition(
            id: .viewFile, label: "Open in Viewer", group: .files, defaults: ["Cmd+E"],
            menuPath: "File > Open in Viewer"),
        ShortcutCommandDefinition(
            id: .deselectAll, label: "Deselect All", group: .files, defaults: ["Cmd+Option+A"],
            menuPath: "Edit > Deselect All"),
        ShortcutCommandDefinition(
            id: .invertSelection, label: "Invert Selection", group: .files, defaults: [],
            menuPath: "Edit > Invert Selection"),
        ShortcutCommandDefinition(
            id: .calculateSize, label: "Calculate Size", group: .files, defaults: [], menuPath: "File > Calculate Size"),
        ShortcutCommandDefinition(
            id: .renameSelection, label: "Rename", group: .files, defaults: ["F2"], menuPath: "File > Rename"),
        ShortcutCommandDefinition(
            id: .duplicateSelection, label: "Duplicate", group: .files, defaults: ["Cmd+D"],
            menuPath: "File > Duplicate"),
        // Make Alias has Finder's ⌃⌘A. Show Original has no key, as Finder's ⌘R is Refresh here; one can be given in
        // Settings.
        ShortcutCommandDefinition(
            id: .makeAlias, label: "Make Alias", group: .files, defaults: ["Ctrl+Cmd+A"],
            menuPath: "File > Make Alias"),
        ShortcutCommandDefinition(
            id: .showOriginal, label: "Show Original", group: .files, defaults: [], menuPath: "File > Show Original"),
        ShortcutCommandDefinition(
            id: .convertImages, label: "Convert Images\u{2026}", group: .files, defaults: [],
            menuPath: "File > Convert Images\u{2026}"),
        ShortcutCommandDefinition(
            id: .moveSelection, label: "Move to…", group: .files, defaults: ["Cmd+Shift+M"], menuPath: "File > Move to…"
        ),
        // No keys of their own, as in Finder; one can be given in Settings.
        ShortcutCommandDefinition(
            id: .compressSelection, label: "Compress", group: .files, defaults: [], menuPath: "File > Compress"),
        ShortcutCommandDefinition(
            id: .extractSelection, label: "Extract", group: .files, defaults: [], menuPath: "File > Extract"),
        ShortcutCommandDefinition(
            id: .extractSelectionTo, label: "Extract To…", group: .files, defaults: [],
            menuPath: "File > Extract To…"),
        ShortcutCommandDefinition(
            id: .newFolder, label: "New Folder", group: .files, defaults: ["Cmd+Shift+N"], menuPath: "File > New Folder"
        ),
        ShortcutCommandDefinition(
            id: .newFolderWithSelection, label: "New Folder with Selection", group: .files, defaults: ["Ctrl+Cmd+N"],
            menuPath: "File > New Folder with Selection"),
        ShortcutCommandDefinition(
            id: .newTextFile, label: "New Text File", group: .files, defaults: [],
            menuPath: "File > New File > Text File"),
        ShortcutCommandDefinition(
            id: .openTemplatesFolder, label: "Open Templates Folder", group: .files, defaults: [],
            menuPath: "File > New File > Open Templates Folder"),
        ShortcutCommandDefinition(
            id: .saveAsTemplate, label: "Save as Template", group: .files, defaults: [],
            menuPath: "File > Save as Template"),
        ShortcutCommandDefinition(
            id: .pasteAsFile, label: "Paste as File", group: .files, defaults: ["Cmd+Shift+V"],
            menuPath: "Edit > Paste as File"),
        ShortcutCommandDefinition(
            id: .trashSelection, label: "Move to Trash", group: .files, defaults: ["Cmd+Backspace"],
            menuPath: "File > Move to Trash"),
        // Finder's key and place: the item ⌥ shows in Move to Trash's, for what is in the Trash. It always asks first.
        ShortcutCommandDefinition(
            id: .deleteImmediately, label: "Delete Immediately…", group: .files, defaults: ["Cmd+Option+Backspace"],
            menuPath: "File > Delete Immediately…"),
        ShortcutCommandDefinition(
            id: .ejectVolume, label: "Eject", group: .files, defaults: [], menuPath: "File > Eject"),
        ShortcutCommandDefinition(
            id: .emptyTrash, label: "Empty Trash…", group: .files, defaults: ["Cmd+Shift+Backspace"],
            menuPath: "File Trail > Empty Trash…"),
        ShortcutCommandDefinition(
            id: .copyPath, label: "Copy Path", group: .files, defaults: ["Cmd+Option+C"], menuPath: "Edit > Copy Path"),
        ShortcutCommandDefinition(
            id: .copyContents, label: "Copy Contents", group: .files, defaults: ["Cmd+Shift+C"],
            menuPath: "Edit > Copy Contents"),
        ShortcutCommandDefinition(
            id: .shareSelection, label: "Share\u{2026}", group: .files, defaults: [], menuPath: "File > Share\u{2026}"),
        ShortcutCommandDefinition(
            id: .addToCopied, label: "Add to Copied Items", group: .files, defaults: ["Ctrl+Cmd+C"],
            menuPath: "Edit > Add to Copied Items"),
        ShortcutCommandDefinition(
            id: .addToCut, label: "Add to Cut Items", group: .files, defaults: ["Ctrl+Cmd+X"],
            menuPath: "Edit > Add to Cut Items"),
        ShortcutCommandDefinition(
            id: .moveItemsHere, label: "Move Items Here", group: .files, defaults: ["Cmd+Option+V"],
            menuPath: "Edit > Move Items Here"),
        ShortcutCommandDefinition(
            id: .removeFromClipboard, label: "Remove from Clipboard", group: .files, defaults: [],
            menuPath: "Edit > Remove from Clipboard"),
        ShortcutCommandDefinition(
            id: .showClipboard, label: "Show Clipboard", group: .files, defaults: ["Ctrl+Cmd+V"],
            menuPath: "Edit > Show Clipboard"),
        ShortcutCommandDefinition(
            id: .clearClipboard, label: "Clear Clipboard", group: .files, defaults: [],
            menuPath: "Edit > Clear Clipboard"),
        ShortcutCommandDefinition(
            id: .openInTerminal, label: "Open in Terminal", group: .files, defaults: ["Cmd+Option+T"],
            menuPath: "File > Open in Terminal"),
        ShortcutCommandDefinition(
            id: .showInFinder, label: "Show in Finder", group: .files, defaults: [], menuPath: "File > Show in Finder"),
        ShortcutCommandDefinition(
            id: .toggleFavorite, label: "Add to Favorites", group: .files, defaults: ["Ctrl+Cmd+T"],
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
            id: .viewAsPreviews, label: "View as Previews", group: .view, defaults: ["Cmd+4"],
            menuPath: "View > as Previews"),
        // A pane in Previews at one of its four counts, from any view: no keys until they are chosen.
        ShortcutCommandDefinition(
            id: .showPreviews9, label: "Show Previews 9 at a Time", group: .view, defaults: [],
            menuPath: "View > Show Previews > 9 at a Time"),
        ShortcutCommandDefinition(
            id: .showPreviews4, label: "Show Previews 4 at a Time", group: .view, defaults: [],
            menuPath: "View > Show Previews > 4 at a Time"),
        ShortcutCommandDefinition(
            id: .showPreviews2, label: "Show Previews 2 at a Time", group: .view, defaults: [],
            menuPath: "View > Show Previews > 2 at a Time"),
        ShortcutCommandDefinition(
            id: .showPreviews1, label: "Show Previews 1 at a Time", group: .view, defaults: [],
            menuPath: "View > Show Previews > 1 at a Time"),
        // ⌘+ is pressed as ⌘= on most keyboards, so ⌘= is its other key.
        ShortcutCommandDefinition(
            id: .increaseSize, label: "Make Bigger", group: .view, defaults: ["Cmd+Plus", "Cmd+="],
            menuPath: "View > Make Bigger"),
        ShortcutCommandDefinition(
            id: .decreaseSize, label: "Make Smaller", group: .view, defaults: ["Cmd+-"],
            menuPath: "View > Make Smaller"),
        ShortcutCommandDefinition(
            id: .resetSize, label: "Default Size", group: .view, defaults: ["Cmd+0"], menuPath: "View > Default Size"),
        ShortcutCommandDefinition(
            id: .groupByNone, label: "Group by None", group: .view, defaults: [],
            menuPath: "View > Group By > None"),
        ShortcutCommandDefinition(
            id: .groupByName, label: "Group by Name", group: .view, defaults: [],
            menuPath: "View > Group By > Name"),
        ShortcutCommandDefinition(
            id: .groupByModified, label: "Group by Date Modified", group: .view, defaults: [],
            menuPath: "View > Group By > Date Modified"),
        ShortcutCommandDefinition(
            id: .groupByCreated, label: "Group by Date Created", group: .view, defaults: [],
            menuPath: "View > Group By > Date Created"),
        ShortcutCommandDefinition(
            id: .groupByLastOpened, label: "Group by Date Last Opened", group: .view, defaults: [],
            menuPath: "View > Group By > Date Last Opened"),
        ShortcutCommandDefinition(
            id: .groupByAdded, label: "Group by Date Added", group: .view, defaults: [],
            menuPath: "View > Group By > Date Added"),
        ShortcutCommandDefinition(
            id: .groupBySize, label: "Group by Size", group: .view, defaults: [],
            menuPath: "View > Group By > Size"),
        ShortcutCommandDefinition(
            id: .groupByKind, label: "Group by Kind", group: .view, defaults: [],
            menuPath: "View > Group By > Kind"),
        ShortcutCommandDefinition(
            id: .groupByTags, label: "Group by Tags", group: .view, defaults: [],
            menuPath: "View > Group By > Tags"),
        ShortcutCommandDefinition(
            id: .groupByFolder, label: "Group by Folder", group: .view, defaults: [],
            menuPath: "View > Group By > Folder"),
        ShortcutCommandDefinition(
            id: .reverseGroupOrder, label: "Reverse Group Order", group: .view, defaults: [],
            menuPath: "View > Group By > Reverse Group Order"),
        ShortcutCommandDefinition(
            id: .sortByName, label: "Sort by Name", group: .view, defaults: [], menuPath: "View > Sort By > Name"),
        ShortcutCommandDefinition(
            id: .sortByModified, label: "Sort by Date Modified", group: .view, defaults: [],
            menuPath: "View > Sort By > Date Modified"),
        ShortcutCommandDefinition(
            id: .sortByCreated, label: "Sort by Date Created", group: .view, defaults: [],
            menuPath: "View > Sort By > Date Created"),
        ShortcutCommandDefinition(
            id: .sortByLastOpened, label: "Sort by Date Last Opened", group: .view, defaults: [],
            menuPath: "View > Sort By > Date Last Opened"),
        ShortcutCommandDefinition(
            id: .sortByAdded, label: "Sort by Date Added", group: .view, defaults: [],
            menuPath: "View > Sort By > Date Added"),
        ShortcutCommandDefinition(
            id: .sortBySize, label: "Sort by Size", group: .view, defaults: [], menuPath: "View > Sort By > Size"),
        ShortcutCommandDefinition(
            id: .sortByKind, label: "Sort by Kind", group: .view, defaults: [], menuPath: "View > Sort By > Kind"),
        ShortcutCommandDefinition(
            id: .toggleFoldersFirst, label: "Folders First", group: .view, defaults: [],
            menuPath: "View > Folders First"),
        ShortcutCommandDefinition(
            id: .toggleHiddenFiles, label: "Hidden Files", group: .view, defaults: ["Cmd+Shift+."],
            menuPath: "View > Hidden Files"),
        ShortcutCommandDefinition(
            id: .showModifiedColumn, label: "Date Modified Column", group: .view, defaults: [],
            menuPath: "View > Columns > Date Modified"),
        ShortcutCommandDefinition(
            id: .showCreatedColumn, label: "Date Created Column", group: .view, defaults: [],
            menuPath: "View > Columns > Date Created"),
        ShortcutCommandDefinition(
            id: .showLastOpenedColumn, label: "Date Last Opened Column", group: .view, defaults: [],
            menuPath: "View > Columns > Date Last Opened"),
        ShortcutCommandDefinition(
            id: .showAddedColumn, label: "Date Added Column", group: .view, defaults: [],
            menuPath: "View > Columns > Date Added"),
        ShortcutCommandDefinition(
            id: .showSizeColumn, label: "Size Column", group: .view, defaults: [],
            menuPath: "View > Columns > Size"),
        ShortcutCommandDefinition(
            id: .showKindColumn, label: "Kind Column", group: .view, defaults: [],
            menuPath: "View > Columns > Kind"),
        ShortcutCommandDefinition(
            id: .showPermissionsColumn, label: "Permissions Column", group: .view, defaults: [],
            menuPath: "View > Columns > Permissions"),
        ShortcutCommandDefinition(
            id: .rememberFolderView, label: "Remember View for This Folder", group: .view, defaults: [],
            menuPath: "View > Folder View > Remember View for This Folder"),
        ShortcutCommandDefinition(
            id: .updateFolderView, label: "Update Folder View", group: .view, defaults: [],
            menuPath: "View > Folder View > Update Folder View"),
        ShortcutCommandDefinition(
            id: .revertFolderView, label: "Revert to Saved View", group: .view, defaults: [],
            menuPath: "View > Folder View > Revert to Saved View"),
        ShortcutCommandDefinition(
            id: .folderViewOptions, label: "Folder View Options…", group: .view, defaults: ["Cmd+J"],
            menuPath: "View > Folder View > Folder View Options…"),
        ShortcutCommandDefinition(
            id: .resetFolderView, label: "Reset Folder View", group: .view, defaults: [],
            menuPath: "View > Folder View > Reset Folder View"),
        ShortcutCommandDefinition(
            id: .manageFolderViews, label: "Manage Folder Views…", group: .view, defaults: [],
            menuPath: "View > Folder View > Manage Folder Views…"),
        ShortcutCommandDefinition(
            id: .togglePinFilter, label: "Pin Filter", group: .view, defaults: [], menuPath: "View > Pin Filter"),
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
            id: .showCommandPalette, label: "Command Palette…", group: .view, defaults: ["Cmd+Shift+P"],
            menuPath: "View > Command Palette…"),
        ShortcutCommandDefinition(
            id: .openHelp, label: "File Trail Help", group: .view, defaults: ["?"], menuPath: "Help > File Trail Help"),
        ShortcutCommandDefinition(
            id: .openKeyboardShortcuts, label: "Keyboard Shortcuts", group: .view, defaults: [],
            menuPath: "Help > Keyboard Shortcuts"),
        // The viewer's own keys, taken while it has the keyboard; its ⋯ menu shows them.
        ShortcutCommandDefinition(id: .saveViewerFile, label: "Save File", group: .viewer, defaults: ["Cmd+S"]),
        ShortcutCommandDefinition(
            id: .nextViewerFile, label: "Next File", group: .viewer, defaults: ["Cmd+Option+]"]),
        ShortcutCommandDefinition(
            id: .previousViewerFile, label: "Previous File", group: .viewer, defaults: ["Cmd+Option+["]),
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
