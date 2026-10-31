// Generated once from apps/desktop/src/shared/rendererCommands.ts (RENDERER_COMMAND_TYPES) in the Electron app; now edited by hand.

/// The commands the application menu, the toolbar and the keys send to the explorer window. The raw value is the original's command name.
public enum RendererCommand: String, CaseIterable, Sendable, Hashable, Codable {
    case undo
    case redo
    case editCut
    case editCopy
    case editPaste
    case editSelectAll
    case focusFileSearch
    case openSelection
    case editSelection
    case openLocationSheet
    case openSettings
    case openInTerminal
    case moveSelection
    case renameSelection
    case duplicateSelection
    case newFolder
    case trashSelection
    case emptyTrash
    case ejectVolume
    case copySelection
    case cutSelection
    case pasteSelection
    case copyPath
    case showClipboard
    case clearClipboard
    case refreshOrApplySearchSort
    case toggleFolderTree
    case toggleInfoPanel
    case toggleInfoRow
    case customizeToolbar
    case goHomeRootTree
    case goDocuments
    case goDesktop
    case goDownloads
    case goLibrary
    case goMacintoshHD
    case goApplications
    case goTrash
    case rootTreeAtSelection
    case newWindow
    case newTab
    case reopenClosedTab
    /// Not a command of the original, whose Duplicate Tab is in the tab strip's menu only (DEVIATIONS D-001).
    case duplicateTab
    case closeTab
    case selectNextTab
    case selectPreviousTab
    case openSelectionInNewTab
    case openSelectionInNewWindow
    case moveTabToNewWindow
    case mergeAllWindows
    case quickLookSelection
    case calculateSize
    case revealInFolder
    case toggleFavorite
    case showInFinder
    case showLastSearchResults
    case viewAsIcons
    case viewAsList
    case viewAsDetails
    case sortByName
    case sortByModified
    case sortBySize
    case sortByKind
    case toggleFoldersFirst
    case toggleHiddenFiles
    case goBack
    case goForward
    case goEnclosingFolder
    case focusTreePane
    case focusContentPane
    case openHelp
    case openKeyboardShortcuts

    /// Whether `value` names a command (`isRendererCommandType`).
    public static func isRendererCommandType(_ value: String) -> Bool {
        RendererCommand(rawValue: value) != nil
    }
}
