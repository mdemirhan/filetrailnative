// What the explorer window asks of its sidebar: the state a tab keeps, the folders it opens, and the commands
import AppKit
import FTFileSystem
import FTFoundation

extension SidebarViewController {
    // MARK: What a tab keeps

    var treeRootPath: String { model.rootPath }

    /// The favorite the tab was opened on, if its favorite row is the selection.
    var favoritePath: String? { model.selected?.favoritePath }

    var selectedTreeItemID: String? { model.selected?.rawValue }

    var leftPaneSubview: SidebarSubview { model.subview }

    var favoritesExpanded: Bool { model.favoritesExpanded }

    var locationsExpanded: Bool { model.locationsExpanded }

    /// A tab opens with the sidebar it was saved with: the tree's top, the row selected and the sections open.
    func restore(
        rootPath: String, folder: String, favoritePath: String?, favoritesExpanded: Bool, locationsExpanded: Bool,
        includeHidden: Bool
    ) {
        model.homePath = FileManager.default.homeDirectoryForCurrentUser.path
        model.includeHidden = includeHidden
        model.currentPath = folder
        let selected: TreeItemID =
            favoritePath.map { TreeItemID.favorite($0) } ?? TreeItemID.filesystem(folder)
        model.restore(
            rootPath: rootPath, selected: selected,
            subview: favoritePath != nil && model.placement == .separate ? .favorites : .tree,
            favoritesExpanded: favoritesExpanded, locationsExpanded: locationsExpanded)
    }

    /// Sets the saved selection when it is a tab's snapshot (a favorite, a location or a folder row).
    func restoreSelection(_ id: String?) {
        guard let id, let item = TreeItemID(rawValue: id) else { return }
        model.restore(
            rootPath: model.rootPath, selected: item,
            subview: item.shortcutPath != nil && model.placement == .separate ? .favorites : .tree,
            favoritesExpanded: model.favoritesExpanded, locationsExpanded: model.locationsExpanded)
    }

    // MARK: Opening folders

    /// The window opened a folder. `open` says how it was reached.
    func folderOpened(_ url: URL, _ open: SidebarOpen = .other) {
        Task { await model.folderOpened(url.path, open) }
    }

    /// The folder asked for could not be opened.
    func openFailed() {
        model.openFailed()
    }

    func hiddenFilesChanged(_ include: Bool) {
        model.includeHidden = include
        model.hiddenFilesChanged()
    }

    /// The tab is shown again after being away: its open branches are read again.
    func refreshBranches() {
        Task { await model.refreshBranches() }
    }

    // MARK: Focus

    /// The keyboard goes to the sidebar, on the row selected (in the list last used), else the first.
    @discardableResult
    func focusTree() -> Bool {
        guard let window = view.window else { return false }
        model.clearTypeahead()
        let favoritesVisible =
            !sections.isHidden
            && (model.favoritesExpanded && !model.favoriteRows.isEmpty
                || model.locationsExpanded)
        let subview: SidebarSubview = model.placement == .separate && favoritesVisible ? model.subview : .tree
        let target = outline(for: subview)
        window.makeFirstResponder(target)
        return true
    }

    func isInside(_ responder: NSResponder?) -> Bool {
        (responder as? NSView)?.isDescendant(of: view) == true
    }

    // MARK: Commands

    /// The folder "Use as Tree Root" roots the tree at (`resolveRootTreeTargetPath`).
    func rootTreeTarget(
        focusedPane: ExplorerPane?, lastFocusedPane: ExplorerPane?, selectedContentFolder: String?, currentPath: String
    ) -> String? {
        if let menu = model.menuTarget?.path { return menu }
        let active = focusedPane ?? lastFocusedPane
        let selected = active == .tree ? model.selectedTreeTargetPath : selectedContentFolder
        if let selected, !selected.isEmpty { return selected }
        return currentPath.isEmpty ? nil : currentPath
    }

    /// Opens the selected row again (Return, ⌘↓).
    @discardableResult
    func openSelection() -> Bool {
        model.openSelected()
    }

    /// ⌘↑ with the sidebar focused: the parent folder's row of the selected folder.
    @discardableResult
    func selectParent() -> Bool {
        model.selectParent()
    }

    func rootTree(at path: String) {
        model.rootTree(at: path)
    }

    /// The favorites with `path` added or removed; nil when nothing changes.
    func toggleFavorite(_ path: String) {
        let homePath = model.homePath
        if Favorites.contains(model.favorites, path: path) {
            guard let next = Favorites.removing(path, from: model.favorites) else { return }
            model.favorites = next
            updatePreferences(["favorites": .array(next.map(Self.json))])
        } else {
            guard let next = Favorites.adding(path, to: model.favorites, homePath: homePath) else { return }
            model.favorites = next
            updatePreferences(["favorites": .array(next.map(Self.json))])
        }
        refresh()
    }

    func isFavorite(_ path: String) -> Bool {
        Favorites.contains(model.favorites, path: path)
    }

    /// "Reveal in Tree": the folder's filesystem row, down to it.
    func reveal(_ path: String) {
        model.selectItem(.filesystem(path))
    }

    var selectedTreeTargetPath: String? { model.selectedTreeTargetPath }

    /// What kind of row the selection is, for the rules of which commands act (`selectedTreeTargetKind`).
    var selectedTreeTargetKind: SelectedTreeTargetKind? {
        guard let selected = model.selected else { return nil }
        if selected.favoritePath != nil { return .favorite }
        if selected.filesystemPath != nil { return .filesystemFolder }
        return nil
    }

    /// Go ▸ Macintosh HD and Trash: as a click on the Locations row.
    func openLocation(_ path: String) {
        model.selectItem(.location(path))
    }

    /// Opens or closes Favorites or Locations (a capture scenario sets what a person clicks).
    func setSection(favorites: Bool, open: Bool) {
        model.setSections(
            favorites: favorites ? open : model.favoritesExpanded, locations: favorites ? model.locationsExpanded : open
        )
        updatePreferences([
            "favoritesExpanded": .bool(model.favoritesExpanded), "locationsExpanded": .bool(model.locationsExpanded),
        ])
        stateChanged()
    }

    var typeaheadQuery: String { model.typeaheadQuery }
}
