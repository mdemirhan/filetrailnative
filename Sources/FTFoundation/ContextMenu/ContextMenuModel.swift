// Port of apps/desktop/src/renderer/lib/contextMenu.ts
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
    case showPackageContents, edit, showInfo, calculateSize, cut, copy, paste, move, rename, duplicate, newFolder
    case viewAs, sortBy, toggleFavorite, terminal, showInFinder, copyPath, rootTreeHere, trash
    case deleteImmediately, emptyTrash, eject

    /// The items that open a submenu rather than act.
    public var isSubmenu: Bool { self == .openWith || self == .viewAs || self == .sortBy }
}

/// The 14 pt line icon of an item (`ContextMenuIconName`).
public enum ContextMenuIconName: String, Sendable, CaseIterable, Hashable {
    case revealInFolder, revealInTree, open, openFile, openInNewTab, openInNewWindow, openWith, quickLook
    case showPackageContents, edit, showInfo, calculateSize, cut, copy, paste, move, rename, duplicate, newFolder
    case viewAs, sortBy, terminal, showInFinder, copyPath, rootTreeHere, trash, deleteImmediately, emptyTrash
    case eject, favorite
}

public enum ContextMenuItem: Equatable, Sendable {
    case separator(key: String)
    case action(
        id: ContextMenuActionID, label: String, icon: ContextMenuIconName, destructive: Bool, hasSubmenu: Bool)

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

    public init(
        favoriteToggleLabel: String? = nil, textEditorName: String? = nil, targetsFolder: Bool = false,
        renameLabel: String? = nil, ejectLabel: String? = nil
    ) {
        self.favoriteToggleLabel = favoriteToggleLabel
        self.textEditorName = textEditorName
        self.targetsFolder = targetsFolder
        self.renameLabel = renameLabel
        self.ejectLabel = ejectLabel
    }
}

public enum ContextMenuItems {
    private static func item(
        _ id: ContextMenuActionID, _ label: String, _ icon: ContextMenuIconName, destructive: Bool = false,
        submenu: Bool = false
    ) -> ContextMenuItem {
        .action(id: id, label: label, icon: icon, destructive: destructive, hasSubmenu: submenu)
    }

    private static func line(_ key: String) -> ContextMenuItem { .separator(key: key) }

    /// `getContextMenuItems`.
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
                item(.rootTreeHere, "Use as Tree Root", .rootTreeHere), line("separator-tree-open"),
                item(.showInfo, "Show Info", .showInfo), item(.calculateSize, "Calculate Size", .calculateSize),
                line("separator-tree-info"),
                item(.cut, "Cut", .cut), item(.copy, "Copy", .copy),
                item(.paste, "Paste into Folder", .paste), item(.copyPath, "Copy Path", .copyPath),
                line("separator-tree-clipboard"),
                item(.rename, "Rename", .rename), item(.duplicate, "Duplicate", .duplicate),
                item(.move, "Move to…", .move), line("separator-tree-organize"),
                item(.toggleFavorite, favoriteToggleLabel, .favorite), line("separator-tree-favorite"),
                item(.terminal, "Open in Terminal", .terminal), item(.showInFinder, "Show in Finder", .showInFinder),
                line("separator-tree-apps"),
                item(.trash, "Move to Trash", .trash, destructive: true),
                item(.deleteImmediately, "Delete Immediately…", .deleteImmediately, destructive: true),
            ]
        case .background:
            return [
                item(.newFolder, "New Folder", .newFolder), line("separator-background-organize"),
                item(.showInfo, "Show Info", .showInfo), item(.calculateSize, "Calculate Size", .calculateSize),
                line("separator-background-info"),
                item(.paste, "Paste", .paste), item(.copyPath, "Copy Path", .copyPath),
                line("separator-background-clipboard"),
                item(.viewAs, "View As", .viewAs, submenu: true), item(.sortBy, "Sort By", .sortBy, submenu: true),
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
                item(.revealInTree, "Reveal in Tree", .revealInTree),
                item(.rootTreeHere, "Use as Tree Root", .rootTreeHere),
                // Only for a disk that can be ejected (hidden by the caller for the others).
                line("separator-favorite-eject"),
                item(.eject, options.ejectLabel ?? "Eject", .eject), line("separator-favorite-open"),
                item(.showInfo, "Show Info", .showInfo), item(.calculateSize, "Calculate Size", .calculateSize),
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
                item(.open, "Open", options.targetsFolder ? .open : .openFile),
                item(.openInNewTab, "Open in New Tab", .openInNewTab),
                item(.openInNewWindow, "Open in New Window", .openInNewWindow),
                item(.openWith, "Open With", .openWith, submenu: true),
                item(.quickLook, "Quick Look", .quickLook),
                item(.edit, "Edit in \(textEditorName)", .edit),
                item(.showPackageContents, "Show Package Contents", .showPackageContents),
                line("separator-open"),
                item(.showInfo, "Show Info", .showInfo),
                // For folders, or a selection with folders among it: hidden by the caller otherwise.
                item(.calculateSize, "Calculate Size", .calculateSize), line("separator-info"),
                item(.cut, "Cut", .cut), item(.copy, "Copy", .copy), item(.paste, "Paste into Folder", .paste),
                item(.copyPath, "Copy Path", .copyPath), line("separator-clipboard"),
                item(.rename, options.renameLabel ?? "Rename", .rename), item(.duplicate, "Duplicate", .duplicate),
                item(.move, "Move to…", .move), item(.newFolder, "New Folder", .newFolder),
                line("separator-organize"),
                item(.toggleFavorite, favoriteToggleLabel, .favorite), line("separator-favorite"),
                item(.terminal, "Open in Terminal", .terminal), item(.showInFinder, "Show in Finder", .showInFinder),
                line("separator-apps"),
                item(.trash, "Move to Trash", .trash, destructive: true),
            ]
        }
    }

    /// The items a menu shows: the hidden ones left out, and the separators that would stand first, last or twice in
    /// a row dropped (`ItemContextMenu`'s `items`).
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
