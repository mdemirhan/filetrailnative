// Two folders whose names differ only in how an accent is stored, side by side in the sidebar
import AppKit
import FTFileSystem
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

/// "café" with its "é" as one scalar, and as an "e" with the accent after it: one name to `String`, and two folders on
/// a disk that keeps both (a share from Linux, a FAT disk as some systems write it). A stand-in lists them: a Mac's own
/// disk holds only one.
@MainActor
@Suite struct TreeAccentTwinsTests {
    private let top = "/Volumes/Twins"
    private var composed: String { top + "/caf\u{E9}" }
    private var decomposed: String { top + "/cafe\u{301}" }
    private var plain: String { top + "/plain" }

    /// A sidebar whose tree is at the disk holding the two folders, each with a folder of its own in it.
    private func sidebar() async -> SidebarViewController {
        let controller = SidebarViewController()
        controller.view.frame = NSRect(x: 0, y: 0, width: 260, height: 600)
        var folders: [DiskPath: [TreePaths.Child]] = [:]
        func folder(_ path: String, _ names: [String]) {
            folders[DiskPath(path)] = names.map {
                TreePaths.Child(path: path + "/" + $0, name: $0, isHidden: false, isSymlink: false)
            }
        }
        folder(top, ["caf\u{E9}", "cafe\u{301}", "plain"])
        folder(composed, ["in-composed"])
        folder(decomposed, ["in-decomposed"])
        let listed = folders
        controller.model.readChildren = { path, _ in listed[DiskPath(path)] ?? [] }
        await controller.model.folderOpened(top, .other)
        return controller
    }

    /// The rows the tree's list draws, of one kind.
    private func rows(_ controller: SidebarViewController, _ kind: TreeItemKind = .filesystem) -> [SidebarRowState] {
        (0..<controller.tree.rowCount).compactMap { index in
            guard case .item(let state)? = controller.tree.row(at: index), state.item.kind == kind else { return nil }
            return state
        }
    }

    private func bytes(_ paths: [String?]) -> [[UInt8]] { paths.map { Array(($0 ?? "").utf8) } }

    // Each is a row of its own, and opens onto its own folders.
    @Test func theTwoAreTwoRowsEachOpeningOntoItsOwnFolders() async {
        let controller = await sidebar()
        #expect(bytes(rows(controller).map(\.item.path)) == bytes([top, composed, decomposed, plain]))

        await controller.model.loadChildren(decomposed, expandOnSuccess: true)
        await controller.model.loadChildren(composed, expandOnSuccess: true)

        let expected = [top, composed, composed + "/in-composed", decomposed, decomposed + "/in-decomposed", plain]
        #expect(bytes(rows(controller).map(\.item.path)) == bytes(expected))
        #expect(rows(controller).map(\.item.id) == expected.map { .filesystem($0) })
        // No row of the list stands for two folders.
        let items = (0..<controller.tree.rowCount).compactMap { controller.tree.item(at: $0) }
        #expect(Set(items.map(ObjectIdentifier.init)).count == items.count)

        controller.model.toggle(composed)
        #expect(
            bytes(rows(controller).map(\.item.path))
                == bytes([top, composed, decomposed, decomposed + "/in-decomposed", plain]))
    }

    @Test func selectingOneSelectsOnlyIt() async {
        let controller = await sidebar()
        controller.model.selectItem(.filesystem(decomposed))
        #expect(bytes(rows(controller).filter { $0.selection != .none }.map(\.item.path)) == bytes([decomposed]))
        controller.model.selectItem(.filesystem(composed))
        #expect(bytes(rows(controller).filter { $0.selection != .none }.map(\.item.path)) == bytes([composed]))
    }

    @Test func aDragOverOneIsNotOverTheOther() async {
        let controller = await sidebar()
        controller.dropStates = [DiskPath(decomposed): .valid]
        #expect(bytes(rows(controller).filter { $0.drop != nil }.map(\.item.path)) == bytes([decomposed]))
        controller.dropStates = [DiskPath(composed): .invalid]
        #expect(bytes(rows(controller).filter { $0.drop != nil }.map(\.item.path)) == bytes([composed]))
    }

    @Test func thePaneMarkIsOnTheFolderItsPaneShows() async {
        let controller = await sidebar()
        controller.paneFolders = [decomposed, plain]
        let marked = rows(controller).filter { $0.paneMark != nil }
        #expect(bytes(marked.map(\.item.path)) == bytes([decomposed, plain]))
        #expect(marked.map(\.paneMark) == [SidebarPaneMark(left: true, right: false), .init(left: false, right: true)])
        controller.paneFolders = [plain, composed]
        #expect(bytes(rows(controller).filter { $0.paneMark != nil }.map(\.item.path)) == bytes([composed, plain]))
    }

    // The ring of the row a menu is open for goes from one to the other.
    @Test func aMenusRingMovesFromOneToTheOther() async {
        let controller = await sidebar()
        controller.model.menuTarget = SidebarMenuTarget(path: composed, subview: .tree, kind: .treeFolder)
        #expect(bytes(rows(controller).filter(\.menuTarget).map(\.item.path)) == bytes([composed]))
        controller.model.menuTarget = SidebarMenuTarget(path: decomposed, subview: .tree, kind: .treeFolder)
        #expect(bytes(rows(controller).filter(\.menuTarget).map(\.item.path)) == bytes([decomposed]))
    }

    // Two favorites that differ so: the one dragged is drawn as dragged, and the line is at the one it is over.
    @Test func aFavoriteDraggedOverItsTwinIsTheOnlyOneDragged() async {
        let controller = await sidebar()
        controller.model.favorites = [
            FavoritePreference(path: composed, icon: .folder), FavoritePreference(path: decomposed, icon: .folder),
        ]
        controller.sidebarList(controller.tree, favoriteDragStarted: composed)
        #expect(bytes(rows(controller, .favorite).filter(\.dragging).map(\.item.path)) == bytes([composed]))

        controller.sidebarList(controller.tree, favoriteDragOver: (path: decomposed, position: .after))
        #expect(
            bytes(rows(controller, .favorite).filter { $0.dropLine != nil }.map(\.item.path)) == bytes([decomposed]))

        controller.sidebarList(controller.tree, favoriteDropped: composed)
        #expect(bytes(controller.model.favorites.map(\.path)) == bytes([decomposed, composed]))
    }

    // A disk being ejected is that disk, not one whose name differs so.
    // A row's id is read back from its saved text with every scalar of its path, and is told from its twin's.
    @Test func aRowsSavedTextIsItsPathByteForByte() throws {
        for path in [composed, decomposed, "/", "", "/\u{301}starts-with-an-accent", "\u{301}relative"] {
            for id in [TreeItemID.filesystem(path), .favorite(path), .location(path)] {
                let read = try #require(TreeItemID(rawValue: id.rawValue))
                #expect(read == id)
                #expect(bytes([read.path]) == bytes([path]))
            }
        }
        #expect(TreeItemID.filesystem(composed).rawValue == "fs:" + composed)
        #expect(TreeItemID.favorite(composed).rawValue == "favorite:" + composed)
        #expect(TreeItemID.location(composed).rawValue == "location:" + composed)
        #expect(TreeItemID(rawValue: "favorites-root") == .favoritesRoot)
        #expect(TreeItemID(rawValue: "locations-root") == .locationsRoot)
        #expect(TreeItemID(rawValue: "elsewhere:/a") == nil)
        #expect(TreeItemID.filesystem(composed) != .filesystem(decomposed))
        #expect(Set([TreeItemID.filesystem(composed), .filesystem(decomposed), .favorite(composed)]).count == 3)
    }

    @Test func aDiskBeingEjectedIsNotItsTwin() async {
        let gate = EjectGate()
        var asked: [String] = []
        let coordinator = EjectCoordinator(
            volumes: { [] },
            eject: { request in
                await MainActor.run { asked.append(request.path) }
                await gate.wait()
                return EjectResponse(status: .ejected)
            })
        let first = Task { await coordinator.run(path: "/Volumes/caf\u{E9}", wholeDisk: true, force: false) }
        #expect(await waitUntil { asked.count == 1 })
        let second = Task { await coordinator.run(path: "/Volumes/cafe\u{301}", wholeDisk: true, force: false) }
        #expect(await waitUntil(timeout: .seconds(3)) { asked.count == 2 })
        #expect(coordinator.ejectingPaths.count == 2)
        await gate.open()
        await first.value
        await second.value
        #expect(bytes(asked) == bytes(["/Volumes/caf\u{E9}", "/Volumes/cafe\u{301}"]))
    }
}

/// A tree whose top a tab kept from an earlier launch, over a stand-in for the listings.
@MainActor
@Suite struct TreeKeptTopTests {
    private let listed = "/Volumes/Twins/caf\u{E9}"
    private let kept = "/Volumes/Twins/cafe\u{301}"

    private func bytes(_ paths: [String]) -> [[UInt8]] { paths.map { Array($0.utf8) } }

    /// A link to the folder, named with an accent of its own.
    private let link = "/Volumes/Twins/lie\u{301}"

    /// A model restored with its top at `root`. The disk has "café" composed and takes either spelling for it, as a
    /// Mac's own does, and "lié" and "plain" are links that lead to it; a listing spells what it lists as the disk
    /// does.
    private func model(root: String) -> (model: SidebarModel, asked: () -> [String]) {
        let model = SidebarModel()
        model.homePath = "/Users/demo"
        let folder = listed
        let spellings = [
            DiskPath(kept): folder, DiskPath(link): folder, DiskPath("/Volumes/Twins/plain"): folder,
        ]
        var asked: [String] = []
        model.listedPath = { path in
            asked.append(path)
            return spellings[DiskPath(path)] ?? path
        }
        model.readChildren = { path, _ in
            let real = spellings[DiskPath(path)] ?? path
            let names: [String]
            switch DiskPath(real) {
            case DiskPath("/Volumes/Twins"): names = ["caf\u{E9}", "lie\u{301}", "plain"]
            case DiskPath(folder): names = ["sub"]
            default: names = []
            }
            return names.map {
                TreePaths.Child(path: real + "/" + $0, name: $0, isHidden: false, isSymlink: !$0.hasPrefix("caf"))
            }
        }
        model.restore(
            rootPath: root, selected: .filesystem(root + "/sub"), subview: .tree, favoritesExpanded: true,
            locationsExpanded: true)
        return (model, { asked })
    }

    private func rows(_ model: SidebarModel) -> [String] {
        model.treePresentation.visibleItemIDs.compactMap(\.filesystemPath)
    }

    // The top spelled otherwise than its listing spells it: the tree stays there, by the listing's spelling.
    @Test func aTopSpelledOtherwiseStartsAgainFromItsListingsSpelling() async {
        let made = model(root: kept)
        await made.model.folderOpened(listed + "/sub", .other)
        #expect(bytes([made.model.rootPath]) == bytes([listed]))
        #expect(made.model.selected == .filesystem(listed + "/sub"))
        #expect(bytes(rows(made.model)) == bytes([listed, listed + "/sub"]))
        #expect(bytes(made.asked()) == bytes([kept]))

        // Asked once: a folder outside the tree moves its top as ever, with nothing listed for its spelling.
        await made.model.folderOpened("/Volumes/Twins", .other)
        #expect(made.model.rootPath == "/Volumes/Twins")
        #expect(made.asked().count == 1)
    }

    // The top spelled as its listing spells it holds the folder byte for byte: nothing is asked.
    @Test func aTopSpelledAsListedIsNotAskedAbout() async {
        let made = model(root: listed)
        await made.model.folderOpened(listed + "/sub", .other)
        #expect(bytes([made.model.rootPath]) == bytes([listed]))
        #expect(made.asked().isEmpty)
        await made.model.folderOpened("/Volumes/Twins", .other)
        #expect(made.asked().isEmpty)
    }

    // A top that is a link is another folder to its listing: the tree moves to the disk, as it does for any folder
    // outside its top.
    @Test func aTopThatIsALinkMovesAsBefore() async {
        let made = model(root: link)
        await made.model.folderOpened(listed + "/sub", .other)
        #expect(made.model.rootPath == "/Volumes/Twins")
        #expect(made.model.selected == .filesystem(listed + "/sub"))
        #expect(bytes(made.asked()) == bytes([link]))
    }

    // A top with no accent in it has one spelling: no disk is asked, whatever is opened.
    @Test func aTopOfPlainLettersIsNeverAskedAbout() async {
        let made = model(root: "/Volumes/Twins/plain")
        await made.model.folderOpened(listed + "/sub", .other)
        #expect(made.model.rootPath == "/Volumes/Twins")
        #expect(made.model.selected == .filesystem(listed + "/sub"))
        #expect(made.asked().isEmpty)
    }

    // The other pane of a tab becoming the active one finds its folder in the tree kept so, too.
    @Test func theOtherPanesFolderIsFoundInATopSpelledOtherwise() async {
        let made = model(root: kept)
        await made.model.activePaneChanged(to: listed + "/sub")
        #expect(bytes([made.model.rootPath]) == bytes([listed]))
        #expect(made.model.selected == .filesystem(listed + "/sub"))
    }
}

/// Holds an eject until the test lets it go.
private actor EjectGate {
    private var opened = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func open() {
        opened = true
        for continuation in waiting { continuation.resume() }
        waiting = []
    }
}
