/// The icon of a command, for the toolbar's buttons and the right-click menus; the app shows each as a system symbol.
/// The raw value is what the context-menu golden records.
public enum CommandIcon: String, CaseIterable, Sendable, Hashable {
    // Going places
    case back, forward, up, goTo, refresh, newTab
    // The folder on screen
    case icons, details, list, previews, sortBy, viewAs, foldersFirst, hidden, hiddenShown, viewOptions, search
    // The window's panes
    case folderTree, twoPanes, infoPanel, infoRow
    // Opening and looking
    case open, openFile, openInNewTab, openInNewWindow, openWith, quickLook, showPackageContents, edit, showInfo
    case calculateSize, revealInFolder, revealInTree, rootTreeHere, showInFinder, terminal
    // Clipboard and organizing
    case cut, copy, paste, pasteAsFile, copyPath, copyContents, move, rename, duplicate, newFolder, favorite
    // Archives
    case compress, extract
    // Removing
    case trash, deleteImmediately, emptyTrash, eject
    // Undo
    case undo, redo, undoHistory
    // The app
    case theme, settings, help
}
