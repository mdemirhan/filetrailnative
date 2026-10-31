// The sidebar's tree and selection as the original's navigation controller keeps them
// (apps/desktop/src/renderer/hooks/useExplorerNavigationController.ts, B-TREE-073..102), without views
import FTFileSystem
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

/// A folder tree by hand: the folders of each path.
@MainActor
private final class Disk {
    var children: [String: [TreePaths.Child]] = [:]
    var reads: [String] = []
    var failing: [String: String] = [:]

    func folder(_ path: String, _ names: [String], hidden: [String] = [], aliases: [String] = []) {
        children[path] =
            (names + hidden).sorted().map { name in
                let child = path == "/" ? "/\(name)" : "\(path)/\(name)"
                return TreePaths.Child(
                    path: child, name: name, isHidden: hidden.contains(name), isSymlink: aliases.contains(name))
            }
    }
}

private struct Failure: Error {
    let text: String
}

@MainActor
private final class Rig {
    let disk = Disk()
    let model = SidebarModel()
    var opened: [(String, SidebarOpen)] = []
    var timers: [(at: Int, fire: @MainActor () -> Void, id: Int)] = []
    var clock = 0
    var nextID = 0
    var released = 0
    var savedFavorites: [[FavoritePreference]] = []

    init(home: String = "/Users/demo") {
        model.homePath = home
        disk.folder("/", ["Applications", "Users", "Volumes"])
        disk.folder("/Users", ["demo", "other"])
        disk.folder("/Users/demo", ["Documents", "Linked", "src"], hidden: [".config"], aliases: ["Linked"])
        disk.folder("/Users/demo/src", ["app", "lib"])
        disk.folder("/Users/demo/src/app", ["Safari.app".replacingOccurrences(of: ".app", with: "x")])
        let disk = self.disk
        model.readChildren = { path, includeHidden in
            disk.reads.append(path)
            if let text = disk.failing[path] { throw Failure(text: text) }
            return (disk.children[path] ?? []).filter { includeHidden || !$0.isHidden }
        }
        model.openFolder = { [unowned self] url, open in opened.append((url.path, open)) }
        model.releaseFolder = { [unowned self] in released += 1 }
        model.onFavoritesChanged = { [unowned self] in savedFavorites.append($0) }
        model.schedule = { [unowned self] milliseconds, fire in
            nextID += 1
            let id = nextID
            timers.append((clock + milliseconds, fire, id))
            return { [weak self] in self?.timers.removeAll { $0.id == id } }
        }
        model.favorites = Favorites.defaults(homePath: home)
    }

    func advance(_ milliseconds: Int) {
        clock += milliseconds
        while let next = timers.filter({ $0.at <= clock }).min(by: { $0.at < $1.at }) {
            timers.removeAll { $0.id == next.id }
            next.fire()
        }
    }

    func visible() -> [String] { model.treePresentation.visibleItemIDs.map(\.rawValue) }
}

struct SidebarModelTests {
    // T-07c435a7 T-620275a3 T-8012dbd4 T-0b507270 F-729 B-TREE-075 B-TREE-097
    // B-NAV-020 B-NAV-096
    @Test @MainActor func opensTheTreeDownToAFolderSelectingItsRowAndLeavingItClosed() async {
        let rig = Rig()
        await rig.model.folderOpened("/Users/demo/src", .other)
        #expect(rig.model.rootPath == "/Users/demo")
        #expect(rig.model.selected == .filesystem("/Users/demo/src"))
        #expect(rig.model.subview == .tree)
        let ids = rig.visible()
        #expect(ids.contains("fs:/Users/demo"))
        #expect(ids.contains("fs:/Users/demo/src"))
        // The folder itself is read only when it is already open.
        #expect(!rig.disk.reads.contains("/Users/demo/src"))
        #expect(rig.model.nodes["/Users/demo"]?.expanded == true)
        #expect(rig.model.nodes["/Users/demo/src"]?.expanded == false)
    }

    // T-36c41abf T-c6941446 T-7d4e382e T-52453124 B-TREE-073 B-TREE-078
    // B-NAV-081 B-NAV-097 B-TREE-076
    @Test @MainActor func keepsAHandPickedRootWhileFoldersOpenInsideItAndMovesItForAFolderOutside() async {
        let rig = Rig()
        await rig.model.folderOpened("/Users/demo/src", SidebarOpen(rerootTree: true))
        #expect(rig.model.rootPath == "/Users/demo/src")
        await rig.model.folderOpened("/Users/demo/src/app", .other)
        #expect(rig.model.rootPath == "/Users/demo/src")
        // A folder outside: Home for what is in Home, otherwise the disk.
        await rig.model.folderOpened("/Users/demo/Documents", .other)
        #expect(rig.model.rootPath == "/Users/demo")
        await rig.model.folderOpened("/Applications", .other)
        #expect(rig.model.rootPath == "/")
        await rig.model.folderOpened("/Volumes/Backup/Photos", .other)
        #expect(rig.model.rootPath == "/Volumes/Backup")
    }

    // T-8b29ba2d T-7170adb7 B-TREE-079 B-TREE-080 B-TREE-101
    // B-NAV-020 B-NAV-080 B-NAV-081 B-TREE-098 T-6c54c49c
    @Test @MainActor func aFavoriteKeepsItsRowSelectedAndALocationRootsTheTreeAtItsTop() async {
        let rig = Rig()
        await rig.model.folderOpened("/Users/demo/src", .other)
        // A favorite inside the root keeps the root; /Applications is outside, so the root moves to "/".
        await rig.model.folderOpened(
            "/Users/demo/Documents", SidebarOpen(origin: .favorite(.favorite("/Users/demo/Documents"))))
        #expect(rig.model.rootPath == "/Users/demo")
        #expect(rig.model.selected == .favorite("/Users/demo/Documents"))
        await rig.model.folderOpened("/Applications", SidebarOpen(origin: .favorite(.favorite("/Applications"))))
        #expect(rig.model.rootPath == "/")
        #expect(rig.model.selected == .favorite("/Applications"))
        // A location: the tree starts at the place's own top.
        await rig.model.folderOpened("/Users/demo", SidebarOpen(origin: .location(.location("/Users/demo"))))
        #expect(rig.model.rootPath == "/Users/demo")
        #expect(rig.model.selected == .location("/Users/demo"))
        await rig.model.folderOpened("/", SidebarOpen(origin: .location(.location("/"))))
        #expect(rig.model.rootPath == "/")
        // Back to a folder row: the filesystem row is selected, not the favorite.
        await rig.model.folderOpened("/Applications", .other)
        #expect(rig.model.selected == .filesystem("/Applications"))
    }

    // T-8b29ba2d T-ed81b82b B-TREE-081
    // B-NAV-082 B-TREE-083
    @Test @MainActor func theTrashOpenedFromTheSidebarLeavesTheTreeAlone() async {
        let rig = Rig()
        await rig.model.folderOpened("/Users/demo/src", .other)
        let reads = rig.disk.reads.count
        await rig.model.folderOpened(
            "/Users/demo/.Trash", SidebarOpen(origin: .location(.location("/Users/demo/.Trash"))))
        #expect(rig.model.rootPath == "/Users/demo")
        #expect(rig.disk.reads.count == reads)
        #expect(rig.model.selected == .location("/Users/demo/.Trash"))
    }

    // T-1fb6401c T-1a68f61e B-TREE-100
    // B-NAV-079 B-TREE-099
    @Test @MainActor func aLinkKeepsItsRowAndDoesNotMoveOrReadTheTree() async {
        let rig = Rig()
        await rig.model.folderOpened("/Users/demo/src", .other)
        rig.model.selectItem(.filesystem("/Users/demo/Linked"))
        #expect(rig.opened.last?.1.origin == .alias)
        let reads = rig.disk.reads
        await rig.model.folderOpened("/Users/demo/Linked", rig.opened.last!.1)
        #expect(rig.model.selected == .filesystem("/Users/demo/Linked"))
        #expect(rig.disk.reads == reads)
        #expect(rig.model.nodes["/Users/demo/Linked"]?.isSymlink == true)
    }

    // T-431cfb70 T-56d4103f B-TREE-084 B-TREE-091
    // B-TREE-094: `refreshDirectory`'s `treeSelectionPath`: the row is selected and the tree read down to it, with
    // nothing opened; a folder opened meanwhile wins.
    @Test @MainActor func aWritesEndSelectsARowWithoutOpeningIt() async {
        let rig = Rig()
        await rig.model.folderOpened("/Users/demo/src", .other)
        rig.opened = []
        rig.disk.folder("/Users/demo/src/app", ["Made"])

        var open = rig.model.openReadingAgain("/Users/demo/src")
        open.selectingRow = "/Users/demo/src/app/Made"
        await rig.model.folderOpened("/Users/demo/src", open)
        #expect(rig.model.currentItemID == .filesystem("/Users/demo/src/app/Made"))
        #expect(rig.model.currentPath == "/Users/demo/src")
        #expect(rig.visible().contains("fs:/Users/demo/src/app/Made"))
        #expect(rig.opened.isEmpty)

        // The folder on screen moved by the write: the row asked for, not the folder's own.
        await rig.model.folderOpened("/Users/demo", SidebarOpen(selectingRow: "/Users/demo/src/lib"))
        #expect(rig.model.currentItemID == .filesystem("/Users/demo/src/lib"))
        #expect(rig.model.currentPath == "/Users/demo")
        #expect(rig.opened.isEmpty)

        // The next write asks for no row: the tree comes back to the folder on screen.
        await rig.model.folderOpened("/Users/demo", rig.model.openReadingAgain("/Users/demo"))
        #expect(rig.model.currentItemID == .filesystem("/Users/demo"))
    }

    // B-TREE-094: `getSelectedTreeReloadOptions`: the row of a link stays through a write that asks for none, the tree
    // left as it is; a row the write asks for is still selected.
    @Test @MainActor func aWritesEndKeepsALinksRowUnlessItAsksForARow() async {
        let rig = Rig()
        await rig.model.folderOpened("/Users/demo/src", .other)
        rig.model.selectItem(.filesystem("/Users/demo/Linked"))
        await rig.model.folderOpened("/Users/demo/Linked", rig.opened.last!.1)

        await rig.model.folderOpened("/Users/demo/Linked", rig.model.openReadingAgain("/Users/demo/Linked"))
        #expect(rig.model.selected == .filesystem("/Users/demo/Linked"))

        var open = rig.model.openReadingAgain("/Users/demo/Linked")
        #expect(open.origin == .alias)
        open.selectingRow = "/Users/demo/src"
        await rig.model.folderOpened("/Users/demo/Linked", open)
        #expect(rig.model.selected == .filesystem("/Users/demo/src"))
    }

    // B-NAV-095 B-NAV-130 T-4e880a90
    @Test @MainActor func hiddenFoldersShowOnlyWithShowHiddenExceptTheOneOnThePathToTheFolderOnScreen() async {
        let rig = Rig()
        rig.disk.folder("/Users/demo/.config", ["app"])
        await rig.model.folderOpened("/Users/demo/src", .other)
        #expect(!rig.visible().contains("fs:/Users/demo/.config"))
        await rig.model.folderOpened("/Users/demo/.config/app", .other)
        #expect(rig.visible().contains("fs:/Users/demo/.config"))
        #expect(rig.visible().contains("fs:/Users/demo/.config/app"))
        // Back to a folder elsewhere: the hidden one is gone again.
        await rig.model.folderOpened("/Users/demo/src", SidebarOpen(forceTreeReload: true))
        #expect(!rig.visible().contains("fs:/Users/demo/.config"))
        // With hidden files on, all of them are listed; turning them off seeds the tree again.
        rig.model.includeHidden = true
        await rig.model.folderOpened("/Users/demo/src", SidebarOpen(forceTreeReload: true))
        #expect(rig.visible().contains("fs:/Users/demo/.config"))
        rig.model.includeHidden = false
        rig.model.hiddenFilesChanged()
        await settleModel()
        #expect(!rig.visible().contains("fs:/Users/demo/.config"))
        #expect(
            rig.model.nodes["/Users/demo/Documents"] == nil
                || rig.model.nodes["/Users/demo/Documents"]?.expanded == false)
    }

    // T-223415d5 T-4becddde T-38c52395 B-TREE-085 B-TREE-086
    // B-NAV-095
    @Test @MainActor func aPackageOnThePathIsAddedInOrderAndVolumesLeavesMacintoshHDUnlessHiddenShow() async {
        let rig = Rig(home: "")
        rig.disk.folder("/Applications", ["Alpha", "Zed"])
        await rig.model.folderOpened("/Applications/Mail.app/Contents", .other)
        #expect(
            rig.model.nodes["/Applications"]?.childPaths == [
                "/Applications/Alpha", "/Applications/Mail.app", "/Applications/Zed",
            ])
        // /Volumes is left out of Macintosh HD's children, where the other disks are under Locations.
        #expect(rig.model.nodes["/"]?.childPaths.contains("/Volumes") == false)
    }

    // T-de93e592 B-TREE-088 B-TREE-089 B-TREE-090
    @Test @MainActor func aFailedReadLeavesTheFolderUnreadAndShowsWhyAndTheLoadingLineWaits() async {
        let rig = Rig()
        await rig.model.folderOpened("/Users/demo", .other)
        rig.disk.failing["/Users/demo/Documents"] = "boom"
        await rig.model.loadChildren("/Users/demo/Documents", expandOnSuccess: true)
        let node = rig.model.nodes["/Users/demo/Documents"]
        #expect(node?.loaded == false)
        #expect(node?.expanded == false)
        #expect(node?.loading == false)
        #expect(node?.error?.isEmpty == false)
        // The next try reads it again.
        rig.disk.failing = [:]
        await rig.model.loadChildren("/Users/demo/Documents", expandOnSuccess: true)
        #expect(rig.model.nodes["/Users/demo/Documents"]?.loaded == true)
        #expect(rig.model.nodes["/Users/demo/Documents"]?.expanded == true)
        #expect(rig.model.nodes["/Users/demo/Documents"]?.error == nil)
        // An empty folder keeps its chevron once read; Right on it does nothing.
        rig.model.selectItem(.filesystem("/Users/demo/Documents"))
        #expect(!rig.model.handle(.right))
    }

    // T-0cd8f183 T-2404af85 B-TREE-087
    // B-NAV-096 B-NAV-193 B-TREE-180
    @Test @MainActor func aFolderLoadedOrLoadingIsNotReadTwiceButAForcedReloadAlwaysReads() async {
        let rig = Rig()
        await rig.model.folderOpened("/Users/demo", .other)
        let first = rig.disk.reads.filter { $0 == "/Users/demo" }.count
        await rig.model.loadChildren("/Users/demo", expandOnSuccess: true)
        #expect(rig.disk.reads.filter { $0 == "/Users/demo" }.count == first)
        await rig.model.loadChildren("/Users/demo", forceReload: true)
        #expect(rig.disk.reads.filter { $0 == "/Users/demo" }.count == first + 1)
        // A new root forgets what was under way: an old answer does not land.
        rig.model.initializeTree("/Users")
        #expect(rig.model.nodes["/Users/demo"] == nil)
    }

    // T-fc0da8c2 T-eaf07a43 T-6625a938 F-740 B-TREE-111 B-TREE-113
    // B-NAV-086 B-NAV-088
    @Test @MainActor func theArrowKeysOpenABranchGoIntoItAndComeBackOut() async {
        let rig = Rig()
        await rig.model.folderOpened("/Users/demo", .other)
        rig.model.selectItem(.filesystem("/Users/demo/src"))
        // Never read: Right reads and opens it, the selection stays.
        #expect(rig.model.handle(.right))
        await settleModel()
        #expect(rig.model.nodes["/Users/demo/src"]?.expanded == true)
        #expect(rig.model.selected == .filesystem("/Users/demo/src"))
        // Open with subfolders: Right goes to the first one, opening it.
        #expect(rig.model.handle(.right))
        #expect(rig.model.selected == .filesystem("/Users/demo/src/app"))
        #expect(rig.opened.last?.0 == "/Users/demo/src/app")
        // Left goes back up to the parent.
        #expect(rig.model.handle(.left))
        #expect(rig.model.selected == .filesystem("/Users/demo/src"))
        // Left on an open branch closes it, selection stays.
        #expect(rig.model.handle(.left))
        #expect(rig.model.nodes["/Users/demo/src"]?.expanded == false)
        #expect(rig.model.selected == .filesystem("/Users/demo/src"))
    }

    // T-e976a231 T-faee0026 B-TREE-128 B-TREE-129 B-TREE-130 B-TREE-133
    // B-NAV-093 B-SEL-096 B-SEL-097 T-c48862d7
    @Test @MainActor func typingBuildsAPrefixForASecondAndSelectsTheFirstMatch() async {
        let rig = Rig()
        await rig.model.folderOpened("/Users/demo", .other)
        rig.model.type("d")
        #expect(rig.model.selected == .favorite("/Users/demo/Desktop"))
        rig.model.type("o")
        #expect(rig.model.selected == .favorite("/Users/demo/Documents") || rig.model.typeaheadQuery == "do")
        #expect(rig.model.typeaheadQuery == "do")
        // The prefix is forgotten 1000 ms after the last key.
        rig.advance(999)
        #expect(rig.model.typeaheadQuery == "do")
        rig.advance(1)
        #expect(rig.model.typeaheadQuery.isEmpty)
        // A key typed within the second restarts the wait.
        rig.model.type("s")
        rig.advance(900)
        rig.model.type("r")
        rig.advance(900)
        #expect(rig.model.typeaheadQuery == "sr")
        rig.advance(100)
        #expect(rig.model.typeaheadQuery.isEmpty)
    }

    // T-3612c2bf T-04cd2bf4 T-5203f9f2 T-54e05341 T-11c34a3c B-TREE-059 B-TREE-060 B-TREE-061
    @Test @MainActor func clearingTheSelectionLetsGoOfTheFolderOnScreen() async {
        let rig = Rig()
        await rig.model.folderOpened("/Users/demo/src", .other)
        rig.model.clearSelection()
        #expect(rig.model.selected == nil)
        #expect(rig.released == 1)
    }

    // T-e6bdc21c B-TREE-051 B-TREE-056
    @Test @MainActor func aPressedRowShowsSelectedAtOnceAndNotOnceItsFolderFailsToOpen() async {
        let rig = Rig()
        await rig.model.folderOpened("/Users/demo", .other)
        rig.model.markPressed(.filesystem("/Users/demo/src"))
        #expect(rig.model.currentItemID == .filesystem("/Users/demo/src"))
        #expect(rig.model.selected == .filesystem("/Users/demo"))
        rig.model.openFailed()
        #expect(rig.model.currentItemID == .filesystem("/Users/demo"))
    }

    // T-70dc8460 T-88a6a54c F-738 B-TREE-043 B-TREE-044
    @Test @MainActor func reorderingFavoritesSavesOnlyWhenTheOrderChanges() async {
        let rig = Rig()
        rig.model.reorder(moved: "/Applications", target: "/Applications", position: .after)
        #expect(rig.savedFavorites.isEmpty)
        rig.model.reorder(moved: "/Users/demo/Downloads", target: "/Applications", position: .before)
        #expect(rig.savedFavorites.count == 1)
        #expect(rig.model.favorites.first?.path == "/Users/demo/Downloads")
    }

    // T-f18d8812 T-8cb3e771 T-4d6ca227 B-TREE-066 B-TREE-067 B-TREE-068
    // B-TREE-095
    @Test @MainActor func closingTheFavoritesListSwitchesTheKeyboardToTheTree() async {
        let rig = Rig()
        rig.model.placement = .separate
        rig.model.restore(
            rootPath: "/Users/demo", selected: .favorite("/Applications"), subview: .favorites,
            favoritesExpanded: true, locationsExpanded: true)
        rig.model.toggleFavorites()
        #expect(rig.model.favoritesExpanded == false)
        #expect(rig.model.subview == .tree)
        rig.model.toggleLocations()
        #expect(rig.model.locationsExpanded == false)
        // A heading is never selected.
        rig.model.selectItem(.favoritesRoot)
        #expect(rig.opened.isEmpty)
    }

    // T-3d2da726 B-TREE-103 B-TREE-081
    // B-TREE-105
    @Test @MainActor func theCommandsOfTheSidebarRowSelection() async {
        let rig = Rig()
        rig.model.restore(
            rootPath: "/Users/demo", selected: .location("/"), subview: .tree, favoritesExpanded: true,
            locationsExpanded: true)
        // A location row gives the commands no target (B-TREE-105).
        #expect(rig.model.selectedTreeTargetPath == nil)
        rig.model.restore(
            rootPath: "/Users/demo", selected: .favorite("/Applications"), subview: .tree, favoritesExpanded: true,
            locationsExpanded: true)
        #expect(rig.model.selectedTreeTargetPath == "/Applications")
    }
}

@MainActor
private func settleModel() async {
    for _ in 0..<60 { await Task.yield() }
}
