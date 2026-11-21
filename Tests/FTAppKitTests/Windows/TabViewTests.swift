// Checks tab views applied to the app's own tabs, never shown: the panes, the divider, each pane's settings and
// folder, the override left on a folder with a view of its own and every way it ends, and the new-tab view
import AppKit
import FTFileSystem
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    @MainActor
    @Suite struct TabViewTests {
        private func real(_ harness: ExplorerHarness, _ name: String = "") -> String {
            let path = name.isEmpty ? harness.folder.path : harness.folder.path + "/" + name
            guard let resolved = realpath(path, nil) else { return path }
            defer { free(resolved) }
            return String(cString: resolved)
        }

        private func go(_ tab: MainWindowController, _ harness: ExplorerHarness, _ name: String) async {
            await tab.navigate(to: real(harness, name))
            #expect(await waitUntil { !tab.isNavigating })
        }

        private func settled(_ tab: MainWindowController) async {
            #expect(await waitUntil { tab.panes.allSatisfy { !$0.isNavigating } })
        }

        /// Saves `keeps` as the tab views' first and applies it to `tab`, then waits for each pane it sends to another
        /// folder to get there (or near it, for a folder that is gone).
        private func apply(_ keeps: TabViewKeeps, to tab: MainWindowController, id: String = "tv-1") async {
            tab.updatePreferences { $0.tabViews = [TabView(id: id, name: "View \(id)", keeps: keeps)] }
            let before = tab.panes.map(\.folderPath)
            tab.applyTabView(id: id)
            for (index, paneKeeps) in keeps.paneKeeps(active: tab.activePaneIndex) {
                guard let folder = paneKeeps.folder else { continue }
                let from = before.indices.contains(index) ? before[index] : nil
                guard from != folder else { continue }
                #expect(
                    await waitUntil {
                        tab.panes.indices.contains(index) && tab.panes[index].folderPath != from
                            && !tab.panes[index].isNavigating
                    }, "pane \(index) went to its folder")
            }
            await settled(tab)
        }

        /// The folder `name` keeps `view` as its own, saved, and covers the folders inside with `subfolders`.
        private func remember(
            _ name: String, _ view: ExplorerViewMode, subfolders: Bool = false, in tab: MainWindowController,
            _ harness: ExplorerHarness
        ) async {
            await go(tab, harness, name)
            tab.setMode(view)
            tab.perform(.rememberFolderView)
            if subfolders {
                tab.activePane.setFolderViewSubfolders(true)
                tab.perform(.updateFolderView)
            }
        }

        // MARK: Panes and settings

        @Test func withNoFolderKeptThePanesStayAndTakeTheSettings() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            await go(tab, harness, "Alpha")
            let pane = tab.activePane
            let back = pane.navigationHistory.paths
            await apply(
                TabViewKeeps(
                    pane: PaneKeeps(
                        view: FolderViewKeeps(
                            view: .details, sort: FolderViewSort(by: .size, direction: .desc), foldersFirst: false))),
                to: tab)
            #expect(pane.folderPath == real(harness, "Alpha"))
            #expect(pane.navigationHistory.paths == back)
            #expect(pane.viewMode == .details && pane.content.mode == .details)
            #expect(pane.sortBy == .size && pane.sortDirection == .desc && !pane.foldersFirst)
            #expect(tab.lastTabViewID == "tv-1")
        }

        @Test func aFolderKeptMovesThePaneAndBackComesBack() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            await go(tab, harness, "Alpha")
            await apply(TabViewKeeps(pane: PaneKeeps(folder: real(harness, "Beta"))), to: tab)
            let pane = tab.activePane
            #expect(pane.folderPath == real(harness, "Beta"))
            tab.perform(.goBack)
            #expect(await waitUntil { pane.folderPath == real(harness, "Alpha") && !pane.isNavigating })
        }

        @Test func twoPanesOpenTheSecondWhereItWasClosedAndOnePaneClosesTheOneNotActive() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            await go(tab, harness, "Alpha")
            tab.openSecondPane(at: real(harness, "Gamma"))
            await settled(tab)
            #expect(tab.showsTwoPanes)
            // One pane: the pane that isn't active closes, and ⌘\ brings it back where it was.
            await apply(TabViewKeeps(panes: 1), to: tab)
            #expect(!tab.showsTwoPanes)
            #expect(tab.activePane.folderPath == real(harness, "Alpha"))
            await apply(TabViewKeeps(panes: 2), to: tab)
            #expect(tab.showsTwoPanes)
            #expect(tab.panes[1].folderPath == real(harness, "Gamma"))
            // The active pane stays the one it was.
            #expect(tab.activePaneIndex == 0)
        }

        @Test func eachPaneTakesItsOwnSettingsAndFolder() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            await apply(
                TabViewKeeps(
                    panes: 2, divider: .share(0.3),
                    left: PaneKeeps(folder: real(harness, "Alpha"), view: FolderViewKeeps(view: .details)),
                    right: PaneKeeps(folder: real(harness, "Beta"), view: FolderViewKeeps(view: .previews))),
                to: tab)
            #expect(tab.panes.map(\.folderPath) == [real(harness, "Alpha"), real(harness, "Beta")])
            #expect(tab.panes.map(\.viewMode) == [.details, .previews])
            #expect(abs(tab.workspace.paneSplit - 0.3) < 0.0001)
        }

        @Test func withPanesNotKeptOnlyTheActivePaneChanges() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            tab.setMode(.icons)
            tab.openSecondPane(at: real(harness, "Gamma"))
            await settled(tab)
            tab.activate(tab.panes[1])
            await apply(TabViewKeeps(pane: PaneKeeps(view: FolderViewKeeps(view: .details))), to: tab)
            #expect(tab.panes.map(\.viewMode) == [.icons, .details])
        }

        @Test func aDividerKeptAsAWidthGivesTheLeftPaneThatWidth() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            tab.openSecondPane()
            await settled(tab)
            let room = tab.workspace.paneColumnWidth - PaneSplit.dividerWidth
            await apply(TabViewKeeps(panes: 2, divider: .leftWidth((room * 0.4).rounded())), to: tab)
            #expect(abs(tab.workspace.paneSplit - 0.4) < 0.01)
        }

        @Test func hiddenFilesAreTheTabsAndChangeWhenKept() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            #expect(!tab.includeHidden)
            await apply(TabViewKeeps(includeHidden: true), to: tab)
            #expect(tab.includeHidden)
        }

        @Test func aGoneFolderOpensTheNearestOneAbove() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            await apply(TabViewKeeps(pane: PaneKeeps(folder: real(harness, "Alpha") + "/Gone/Deeper")), to: tab)
            #expect(tab.activePane.folderPath == real(harness, "Alpha"))
        }

        // MARK: The override

        @Test func theFoldersViewFirstShowsTheFoldersViewAndLeavingShowsTheTabViews() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            await remember("Alpha", .previews, in: tab, harness)
            await go(tab, harness, "Beta")
            await apply(
                TabViewKeeps(pane: PaneKeeps(folder: real(harness, "Alpha"), view: FolderViewKeeps(view: .details))),
                to: tab)
            let pane = tab.activePane
            #expect(pane.tabViewOverride == nil)
            #expect(pane.content.mode == .previews)
            await go(tab, harness, "Gamma")
            #expect(pane.content.mode == .details)
        }

        @Test func theTabViewFirstShowsWhatItKeepsAndTheFoldersViewGivesTheRest() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            await go(tab, harness, "Alpha")
            tab.setMode(.previews)
            tab.setSort(.size, .desc)
            tab.perform(.rememberFolderView)
            await go(tab, harness, "Beta")
            await apply(
                TabViewKeeps(
                    pane: PaneKeeps(
                        folder: real(harness, "Alpha"), view: FolderViewKeeps(view: .details),
                        folderViews: .tabViewFirst)),
                to: tab)
            let pane = tab.activePane
            #expect(pane.tabViewOverride?.holds(in: real(harness, "Alpha")) == true)
            #expect(pane.content.mode == .details)
            // Sort By isn't the tab view's: the folder's view gives it.
            #expect(pane.shownSortBy == .size && pane.shownSortDirection == .desc)
            #expect(
                pane.content.contentShell.pathBarRow.folderViewMark?.tooltip.contains("tab view comes first") == true)
        }

        @Test func theTabViewFirstHoldsInAFolderCoveredFromAbove() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            await remember("Alpha", .previews, subfolders: true, in: tab, harness)
            await go(tab, harness, "Beta")
            await apply(
                TabViewKeeps(
                    pane: PaneKeeps(
                        folder: real(harness, "Alpha/Inner"), view: FolderViewKeeps(view: .details),
                        folderViews: .tabViewFirst)),
                to: tab)
            #expect(tab.activePane.shownFolderView?.use.own == false)
            #expect(tab.activePane.content.mode == .details)
        }

        @Test func notUsedIgnoresTheFoldersView() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            await remember("Alpha", .previews, in: tab, harness)
            tab.setMode(.icons)
            await go(tab, harness, "Beta")
            tab.setMode(.list)
            await apply(TabViewKeeps(pane: PaneKeeps(folder: real(harness, "Alpha"), folderViews: .notUsed)), to: tab)
            // What the pane carries, though the tab view keeps no view.
            #expect(tab.activePane.content.mode == .list)
            #expect(tab.activePane.content.contentShell.pathBarRow.folderViewMark?.tooltip.contains("Not used") == true)
        }

        @Test func theOverrideEndsOnLeavingAndDoesntComeBackWithBack() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            await remember("Alpha", .previews, in: tab, harness)
            await apply(
                TabViewKeeps(pane: PaneKeeps(view: FolderViewKeeps(view: .details), folderViews: .tabViewFirst)),
                to: tab)
            let pane = tab.activePane
            #expect(pane.content.mode == .details)
            await go(tab, harness, "Alpha/Inner")
            #expect(pane.tabViewOverride == nil)
            tab.perform(.goBack)
            #expect(await waitUntil { pane.folderPath == real(harness, "Alpha") && !pane.isNavigating })
            #expect(pane.content.mode == .previews)
        }

        @Test func eachFolderViewCommandEndsTheOverrideFirst() async throws {
            for command in [AppCommand.rememberFolderView, .resetFolderView, .folderViewOptions] {
                let harness = try ExplorerHarness.windowless()
                let tab = try await harness.open()
                await remember("Alpha", .previews, in: tab, harness)
                await apply(
                    TabViewKeeps(pane: PaneKeeps(view: FolderViewKeeps(view: .details), folderViews: .tabViewFirst)),
                    to: tab)
                #expect(tab.activePane.tabViewOverride != nil)
                tab.perform(command)
                #expect(tab.activePane.tabViewOverride == nil, "\(command)")
                tab.closeFolderViewPopover()
            }
        }

        @Test func rememberAfterTheOverrideKeepsTheFoldersViewNotTheTabViews() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            await remember("Alpha", .previews, in: tab, harness)
            await apply(
                TabViewKeeps(pane: PaneKeeps(view: FolderViewKeeps(view: .details), folderViews: .tabViewFirst)),
                to: tab)
            tab.perform(.rememberFolderView)
            #expect(tab.activePane.folderViews.views.own(real(harness, "Alpha"))?.keeps.view == .previews)
        }

        @Test func aCoveredSettingChangedByHandLeavesTheOverrideAndIsAChangeOfTheFoldersView() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            await go(tab, harness, "Alpha")
            tab.setMode(.previews)
            tab.setSort(.size, .desc)
            tab.perform(.rememberFolderView)
            await apply(
                TabViewKeeps(
                    pane: PaneKeeps(
                        view: FolderViewKeeps(view: .details, sort: FolderViewSort(by: .name, direction: .asc)),
                        folderViews: .tabViewFirst)),
                to: tab)
            let pane = tab.activePane
            tab.setMode(.list)
            // View is the folder's again, changed on screen; Sort By is still the tab view's.
            #expect(pane.tabViewOverride?.kept == [.sort])
            #expect(pane.shownFolderView?.unsaved == [.view])
            #expect(pane.content.mode == .list)
            #expect(pane.shownSortBy == .name)
        }

        @Test func aToggleTurnsWhatIsOnScreen() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            await go(tab, harness, "Alpha")
            tab.activePane.foldersFirst = true
            tab.perform(.rememberFolderView)
            await apply(
                TabViewKeeps(pane: PaneKeeps(view: FolderViewKeeps(foldersFirst: false), folderViews: .tabViewFirst)),
                to: tab)
            #expect(!tab.activePane.shownFoldersFirst)
            tab.activePane.toggleFoldersFirst()
            // On screen it was off: on now, as a change of the folder's view.
            #expect(tab.activePane.shownFoldersFirst)
            #expect(tab.activePane.shownFolderView?.unsaved.isEmpty == true)
        }

        @Test func refreshAndHiddenFilesKeepTheOverride() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            await remember("Alpha", .previews, in: tab, harness)
            await apply(
                TabViewKeeps(pane: PaneKeeps(view: FolderViewKeeps(view: .details), folderViews: .tabViewFirst)),
                to: tab)
            tab.perform(.refreshOrApplySearchSort)
            await settled(tab)
            tab.perform(.toggleHiddenFiles)
            await settled(tab)
            #expect(tab.activePane.tabViewOverride != nil)
            #expect(tab.activePane.content.mode == .details)
        }

        @Test func aDuplicatedPaneShowsTheFoldersView() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            await remember("Alpha", .previews, in: tab, harness)
            await apply(
                TabViewKeeps(pane: PaneKeeps(view: FolderViewKeeps(view: .details), folderViews: .tabViewFirst)),
                to: tab)
            tab.duplicatePane()
            await settled(tab)
            let copy = try #require(tab.otherPane)
            #expect(copy.tabViewOverride == nil)
            #expect(await waitUntil { copy.loaded && !copy.isNavigating && copy.content.mode == .previews })
        }

        @Test func twoPanesOnOneFolderEachShowTheirOwn() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            await remember("Alpha", .previews, in: tab, harness)
            tab.openSecondPane(at: real(harness, "Alpha"))
            await settled(tab)
            await apply(
                TabViewKeeps(pane: PaneKeeps(view: FolderViewKeeps(view: .details), folderViews: .tabViewFirst)),
                to: tab)
            #expect(await waitUntil { tab.panes.map(\.content.mode) == [.details, .previews] })
        }

        // MARK: New tabs

        @Test func aNewTabTakesTheNewTabViewAndATabForAFolderDoesnt() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            tab.setMode(.icons)
            tab.updatePreferences {
                $0.tabViews = [
                    TabView(
                        id: "new", name: "New",
                        keeps: TabViewKeeps(pane: PaneKeeps(view: FolderViewKeeps(view: .details))))
                ]
                $0.newTabViewID = "new"
            }
            let group = try #require(tab.group)
            group.openNewTab(from: tab)
            let opened = try #require(group.selected)
            #expect(opened !== tab)
            // A new tab of a test reads this harness's preferences once it is given its services, before its first
            // folder is read: the new-tab view is looked for then.
            opened.servicesOverride = harness.services
            opened.ensureLoaded()
            #expect(await waitUntil { opened.activePane.viewMode == .details })
            group.openTab(path: real(harness, "Beta"), from: tab)
            let forFolder = try #require(group.selected)
            forFolder.servicesOverride = harness.services
            forFolder.ensureLoaded()
            #expect(await waitUntil { forFolder.loaded && !forFolder.isNavigating })
            #expect(forFolder.activePane.viewMode == .icons)
        }

        @Test func aNewTabViewThatIsGoneIsNone() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            // An id that names no tab view is kept as it was saved, and does nothing.
            tab.updatePreferences { $0.newTabViewID = "nothing" }
            #expect(tab.preferences.newTabViewID == "nothing")
            tab.setMode(.icons)
            let group = try #require(tab.group)
            group.openNewTab(from: tab)
            let opened = try #require(group.selected)
            opened.servicesOverride = harness.services
            opened.ensureLoaded()
            #expect(await waitUntil { opened.loaded && !opened.isNavigating })
            #expect(opened.activePane.viewMode == .icons)
        }
    }
}
