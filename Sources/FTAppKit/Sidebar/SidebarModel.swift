// Port of the tree and sidebar parts of apps/desktop/src/renderer/hooks/useExplorerNavigationController.ts (tree nodes,
// loadTreeChildren, syncTreeToPath, selectTreeItem, the keyboard and typeahead) and of the state TreePane.tsx keeps
import FTFileSystem
import FTFoundation
import Foundation

/// How a folder is opened from the sidebar, or from anywhere else.
struct SidebarOpen: Equatable {
    enum Origin: Equatable {
        /// The path bar, Go To, a double-click in the list, Back…: the folder's own row is selected.
        case other
        /// A folder row of the tree.
        case folder
        /// A link to a folder: its row stays selected, and the tree stays where it is.
        case alias
        case favorite(TreeItemID)
        case location(TreeItemID)
    }

    var origin: Origin = .other
    /// "Use as Tree Root" and Go ▸ Home: the tree starts again at the folder.
    var rerootTree = false
    /// The folder is a new step of the history.
    var pushesHistory = true
    /// Reads the tree's branch to the folder again.
    var forceTreeReload = false

    static let other = SidebarOpen()
}

/// The row a context menu is open for: it gets a ring, and the selection stays on the folder being shown.
struct SidebarMenuTarget: Equatable {
    enum Kind { case favorite, treeFolder }
    var path: String
    var subview: SidebarSubview
    var kind: Kind
}

/// The state of one tab's sidebar: its tree, selection, open sections and typed prefix, and what to do when a row is
/// opened. It has no views; `SidebarViewController` draws it.
@MainActor
final class SidebarModel {
    // MARK: What the window tells

    var homePath = ""
    var favorites: [FavoritePreference] = []
    var placement: FavoritesPlacement = .integrated
    var singleClickExpand = false
    var includeHidden = false
    /// The folder on screen.
    var currentPath = ""
    private(set) var volumes: [SidebarVolume] = []
    /// Reads a folder's subfolders (`tree:getChildren`).
    var readChildren: (_ path: String, _ includeHidden: Bool) async throws -> [TreePaths.Child] = { _, _ in
        []
    }
    /// Opens a folder in the window.
    var openFolder: (_ url: URL, _ open: SidebarOpen) -> Void = { _, _ in }
    /// The state changed: the views draw it again.
    var onChange: () -> Void = {}
    /// Saves a change of the favorites (reorder).
    var onFavoritesChanged: ([FavoritePreference]) -> Void = { _ in }
    /// A section was opened or closed by hand, or the sub-view used last changed.
    var onSectionsChanged: () -> Void = {}
    /// Schedules `fire` after `milliseconds`; the returned function cancels it.
    var schedule: (_ milliseconds: Int, _ fire: @escaping @MainActor () -> Void) -> (() -> Void) = { milliseconds, fire in
        let item = DispatchWorkItem { MainActor.assumeIsolated { fire() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(milliseconds), execute: item)
        return { item.cancel() }
    }

    // MARK: The tab's sidebar

    private(set) var rootPath = ""
    private(set) var nodes = TreeNodes()
    private(set) var selected: TreeItemID?
    /// The row just pressed, shown selected before its folder has opened.
    private(set) var optimistic: TreeItemID?
    private(set) var subview: SidebarSubview = .tree
    private(set) var favoritesExpanded = true
    private(set) var locationsExpanded = true
    var menuTarget: SidebarMenuTarget? {
        didSet { if menuTarget != oldValue { onChange() } }
    }
    private(set) var typeaheadQuery = ""

    /// The row shown as selected: the one just pressed, or the tree's selection.
    var currentItemID: TreeItemID? { optimistic ?? selected }

    private var treeRequests: [ExactKeyBox: Int] = [:]
    private var nextRequestID = 0
    /// Counts the tab's navigations: an answer for an older one is dropped.
    private var viewVersion = 0
    private var cancelTypeaheadTimer: (() -> Void)?

    struct ExactKeyBox: Hashable {
        let bytes: [UInt8]
        init(_ path: String) { bytes = Array(path.utf8) }
    }

    // MARK: Setting up

    /// A tab opened with its sidebar as it was saved: its top, the row selected, the sections open.
    func restore(
        rootPath: String, selected: TreeItemID?, subview: SidebarSubview, favoritesExpanded: Bool,
        locationsExpanded: Bool
    ) {
        self.rootPath = rootPath
        self.selected = selected
        self.subview = subview
        self.favoritesExpanded = favoritesExpanded
        self.locationsExpanded = locationsExpanded
        if !rootPath.isEmpty { nodes = TreeNodes([TreeNodeState(path: rootPath, expanded: true)]) }
        onChange()
    }

    func setVolumes(_ volumes: [Volume]) {
        let next = volumes.map {
            SidebarVolume(path: $0.path, name: $0.name, isLocal: $0.isLocal, canEject: $0.canEject)
        }
        guard next != self.volumes else { return }
        self.volumes = next
        onChange()
    }

    // MARK: What is drawn

    var locations: [SidebarLocation] { Favorites.locations(volumes: volumes, homePath: homePath) }

    private var separate: Bool { placement == .separate }

    /// The rows of the folder tree: with Favorites and Locations ahead of it when they are integrated.
    var treePresentation: TreePresentation {
        Favorites.presentation(
            .init(
                favorites: favorites, favoritesExpanded: favoritesExpanded, homePath: homePath, rootPath: rootPath,
                nodes: nodes, includeFavorites: !separate, locations: locations,
                locationsExpanded: locationsExpanded))
    }

    /// The separate Favorites list (`favoriteItems`).
    var favoriteRows: [TreePresentationItem] {
        favorites.map {
            TreePresentationItem(
                id: .favorite($0.path), kind: .favorite,
                label: FavoriteLabel.label(for: $0.path, homePath: homePath), depth: 0, path: $0.path, parentID: nil,
                expanded: false, canExpand: false, icon: $0.icon)
        }
    }

    /// The separate Locations list.
    var locationRows: [TreePresentationItem] {
        Favorites.locationItems(locations, parent: nil, depth: 0)
    }

    var keyContext: SidebarKeyContext {
        SidebarKeyContext(
            separate: separate, subview: subview, selected: selected,
            favoriteList: favoriteList, presentation: treePresentation, nodes: nodes, rootPath: rootPath)
    }

    /// `getFavoriteItemIds`: the favorites, then the Locations when open.
    private var favoriteList: [(id: TreeItemID, label: String)] {
        favoriteRows.map { ($0.id, $0.label) }
            + (locationsExpanded ? locationRows.map { ($0.id, $0.label) } : [])
    }

    /// The folder the selected row stands for, for the commands that act on the tree (`selectedTreeTargetPath`): a
    /// folder row of the tree or a favorite; none for a location.
    var selectedTreeTargetPath: String? {
        guard let selected else { return nil }
        if selected.locationPath != nil { return nil }
        return selected.favoritePath ?? selected.filesystemPath
    }

    // MARK: Tree nodes

    private func update(_ path: String, _ change: (inout TreeNodeState) -> Void) {
        guard var node = nodes[path] else { return }
        change(&node)
        nodes[path] = node
    }

    func initializeTree(_ path: String) {
        treeRequests = [:]
        rootPath = path
        nodes = TreeNodes([TreeNodeState(path: path, expanded: true)])
        onChange()
    }

    /// `reinitializeTree`: the root stays, only the path to `focusPath` stays open.
    func reinitializeTree(root: String, focus: String) {
        treeRequests = [:]
        rootPath = root
        var seeded = TreeNodes()
        for (path, child) in TreePaths.seedChain(from: root, to: focus) {
            var node = TreeNodeState(path: path, expanded: child != nil)
            node.childPaths = child.map { [$0] } ?? []
            seeded[path] = node
        }
        nodes = seeded
        onChange()
    }

    private func ensureNode(_ path: String, expanded: Bool = false) {
        if var existing = nodes[path] {
            if expanded, !existing.expanded {
                existing.expanded = true
                nodes[path] = existing
            }
        } else {
            nodes[path] = TreeNodeState(path: path, expanded: expanded)
        }
    }

    private func effectiveIncludeHidden(_ override: Bool, path: String, activePath: String) -> Bool {
        if override { return true }
        if rootPath.isEmpty { return TreePaths.hasHiddenSegment(path, withinRoot: path) }
        return TreePaths.forcedVisibleHiddenChild(of: path, activePath: activePath) != nil
    }

    /// `loadTreeChildren`: reads the folder's subfolders, and expands it when asked to.
    func loadChildren(
        _ path: String, includeHiddenOverride: Bool? = nil, expandOnSuccess: Bool = false, activePath: String? = nil,
        forceReload: Bool = false
    ) async {
        let includeHidden = includeHiddenOverride ?? self.includeHidden
        let activePath = activePath ?? currentPath
        let current = nodes[path]
        let forcedHidden =
            includeHidden || rootPath.isEmpty ? nil : TreePaths.forcedVisibleHiddenChild(of: path, activePath: activePath)
        let forcedPackage =
            rootPath.isEmpty ? nil : TreePaths.forcedVisiblePackageChild(of: path, activePath: activePath)
        if current?.loading == true, !forceReload { return }
        if !forceReload, let current, current.loaded, current.loadedIncludeHidden == includeHidden,
            current.forcedVisibleHiddenChildPath == forcedHidden,
            current.forcedVisiblePackageChildPath == forcedPackage
        {
            if expandOnSuccess, !current.expanded {
                update(path) { $0.expanded = true }
                onChange()
            }
            return
        }

        // Numbered across the whole tree, not per folder: forgetting the requests under way (a new root, another
        // tab) can then never make an old answer look like a new one.
        nextRequestID += 1
        let requestID = nextRequestID
        treeRequests[ExactKeyBox(path)] = requestID
        if nodes[path] == nil { nodes[path] = TreeNodeState(path: path, expanded: true) }
        update(path) {
            $0.loading = true
            $0.error = nil
        }
        onChange()
        do {
            let effective = effectiveIncludeHidden(includeHidden, path: path, activePath: activePath)
            let response = try await readChildren(path, effective)
            guard treeRequests[ExactKeyBox(path)] == requestID else { return }
            apply(
                response, to: path, includeHidden: includeHidden, forcedHidden: forcedHidden,
                forcedPackage: forcedPackage, expandOnSuccess: expandOnSuccess)
        } catch {
            guard treeRequests[ExactKeyBox(path)] == requestID else { return }
            update(path) {
                $0.loading = false
                $0.error = Self.message(of: error)
            }
        }
        onChange()
    }

    private func apply(
        _ response: [TreePaths.Child], to path: String, includeHidden: Bool, forcedHidden: String?,
        forcedPackage: String?, expandOnSuccess: Bool
    ) {
        // Macintosh HD's Volumes folder, where the other disks are mounted, is left out as Finder leaves it out:
        // those disks are under Locations.
        let children = response.filter { includeHidden || !TreePaths.same($0.path, "/Volumes") }
        var visible =
            forcedHidden == nil
            ? children.filter { includeHidden || !$0.isHidden }
            : children.filter { !$0.isHidden || TreePaths.same($0.path, forcedHidden ?? "") }
        if let forcedPackage { visible = TreePaths.withPackageChild(visible, packagePath: forcedPackage) }
        var existing = nodes[path] ?? TreeNodeState(path: path, expanded: true)
        existing.expanded = existing.expanded || expandOnSuccess
        existing.loading = false
        existing.loaded = true
        existing.loadedIncludeHidden = includeHidden
        existing.forcedVisibleHiddenChildPath = forcedHidden
        existing.forcedVisiblePackageChildPath = forcedPackage
        existing.error = nil
        existing.childPaths = visible.map(\.path)
        nodes[path] = existing
        for child in visible {
            let known = nodes[child.path]
            nodes[child.path] = TreeNodeState(
                path: child.path, name: child.name, isHidden: child.isHidden, isSymlink: child.isSymlink,
                expanded: known?.expanded == true && (known?.loaded == true || known?.loading == true
                    || !(known?.childPaths.isEmpty ?? true)),
                loading: known?.loading ?? false, loaded: known?.loaded ?? false,
                loadedIncludeHidden: known?.loadedIncludeHidden ?? false,
                forcedVisibleHiddenChildPath: known?.forcedVisibleHiddenChildPath,
                forcedVisiblePackageChildPath: known?.forcedVisiblePackageChildPath, error: nil,
                childPaths: known?.childPaths ?? [])
        }
    }

    /// The text of an error as the original's IPC carries it ("EACCES: permission denied, scandir '…'").
    static func message(of error: Error) -> String {
        if let listing = error as? ExplorerError {
            guard case .system(let code, let path) = listing else { return listing.description }
            let reason = String(cString: strerror(code))
            let lowered = reason.prefix(1).lowercased() + reason.dropFirst()
            let name = POSIXErrorCode(rawValue: code)?.name ?? "E\(code)"
            return "\(name): \(lowered), scandir '\(path)'"
        }
        return (error as NSError).localizedDescription
    }

    /// `syncTreeToPath`: opens the tree down to `path` (each ancestor read in turn), moving the root when `path` is
    /// outside it. The folder itself is read only if it is already open.
    func syncTree(to path: String, includeHidden: Bool? = nil, forceReload: Bool = false, version: Int? = nil) async {
        let includeHidden = includeHidden ?? self.includeHidden
        let version = version ?? viewVersion
        let isCurrent = { [weak self] in self?.viewVersion == version }
        let nextRoot =
            rootPath.isEmpty || !TreePaths.isWithinTreeRoot(path, rootPath)
            ? TreePaths.resolveRootPath(for: path, homePath: homePath) : rootPath
        if nextRoot != rootPath {
            initializeTree(nextRoot)
        } else {
            ensureNode(nextRoot, expanded: true)
        }
        await loadChildren(
            nextRoot, includeHiddenOverride: includeHidden, expandOnSuccess: false, activePath: path,
            forceReload: forceReload)
        if TreePaths.same(path, nextRoot) || !isCurrent() { return }
        for ancestor in TreePaths.ancestorChain(from: nextRoot, to: path).dropFirst().dropLast() {
            ensureNode(ancestor, expanded: true)
            await loadChildren(
                ancestor, includeHiddenOverride: includeHidden, expandOnSuccess: true, activePath: path,
                forceReload: forceReload)
            if !isCurrent() { return }
        }
        let focused = nodes[path]
        if !TreePaths.same(path, nextRoot), focused?.expanded == true || forceReload {
            ensureNode(path, expanded: focused?.expanded ?? false)
            await loadChildren(
                path, includeHiddenOverride: includeHidden, expandOnSuccess: false, activePath: path,
                forceReload: forceReload)
        }
        onChange()
    }

    /// `toggleTreeNode`.
    func toggle(_ path: String) {
        guard let node = nodes[path], !node.isSymlink else { return }
        if !node.loaded {
            if !node.loading { Task { await loadChildren(path, expandOnSuccess: true) } }
            return
        }
        update(path) { $0.expanded.toggle() }
        onChange()
    }

    /// A folder opened or closed by a hand (chevron, heading, key, double-click): the sidebar will not scroll to the
    /// selection for a moment.
    var onHandToggle: () -> Void = {}

    func toggleByHand(_ path: String) {
        onHandToggle()
        toggle(path)
    }

    func toggleFavorites() {
        onHandToggle()
        // The keyboard cannot stay in a hidden list.
        if separate, favoritesExpanded, subview == .favorites { setSubview(.tree) }
        favoritesExpanded.toggle()
        onSectionsChanged()
        onChange()
    }

    func toggleLocations() {
        onHandToggle()
        locationsExpanded.toggle()
        onSectionsChanged()
        onChange()
    }

    func setSections(favorites: Bool, locations: Bool) {
        guard favoritesExpanded != favorites || locationsExpanded != locations else { return }
        favoritesExpanded = favorites
        locationsExpanded = locations
        onChange()
    }

    func setSubview(_ value: SidebarSubview) {
        guard subview != value else { return }
        subview = value
        onSectionsChanged()
        onChange()
    }

    // MARK: Opening

    /// The folder the window just showed. `request` says how it was reached, which decides how the tree follows and
    /// which row is selected.
    func folderOpened(_ path: String, _ request: SidebarOpen) async {
        currentPath = path
        viewVersion += 1
        let version = viewVersion
        let fromSidebar: TreeItemID?
        switch request.origin {
        case .favorite(let id), .location(let id): fromSidebar = id
        default: fromSidebar = nil
        }
        let isLocation = request.origin.isLocation
        // The Trash, gone to from the sidebar, leaves the tree as it is: it is not a folder the tree shows.
        let inTrash = fromSidebar != nil && Paths.isInsideTrash(path, homePath: homePath)
        let syncsTree = request.origin != .alias && !inTrash
        if request.rerootTree { initializeTree(path) }
        var reveal = path
        if isLocation, !inTrash {
            let top = TreePaths.resolveRootPath(for: path, homePath: homePath)
            if top != rootPath { initializeTree(top) }
            if !includeHidden, TreePaths.hasHiddenSegment(path, withinRoot: top) { reveal = top }
        }
        if syncsTree {
            await syncTree(to: reveal, forceReload: request.forceTreeReload, version: version)
            if viewVersion != version { return }
        }
        switch request.origin {
        case .favorite(let id), .location(let id):
            select(id, subview: separate ? .favorites : nil)
        case .alias:
            break
        case .other, .folder:
            select(.filesystem(path), subview: .tree)
        }
        optimistic = nil
        onChange()
    }

    /// The window could not open the folder asked for: the pressed row is no longer shown selected.
    func openFailed() {
        guard optimistic != nil else { return }
        optimistic = nil
        onChange()
    }

    private func select(_ id: TreeItemID?, subview: SidebarSubview?) {
        selected = id
        if let subview, self.subview != subview {
            self.subview = subview
            onSectionsChanged()
        }
    }

    /// Selects a row and opens its folder (`selectTreeItem`): headings are never selected.
    func selectItem(_ id: TreeItemID, subview newSubview: SidebarSubview? = nil) {
        if id.isHeading { return }
        if let newSubview { setSubview(newSubview) }
        if let path = id.locationPath {
            select(id, subview: separate ? .favorites : nil)
            open(path, SidebarOpen(origin: .location(id)))
        } else if let path = id.favoritePath {
            select(id, subview: separate ? .favorites : nil)
            open(path, SidebarOpen(origin: .favorite(id)))
        } else if let path = id.filesystemPath {
            select(id, subview: .tree)
            let alias = nodes[path]?.isSymlink == true
            open(path, SidebarOpen(origin: alias ? .alias : .folder))
        }
        onChange()
    }

    private func open(_ path: String, _ request: SidebarOpen) {
        openFolder(URL(fileURLWithPath: path), request)
    }

    /// A row pressed with the primary button: shown selected at once (`setOptimisticSelectedItemId`).
    func markPressed(_ id: TreeItemID?) {
        guard optimistic != id else { return }
        optimistic = id
        onChange()
    }

    /// Empties the selection, as a press on empty space or a ⌘-click on the selected row does.
    var releaseFolder: () -> Void = {}

    func clearSelection() {
        optimistic = nil
        selected = nil
        onChange()
        releaseFolder()
    }

    // MARK: The window's commands

    /// "Use as Tree Root" and Go ▸ Home: opens the folder with the tree starting at it.
    func rootTree(at path: String) {
        guard !path.isEmpty else { return }
        open(path, SidebarOpen(origin: .other, rerootTree: true, pushesHistory: !TreePaths.same(path, currentPath)))
    }

    /// Hidden files were turned on or off: the tree is seeded again (not for a favorite, a location or a link that
    /// is selected), and read again.
    func hiddenFilesChanged() {
        guard !currentPath.isEmpty else { return }
        let keeps: Bool
        if let shortcut = selected?.shortcutPath, TreePaths.same(shortcut, currentPath) {
            keeps = true
        } else if let path = selected?.filesystemPath, nodes[path]?.isSymlink == true {
            keeps = true
        } else {
            keeps = false
        }
        if !keeps { reinitializeTree(root: rootPath.isEmpty ? currentPath : rootPath, focus: currentPath) }
        guard !keeps else { return }
        let path = currentPath
        viewVersion += 1
        let version = viewVersion
        Task { await syncTree(to: path, version: version) }
    }

    /// The tree's open branches read again, from `path` down (`refreshVisibleTreePath`).
    func refreshBranches(from path: String? = nil, recursive: Bool = true) async {
        var seen = Set<ExactKeyBox>()
        func refresh(_ path: String) async {
            guard seen.insert(ExactKeyBox(path)).inserted, let node = nodes[path], node.loaded || node.expanded else {
                return
            }
            await loadChildren(path, expandOnSuccess: false, activePath: currentPath, forceReload: true)
            guard recursive, let reloaded = nodes[path] else { return }
            for child in reloaded.childPaths where nodes[child]?.expanded == true { await refresh(child) }
        }
        await refresh(path ?? rootPath)
    }

    /// A disk went: tabs that showed it are elsewhere. Nothing of the sidebar to do but drop what was under it.
    func volumeGone(_ volumePath: String) {
        if TreePaths.isWithinRoot(rootPath, volumePath), !TreePaths.same(volumePath, "/") {
            rootPath = ""
            nodes = TreeNodes()
            onChange()
        }
    }

    // MARK: Keyboard

    /// Carries out what a key decides. True when the key was taken.
    @discardableResult
    func perform(_ action: SidebarKeyAction) -> Bool {
        switch action {
        case .none:
            return false
        case .select(let id, let newSubview):
            selectItem(id, subview: newSubview)
        case .load(let path):
            Task { await loadChildren(path, expandOnSuccess: true) }
        case .toggle(let path):
            toggle(path)
        }
        return true
    }

    func handle(_ key: TreeView.Key) -> Bool {
        perform(SidebarKeyboard.decide(key, keyContext))
    }

    func openSelected() -> Bool {
        perform(SidebarKeyboard.decideOpen(keyContext))
    }

    func selectParent() -> Bool {
        perform(SidebarKeyboard.decideParent(keyContext))
    }

    func page(forward: Bool, lines: Int) -> Bool {
        guard let target = SidebarKeyboard.pageTarget(forward: forward, lines: lines, keyContext) else { return false }
        selectItem(target)
        return true
    }

    /// A printable key typed in the sidebar (`handleTypeaheadInput`).
    func type(_ character: String) {
        typeaheadQuery += character
        cancelTypeaheadTimer?()
        cancelTypeaheadTimer = schedule(SidebarLayout.typeaheadResetMilliseconds) { [weak self] in
            self?.clearTypeahead()
        }
        if let match = SidebarKeyboard.typeaheadMatch(typeaheadQuery, keyContext) {
            selectItem(match)
        } else {
            onChange()
        }
    }

    func clearTypeahead() {
        cancelTypeaheadTimer?()
        cancelTypeaheadTimer = nil
        guard !typeaheadQuery.isEmpty else { return }
        typeaheadQuery = ""
        onChange()
    }

    // MARK: Favorites

    func reorder(moved: String, target: String, position: Favorites.DropPosition) {
        let next = Favorites.reorder(favorites, moved: moved, target: target, position: position)
        guard next != favorites else { return }
        favorites = next
        onFavoritesChanged(next)
        onChange()
    }
}

extension SidebarOpen.Origin {
    var isLocation: Bool {
        if case .location = self { return true }
        return false
    }
}

extension POSIXErrorCode {
    /// The errno name ("EACCES") a Node error carries as its code.
    var name: String {
        switch self {
        case .EPERM: "EPERM"
        case .ENOENT: "ENOENT"
        case .EACCES: "EACCES"
        case .ENOTDIR: "ENOTDIR"
        case .EIO: "EIO"
        case .EBUSY: "EBUSY"
        case .ETIMEDOUT: "ETIMEDOUT"
        default: "E\(rawValue)"
        }
    }
}
