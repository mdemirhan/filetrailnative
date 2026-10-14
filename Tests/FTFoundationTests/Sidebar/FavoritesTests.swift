// Port of apps/desktop/src/renderer/lib/favorites.test.ts
import Testing

@testable import FTFoundation

struct FavoritesTests {
    static let home = "/Users/demo"

    // T-599e45b7 F-732
    @Test func buildsDefaultFavoritesInTheRequestedOrderLeavingHomeMacintoshHDAndTheTrashToLocations() {
        #expect(
            Favorites.defaults(homePath: Self.home) == [
                FavoritePreference(path: "/Applications", icon: .applications),
                FavoritePreference(path: "/Users/demo/Desktop", icon: .desktop),
                FavoritePreference(path: "/Users/demo/Documents", icon: .documents),
                FavoritePreference(path: "/Users/demo/Downloads", icon: .downloads),
            ])
        // Without a home folder, only /Applications.
        #expect(Favorites.defaults(homePath: "") == [FavoritePreference(path: "/Applications", icon: .applications)])
    }

    // T-a8edbb95 F-731
    @Test func listsHomeMacintoshHDAndTheTrashUnderLocationsThenTheDisksMounted() {
        let volumes = [
            SidebarVolume(path: "/Volumes/Backup", name: "Backup", isLocal: true, canEject: true),
            SidebarVolume(path: "/Volumes/Shared", name: "Shared", isLocal: false, canEject: true),
        ]
        #expect(
            Favorites.locations(volumes: volumes, homePath: Self.home) == [
                SidebarLocation(path: "/Users/demo", label: "demo", icon: .home),
                SidebarLocation(path: "/", label: "Macintosh HD", icon: .drive),
                SidebarLocation(path: "/Users/demo/.Trash", label: "Trash", icon: .trash),
                SidebarLocation(path: "/Volumes/Backup", label: "Backup", icon: .drive, canEject: true),
                SidebarLocation(path: "/Volumes/Shared", label: "Shared", icon: .server, canEject: true),
            ])
        // Without a home folder there is no Home or Trash to list.
        #expect(
            Favorites.locations(volumes: [], homePath: "") == [
                SidebarLocation(path: "/", label: "Macintosh HD", icon: .drive)
            ])
    }

    // T-ffcc48a5 F-729
    @Test func showsLocationsAfterFavoritesInTheTreeItsPlacesAsRowsWithoutFolders() {
        let locations = Favorites.locations(
            volumes: [SidebarVolume(path: "/Volumes/Backup", name: "Backup", isLocal: true, canEject: true)],
            homePath: Self.home)
        let presentation = Favorites.presentation(
            .init(
                favorites: [FavoritePreference(path: "/Users/demo/Documents", icon: .documents)],
                favoritesExpanded: true, homePath: Self.home, rootPath: Self.home, nodes: TreeNodes(),
                locations: locations, locationsExpanded: true))
        #expect(
            presentation.visibleItemIDs.map(\.rawValue) == [
                "favorites-root", "favorite:/Users/demo/Documents", "locations-root", "location:/Users/demo",
                "location:/", "location:/Users/demo/.Trash", "location:/Volumes/Backup",
            ])
        let backup = presentation.items[.location("/Volumes/Backup")]
        #expect(backup?.kind == .location)
        #expect(backup?.label == "Backup")
        #expect(backup?.path == "/Volumes/Backup")
        #expect(backup?.canExpand == false)
        #expect(backup?.icon == .drive)
        #expect(TreeItemID(rawValue: "location:/Volumes/Backup")?.shortcutPath == "/Volumes/Backup")
        #expect(TreeItemID(rawValue: "favorite:/Users/demo/Documents")?.shortcutPath == "/Users/demo/Documents")

        // Folded, only its row is left; with favorites in their own list, it is not in the tree.
        let folded = Favorites.presentation(
            .init(
                favorites: [], favoritesExpanded: true, homePath: Self.home, rootPath: "", nodes: TreeNodes(),
                locations: Favorites.locations(volumes: [], homePath: Self.home), locationsExpanded: false))
        #expect(folded.visibleItemIDs.map(\.rawValue) == ["favorites-root", "locations-root"])
        let separate = Favorites.presentation(
            .init(
                favorites: [], favoritesExpanded: true, homePath: Self.home, rootPath: "", nodes: TreeNodes(),
                includeFavorites: false, locations: Favorites.locations(volumes: [], homePath: Self.home)))
        #expect(separate.visibleItemIDs.isEmpty)
    }

    // T-88a6a54c F-738
    @Test func putsADraggedFavoriteJustBeforeOrAfterAnother() {
        let favorites = [
            FavoritePreference(path: "/Applications", icon: .applications),
            FavoritePreference(path: "/Users/demo/Desktop", icon: .desktop),
            FavoritePreference(path: "/Users/demo/Documents", icon: .documents),
            FavoritePreference(path: "/Users/demo/Downloads", icon: .downloads),
        ]
        func order(_ moved: String, _ target: String, _ position: Favorites.DropPosition) -> [String] {
            Favorites.reorder(favorites, moved: moved, target: target, position: position).map {
                $0.path.split(separator: "/").last.map(String.init) ?? ""
            }
        }
        #expect(
            order("/Users/demo/Downloads", "/Applications", .before) == [
                "Downloads", "Applications", "Desktop", "Documents",
            ])
        #expect(
            order("/Applications", "/Users/demo/Documents", .after) == [
                "Desktop", "Documents", "Applications", "Downloads",
            ])
        #expect(
            order("/Users/demo/Desktop", "/Users/demo/Downloads", .before) == [
                "Applications", "Documents", "Desktop", "Downloads",
            ])
        // Onto itself, or where it already is: the same list, so nothing is saved.
        #expect(
            Favorites.reorder(favorites, moved: "/Applications", target: "/Applications", position: .after)
                == favorites)
        #expect(
            Favorites.reorder(favorites, moved: "/Applications", target: "/Users/demo/Desktop", position: .before)
                == favorites)
        #expect(
            Favorites.reorder(favorites, moved: "/Missing", target: "/Applications", position: .before) == favorites)
        #expect(
            Favorites.reorder(favorites, moved: "/Applications", target: "/Missing", position: .before) == favorites)
    }

    // T-4e9e3ea2 B-TREE-030
    @Test func recognizesMacOSRefusingToListTheTrash() {
        let refusal = "EPERM: operation not permitted, scandir '/Users/demo/.Trash'"
        #expect(Favorites.isTrashListingRefused(path: "/Users/demo/.Trash", error: refusal, homePath: Self.home))
        #expect(!Favorites.isTrashListingRefused(path: "/Users/demo/Private", error: refusal, homePath: Self.home))
        #expect(
            !Favorites.isTrashListingRefused(
                path: "/Users/demo/.Trash", error: "ENOENT: no such file", homePath: Self.home))
        #expect(!Favorites.isTrashListingRefused(path: "/Users/demo/.Trash", error: nil, homePath: Self.home))
        #expect(!Favorites.isTrashListingRefused(path: "", error: refusal, homePath: ""))
        // Any case of the sentence counts.
        #expect(
            Favorites.isTrashListingRefused(
                path: "/Users/demo/.Trash", error: "Operation Not Permitted", homePath: Self.home))
    }

    // T-3e7f9b72 B-TREE-033 F-732
    @Test func infersCuratedIconsForCommonAddedFolders() {
        #expect(Favorites.create(path: "/Users/demo/Music", homePath: Self.home).icon == .music)
        #expect(Favorites.create(path: "/Users/demo/Projects", homePath: Self.home).icon == .projects)
        #expect(Favorites.create(path: "/Users/demo", homePath: Self.home).icon == .home)
        #expect(Favorites.create(path: "/Applications", homePath: Self.home).icon == .applications)
        #expect(Favorites.create(path: "/Users/demo/.Trash", homePath: Self.home).icon == .trash)
        #expect(Favorites.create(path: "/", homePath: Self.home).icon == .drive)
        #expect(Favorites.create(path: "/Users/demo/Pictures/", homePath: Self.home).icon == .photos)
        #expect(Favorites.create(path: "/Users/demo/Movies", homePath: Self.home).icon == .videos)
        #expect(Favorites.create(path: "/Users/demo/Videos", homePath: Self.home).icon == .videos)
        #expect(Favorites.create(path: "/Users/demo/Whatever", homePath: Self.home).icon == .folder)
    }

    private func node(_ path: String, expanded: Bool, loaded: Bool, children: [String] = []) -> TreeNodeState {
        var node = TreeNodeState(path: path, name: String(path.split(separator: "/").last ?? "/"), expanded: expanded)
        node.loaded = loaded
        node.childPaths = children
        return node
    }

    // T-16f90fcb F-729
    @Test func includesASyntheticFavoritesRootAheadOfTheFilesystemTree() {
        let nodes = TreeNodes([
            node("/Users/demo", expanded: true, loaded: true, children: ["/Users/demo/src"]),
            node("/Users/demo/src", expanded: false, loaded: false),
        ])
        let presentation = Favorites.presentation(
            .init(
                favorites: [FavoritePreference(path: "/Users/demo/Documents", icon: .documents)],
                favoritesExpanded: true, homePath: Self.home, rootPath: Self.home, nodes: nodes))
        #expect(
            presentation.visibleItemIDs.map(\.rawValue) == [
                "favorites-root", "favorite:/Users/demo/Documents", "fs:/Users/demo", "fs:/Users/demo/src",
            ])
        #expect(presentation.items[.favoritesRoot]?.childIDs == [.favorite("/Users/demo/Documents")])
        #expect(presentation.items[.favoritesRoot]?.icon == .star)
        #expect(presentation.items[.favorite("/Users/demo/Documents")]?.icon == .documents)
        #expect(presentation.items[.filesystem("/Users/demo/src")]?.depth == 1)
        // The heading's depth and a favorite's (B-TREE-007).
        #expect(presentation.items[.favoritesRoot]?.depth == 0)
        #expect(presentation.items[.favorite("/Users/demo/Documents")]?.depth == 1)
    }

    // T-8eb7708a B-TREE-009
    @Test func keepsFavoritesFlatEvenWhenTheFilesystemTreeContainsDescendants() {
        let nodes = TreeNodes([
            node("/Users/demo", expanded: true, loaded: true, children: ["/Users/demo/Documents"]),
            node(
                "/Users/demo/Documents", expanded: true, loaded: true,
                children: ["/Users/demo/Documents/Subfolder"]),
            node("/Users/demo/Documents/Subfolder", expanded: false, loaded: false),
        ])
        let presentation = Favorites.presentation(
            .init(
                favorites: [FavoritePreference(path: "/Users/demo/Documents", icon: .documents)],
                favoritesExpanded: true, homePath: Self.home, rootPath: Self.home, nodes: nodes))
        #expect(presentation.items[.favorite("/Users/demo/Documents")]?.childIDs == [])
        #expect(!presentation.visibleItemIDs.contains(.favorite("/Users/demo/Documents/Subfolder")))
    }

    // T-b44008b1 T-1aad8fe9 F-837 B-TREE-035
    @Test func addsAtTheEndRemovesThatPathOnlyAndRefusesTheTrash() {
        let favorites = Favorites.defaults(homePath: Self.home)
        let added = Favorites.adding("/Users/demo/Music", to: favorites, homePath: Self.home)
        #expect(added?.last == FavoritePreference(path: "/Users/demo/Music", icon: .music))
        #expect(added?.count == favorites.count + 1)
        // Already a favorite: nothing changes. The Trash is refused silently.
        #expect(Favorites.adding("/Applications", to: favorites, homePath: Self.home) == nil)
        #expect(Favorites.adding("/Users/demo/.Trash", to: favorites, homePath: Self.home) == nil)
        // Removing is allowed for a Trash favorite too.
        let withTrash = favorites + [FavoritePreference(path: "/Users/demo/.Trash", icon: .trash)]
        #expect(Favorites.removing("/Users/demo/.Trash", from: withTrash) == favorites)
        #expect(Favorites.removing("/Elsewhere", from: favorites) == nil)
    }

    @Test func itemIDsRoundTripTheirRawForm() {
        for raw in ["favorites-root", "locations-root", "favorite:/a", "location:/", "fs:/Users/demo"] {
            #expect(TreeItemID(rawValue: raw)?.rawValue == raw)
        }
        #expect(TreeItemID(rawValue: "other:/a") == nil)
        // The NFC and NFD spellings of a name are two rows.
        #expect(TreeItemID.filesystem("/caf\u{E9}") != TreeItemID.filesystem("/cafe\u{301}"))
    }
}
