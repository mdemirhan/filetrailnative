// Generated from apps/desktop/src/renderer/lib/shortcutPolicy.ts (the tree-focus bucket tables) by tools/parity; the zoom commands are left out (DEVIATIONS D-005).

/// What a command or key does while the folder tree has the keyboard.
public enum TreeFocusShortcutBucket: String, Sendable, Hashable {
    case treeNavigation, globalExplorer, contentOnly
}

extension ShortcutPolicy {
    /// RENDERER_COMMAND_TREE_FOCUS_BUCKETS.
    public static func treeFocusBucket(of command: RendererCommand) -> TreeFocusShortcutBucket {
        switch command {
        case .undo, .redo, .editCut, .editCopy, .editPaste, .editSelectAll, .focusFileSearch, .openLocationSheet,
            .openSettings, .emptyTrash, .ejectVolume, .showClipboard, .clearClipboard, .refreshOrApplySearchSort,
            .toggleFolderTree, .toggleInfoPanel, .toggleInfoRow, .customizeToolbar, .goHomeRootTree, .goDocuments,
            .goDesktop, .goDownloads, .goLibrary, .goMacintoshHD, .goApplications, .goTrash, .rootTreeAtSelection,
            .newWindow, .newTab, .duplicateTab, .reopenClosedTab, .closeTab, .selectNextTab, .selectPreviousTab,
            .moveTabToNewWindow,
            .mergeAllWindows, .calculateSize, .toggleFavorite, .showInFinder, .showLastSearchResults, .viewAsIcons,
            .viewAsList, .viewAsDetails, .sortByName, .sortByModified, .sortBySize, .sortByKind, .toggleFoldersFirst,
            .toggleHiddenFiles, .goBack, .goForward, .goEnclosingFolder, .focusTreePane, .focusContentPane, .openHelp,
            .openKeyboardShortcuts:
            .globalExplorer
        case .openSelection, .editSelection, .openInTerminal, .moveSelection, .renameSelection, .duplicateSelection,
            .newFolder, .trashSelection, .copySelection, .cutSelection, .pasteSelection, .copyPath,
            .openSelectionInNewTab, .openSelectionInNewWindow, .quickLookSelection, .revealInFolder:
            .contentOnly
        }
    }
}

/// The explorer's raw key handlers (`RAW_EXPLORER_SHORTCUT_IDS`).
public enum RawExplorerShortcutID: String, CaseIterable, Sendable, Hashable {
    case paneTabSwitch
    case copySelection
    case cutSelection
    case pasteSelection
    case duplicateSelection
    case trashSelection
    case renameSelection
    case selectAllContent
    case focusTreePane
    case focusContentPane
    case showCachedSearchResults
    case focusFileSearch
    case historyBack
    case historyForward
    case openParentTree
    case openParentContent
    case openSelectedContentWithCommand
    case openTreeNodeWithCommand
    case toggleHiddenFiles
    case refreshOrApplySearchSort
    case copyPath
    case openInTerminal
    case moveSelection
    case newFolder
    case openLocationSheet
    case toggleInfoRow
    case toggleFolderTree
    case toggleInfoPanel
    case goHomeRootTree
    case rootTreeAtSelection
    case newTab
    case reopenClosedTab
    case closeTab
    case selectNextTab
    case selectPreviousTab
    case pageBackward
    case pageForward
    case halfPageBackward
    case halfPageForward
    case pagedSelectionExtend
    case listFilterEdit
    case typeahead
    case treeArrowNavigation
    case contentArrowNavigation
    case treeEnter
    case contentEnter
    case quickLook
}

extension ShortcutPolicy {
    /// RAW_EXPLORER_SHORTCUT_TREE_FOCUS_BUCKETS.
    public static func treeFocusBucket(of shortcut: RawExplorerShortcutID) -> TreeFocusShortcutBucket {
        switch shortcut {
        case .paneTabSwitch, .focusTreePane, .focusContentPane, .openParentTree, .openTreeNodeWithCommand,
            .pageBackward, .pageForward, .halfPageBackward, .halfPageForward, .pagedSelectionExtend, .typeahead,
            .treeArrowNavigation, .treeEnter:
            .treeNavigation
        case .copySelection, .cutSelection, .pasteSelection, .duplicateSelection, .trashSelection, .renameSelection,
            .selectAllContent, .openParentContent, .openSelectedContentWithCommand, .copyPath, .openInTerminal,
            .moveSelection, .newFolder, .listFilterEdit, .contentArrowNavigation, .contentEnter, .quickLook:
            .contentOnly
        case .showCachedSearchResults, .focusFileSearch, .historyBack, .historyForward, .toggleHiddenFiles,
            .refreshOrApplySearchSort, .openLocationSheet, .toggleInfoRow, .toggleFolderTree, .toggleInfoPanel,
            .goHomeRootTree, .rootTreeAtSelection, .newTab, .reopenClosedTab, .closeTab, .selectNextTab,
            .selectPreviousTab:
            .globalExplorer
        }
    }
}
