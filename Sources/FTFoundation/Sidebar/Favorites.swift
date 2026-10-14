// Port of apps/desktop/src/renderer/lib/favorites.ts
import Foundation

public enum Favorites {
    // MARK: Locations

    /// `buildSidebarLocations`: Home, Macintosh HD and the Trash always come first and keep their rows; the disks
    /// come and go after them.
    public static func locations(volumes: [SidebarVolume], homePath: String) -> [SidebarLocation] {
        var places: [SidebarLocation] = []
        if !homePath.isEmpty {
            places.append(
                SidebarLocation(
                    path: homePath, label: JSString.components(homePath, separator: 0x2F).last ?? homePath,
                    icon: .home))
        }
        places.append(SidebarLocation(path: "/", label: "Macintosh HD", icon: .drive))
        if !homePath.isEmpty {
            places.append(SidebarLocation(path: FavoriteLabel.trashPath(homePath: homePath), label: "Trash", icon: .trash))
        }
        for volume in volumes {
            places.append(
                SidebarLocation(
                    path: volume.path, label: volume.name,
                    // A network share is drawn as one; a drive or a disk image as a drive.
                    icon: volume.isLocal ? .drive : .server, canEject: volume.canEject))
        }
        return places
    }

    // MARK: Favorites

    public enum DropPosition: String, Sendable {
        case before, after
    }

    /// `reorderFavorites`: the favorites with one of them put just before or after another. The very same list comes
    /// back when nothing changes (the moved path is the target, is not a favorite, the target is not found, or the
    /// order stays), so nothing is saved.
    public static func reorder(
        _ favorites: [FavoritePreference], moved movedPath: String, target targetPath: String,
        position: DropPosition
    ) -> [FavoritePreference] {
        guard let moved = favorites.first(where: { JSString.equals($0.path, movedPath) }),
            !JSString.equals(movedPath, targetPath)
        else { return favorites }
        var rest = favorites.filter { !JSString.equals($0.path, movedPath) }
        guard let targetIndex = rest.firstIndex(where: { JSString.equals($0.path, targetPath) }) else {
            return favorites
        }
        rest.insert(moved, at: position == .before ? targetIndex : targetIndex + 1)
        return rest == favorites ? favorites : rest
    }

    /// `getDefaultFavorites`: Finder's sidebar places, all ordinary favorites the user can remove or reorder. Home,
    /// Macintosh HD and the Trash are under Locations, as in Finder.
    public static func defaults(homePath: String) -> [FavoritePreference] {
        if homePath.isEmpty {
            return [FavoritePreference(path: "/Applications", icon: .applications)]
        }
        return [
            FavoritePreference(path: "/Applications", icon: .applications),
            FavoritePreference(path: "\(homePath)/Desktop", icon: .desktop),
            FavoritePreference(path: "\(homePath)/Documents", icon: .documents),
            FavoritePreference(path: "\(homePath)/Downloads", icon: .downloads),
        ]
    }

    /// `inferFavoriteIcon`: the icon a folder added to the favorites gets, from its path.
    public static func inferIcon(path: String, homePath: String) -> FavoriteIconID {
        if JSString.equals(path, homePath) { return .home }
        if JSString.equals(path, "/Applications") { return .applications }
        if JSString.equals(path, FavoriteLabel.trashPath(homePath: homePath)) { return .trash }
        if JSString.equals(path, "/") { return .drive }
        let leaf = leafName(path)
        switch leaf {
        case "Desktop": return .desktop
        case "Documents": return .documents
        case "Downloads": return .downloads
        case "Music": return .music
        case "Pictures", "Photos": return .photos
        case "Movies", "Videos": return .videos
        case "Projects": return .projects
        case "Applications": return .applications
        default: return .folder
        }
    }

    /// `createFavorite`.
    public static func create(path: String, homePath: String) -> FavoritePreference {
        FavoritePreference(path: path, icon: inferIcon(path: path, homePath: homePath))
    }

    /// `isFavoritePath`.
    public static func contains(_ favorites: [FavoritePreference], path: String) -> Bool {
        favorites.contains { JSString.equals($0.path, path) }
    }

    /// Add to Favorites: the folder at the end of the list, with its inferred icon. The Trash is refused, and a
    /// folder that already is a favorite stays where it is. Nil when nothing changes.
    public static func adding(_ path: String, to favorites: [FavoritePreference], homePath: String)
        -> [FavoritePreference]?
    {
        if JSString.equals(path, FavoriteLabel.trashPath(homePath: homePath)) || contains(favorites, path: path) {
            return nil
        }
        return favorites + [create(path: path, homePath: homePath)]
    }

    /// Remove from Favorites: that path only (a Trash favorite too).
    public static func removing(_ path: String, from favorites: [FavoritePreference]) -> [FavoritePreference]? {
        let next = favorites.filter { !JSString.equals($0.path, path) }
        return next.count == favorites.count ? nil : next
    }

    // MARK: The Trash

    /// `isTrashListingRefused`: macOS refuses to list the Trash ("EPERM: operation not permitted, scandir …") to an
    /// app without Full Disk Access, even though everything inside it can still be read.
    public static func isTrashListingRefused(path: String, error: String?, homePath: String) -> Bool {
        guard let error, !path.isEmpty, JSString.equals(path, FavoriteLabel.trashPath(homePath: homePath)) else {
            return false
        }
        return error.contains("EPERM") || JSString.lowercased(error).contains("operation not permitted")
    }

    private static func leafName(_ path: String) -> String {
        var units = Array(path.utf16)
        while units.last == 0x2F { units.removeLast() }
        let trimmed = JSString.string(units)
        return JSString.components(trimmed, separator: 0x2F).last ?? trimmed
    }

    // MARK: Rows

    /// `buildLocationItems`.
    public static func locationItems(_ locations: [SidebarLocation], parent: TreeItemID?, depth: Int)
        -> [TreePresentationItem]
    {
        locations.map { location in
            TreePresentationItem(
                id: .location(location.path), kind: .location, label: location.label, depth: depth,
                path: location.path, parentID: parent, expanded: false, canExpand: false, icon: location.icon,
                canEject: location.canEject)
        }
    }

    /// What `buildTreePresentation` takes.
    public struct PresentationInput {
        public var favorites: [FavoritePreference]
        public var favoritesExpanded: Bool
        public var homePath: String
        public var rootPath: String
        public var nodes: TreeNodes
        public var includeFavorites = true
        /// Shown as a Locations row after Favorites when `includeFavorites` is set.
        public var locations: [SidebarLocation] = []
        public var locationsExpanded = true

        public init(
            favorites: [FavoritePreference], favoritesExpanded: Bool, homePath: String, rootPath: String,
            nodes: TreeNodes, includeFavorites: Bool = true, locations: [SidebarLocation] = [],
            locationsExpanded: Bool = true
        ) {
            self.favorites = favorites
            self.favoritesExpanded = favoritesExpanded
            self.homePath = homePath
            self.rootPath = rootPath
            self.nodes = nodes
            self.includeFavorites = includeFavorites
            self.locations = locations
            self.locationsExpanded = locationsExpanded
        }
    }

    /// `buildTreePresentation`: Favorites and Locations as heading rows ahead of the tree (the integrated layout),
    /// then the tree itself from its root.
    public static func presentation(_ input: PresentationInput) -> TreePresentation {
        var result = TreePresentation()
        func add(_ item: TreePresentationItem) {
            result.items[item.id] = item
            result.visibleItemIDs.append(item.id)
        }

        if input.includeFavorites {
            let favoriteIDs = input.favorites.map { TreeItemID.favorite($0.path) }
            add(
                TreePresentationItem(
                    id: .favoritesRoot, kind: .favoritesRoot, label: "Favorites", depth: 0, path: nil, parentID: nil,
                    expanded: input.favoritesExpanded, canExpand: !favoriteIDs.isEmpty, childIDs: favoriteIDs,
                    icon: .star))
            if input.favoritesExpanded {
                for favorite in input.favorites {
                    add(
                        TreePresentationItem(
                            id: .favorite(favorite.path), kind: .favorite,
                            label: FavoriteLabel.label(for: favorite.path, homePath: input.homePath), depth: 1,
                            path: favorite.path, parentID: .favoritesRoot, expanded: false, canExpand: false,
                            icon: favorite.icon))
                }
            }
        }

        if input.includeFavorites, !input.locations.isEmpty {
            add(
                TreePresentationItem(
                    id: .locationsRoot, kind: .locationsRoot, label: "Locations", depth: 0, path: nil,
                    parentID: nil, expanded: input.locationsExpanded, canExpand: true,
                    childIDs: input.locations.map { .location($0.path) }, icon: .drive))
            if input.locationsExpanded {
                for item in locationItems(input.locations, parent: .locationsRoot, depth: 1) { add(item) }
            }
        }

        func addNode(_ path: String, depth: Int, parent: TreeItemID?) {
            guard let node = input.nodes[path] else { return }
            let id = TreeItemID.filesystem(path)
            add(
                TreePresentationItem(
                    id: id, kind: .filesystem, label: node.name, depth: depth, path: path, parentID: parent,
                    expanded: node.expanded, canExpand: !node.isSymlink, loading: node.loading, error: node.error,
                    isSymlink: node.isSymlink, childIDs: node.childPaths.map { .filesystem($0) }))
            guard node.expanded else { return }
            for child in node.childPaths { addNode(child, depth: depth + 1, parent: id) }
        }
        if !input.rootPath.isEmpty { addNode(input.rootPath, depth: 0, parent: nil) }
        return result
    }
}
