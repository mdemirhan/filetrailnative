// What the pane that isn't active does, and what of the tab doesn't follow it: the Info panel describes the active
// pane only
import AppKit
import FTFileSystem
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    @MainActor
    @Suite struct TwoPanesApartTests {
        /// The real path of `name` in the harness's folder: what listings and the tree call it.
        private func real(_ harness: ExplorerHarness, _ name: String = "") -> String {
            let path = name.isEmpty ? harness.folder.path : harness.folder.path + "/" + name
            guard let resolved = realpath(path, nil) else { return path }
            defer { free(resolved) }
            return String(cString: resolved)
        }

        /// The pane has read its folder, and what follows in the sidebar has been told.
        private func arrived(_ pane: BrowserPane) async {
            #expect(await waitUntil { pane.loaded && pane.hasShownFolder && !pane.isNavigating })
            await settle()
        }

        /// The tab with a second pane on `right`, and the first pane active.
        private func twoPanes(_ harness: ExplorerHarness, right: String) async throws -> (
            MainWindowController, BrowserPane, BrowserPane
        ) {
            let tab = try await harness.open()
            let left = tab.activePane
            let second = tab.openSecondPane(at: real(harness, right))
            await arrived(second)
            harness.layout(tab)
            return (tab, left, second)
        }

        // MARK: The Info panel

        // A change from outside read in the other pane (a download landing in its folder) leaves Show Info's item, and
        // the active item isn't asked for again; the tree still marks both panes' folders.
        @Test func anOutsideChangeInTheOtherPaneKeepsShowInfosItem() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let (tab, _, right) = try await twoPanes(harness, right: "Alpha")
            let info = try #require(tab.infoController)
            let beta = real(harness, "Beta")
            info.showInfo(for: beta)
            harness.layout(tab)
            #expect(await waitUntil { info.propertiesLoad.phase == .answered(path: beta) })
            let asked = info.propertiesLoad.requests
            let made = real(harness, "Alpha") + "/made.txt"
            try "x".write(toFile: made, atomically: true, encoding: .utf8)
            harness.services.directoryService.cache.clear()

            harness.windows.folderChanged(
                windowID: right.watchID, FolderChange(path: real(harness, "Alpha"), changedPaths: [made]))
            #expect(await waitUntil { right.content.listed.contains { $0.path == made } })
            await settle()
            #expect(info.targetOverride == beta)
            #expect(info.propertiesLoad.requests == asked)
            #expect(tab.sidebarController.paneFolders == [real(harness), real(harness, "Alpha")])
        }

        // The other pane opening a folder (⌥-click in the tree, Show Folder in Other Pane) leaves Show Info's item and
        // asks nothing again; the tree marks the folder it went to.
        @Test func theOtherPaneOpeningAFolderKeepsShowInfosItem() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let (tab, _, right) = try await twoPanes(harness, right: "Alpha")
            let info = try #require(tab.infoController)
            let beta = real(harness, "Beta")
            info.showInfo(for: beta)
            harness.layout(tab)
            #expect(await waitUntil { info.propertiesLoad.phase == .answered(path: beta) })
            let asked = info.propertiesLoad.requests

            right.go(to: URL(fileURLWithPath: real(harness, "Gamma")))
            #expect(await waitUntil { right.shownFolderPath == real(harness, "Gamma") && !right.isNavigating })
            await settle()
            #expect(info.targetOverride == beta)
            #expect(info.propertiesLoad.requests == asked)
            #expect(tab.sidebarController.paneFolders == [real(harness), real(harness, "Gamma")])

            // The active pane opening a folder still lets it go.
            tab.activePane.go(to: URL(fileURLWithPath: real(harness, "Beta")))
            #expect(await waitUntil { info.targetOverride == nil })
        }
    }
}
