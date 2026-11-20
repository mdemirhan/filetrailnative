// A tab kept from an earlier launch with its tree's top spelled otherwise than the folder's listing spells it
import AppKit
import FTFileSystem
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    /// The folder is "café" with its "é" as one scalar, as `mkdir` keeps it; the tab kept its paths with the accent in
    /// two, as an earlier version saved them. The tree's rows come from listings, which spell it as the disk does.
    @MainActor
    @Suite struct TreeKeptSpellingTests: SidebarTesting {
        private func bytes(_ paths: [String]) -> [[UInt8]] { paths.map { Array($0.utf8) } }

        /// The harness's folder with "café" in it, holding "sub": the two as listed, and "café" as it was kept.
        private func harness() throws -> (harness: ExplorerHarness, folder: String, kept: String) {
            let harness = try ExplorerHarness.windowless()
            let parent = listed(harness, "")
            let folder = parent + "/caf\u{E9}"
            #expect(mkdir(folder, 0o755) == 0)
            #expect(mkdir(folder + "/sub", 0o755) == 0)
            return (harness, folder, parent + "/cafe\u{301}")
        }

        /// A tab as it comes back from what was saved: on `path`, its tree's top at `root`.
        private func restored(_ harness: ExplorerHarness, path: String, root: String) -> MainWindowController {
            let startup = StartupTab(
                path: path, rootPath: root, favoritePath: nil, viewMode: .details, searchViewMode: .details,
                sortBy: .name, sortDirection: .asc, includeHidden: false, foldersFirst: true, favoritesExpanded: true,
                locationsExpanded: true)
            let tab = MainWindowController(tab: startup, loadNow: false)
            tab.servicesOverride = harness.services
            tab.ensureLoaded()
            return tab
        }

        private func treeRows(_ tab: MainWindowController) -> [String] {
            tab.sidebarController.model.treePresentation.visibleItemIDs.compactMap(\.filesystemPath)
        }

        // The tree stays at the folder it was rooted at, by the listing's spelling, with the folder's row selected.
        @Test func aTreeTopKeptDecomposedIsTheFolderAsItIsListed() async throws {
            let made = try harness()
            let tab = restored(made.harness, path: made.kept + "/sub", root: made.kept)
            let model = tab.sidebarController.model
            let sub = made.folder + "/sub"

            #expect(await waitUntil { samePath(tab.shownFolderPath, sub) && !tab.isNavigating })
            #expect(await waitUntil { model.selected == .filesystem(sub) && model.nodes[made.folder]?.loaded == true })
            #expect(bytes([tab.treeRootPath]) == bytes([made.folder]))
            #expect(bytes(treeRows(tab)) == bytes([made.folder, sub]))
            tab.window?.close()
            await made.harness.close()
        }

        // The top itself on screen: its row is the one selected.
        @Test func aTabKeptOnItsTreesTopSelectsItsRow() async throws {
            let made = try harness()
            let tab = restored(made.harness, path: made.kept, root: made.kept)
            let model = tab.sidebarController.model

            #expect(await waitUntil { samePath(tab.shownFolderPath, made.folder) && !tab.isNavigating })
            #expect(
                await waitUntil {
                    model.selected == .filesystem(made.folder) && model.nodes[made.folder]?.loaded == true
                })
            #expect(bytes([tab.treeRootPath]) == bytes([made.folder]))
            #expect(bytes(treeRows(tab)) == bytes([made.folder, made.folder + "/sub"]))
            tab.window?.close()
            await made.harness.close()
        }
    }
}
