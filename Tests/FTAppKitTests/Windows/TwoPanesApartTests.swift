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

        // Closing the other pane changes nothing of the active one: Show Info's item stays, its properties aren't
        // asked for again, and the sidebar's row stays where it was, whichever side the active pane was on.
        @Test(arguments: [false, true]) func closingTheOtherPaneLeavesWhatFollowsTheActivePane(rightActive: Bool)
            async throws
        {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let (tab, _, right) = try await twoPanes(harness, right: "Alpha")
            if rightActive { tab.focusPane(right) }
            await settle()
            let active = tab.activePane
            let info = try #require(tab.infoController)
            let beta = real(harness, "Beta")
            info.showInfo(for: beta)
            harness.layout(tab)
            #expect(await waitUntil { info.propertiesLoad.phase == .answered(path: beta) })
            let asked = info.propertiesLoad.requests
            let row = tab.sidebarController.model.selected
            var changes: [ExplorerWindowChange] = []
            let watching = tab.observe { changes.append($0) }
            defer { withExtendedLifetime(watching) {} }

            tab.perform(.toggleTwoPanes)
            await settle()
            #expect(tab.panes.count == 1 && tab.activePane === active)
            #expect(info.targetOverride == beta)
            #expect(info.propertiesLoad.requests == asked)
            #expect(tab.sidebarController.model.selected == row)
            // The panes changed; the active pane's folder did not.
            #expect(changes.contains(.panels))
            #expect(!changes.contains(.folder), "\(changes)")
            #expect(tab.sidebarController.paneFolders.isEmpty)
        }

        // Go to Other Pane's Folder goes wherever the other pane is, the Trash and a folder being searched too:
        // nothing is written there, unlike Copy and Move to Other Pane.
        @Test func goToOtherPanesFolderIsOfferedForTheTrashAndForSearchResults() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let (tab, _, right) = try await twoPanes(harness, right: "Alpha")
            #expect(tab.canPerform(.goToOtherPaneFolder))
            let trash = real(harness) + "/.Trash"
            try FileManager.default.createDirectory(atPath: trash, withIntermediateDirectories: true)
            tab.trashHomePath = real(harness)
            await right.navigate(to: URL(fileURLWithPath: trash))
            #expect(right.shownFolderPath == trash)
            #expect(!tab.canPerform(.copyToOtherPane))
            #expect(tab.canPerform(.goToOtherPaneFolder))
            tab.perform(.goToOtherPaneFolder)
            #expect(await waitUntil { tab.activePane.shownFolderPath == trash })
            // Both in one folder now: nowhere else to go.
            #expect(!tab.canPerform(.goToOtherPaneFolder))
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

        // MARK: What follows the active pane

        /// What the tab tells what follows it, while the token is kept.
        @MainActor
        private final class Told {
            var changes: [ExplorerWindowChange] = []
            var token: ExplorerWindowObservation?

            init(_ tab: MainWindowController) {
                token = tab.observe { [unowned self] in self.changes.append($0) }
            }

            /// The changes of a pane's own that the toolbar and the Info panel follow, told as the active pane's. Not the
            /// selection: the tree tells of its own as it redraws its marks of the panes' folders.
            var ofTheActivePane: [ExplorerWindowChange] {
                changes.filter { [.folder, .history, .view, .search].contains($0) }
            }
        }

        /// What the toolbar shows of the pane it follows.
        private struct ToolbarShows: Equatable {
            var back: Bool?
            var forward: Bool?
            var view: ExplorerViewMode?
            var sort: String?
            var title: String?
            var search: String?
        }

        private func toolbarShows(_ tab: MainWindowController) -> ToolbarShows {
            let toolbar = tab.explorerToolbar
            return ToolbarShows(
                back: toolbar.button(.back)?.isEnabled, forward: toolbar.button(.forward)?.isEnabled,
                view: toolbar.viewSwitch?.selected, sort: toolbar.button(.sort)?.tooltip,
                title: toolbar.titleView?.field.stringValue, search: tab.searchField?.stringValue)
        }

        /// The Info panel describes `path` (Show Info), its properties read once.
        private func showingInfo(_ tab: MainWindowController, _ path: String, _ harness: ExplorerHarness) async throws
            -> (InfoController, Int)
        {
            let info = try #require(tab.infoController)
            info.showInfo(for: path)
            harness.layout(tab)
            #expect(await waitUntil { info.propertiesLoad.phase == .answered(path: path) })
            return (info, info.propertiesLoad.requests)
        }

        // The other pane going Back and Forward leaves the toolbar's Back and Forward the active pane's, and Show Info's
        // item with nothing asked again; the active pane's own Back still moves them.
        @Test func theOtherPaneGoingBackAndForwardLeavesTheToolbarAndTheInfoPanel() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let (tab, left, right) = try await twoPanes(harness, right: "Alpha")
            await open(right, harness, "Gamma")
            await open(left, harness, "Beta")
            let (info, asked) = try await showingInfo(tab, real(harness, "Gamma"), harness)
            let shows = toolbarShows(tab)
            #expect(shows.back == true && shows.forward == false)
            let told = Told(tab)

            right.go(to: URL(fileURLWithPath: real(harness, "Alpha")), history: .back)
            #expect(await waitUntil { right.shownFolderPath == real(harness, "Alpha") && !right.isNavigating })
            await settle()
            #expect(right.navigationHistory.canGoForward)
            #expect(toolbarShows(tab) == shows)
            right.go(to: URL(fileURLWithPath: real(harness, "Gamma")), history: .forward)
            #expect(await waitUntil { right.shownFolderPath == real(harness, "Gamma") && !right.isNavigating })
            await settle()
            #expect(toolbarShows(tab) == shows)
            #expect(told.ofTheActivePane == [])
            #expect(told.changes.contains(.otherPane(.history)))
            #expect(told.changes.contains(.otherPane(.folder)))
            #expect(info.targetOverride == real(harness, "Gamma"))
            #expect(info.propertiesLoad.requests == asked)
            // The tree marks the folders of both all along.
            #expect(tab.sidebarController.paneFolders == [real(harness, "Beta"), real(harness, "Gamma")])

            left.go(to: URL(fileURLWithPath: real(harness)), history: .back)
            #expect(await waitUntil { left.shownFolderPath == real(harness) && !left.isNavigating })
            await settle()
            #expect(told.changes.contains(.history))
            #expect(toolbarShows(tab).back == false)
            #expect(toolbarShows(tab).forward == true)
            #expect(await waitUntil { info.targetOverride == nil })
        }

        // The other pane switching its view or its order leaves the toolbar's view switch and Sort button the active
        // pane's; the active pane's own switch still moves them.
        @Test func theOtherPaneSwitchingItsViewLeavesTheToolbarsViewSwitch() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let (tab, left, right) = try await twoPanes(harness, right: "Alpha")
            left.setMode(.details)
            let (info, asked) = try await showingInfo(tab, real(harness, "Gamma"), harness)
            let shows = toolbarShows(tab)
            #expect(shows.view == .details)
            let told = Told(tab)

            right.setMode(.icons)
            right.setSort(.size, .desc)
            #expect(await waitUntil { !right.isNavigating })
            await settle()
            #expect(right.content.mode == .icons)
            #expect(toolbarShows(tab) == shows)
            #expect(told.ofTheActivePane == [])
            #expect(told.changes.contains(.otherPane(.view)))
            #expect(info.targetOverride == real(harness, "Gamma"))
            #expect(info.propertiesLoad.requests == asked)

            left.setMode(.list)
            #expect(told.changes.contains(.view))
            #expect(toolbarShows(tab).view == .list)
        }

        // Items selected in the other pane (as a copy to it selects what arrived) leave Show Info's item, with nothing
        // asked again; a selection in the active pane still lets it go.
        @Test func aSelectionInTheOtherPaneLeavesShowInfosItem() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let (tab, left, right) = try await twoPanes(harness, right: "Alpha")
            let (info, asked) = try await showingInfo(tab, real(harness, "Gamma"), harness)
            let told = Told(tab)

            let inner = real(harness, "Alpha") + "/Inner"
            right.content.select(paths: [inner])
            await settle()
            #expect(right.content.selection.paths == [inner])
            #expect(told.changes.contains(.otherPane(.selection)))
            #expect(!told.changes.contains(.selection))
            #expect(info.targetOverride == real(harness, "Gamma"))
            #expect(info.propertiesLoad.requests == asked)

            left.content.select(paths: [real(harness, "Beta")])
            #expect(told.changes.contains(.selection))
            #expect(info.targetOverride == nil)
        }

        // A search starting and ending in the other pane (its results put away by a folder opened there) leaves the
        // toolbar's search field, title and view the active pane's, and Show Info's item; the tab still shows the
        // magnifier for it, and a search in the active pane still tells them.
        @Test func aSearchInTheOtherPaneLeavesTheToolbarsSearchField() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let (tab, left, right) = try await twoPanes(harness, right: "Alpha")
            let engine = FakeSearchEngine()
            engine.finds = { _ in (["notes.md"], false, false) }
            for pane in [left, right] {
                pane.search.session.engine = engine
                pane.search.session.timers = ManualTimers()
            }
            let (info, asked) = try await showingInfo(tab, real(harness, "Gamma"), harness)
            let shows = toolbarShows(tab)
            let told = Told(tab)

            right.search.session.submit("no")
            #expect(await waitUntil { right.searchRootPath == real(harness, "Alpha") })
            await settle()
            #expect(left.searchRootPath == nil)
            #expect(toolbarShows(tab) == shows)
            #expect(tab.window?.tab.accessoryView is SearchTabMagnifier)
            right.go(to: URL(fileURLWithPath: real(harness, "Gamma")))
            #expect(await waitUntil { right.searchRootPath == nil && !right.isNavigating })
            await settle()
            #expect(toolbarShows(tab) == shows)
            #expect(told.ofTheActivePane == [])
            #expect(told.changes.contains(.otherPane(.search)))
            #expect(info.targetOverride == real(harness, "Gamma"))
            #expect(info.propertiesLoad.requests == asked)

            let field = try #require(tab.searchField)
            field.stringValue = "no"
            tab.search.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
            left.search.session.submit("no")
            #expect(await waitUntil { left.searchRootPath == real(harness) })
            #expect(told.changes.contains(.search))
            #expect(toolbarShows(tab).title?.hasPrefix("Searching") == true)
        }
    }
}
