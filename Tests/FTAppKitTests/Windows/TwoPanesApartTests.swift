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

        // MARK: The visits Go To counts

        /// Whether the Go To box counts a visit of `path`.
        private func visited(_ store: AppStateStore, _ path: String) -> Bool {
            store.folders().contains { samePath($0.path, path) && !$0.visits.isEmpty }
        }

        /// The panes' visits are decided on by hand: no folder stays on screen long enough to count by itself, however
        /// busy the Mac is.
        private func visitsByHand(_ panes: BrowserPane...) {
            for pane in panes {
                pane.visitTracker = FolderVisitTracker(scheduler: ManualTimers()) { path, kind in
                    MainWindowController.visitStore()?.recordFolderVisit(path, kind: kind)
                }
            }
        }

        /// `pane` opens `name` and shows it.
        private func open(_ pane: BrowserPane, _ harness: ExplorerHarness, _ name: String) async {
            pane.go(to: URL(fileURLWithPath: real(harness, name)))
            #expect(await waitUntil { pane.shownFolderPath == real(harness, name) && !pane.isNavigating })
        }

        // A folder opened in the other pane (⌥-click in the tree) doesn't make the active pane's folder a pass-through,
        // and what is then done in the active pane's folder counts for it, not for the other pane's.
        @Test func aFolderOpenedInTheOtherPaneLeavesTheActivePanesVisitAlone() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let store = harness.store
            MainWindowController.visitStore = { store }
            defer { MainWindowController.visitStore = { (NSApp.delegate as? AppDelegate)?.store } }
            let (tab, left, right) = try await twoPanes(harness, right: "Gamma")
            visitsByHand(left, right)
            await open(left, harness, "Alpha")
            await open(right, harness, "Beta")

            tab.onFolderUsed?()
            #expect(visited(store, real(harness, "Alpha")))
            #expect(!visited(store, real(harness, "Beta")))
        }

        // The other pane's folder is decided on by its own use: made active, a use counts for its folder.
        @Test func eachPaneDecidesOnItsOwnFolder() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let store = harness.store
            MainWindowController.visitStore = { store }
            defer { MainWindowController.visitStore = { (NSApp.delegate as? AppDelegate)?.store } }
            let (tab, left, right) = try await twoPanes(harness, right: "Gamma")
            visitsByHand(left, right)
            await open(left, harness, "Alpha")
            await open(right, harness, "Beta")

            tab.activate(right)
            tab.onFolderUsed?()
            #expect(visited(store, real(harness, "Beta")))
            #expect(!visited(store, real(harness, "Alpha")))
            // Swapped, each pane keeps its own: the one that was on the left, active again, still decides on Alpha.
            tab.swapPanes()
            tab.activate(left)
            tab.onFolderUsed?()
            #expect(visited(store, real(harness, "Alpha")))
        }

        // A folder the closed pane was still being decided on was only passed through: nothing done later counts for
        // it.
        @Test func closingTheOtherPanePassesThroughItsFolder() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let store = harness.store
            MainWindowController.visitStore = { store }
            defer { MainWindowController.visitStore = { (NSApp.delegate as? AppDelegate)?.store } }
            let (tab, left, right) = try await twoPanes(harness, right: "Gamma")
            visitsByHand(left, right)
            await open(right, harness, "Beta")

            tab.closeOtherPane()
            right.visitTracker.use()
            tab.onFolderUsed?()
            #expect(!visited(store, real(harness, "Beta")))
        }

        // MARK: Closing the other pane

        /// The harness's folder watches, which watch nothing on disk.
        private func watches(_ harness: ExplorerHarness) -> FolderWatches {
            let watches = FolderWatches(
                FolderWatches.Dependencies(
                    watchFolder: { _, _, _ in {} }, readModifiedTime: { _ in nil }, onFolderChanged: { _, _ in },
                    forgetCachedListings: { _, _ in }))
            harness.windows.folderWatches = watches
            return watches
        }

        /// The pane closes with its list, and its folder is no longer watched.
        private func closesWhole(
            _ tab: MainWindowController, _ harness: ExplorerHarness, _ watches: FolderWatches, closing: () -> Void
        ) async throws {
            weak var gone: BrowserPane?
            weak var list: ContentPaneController?
            var watchID = 0
            do {
                let other = try #require(tab.otherPane)
                gone = other
                list = other.content
                watchID = other.watchID
            }
            harness.windows.tabNavigated(tab)
            #expect(watches.watchedPaths[watchID] != nil)
            closing()
            #expect(tab.panes.count == 1)
            #expect(watches.watchedPaths[watchID] == nil)
            #expect(watches.watchedPaths[tab.activePane.watchID] != nil)
            await settle()
            #expect(await waitUntil { gone == nil && list == nil })
        }

        @Test func theClosedPaneAndItsListAreFreedAndItsFolderNoLongerWatched() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let watches = watches(harness)
            let (tab, _, _) = try await twoPanes(harness, right: "Gamma")
            try await closesWhole(tab, harness, watches) { tab.perform(.toggleTwoPanes) }
        }

        // So is the pane that started on the left, closed after Swap Panes.
        @Test func aPaneClosedAfterSwapPanesIsFreedAndNoLongerWatched() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let watches = watches(harness)
            let (tab, _, right) = try await twoPanes(harness, right: "Gamma")
            tab.swapPanes()
            tab.activate(right)
            #expect(tab.panes.first === right)
            try await closesWhole(tab, harness, watches) { tab.closeOtherPane() }
        }
    }
}
