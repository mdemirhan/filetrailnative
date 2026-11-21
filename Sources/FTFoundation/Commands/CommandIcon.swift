/// The icon of a command, for the toolbar's buttons and the right-click menus; the app shows each as a system symbol.
/// The raw value is what the context-menu golden records.
public enum CommandIcon: String, CaseIterable, Sendable, Hashable {
    // Going places
    case back, forward, up, goTo, refresh, newTab
    // The folder on screen
    case icons, details, list, previews, sortBy, groupBy, viewAs, foldersFirst, hidden, viewOptions, search
    case folderView
    // The window's panes
    case folderTree, twoPanes, duplicatePane, infoPanel, infoRow
    // Opening and looking
    case open, openFile, openInNewTab, openInNewWindow, openWith, quickLook, showPackageContents, edit, showInfo
    case calculateSize, revealInFolder, revealInTree, rootTreeHere, showInFinder, terminal, showOriginal
    // Clipboard and organizing
    case cut, copy, paste, pasteAsFile, copyPath, copyContents, share, move, rename, duplicate, newFolder, newFile
    case removeFromClipboard
    case favorite
    case convertImages, makeAlias
    // Archives
    case compress, extract
    // Removing
    case trash, deleteImmediately, emptyTrash, eject
    // Undo
    case undo, redo, undoHistory
    // The app
    case theme, settings, help
}
