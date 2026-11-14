// What each command and key does while the folder tree has the keyboard.

/// What a command or key does while the folder tree has the keyboard.
public enum TreeFocusShortcutBucket: String, Sendable, Hashable {
    case treeNavigation, globalExplorer, contentOnly
}

extension ShortcutPolicy {
    /// What the command does while the folder tree has the keyboard.
    public static func treeFocusBucket(of command: AppCommand) -> TreeFocusShortcutBucket {
        switch command {
        case .undo, .redo, .editCut, .editCopy, .editPaste, .editSelectAll, .focusFileSearch, .openLocationSheet,
            .openSettings, .emptyTrash, .ejectVolume, .showClipboard, .clearClipboard, .refreshOrApplySearchSort,
            .toggleFolderTree, .toggleInfoPanel, .toggleInfoRow, .customizeToolbar, .goHomeRootTree, .goDocuments,
            .goDesktop, .goDownloads, .goLibrary, .goMacintoshHD, .goApplications, .goTrash, .rootTreeAtSelection,
            .newWindow, .newTab, .duplicateTab, .reopenClosedTab, .closeTab, .selectNextTab, .selectPreviousTab,
            .moveTabToNewWindow,
            .mergeAllWindows, .toggleTwoPanes, .switchToOtherPane, .openSelectionInOtherPane, .swapPanes,
            .showFolderInOtherPane, .goToOtherPaneFolder, .equalizePanes, .calculateSize, .toggleFavorite,
            .showInFinder,
            .showLastSearchResults, .viewAsIcons,
            .viewAsList, .viewAsDetails, .viewAsPreviews, .increaseSize, .decreaseSize, .resetSize, .sortByName,
            .sortByModified,
            .sortBySize, .sortByKind, .toggleFoldersFirst,
            .toggleHiddenFiles, .togglePinFilter, .goBack, .goForward, .goEnclosingFolder, .focusTreePane,
            .focusContentPane, .openHelp, .openKeyboardShortcuts:
            .globalExplorer
        case .openSelection, .editSelection, .openInTerminal, .moveSelection, .renameSelection, .duplicateSelection,
            .newFolder, .trashSelection, .copySelection, .cutSelection, .pasteSelection, .copyPath,
            .openSelectionInNewTab, .openSelectionInNewWindow, .quickLookSelection, .revealInFolder, .copyToOtherPane,
            .moveToOtherPane:
            .contentOnly
        }
    }
}

/// The explorer's raw key handlers that the right-click menus ask about for their shortcut badges. All of them act on
/// the file list's selection, so from the tree only the few that are safe there are handled.
public enum RawExplorerShortcutID: String, CaseIterable, Sendable, Hashable {
    case copySelection
    case cutSelection
    case pasteSelection
    case duplicateSelection
    case trashSelection
    case renameSelection
    case copyPath
    case moveSelection
    case newFolder
}
