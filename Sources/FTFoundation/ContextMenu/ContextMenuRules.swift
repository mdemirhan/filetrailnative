// Port of the menu visibility rules of apps/desktop/src/renderer/hooks/useExplorerActions.ts (lines 140-160, 520-730)
import Foundation

/// What a context menu is for, and what the window knows around it.
public struct ContextMenuSubject: Equatable, Sendable {
    public var surface: ContextMenuSurface
    public var scope: ContextMenuScope
    /// The right-clicked items (the selection they belong to), or the one folder of a tree row.
    public var paths: [String]
    /// The row's folder for the sidebar surfaces; the first right-clicked path for the file list.
    public var targetPath: String?
    /// The listing rows at `paths` (rows missing from the listing are left out, as `contextMenuTargetEntries`).
    public var entries: [CommandEntry]
    /// The name of the disk a favorite or location is, when it can be ejected; nil for any other folder.
    public var ejectableDiskName: String?

    public init(
        surface: ContextMenuSurface, scope: ContextMenuScope = .selection, paths: [String] = [],
        targetPath: String? = nil, entries: [CommandEntry] = [], ejectableDiskName: String? = nil
    ) {
        self.ejectableDiskName = ejectableDiskName
        self.surface = surface
        self.scope = scope
        self.paths = paths
        self.targetPath = targetPath
        self.entries = entries
    }
}

/// The window's state the rules look at.
public struct ContextMenuWorld: Equatable, Sendable {
    public var homePath: String
    public var currentPath: String
    public var isSearchMode: Bool
    /// The paths that are favorites.
    public var favoritePaths: [String]
    /// The Trash has nothing to empty (nil: it can't be told).
    public var trashIsEmpty: Bool?
    /// A file operation is running (`isWriteOperationLocked`).
    public var writeLocked: Bool
    /// What is on the clipboard can be pasted at the destination (`canPasteAtResolvedDestination`).
    public var canPaste: Bool
    /// Where Paste would go for an item's menu (`pasteDestinationPath`), nil when nowhere.
    public var hasPasteDestination: Bool

    public init(
        homePath: String, currentPath: String = "", isSearchMode: Bool = false, favoritePaths: [String] = [],
        trashIsEmpty: Bool? = nil, writeLocked: Bool = false, canPaste: Bool = false, hasPasteDestination: Bool = false
    ) {
        self.homePath = homePath
        self.currentPath = currentPath
        self.isSearchMode = isSearchMode
        self.favoritePaths = favoritePaths
        self.trashIsEmpty = trashIsEmpty
        self.writeLocked = writeLocked
        self.canPaste = canPaste
        self.hasPasteDestination = hasPasteDestination
    }
}

public enum ContextMenuRules {
    /// What a running file operation blocks, in every tab: anything that would start another. Copy, Cut and Copy Path
    /// only fill a clipboard, so they stay available.
    public static let writeLockedActions: [ContextMenuActionID] = [
        .paste, .move, .rename, .duplicate, .newFolder, .trash, .deleteImmediately, .emptyTrash,
    ]

    /// What the menus leave out in the Trash: nothing is pasted, made or duplicated there, and what is in it is in
    /// the Trash already (Delete Immediately is offered instead).
    public static let trashHiddenActions: [ContextMenuActionID] = [.paste, .newFolder, .duplicate, .trash]

    /// Background-menu actions that act on the folder on screen rather than on a selection.
    public static let backgroundFolderActions: [ContextMenuActionID] = [
        .showInfo, .calculateSize, .copyPath, .terminal, .showInFinder,
    ]

    private static func trashPath(_ world: ContextMenuWorld) -> String {
        FavoriteLabel.trashPath(homePath: world.homePath)
    }

    private static func isFavorite(_ path: String, _ world: ContextMenuWorld) -> Bool {
        world.favoritePaths.contains { JSString.equals($0, path) }
    }

    /// `contextMenuFavoriteToggleLabel`: nil hides the item.
    public static func favoriteToggleLabel(_ subject: ContextMenuSubject, _ world: ContextMenuWorld) -> String? {
        if world.isSearchMode { return nil }
        if subject.scope != .selection || subject.paths.count != 1 { return nil }
        guard let target = subject.targetPath, !target.isEmpty else { return nil }
        let remove = "Remove from Favorites"
        let add = "Add to Favorites"
        // The Trash is always under Locations: a Trash favorite can be taken out, and none put in.
        if JSString.equals(target, trashPath(world)) {
            return isFavorite(target, world) ? remove : nil
        }
        if subject.surface == .favorite {
            return isFavorite(target, world) ? remove : add
        }
        if subject.surface != .content && subject.surface != .treeFolder { return nil }
        if subject.surface == .content, !(subject.entries.first?.kind.isDirectoryLike ?? false) { return nil }
        return isFavorite(target, world) ? remove : add
    }

    /// `contextMenuOptions`, for the labels that depend on the items.
    public static func options(
        _ subject: ContextMenuSubject, _ world: ContextMenuWorld, textEditorName: String?, ejectLabel: String? = nil
    ) -> ContextMenuOptions {
        ContextMenuOptions(
            favoriteToggleLabel: favoriteToggleLabel(subject, world), textEditorName: textEditorName,
            targetsFolder: !subject.entries.isEmpty && subject.entries.allSatisfy { $0.kind.isDirectoryLike },
            // Several items are renamed in the Rename sheet, as Finder's Rename does.
            renameLabel: subject.entries.count > 1 ? "Rename \(groupedCount(subject.entries.count)) Items…" : nil,
            ejectLabel: subject.ejectableDiskName.map { "Eject “\($0)”" } ?? ejectLabel)
    }

    /// `Number.prototype.toLocaleString()` for a count.
    static func groupedCount(_ count: Int) -> String {
        count.formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_US")))
    }

    /// `resolveDuplicateFolder`: the one folder the paths are in, nil when they are in several.
    public static func duplicateFolder(of paths: [String]) -> String? {
        var folders = Set<[UInt8]>()
        var first: String?
        for path in paths {
            let folder = CommandAvailability.parentDirectoryPath(path) ?? path
            if folders.insert(Array(folder.utf8)).inserted, first == nil { first = folder }
        }
        return folders.count == 1 ? first : nil
    }

    /// `contextMenuHiddenActionIds`: a right-click menu lists only what can be done to its items, there and then, as
    /// Apple asks of context menus and Finder does; anything else is left out rather than dimmed.
    public static func hiddenActions(_ subject: ContextMenuSubject, _ world: ContextMenuWorld) -> Set<
        ContextMenuActionID
    > {
        var hidden = Set<ContextMenuActionID>()
        let surface = subject.surface
        let entries = subject.entries
        let isItemListSurface = surface == .content || surface == .search || surface == .trash
        // Nothing in the Trash to empty.
        if world.trashIsEmpty == true { hidden.insert(.emptyTrash) }
        // One file operation at a time: while one runs, the others are left out.
        if world.writeLocked {
            for action in writeLockedActions where action != .paste { hidden.insert(action) }
        }
        if favoriteToggleLabel(subject, world) == nil { hidden.insert(.toggleFavorite) }
        // Eject is for a disk that can be ejected.
        if subject.ejectableDiskName == nil { hidden.insert(.eject) }
        let isTreeSurface = surface == .treeFolder || surface == .favorite
        let isSingleFolder = entries.count == 1 && (entries.first?.kind.isDirectoryLike ?? false)
        // In the file list and search results a new tab opens on one folder.
        if !isTreeSurface && (surface == .trash || !isSingleFolder) {
            hidden.insert(.openInNewTab)
            hidden.insert(.openInNewWindow)
        }
        // An item's Paste goes into it, so it is there only for one folder it can paste into: not one that is itself
        // on the clipboard, nor one in search results, where nothing is pasted. The folder on screen has its own,
        // in the menu of the background.
        if (surface == .content || surface == .search) && (!isSingleFolder || !world.hasPasteDestination) {
            hidden.insert(.paste)
        }
        // Edit is for text files.
        if entries.isEmpty || entries.count != subject.paths.count || !entries.allSatisfy({ $0.kind.isEditableFile }) {
            hidden.insert(.edit)
        }
        if isItemListSurface {
            // "Show Package Contents" is for packages (.app, .framework and the like).
            if !entries.contains(where: { $0.kind == .bundle }) { hidden.insert(.showPackageContents) }
            // For folders and packages: one, or a selection with any among it (files have a size).
            if !entries.contains(where: { $0.kind.isFolderSizeEligible }) { hidden.insert(.calculateSize) }
        }
        let inTrash = { (path: String) in Paths.isInsideTrash(path, homePath: world.homePath) }
        switch surface {
        case .trash:
            // In the Trash things are only taken out or deleted for good: nothing is pasted, made or duplicated
            // there, and what is there is in the Trash already.
            hidden.formUnion(trashHiddenActions)
            return hidden
        case .favorite:
            if !JSString.equals(subject.targetPath ?? "", trashPath(world)) {
                hidden.insert(.emptyTrash)
            } else {
                hidden.insert(.paste)
                hidden.insert(.newFolder)
            }
            return hidden
        case .background:
            // Nothing is pasted into or created in the Trash; it can be emptied from there.
            if inTrash(world.currentPath) {
                hidden.insert(.paste)
                hidden.insert(.newFolder)
            } else {
                hidden.insert(.emptyTrash)
            }
            return hidden
        case .treeFolder:
            // Everything goes to the Trash; only what is already in it can be deleted for good.
            guard let target = subject.targetPath, !target.isEmpty, inTrash(target) else {
                hidden.insert(.deleteImmediately)
                return hidden
            }
            hidden.formUnion(trashHiddenActions)
            // The Trash itself is the home folder's: it isn't deleted, only emptied, and it stays where it is, under
            // its name (the main process refuses too).
            if JSString.equals(target, trashPath(world)) {
                hidden.formUnion([.deleteImmediately, .cut, .move, .rename])
            }
            return hidden
        case .search:
            hidden.insert(.toggleFavorite)
            // New Folder goes into the folder on screen, and search results show none.
            hidden.insert(.newFolder)
            // A duplicate goes next to its original: several results from different folders have no one folder for
            // theirs.
            if duplicateFolder(of: subject.paths) == nil { hidden.insert(.duplicate) }
        case .content:
            break
        }
        // An item's New Folder makes the folder inside it, as its Paste pastes there.
        if !isSingleFolder { hidden.insert(.newFolder) }
        return hidden
    }

    /// `resolvePasteDestinationPath` for an open menu: where Paste would go, nil when nowhere. A folder's own menu
    /// pastes into it, the background's into the folder on screen, an item's only when it is the one folder picked and
    /// not itself on the clipboard. Nothing is pasted into the Trash.
    public static func pasteDestination(
        _ subject: ContextMenuSubject, _ world: ContextMenuWorld, clipboardSourcePaths: [String]
    ) -> String? {
        if world.isSearchMode { return nil }
        let currentFolder = world.currentPath.isEmpty ? nil : world.currentPath
        let destination: String?
        if subject.surface == .treeFolder || subject.surface == .favorite {
            destination = subject.targetPath
        } else if subject.paths.isEmpty {
            // The background's menu pastes into the folder on screen.
            destination = currentFolder
        } else if subject.paths.count == 1, let entry = subject.entries.first, entry.kind.isDirectoryLike,
            !clipboardSourcePaths.contains(where: { JSString.equals($0, entry.path) })
        {
            destination = entry.path
        } else {
            destination = nil
        }
        guard let destination, !Paths.isInsideTrash(destination, homePath: world.homePath) else { return nil }
        return destination
    }

    /// `contextMenuDisabledActionIds`: only Paste is ever dimmed, with nothing to paste or while a file operation
    /// runs.
    public static func disabledActions(_ world: ContextMenuWorld) -> Set<ContextMenuActionID> {
        !world.canPaste || world.writeLocked ? [.paste] : []
    }
}
