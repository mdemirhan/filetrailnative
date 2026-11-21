// A folder whose name holds an accent, stored either way, against a plainly named one: the app is to behave the
// same in both
import AppKit
import FTFileSystem
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    /// The app knows a path by its bytes, which is right only while every path it holds is spelled as its disk spells
    /// it: one spelled otherwise misses where it should have been found. So the same run through the app (open the
    /// folder, read its rows, hear of changes in it, write in it, type its path, save it and start again) is made in
    /// a folder with no accent and in folders named with one, stored composed and decomposed, in Latin letters and
    /// in Hangul, holding files spelled both ways; and each thing a step saw in an accented folder is to be what it
    /// saw in the plain one, once every name is told by what it is there for. Here the folders are at the top of the
    /// window's folder; `AccentParityNestedTests` has each inside a folder of its own name. A release compares every
    /// kind of folder, any other run a few (`AccentKind.checked`).
    @MainActor
    @Suite(.restoresWindowSeams) struct AccentParityTests {
        // The plain folder's own run is what the others are held against: every step of it did what it is there to
        // show, so a kind that agrees with it agrees with something.
        @Test func thePlainFolderDoesWhatEachStepShows() async throws {
            try await AccentParity.checkPlain(nested: false)
        }

        @Test(arguments: AccentKind.checked.filter { !$0.nested })
        func anAccentedFolderBehavesAsAPlainOne(_ kind: AccentKind) async throws {
            try await AccentParity.check(kind)
        }

        private func bytes(_ paths: [String?]) -> [[UInt8]?] { paths.map { $0.map { Array($0.utf8) } } }

        // A launch that knew its folders by a URL's spelling saved a folder stored composed with its accents apart:
        // a favorite, the folder's view, and a tab inside it with its tree's top at the folder. Each is the folder's
        // again once the folder is listed. "café" at the top of a folder is looked at where each of these is kept
        // (SavedSpellingsInWindowTests for the favorite, the view, a workspace, the visits and the folders chosen;
        // ComposedAccentFolderTests for the tab; TreeKeptSpellingTests for the tree's top): here are the other
        // names stored composed, and each of them inside a folder of the same name.
        @Test(arguments: AccentKind.savedByAnEarlierVersion)
        func whatAnEarlierVersionSavedIsTheFoldersOnceItIsListed(_ kind: AccentKind) async throws {
            let harness = try ExplorerHarness.windowless()
            let names = AccentNames(kind: kind, under: harness.folder.path)
            if kind.nested { AccentDisk.makeFolder(names.parent) }
            AccentDisk.makeFolder(names.folder)
            AccentDisk.makeFolder(names.sub)
            let earlier = try #require(DiskPath(names.folder).asAURLSpells()).string
            #expect(!samePath(earlier, names.folder), "a URL spells this folder otherwise than the disk")
            let earlierSub = try #require(DiskPath(names.sub).asAURLSpells()).string
            let previews = FolderViewKeeps(view: .previews, sort: FolderViewSort(by: .modified, direction: .desc))

            let store = harness.store
            MainWindowController.visitStore = { store }
            store.update {
                $0.favorites = [FavoritePreference(path: earlier, icon: .star)]
                $0.favoritesInitialized = true
            }
            store.updateFolderViews { $0.set(FolderView(path: earlier, keeps: previews)) }
            let session = store.createWindowSession {
                $0.openTabs = [
                    OpenTabPreference(
                        path: earlierSub, treeRootPath: earlier, favoritePath: nil, viewMode: .list,
                        searchViewMode: .details, sortBy: .name, sortDirection: .asc, includeHidden: false,
                        foldersFirst: true, favoritesExpanded: true, locationsExpanded: true)
                ]
                $0.activeTabIndex = 0
            }
            store.addExplorerWindow(
                id: "window-kept", bounds: StoredWindowState(width: 900, height: 600, maximized: false),
                session: session)
            harness.services.folderViews = SharedFolderViews(store: store)

            // The tab comes back inside the folder, as its listing spells it, the tree's top at the folder.
            let tab = try await harness.openWhatWasKept()
            let pane = tab.activePane
            let model = tab.sidebarController.model
            #expect(await waitUntil { samePath(tab.shownFolderPath, names.sub) && !tab.isNavigating })
            #expect(bytes(tab.historyPaths) == bytes([names.sub]))
            #expect(
                await waitUntil { samePath(tab.treeRootPath, names.folder) && model.selected == .filesystem(names.sub) }
            )
            #expect(bytes([tab.treeRootPath]) == bytes([names.folder]))

            // The folder itself: the view kept for it is the one shown, and it is the favorite.
            tab.go(to: names.folder)
            #expect(await waitUntil { samePath(tab.shownFolderPath, names.folder) && !tab.isNavigating })
            #expect(pane.shownFolderView?.use.own == true)
            #expect(bytes([pane.shownFolderView?.use.view.path]) == bytes([names.folder]))
            #expect(pane.shownMode == .previews)
            #expect(pane.shownSortBy == .modified)
            #expect(bytes(store.preferences().favorites.map(\.path)) == bytes([names.folder]))
            #expect(tab.sidebarController.isFavorite(names.folder))
            #expect(bytes(tab.sidebarController.model.favorites.map(\.path)) == bytes([names.folder]))
            await harness.close()
        }
    }
}

extension ExplorerWindowlessTests {
    /// The same run with each folder inside a folder of its own name, so the path holds the accent twice: in the
    /// folder on screen and in the one above it. A suite of its own, so the two share a full run's time between two
    /// processes.
    @MainActor
    @Suite(.restoresWindowSeams) struct AccentParityNestedTests {
        @Test func thePlainFolderInsideAPlainFolderDoesWhatEachStepShows() async throws {
            try await AccentParity.checkPlain(nested: true)
        }

        @Test(arguments: AccentKind.checked.filter(\.nested))
        func anAccentedFolderInsideOneOfItsNameBehavesAsAPlainOne(_ kind: AccentKind) async throws {
            try await AccentParity.check(kind)
        }
    }
}
