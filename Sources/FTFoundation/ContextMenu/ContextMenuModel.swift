import Foundation

/// Which menu: "background" is the empty space of the file list, whose menu acts on the folder on screen.
public enum ContextMenuSurface: String, Sendable, CaseIterable, Codable {
    case content, search, treeFolder, favorite, trash, background
}

/// Whether the menu is for the items under the pointer or for the folder on screen.
public enum ContextMenuScope: String, Sendable, Codable {
    case selection, background
}

public enum ContextMenuActionID: String, Sendable, CaseIterable, Hashable, Codable {
    case revealInFolder, revealInTree, open, openInNewTab, openInNewWindow, openWith, quickLook
    /// One file's text in its pane (Open in Viewer).
    case openInViewer
    case showPackageContents, edit, showInfo, calculateSize, cut, copy, paste, pasteAsFile, move, rename, duplicate
    /// An alias of each item beside it; and a symbolic link's or an alias's original, selected in its folder.
    case makeAlias, showOriginal
    case newFolder, newFolderWithSelection, saveAsTemplate, compress, extract, extractTo
    /// File ▸ New File's submenu, on the folder's background: Text File, the templates, the Templates folder.
    case newFile
    case convertImages
    case viewAs, sortBy, toggleFavorite, terminal, showInFinder, copyPath, copyContents, rootTreeHere, trash
    /// The system's share popover for the items: AirDrop, Mail, Messages and the rest macOS offers.
    case share
    /// The Tags popover for the items, under the row of tag colors.
    case tags
    case deleteImmediately, emptyTrash, eject
    /// The submenu of what can be done with the tab's other pane, while it shows two.
    case otherPane
    /// A folder of the tree or the favorites shown in the other pane: the one thing its menu does there.
    case openInOtherPane
    /// View ▸ Folder View's submenu, on the folder's background.
    case folderView
    /// View ▸ Group By's submenu, on the folder's background.
    case groupBy
    /// What is right-clicked joins what is on the clipboard, to be copied or moved.
    case addToCopied, addToCut
    /// What is right-clicked, all on the clipboard with one intent, is pasted with the other from now on.
    case switchClipboardMode
    case removeFromClipboard

    /// The items that open a submenu rather than act.
    public var isSubmenu: Bool {
        self == .openWith || self == .viewAs || self == .sortBy || self == .otherPane || self == .newFile
            || self == .folderView || self == .groupBy
    }
}

public enum ContextMenuItem: Equatable, Sendable {
    case separator(key: String)
    case action(
        id: ContextMenuActionID, label: String, icon: CommandIcon, destructive: Bool, hasSubmenu: Bool)

    public var actionID: ContextMenuActionID? {
        if case .action(let id, _, _, _, _) = self { return id }
        return nil
    }

    public var label: String? {
        if case .action(_, let label, _, _, _) = self { return label }
        return nil
    }
}

/// What a menu says about the items it is for (`ContextMenuOptions`).
public struct ContextMenuOptions: Equatable, Sendable {
    public var favoriteToggleLabel: String?
    /// The app Edit opens files in, which its label names, as the menu bar's Edit does.
    public var textEditorName: String?
    /// The menu is for folders: Open shows a folder, and Paste goes into the folder.
    public var targetsFolder: Bool
    /// Rename's label when it isn't plain "Rename": "Rename 3 Items…" for several.
    public var renameLabel: String?
    /// Eject's label, naming the disk as Finder does.
    public var ejectLabel: String?
    /// Paste as File's label, naming what it would write: "Paste Image as File".
    public var pasteAsFileLabel: String?
    /// Copy Contents' label, naming what it would copy: "Copy Image".
    public var copyContentsLabel: String?
    /// Compress's label, naming what it makes a zip of: Compress “Photos”, Compress 3 Items.
    public var compressLabel: String?
    /// Convert Images' label, counting what it would convert: "Convert 3 Images…".
    public var convertImagesLabel: String?
    /// The intent the right-clicked items on the clipboard have now: Copy Instead of Moving for cut ones, Move Instead
    /// of Copying for copied ones.
    public var clipboardModeOfItems: ClipboardMode?

    public init(
        favoriteToggleLabel: String? = nil, textEditorName: String? = nil, targetsFolder: Bool = false,
        renameLabel: String? = nil, ejectLabel: String? = nil, pasteAsFileLabel: String? = nil,
        copyContentsLabel: String? = nil, compressLabel: String? = nil, convertImagesLabel: String? = nil,
        clipboardModeOfItems: ClipboardMode? = nil
    ) {
        self.clipboardModeOfItems = clipboardModeOfItems
        self.favoriteToggleLabel = favoriteToggleLabel
        self.textEditorName = textEditorName
        self.targetsFolder = targetsFolder
        self.renameLabel = renameLabel
        self.ejectLabel = ejectLabel
        self.pasteAsFileLabel = pasteAsFileLabel
        self.copyContentsLabel = copyContentsLabel
        self.compressLabel = compressLabel
        self.convertImagesLabel = convertImagesLabel
    }
}

public enum ContextMenuItems {
    private static func item(
        _ id: ContextMenuActionID, _ label: String, _ icon: CommandIcon, destructive: Bool = false,
        submenu: Bool = false
    ) -> ContextMenuItem {
        .action(id: id, label: label, icon: icon, destructive: destructive, hasSubmenu: submenu)
    }

    private static func line(_ key: String) -> ContextMenuItem { .separator(key: key) }

    public static func items(surface: ContextMenuSurface, options: ContextMenuOptions = .init()) -> [ContextMenuItem] {
        let favoriteToggleLabel = options.favoriteToggleLabel ?? "Add to Favorites"
        let textEditorName = options.textEditorName ?? "Text Editor"

        switch surface {
        case .search:
            return [item(.revealInFolder, "Reveal in Folder", .revealInFolder), line("separator-reveal")]
                + items(surface: .content, options: options)
        case .trash:
            return items(surface: .content, options: options)
                + [item(.deleteImmediately, "Delete Immediately…", .deleteImmediately, destructive: true)]
        case .treeFolder:
            // A folder's menu in the tree or the favorites starts with New Folder, as the menu of a window's
            // background does; clicking the folder already opens it.
            return [
                item(.newFolder, "New Folder", .newFolder), line("separator-tree-new"),
                item(.openInNewTab, "Open in New Tab", .openInNewTab),
                item(.openInNewWindow, "Open in New Window", .openInNewWindow),
                item(.openInOtherPane, "Open in Other Pane", .twoPanes),
                item(.rootTreeHere, "Use as Tree Root", .rootTreeHere), line("separator-tree-open"),
                item(.showInfo, "Get Info", .showInfo), item(.calculateSize, "Calculate Size", .calculateSize),
                line("separator-tree-info"),
                item(.cut, "Cut", .cut), item(.copy, "Copy", .copy),
            ] + clipboardItems(options) + [
                item(.paste, "Paste into Folder", .paste), item(.copyPath, "Copy Path", .copyPath),
                line("separator-tree-clipboard"),
                item(.rename, "Rename", .rename), item(.duplicate, "Duplicate", .duplicate),
                item(.makeAlias, MakeAlias.commandLabel, .makeAlias),
                item(.move, "Move to…", .move), line("separator-tree-organize"),
                item(.toggleFavorite, favoriteToggleLabel, .favorite),
                item(.terminal, "Open in Terminal", .terminal), item(.showInFinder, "Show in Finder", .showInFinder),
                line("separator-tree-apps"),
                item(.trash, "Move to Trash", .trash, destructive: true),
                item(.deleteImmediately, "Delete Immediately…", .deleteImmediately, destructive: true),
            ]
        case .background:
            return [
                item(.newFolder, "New Folder", .newFolder), item(.newFile, "New File", .newFile, submenu: true),
                line("separator-background-organize"),
                item(.showInfo, "Get Info", .showInfo), item(.calculateSize, "Calculate Size", .calculateSize),
                line("separator-background-info"),
                item(.paste, "Paste", .paste),
                // Only with an image or text on the system's clipboard (hidden by the caller otherwise).
                item(.pasteAsFile, options.pasteAsFileLabel ?? PasteAsFile.commandLabel, .pasteAsFile),
                item(.copyPath, "Copy Path", .copyPath), line("separator-background-clipboard"),
                item(.viewAs, "View As", .viewAs, submenu: true),
                item(.groupBy, "Group By", .groupBy, submenu: true), item(.sortBy, "Sort By", .sortBy, submenu: true),
                item(.folderView, "Folder View", .folderView, submenu: true),
                item(.otherPane, "Other Pane", .twoPanes, submenu: true),
                line("separator-background-view"),
                item(.terminal, "Open in Terminal", .terminal), item(.showInFinder, "Show in Finder", .showInFinder),
                // Only in the Trash (the others are hidden by the caller).
                line("separator-background-trash"),
                item(.emptyTrash, "Empty Trash…", .emptyTrash, destructive: true),
            ]
        case .favorite:
            return [
                item(.newFolder, "New Folder", .newFolder), line("separator-favorite-new"),
                item(.openInNewTab, "Open in New Tab", .openInNewTab),
                item(.openInNewWindow, "Open in New Window", .openInNewWindow),
                item(.openInOtherPane, "Open in Other Pane", .twoPanes),
                item(.revealInTree, "Reveal in Tree", .revealInTree),
                item(.rootTreeHere, "Use as Tree Root", .rootTreeHere),
                // Only for a disk that can be ejected (hidden by the caller for the others).
                line("separator-favorite-eject"),
                item(.eject, options.ejectLabel ?? "Eject", .eject), line("separator-favorite-open"),
                item(.showInfo, "Get Info", .showInfo), item(.calculateSize, "Calculate Size", .calculateSize),
                line("separator-favorite-info"),
                item(.paste, "Paste into Folder", .paste), item(.copyPath, "Copy Path", .copyPath),
                line("separator-favorite-clipboard"),
                item(.toggleFavorite, favoriteToggleLabel, .favorite), line("separator-favorite-toggle"),
                item(.terminal, "Open in Terminal", .terminal), item(.showInFinder, "Show in Finder", .showInFinder),
                // Only for the Trash favorite (hidden by the caller for the others).
                line("separator-favorite-trash"),
                item(.emptyTrash, "Empty Trash…", .emptyTrash, destructive: true),
            ]
        case .content:
            return [
                // Open and Open With come first, as in Finder; then the other places the item can open.
                item(.open, "Open", options.targetsFolder ? .open : .openFile),
                item(.openWith, "Open With", .openWith, submenu: true),
                // For one file (hidden by the caller otherwise).
                item(.openInViewer, "Open in Viewer", .openFile),
                item(.openInNewTab, "Open in New Tab", .openInNewTab),
                item(.openInNewWindow, "Open in New Window", .openInNewWindow),
                // With two panes the submenu, with one the item that opens the second (hidden by the caller).
                item(.otherPane, "Other Pane", .twoPanes, submenu: true),
                item(.openInOtherPane, "Open in Other Pane", .twoPanes),
                item(.quickLook, "Quick Look", .quickLook),
                // For one symbolic link or alias (hidden by the caller otherwise).
                item(.showOriginal, MakeAlias.showOriginalLabel, .showOriginal),
                item(.edit, "Edit in \(MenuName.shortened(textEditorName))", .edit),
                item(.showPackageContents, "Show Package Contents", .showPackageContents),
                line("separator-open"),
                item(.showInfo, "Get Info", .showInfo),
                // For folders, or a selection with folders among it: hidden by the caller otherwise.
                item(.calculateSize, "Calculate Size", .calculateSize), line("separator-info"),
                item(.cut, "Cut", .cut), item(.copy, "Copy", .copy),
            ] + clipboardItems(options) + [
                item(.paste, "Paste into Folder", .paste), item(.copyPath, "Copy Path", .copyPath),
                // For one image or text file (hidden by the caller otherwise).
                item(.copyContents, options.copyContentsLabel ?? CopyContents.commandLabel, .copyContents),
                line("separator-clipboard"),
                item(.rename, options.renameLabel ?? "Rename", .rename), item(.duplicate, "Duplicate", .duplicate),
                item(.makeAlias, MakeAlias.commandLabel, .makeAlias),
                item(.move, "Move to…", .move), item(.newFolder, "New Folder", .newFolder),
                item(.newFolderWithSelection, "New Folder with Selection", .newFolder),
                line("separator-rename"),
                // What makes new files from the items. Compress for any items of one folder; Extract and Extract To
                // for archives; Convert Images for images only, every one of them (hidden by the caller otherwise).
                item(.compress, options.compressLabel ?? "Compress", .compress),
                item(.extract, "Extract", .extract), item(.extractTo, "Extract To…", .extract),
                item(.convertImages, options.convertImagesLabel ?? ConvertImagesText.commandLabel, .convertImages),
                line("separator-organize"),
                // Under the row of tag colors, which the menu puts before it; for items of a folder or of search
                // results (hidden by the caller otherwise).
                item(.tags, "Tags…", .tags),
                line("separator-tags"),
                // What hands the items to something else, leaving them as they are, as the File menu has it. Share is
                // not for what is in the Trash; Save as Template for files only (hidden by the caller otherwise).
                item(.share, "Share…", .share),
                item(.saveAsTemplate, "Save as Template", .newFile),
                item(.toggleFavorite, favoriteToggleLabel, .favorite),
                item(.terminal, "Open in Terminal", .terminal), item(.showInFinder, "Show in Finder", .showInFinder),
                line("separator-apps"),
                item(.trash, "Move to Trash", .trash, destructive: true),
            ]
        }
    }

    /// After Cut and Copy: the Adds for items not on the clipboard, and for those on it the other intent and Remove
    /// (the rules leave out the ones that don't apply).
    private static func clipboardItems(_ options: ContextMenuOptions) -> [ContextMenuItem] {
        [
            item(.addToCut, "Add to Cut Items", .cut), item(.addToCopied, "Add to Copied Items", .copy),
            item(
                .switchClipboardMode, ClipboardTexts.switchModeTitle(from: options.clipboardModeOfItems ?? .cut),
                options.clipboardModeOfItems == .copy ? .cut : .copy),
            item(.removeFromClipboard, ClipboardTexts.removeFromClipboardTitle, .removeFromClipboard),
        ]
    }

    /// The items a menu shows: the hidden ones left out, and the separators that would stand first, last or twice in
    /// a row dropped.
    public static func visibleItems(
        surface: ContextMenuSurface, options: ContextMenuOptions = .init(), hidden: Set<ContextMenuActionID> = []
    ) -> [ContextMenuItem] {
        var compacted: [ContextMenuItem] = []
        var previousWasSeparator = true
        for item in items(surface: surface, options: options) {
            switch item {
            case .separator:
                if previousWasSeparator { continue }
                compacted.append(item)
                previousWasSeparator = true
            case .action(let id, _, _, _, _):
                if hidden.contains(id) { continue }
                compacted.append(item)
                previousWasSeparator = false
            }
        }
        if case .separator = compacted.last { compacted.removeLast() }
        return compacted
    }
}
