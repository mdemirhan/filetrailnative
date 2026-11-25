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
            .openSettings, .emptyTrash, .ejectVolume, .pasteAsFile, .newTextFile, .openTemplatesFolder, .showClipboard,
            .clearClipboard, .addToCopied, .addToCut, .moveItemsHere, .removeFromClipboard,
            .refreshOrApplySearchSort, .toggleFolderTree, .toggleInfoPanel, .toggleInfoRow, .customizeToolbar,
            .goHomeRootTree, .goDocuments,
            .goDesktop, .goDownloads, .goLibrary, .goMacintoshHD, .goApplications, .goTrash, .rootTreeAtSelection,
            .newWindow, .newTab, .duplicateTab, .reopenClosedTab, .closePane, .closeTab, .selectNextTab,
            .selectPreviousTab,
            .moveTabToNewWindow,
            .mergeAllWindows, .saveTabView, .saveWindowView, .toggleTwoPanes, .duplicatePane, .switchToOtherPane,
            .openSelectionInOtherPane, .swapPanes,
            .showFolderInOtherPane, .goToOtherPaneFolder, .equalizePanes, .calculateSize, .toggleFavorite,
            .showInFinder,
            .showLastSearchResults, .advancedSearch, .clearSearchConditions, .viewAsIcons,
            .viewAsList, .viewAsDetails, .viewAsPreviews, .showPreviews9, .showPreviews4, .showPreviews2,
            .showPreviews1, .increaseSize, .decreaseSize, .resetSize, .zoomToFit, .goToPage, .groupByNone, .groupByName,
            .groupByModified,
            .groupByCreated, .groupByLastOpened, .groupByAdded, .groupBySize, .groupByKind, .groupByTags,
            .groupByFolder, .reverseGroupOrder, .sortByName, .sortByFolder,
            .sortByModified, .sortByCreated, .sortByAdded, .sortByLastOpened,
            .sortBySize, .sortByKind, .toggleFoldersFirst,
            .toggleHiddenFiles, .showFolderColumn, .showModifiedColumn, .showSizeColumn, .showKindColumn,
            .showCreatedColumn,
            .showAddedColumn, .showLastOpenedColumn, .showPermissionsColumn, .rememberFolderView, .updateFolderView,
            .revertFolderView, .folderViewOptions, .resetFolderView, .manageFolderViews, .togglePinFilter, .goBack,
            .goForward, .goEnclosingFolder, .focusTreePane,
            .focusContentPane, .openHelp, .openKeyboardShortcuts:
            .globalExplorer
        case .openSelection, .editSelection, .openInTerminal, .moveSelection, .renameSelection, .duplicateSelection,
            .makeAlias, .showOriginal,
            .convertImages, .newFolder, .newFolderWithSelection, .saveAsTemplate, .trashSelection, .deleteImmediately,
            .copySelection,
            .cutSelection,
            .pasteSelection, .copyPath,
            .copyContents, .shareSelection,
            .openSelectionInNewTab, .openSelectionInNewWindow, .quickLookSelection, .revealInFolder, .copyToOtherPane,
            .moveToOtherPane, .compressSelection, .extractSelection, .extractSelectionTo, .deselectAll,
            .invertSelection, .viewFile:
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
