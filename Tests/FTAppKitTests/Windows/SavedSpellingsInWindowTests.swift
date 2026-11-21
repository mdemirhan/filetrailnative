// What an earlier launch saved under another spelling of a folder's path, against the folder as its listing spells it
import AppKit
import FTFileSystem
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTAppKit

/// A disk that keeps two folders whose names differ only in how an accent is encoded, as FAT and some network disks
/// can: each is a folder of its own under the name it is asked by, and `realpath` gives each as it is spelled.
private final class TwoSpellingsDisk: ExplorerFileSystem, @unchecked Sendable {
    private let real = NativeFileSystem()
    private let parent: DiskPath
    /// Each folder's name on this disk, and the name of the folder of the real disk that stands behind it.
    private let folders: [(name: String, behind: String)]

    init(parent: String, folders: [(name: String, behind: String)]) {
        self.parent = DiskPath(parent)
        self.folders = folders
    }

    /// Which of the two folders `path` is at or inside, if any.
    private func folder(of path: String) -> (name: String, behind: String)? {
        folders.first { DiskPath(path).isAtOrInside(parent.appending($0.name)) }
    }

    /// The path of the real disk that stands behind `path`.
    private func behind(_ path: String) -> String {
        guard let folder = folder(of: path) else { return path }
        let own = parent.appending(folder.name).string
        let rest = path.utf8.index(path.utf8.startIndex, offsetBy: own.utf8.count)
        return parent.appending(folder.behind).string + path[rest...]
    }

    func readDirectory(_ path: String) throws -> [DirectoryRecord] {
        var records = try real.readDirectory(behind(path))
        guard DiskPath(path) == parent else { return records }
        for index in records.indices {
            if let folder = folders.first(where: { $0.behind == records[index].name }) {
                records[index].name = folder.name
            }
        }
        return records
    }

    func stat(_ path: String) throws -> FileStats { try real.stat(behind(path)) }
    func lstat(_ path: String) throws -> FileStats { try real.lstat(behind(path)) }

    func realpath(_ path: String) throws -> String {
        guard folder(of: path) != nil else { return try real.realpath(path) }
        _ = try real.stat(behind(path))
        return path
    }
}

extension ExplorerWindowlessTests {
    /// A launch that knew its folders by a `URL`'s spelling saved "café" with the accent apart, where the disk has it
    /// as one scalar: what it saved is the folder's again once the folder's listing has said how it is spelled.
    @MainActor
    @Suite struct SavedSpellingsInWindowTests: SidebarTesting {
        private struct Made {
            let harness: ExplorerHarness
            let parent: String
            /// "café" as the disk keeps it, and as an earlier launch saved it.
            let composed: String
            let decomposed: String
        }

        private static let previews = FolderViewKeeps(
            view: .previews, sort: FolderViewSort(by: .modified, direction: .desc))

        /// A harness with "café" in its folder, kept with its "é" as one scalar.
        private func made() throws -> Made {
            let harness = try ExplorerHarness.windowless()
            let parent = listed(harness, "")
            // mkdir(2) keeps the name as given; Foundation would decompose it.
            let composed = parent + "/caf\u{E9}"
            #expect(mkdir(composed, 0o755) == 0)
            #expect(mkdir(composed + "/2019", 0o755) == 0)
            let decomposed = try #require(DiskPath(composed).asAURLSpells()).string
            #expect(!samePath(composed, decomposed))
            return Made(harness: harness, parent: parent, composed: composed, decomposed: decomposed)
        }

        private func bytes(_ paths: [String?]) -> [[UInt8]?] { paths.map { $0.map { Array($0.utf8) } } }

        /// The paths among `paths` that are "café" by either spelling, each as it is spelled.
        private func spellings(_ paths: [String], of made: Made) -> [String] {
            paths.filter { samePath($0, made.composed) || samePath($0, made.decomposed) }
        }

        private func shows(_ pane: BrowserPane, _ path: String) -> Bool {
            samePath(pane.shownFolderPath, path) && !pane.isNavigating
        }

        private func go(_ tab: MainWindowController, to path: String, shown: String? = nil) async {
            tab.go(to: path)
            #expect(await waitUntil { shows(tab.activePane, shown ?? path) })
        }

        private func tab(_ path: String) -> OpenTabPreference {
            OpenTabPreference(
                path: path, treeRootPath: nil, favoritePath: nil, viewMode: .list, searchViewMode: .details,
                sortBy: .name, sortDirection: .asc, includeHidden: false, foldersFirst: true,
                favoritesExpanded: true, locationsExpanded: true)
        }

        private func workspace(_ paths: [String]) -> Workspace {
            var session = AppPreferences.defaults().windowSession
            session.openTabs = paths.map(tab)
            return Workspace(
                id: "workspace-1", name: "Work", bounds: StoredWindowState(width: 900, height: 600, maximized: false),
                session: session)
        }

        /// The harness's window, with the folders' views kept in its store and its visits recorded there, as the
        /// app's are. `disk` stands in for the disk its folders are read from.
        private func open(_ harness: ExplorerHarness, disk: (any ExplorerFileSystem)? = nil) async throws
            -> (tab: MainWindowController, views: SharedFolderViews)
        {
            let store = harness.store
            MainWindowController.visitStore = { store }
            let tab = try await harness.open()
            var services = harness.services
            let views = SharedFolderViews(store: store)
            services.folderViews = views
            if let disk { services.directoryService = DirectoryService(fileSystem: disk) }
            tab.servicesOverride = services
            tab.setMode(.list)
            return (tab, views)
        }

        private func close(_ harness: ExplorerHarness) async {
            await harness.close()
            MainWindowController.visitStore = { (NSApp.delegate as? AppDelegate)?.store }
        }

        private func text(_ harness: ExplorerHarness, _ name: String) throws -> String {
            try String(contentsOfFile: harness.folder.path + "/" + name, encoding: .utf8)
        }

        private func holds(_ text: String, _ path: String) -> Bool {
            text.utf8.split(separator: UInt8(ascii: "\"")).contains { $0.elementsEqual(path.utf8) }
        }

        /// The file's number on its disk: another once the file has been written again.
        private func fileNumber(_ harness: ExplorerHarness, _ name: String) -> UInt64 {
            var info = stat()
            return stat(harness.folder.path + "/" + name, &info) == 0 ? UInt64(info.st_ino) : 0
        }

        // Opened by the path its row has, the folder finds the view, the favorite, the workspace's tab, the visits and
        // the folder chosen in Move To that were saved under the other spelling, and they are saved under its own.
        @Test func whatWasSavedUnderTheOtherSpellingIsTheFoldersOnceItIsListed() async throws {
            let made = try made()
            let store = made.harness.store
            let alpha = made.parent + "/Alpha"
            store.update {
                $0.favorites = [
                    FavoritePreference(path: alpha, icon: .folder),
                    FavoritePreference(path: made.decomposed, icon: .star),
                ]
                $0.favoritesInitialized = true
                $0.workspaces = [workspace([made.decomposed, alpha])]
            }
            store.updateFolderViews { $0.set(FolderView(path: made.decomposed, keeps: Self.previews)) }
            store.recordFolderVisit(made.decomposed, kind: .goTo, now: 1_000)
            store.recordDestination(made.decomposed, now: 2_000)
            let (tab, views) = try await open(made.harness)
            let pane = tab.activePane
            #expect(pane.shownMode == .list)

            await go(tab, to: made.composed)

            // Its view is found, and is the one shown.
            #expect(pane.folderView?.use.own == true)
            #expect(bytes([pane.folderView?.use.view.path]) == bytes([made.composed]))
            #expect(pane.shownMode == .previews)
            #expect(pane.shownSortBy == .modified && pane.shownSortDirection == .desc)
            #expect(views.views.own(made.decomposed) == nil)
            #expect(views.views.own(made.composed)?.keeps == Self.previews)
            // It is the favorite: once in the list, in its place, and offered to be taken out, not added again.
            #expect(bytes(tab.preferences.favorites.map(\.path)) == bytes([alpha, made.composed]))
            #expect(tab.preferences.favorites.map(\.icon) == [.folder, .star])
            #expect(tab.sidebarController.isFavorite(made.composed))
            #expect(bytes(tab.sidebarController.model.favorites.map(\.path)) == bytes([alpha, made.composed]))
            // The workspace's tab is on it.
            let saved = store.preferences().workspaces[0].session
            #expect(bytes(Workspaces.folders(of: saved)) == bytes([made.composed, alpha]))
            // Go To and Move To list it once.
            #expect(bytes(store.destinations().map(\.path)) == bytes([made.composed]))
            #expect(bytes(spellings(store.folders().map(\.path), of: made)) == bytes([made.composed]))
            let places = Places.build(
                visitedFolders: store.folders(), favoritePaths: tab.preferences.favorites.map(\.path),
                currentPath: made.parent, homePath: made.parent, now: 3_000, destinationFolders: store.destinations())
            #expect(bytes(spellings(places.map(\.path), of: made)) == bytes([made.composed]))
            #expect(places.first { samePath($0.path, made.composed) }?.isDestination == true)

            // Each file is written with the listing's spelling, and holds the other no more.
            store.flush()
            let names = ["folder-views.json", "destination-folders.json", "visited-folders.json"]
            for name in names {
                let text = try text(made.harness, name)
                #expect(holds(text, made.composed) && !holds(text, made.decomposed), "\(name)")
            }
            let state = try JSONNode.parse(Data(try text(made.harness, "app-state.json").utf8))["preferences"]
            #expect(bytes([state?["favorites"]?.array?.last?["path"]?.string]) == bytes([made.composed]))
            let numbers = names.map { fileNumber(made.harness, $0) }
            let favorites = store.preferences().favorites
            let workspaces = store.preferences().workspaces
            let kept = views.views

            // Opened again, nothing is left to take over: nothing changes, and no file of a folder's view or of the
            // folders chosen is written again.
            await go(tab, to: made.parent)
            await go(tab, to: made.composed)
            store.flush()
            #expect(pane.shownMode == .previews)
            #expect(store.preferences().favorites == favorites)
            #expect(store.preferences().workspaces == workspaces)
            #expect(views.views == kept)
            #expect(names.prefix(2).map { fileNumber(made.harness, $0) } == Array(numbers.prefix(2)))
            #expect(bytes(spellings(store.folders().map(\.path), of: made)) == bytes([made.composed]))
            await close(made.harness)
        }

        // A view kept for the folder above, which covers the folders inside, is found from a folder inside it.
        @Test func aViewOfAFolderAboveSavedUnderTheOtherSpellingCoversTheFolderOpened() async throws {
            let made = try made()
            let store = made.harness.store
            store.updateFolderViews {
                $0.set(FolderView(path: made.decomposed, subfolders: true, keeps: Self.previews))
            }
            let (tab, views) = try await open(made.harness)

            await go(tab, to: made.composed + "/2019")

            let pane = tab.activePane
            #expect(pane.folderView?.use.own == false)
            #expect(bytes([pane.folderView?.use.view.path]) == bytes([made.composed]))
            #expect(pane.shownMode == .previews)
            #expect(views.views.own(made.decomposed) == nil)
            await close(made.harness)
        }

        // Opened by its favorite's row, which asks for the spelling saved: the favorite goes to the listing's, its
        // row stays the one selected, the tab is saved on it, and Remove from Favorites takes it out.
        @Test func aFavoriteOpenedByItsRowIsRespelledAndItsRowStaysSelected() async throws {
            let made = try made()
            let store = made.harness.store
            store.update {
                $0.favorites = [FavoritePreference(path: made.decomposed, icon: .star)]
                $0.favoritesInitialized = true
            }
            let (tab, _) = try await open(made.harness)
            let sidebar = tab.sidebarController
            #expect(!sidebar.isFavorite(made.composed))

            sidebar.model.selectItem(.favorite(made.decomposed))
            #expect(await waitUntil { shows(tab.activePane, made.composed) })

            #expect(bytes(store.preferences().favorites.map(\.path)) == bytes([made.composed]))
            #expect(await waitUntil { bytes([sidebar.model.selected?.favoritePath]) == bytes([made.composed]) })
            #expect(bytes([tab.favoritePath]) == bytes([made.composed]))
            #expect(
                bytes([tab.activePaneTab.favoritePath, tab.activePaneTab.path])
                    == bytes([made.composed, made.composed]))
            #expect(sidebar.isFavorite(made.composed))
            sidebar.toggleFavorite(made.composed)
            #expect(store.preferences().favorites.isEmpty)
            await close(made.harness)
        }

        // On a disk that keeps both names, the two are two folders: each has its view, its favorite and its tab of a
        // workspace, opening one takes nothing of the other's, and taking one out leaves the other.
        @Test func twoFoldersADiskKeepsApartStayTwo() async throws {
            let harness = try ExplorerHarness.windowless()
            let parent = listed(harness, "")
            for name in ["behind-composed", "behind-decomposed"] {
                #expect(mkdir(parent + "/" + name, 0o755) == 0)
            }
            let composed = parent + "/caf\u{E9}"
            let decomposed = parent + "/cafe\u{301}"
            let disk = TwoSpellingsDisk(
                parent: parent,
                folders: [("caf\u{E9}", "behind-composed"), ("cafe\u{301}", "behind-decomposed")])
            let store = harness.store
            let icons = FolderViewKeeps(view: .icons)
            store.update {
                $0.favorites = [
                    FavoritePreference(path: decomposed, icon: .star),
                    FavoritePreference(path: composed, icon: .folder),
                ]
                $0.favoritesInitialized = true
                $0.workspaces = [workspace([decomposed, composed])]
            }
            store.updateFolderViews {
                $0.set(FolderView(path: decomposed, keeps: Self.previews))
                $0.set(FolderView(path: composed, keeps: icons))
            }
            let (tab, views) = try await open(harness, disk: disk)
            let pane = tab.activePane

            await go(tab, to: composed)

            #expect(bytes([pane.folderView?.use.view.path]) == bytes([composed]))
            #expect(pane.shownMode == .icons)
            #expect(views.views.all.count == 2)
            // Manage Folder Views lists both, in one order.
            #expect(
                bytes(FolderViewNode.tree(views.views.all).map(\.view.path)) == bytes([decomposed, composed]))
            #expect(bytes(store.preferences().favorites.map(\.path)) == bytes([decomposed, composed]))
            #expect(
                bytes(Workspaces.folders(of: store.preferences().workspaces[0].session))
                    == bytes([decomposed, composed]))

            await go(tab, to: decomposed)
            #expect(bytes([pane.folderView?.use.view.path]) == bytes([decomposed]))
            #expect(pane.shownMode == .previews)

            // One taken out leaves the other: the favorite, and the view.
            tab.sidebarController.toggleFavorite(composed)
            #expect(bytes(store.preferences().favorites.map(\.path)) == bytes([decomposed]))
            #expect(tab.sidebarController.isFavorite(decomposed))
            views.update(from: nil) { $0.remove(composed) }
            #expect(views.views.own(decomposed)?.keeps == Self.previews)
            // The folder left with no view of its own doesn't take the other folder's: the disk says they are two.
            await go(tab, to: composed)
            #expect(pane.folderView == nil)
            #expect(pane.shownMode == .list)
            #expect(views.views.own(decomposed)?.keeps == Self.previews)
            #expect(bytes(store.preferences().favorites.map(\.path)) == bytes([decomposed]))
            await close(harness)
        }

        // A home folder the system names by a link: a favorite saved under that name is the folder's once it is
        // listed, by either path. A favorite that is itself a link to a folder stays the link it is.
        @Test func aFavoriteSavedUnderTheSystemsNameForHomeIsTheFoldersOnceItIsListed() async throws {
            let harness = try ExplorerHarness.windowless()
            let parent = listed(harness, "")
            let home = parent + "/home"
            let named = parent + "/named"
            for folder in [home, home + "/Desktop", home + "/Documents"] { #expect(mkdir(folder, 0o755) == 0) }
            #expect(symlink(home, named) == 0)
            let link = parent + "/shortcut"
            #expect(symlink(parent + "/Alpha", link) == 0)
            let before = BrowserPane.savedHome
            BrowserPane.savedHome = SavedSpellings.Home(system: DiskPath(named), real: DiskPath(home))
            defer { BrowserPane.savedHome = before }
            let store = harness.store
            store.update {
                $0.favorites = [
                    FavoritePreference(path: named + "/Desktop", icon: .desktop),
                    FavoritePreference(path: named + "/Documents", icon: .documents),
                    FavoritePreference(path: link, icon: .folder),
                ]
                $0.favoritesInitialized = true
            }
            let (tab, _) = try await open(harness)
            let sidebar = tab.sidebarController

            // By its row, which asks for the path saved.
            sidebar.model.selectItem(.favorite(named + "/Desktop"))
            #expect(await waitUntil { shows(tab.activePane, home + "/Desktop") })
            #expect(
                bytes(store.preferences().favorites.map(\.path))
                    == bytes([home + "/Desktop", named + "/Documents", link]))
            #expect(await waitUntil { bytes([sidebar.model.selected?.favoritePath]) == bytes([home + "/Desktop"]) })
            #expect(sidebar.isFavorite(home + "/Desktop"))

            // By the folder's own path.
            await go(tab, to: home + "/Documents")
            #expect(
                bytes(store.preferences().favorites.map(\.path))
                    == bytes([home + "/Desktop", home + "/Documents", link]))

            // A link opens the folder it leads to, and the favorite is still the link.
            sidebar.model.selectItem(.favorite(link))
            #expect(await waitUntil { shows(tab.activePane, parent + "/Alpha") })
            #expect(bytes([store.preferences().favorites.last?.path]) == bytes([link]))
            await close(harness)
        }
    }
}
