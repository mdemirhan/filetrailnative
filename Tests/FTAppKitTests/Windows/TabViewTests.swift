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

        // One pane that forgets the second: the pane closed isn't kept, so Two Panes then opens a new second pane, a
        // copy of the active one, whether the tab had two panes or one with another closed before.
        @Test func onePaneThatForgetsTheSecondLeavesTwoPanesANewOne() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            await go(tab, harness, "Alpha")
            tab.openSecondPane(at: real(harness, "Gamma"))
            await settled(tab)
            tab.workspace.setPaneSplit(0.3)
            await apply(TabViewKeeps(panes: 1, forgetsSecondPane: true), to: tab)
            #expect(!tab.showsTwoPanes && tab.closedSecondPane == nil)
            tab.perform(.toggleTwoPanes)
            await settled(tab)
            #expect(tab.panes.count == 2 && tab.panes[1].folderPath == real(harness, "Alpha"))
            // The room shared evenly, not where the divider was.
            #expect(tab.workspace.paneSplit == PaneSplit.even)

            await go(tab, harness, "Beta")
            tab.focusPane(tab.panes[1])
            await go(tab, harness, "Gamma")
            tab.perform(.toggleTwoPanes)
            #expect(tab.closedSecondPane != nil)
            await apply(TabViewKeeps(panes: 1, forgetsSecondPane: true), to: tab)
            #expect(tab.closedSecondPane == nil)
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

        @Test func tabViewOptionsStartsFromWhatTheFoldersViewShows() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            await go(tab, harness, "Alpha")
            let pane = tab.activePane
            let carried = (pane.viewMode, pane.sortBy, pane.groupBy)
            #expect(carried.0 != .previews && carried.1 != .size && carried.2 != .kind)
            tab.setMode(.previews)
            tab.setSort(.size, .desc)
            tab.perform(.groupByKind)
            tab.perform(.rememberFolderView)
            // The pane carries what it came in with again; the folder's view is what is on screen.
            #expect(pane.viewMode == carried.0 && pane.sortBy == carried.1 && pane.groupBy == carried.2)
            #expect(pane.shownMode == .previews && pane.shownSortBy == .size && pane.shownGroupBy == .kind)

            let draft = TabViewDraft(tab: tab.tabViewState, columnWidth: tab.workspace.paneColumnWidth)
            // Unchecked rows show what is on screen, so checking one keeps it.
            #expect(draft.active.kept == [.view])
            #expect(draft.active.values.view == .previews)
            #expect(draft.active.values.sort == FolderViewSort(by: .size, direction: .desc))
            #expect(draft.active.values.groupBy == .kind)
            var checked = draft.active
            checked.keep(.sort, true)
            #expect(
                checked.keeps.view
                    == FolderViewKeeps(view: .previews, sort: FolderViewSort(by: .size, direction: .desc)))
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

        // New Window's tab is a new tab wherever New Window is chosen: in a window, from the Dock's menu or while
        // Settings has the keyboard, and with no window open, where it is one tab on the folder that was in front in
        // the window closed last, as is the window a click on the Dock icon opens then. A folder opened in a new
        // window is not a new tab.
        @Test func newWindowTakesTheNewTabViewWhereverItIsChosenAndWithNoWindowOpen() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
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
            let first = try #require(tab.group)
            // A window a test opens reads this harness's preferences once its tab is given its services, before
            // its first folder is read: the new-tab view is looked for then.
            func newest(_ count: Int) throws -> ExplorerTabGroup {
                #expect(harness.windows.count == count)
                let group = try #require(harness.windows.newestGroup)
                group.selected?.servicesOverride = harness.services
                return group
            }
            func settled(_ group: ExplorerTabGroup) async throws -> MainWindowController {
                let front = try #require(group.selected)
                #expect(await waitUntil { front.loaded && !front.isNavigating })
                return front
            }

            first.openNewWindow(from: tab, path: nil)
            let fromWindow = try newest(2)
            #expect(await waitUntil { fromWindow.selected?.activePane.viewMode == .details })

            first.openNewWindow(from: tab, path: real(harness, "Beta"))
            let forFolder = try newest(3)
            #expect(try await settled(forFolder).activePane.viewMode == .icons)

            first.select(tab)
            first.focus()
            harness.windows.openNewWindowFromFront()
            let fromDock = try newest(4)
            #expect(fromDock !== forFolder)
            #expect(await waitUntil { fromDock.selected?.activePane.viewMode == .details })

            // With no window open: the window closed last had two tabs, the second in front, in Icons.
            for group in [fromWindow, forFolder, fromDock] { group.close() }
            #expect(await waitUntil { harness.windows.count == 1 })
            first.openTab(path: real(harness, "Beta"), from: tab)
            let beta = try await settled(first)
            #expect(first.tabs.count == 2 && beta.activePane.viewMode == .icons)
            first.close()
            #expect(await waitUntil { harness.windows.count == 0 })
            harness.windows.openNewWindowFromFront()
            let alone = try newest(1)
            #expect(alone !== first && alone.tabs.count == 1)
            #expect(await waitUntil { alone.selected?.activePane.folderPath == real(harness, "Beta") })
            #expect(await waitUntil { alone.selected?.activePane.viewMode == .details })

            // A click on the Dock icon with no window open: the same. The tab closed was in Icons again.
            alone.selected?.setMode(.icons)
            alone.close()
            #expect(await waitUntil { harness.windows.count == 0 })
            harness.windows.openDefaultWindow(initialCommand: nil)
            let fromIcon = try newest(1)
            #expect(fromIcon !== alone && fromIcon.tabs.count == 1)
            #expect(await waitUntil { fromIcon.selected?.activePane.folderPath == real(harness, "Beta") })
            #expect(await waitUntil { fromIcon.selected?.activePane.viewMode == .details })
        }

        // MARK: The viewer

        private func viewerView(_ id: String, _ keeps: TabViewKeeps) -> TabView {
            TabView(id: id, name: "View \(id)", keeps: keeps)
        }

        // A pane of two can open the viewer: the sheet's Opens the Viewer applies in either of two panes only, and
        // the tab view applied opens the viewer beside the other's list, showing what it selects, as the pane's Read
        // or Edit now says, the keyboard left in the list. Saved again from the tab, that pane opens the viewer; a tab
        // view giving the pane a view of a folder and no viewer closes it.
        @Test func aTabViewOpensTheViewerBesideTheOtherPane() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let tab = try await harness.open()
            let note = harness.folder.appending("note.txt").path
            tab.perform(.saveTabView)
            var sheet = try SheetInput.tabSheet(tab)
            let opens = try #require(
                SheetInput.control("tabViewOptions.keep.Opens the Viewer", in: sheet, as: NSButton.self))
            let view = try #require(SheetInput.control("tabViewOptions.view", in: sheet, as: NSPopUpButton.self))
            #expect(!view.itemTitles.contains("Viewer"))
            #expect(opens.isEnabled)
            try SheetInput.choose("Two", in: "tabViewOptions.panes", of: sheet)
            #expect(opens.isEnabled)
            sheet.onCancel()

            tab.updatePreferences {
                $0.tabViews = [
                    viewerView("v", TabViewKeeps(panes: 2, right: PaneKeeps(opensViewer: true, viewerEditing: true))),
                    viewerView("l", TabViewKeeps(panes: 2, right: PaneKeeps(view: FolderViewKeeps(view: .details)))),
                ]
            }
            tab.panes[0].content.select(paths: [note])
            tab.applyTabView(id: "v")
            #expect(
                await waitUntil {
                    tab.panes.count == 2 && tab.panes[1].viewer?.path.map { samePath($0, note) } == true
                })
            let viewer = try #require(tab.panes[1].viewer)
            #expect(viewer.mode == .following)
            #expect(await waitUntil { viewer.isEditing })
            #expect(tab.activePane === tab.panes[0])
            tab.perform(.saveTabView)
            sheet = try SheetInput.tabSheet(tab)
            #expect(sheet.draft.keeps.right?.opensViewer == true)
            // Its Read or Edit is the pane's own now.
            #expect(sheet.draft.right.viewer == PaneViewer(follows: true, editing: true))
            #expect(tab.panes[1].viewerDefaults == PaneViewer(follows: true, editing: true))
            sheet.onCancel()

            tab.applyTabView(id: "l")
            #expect(await waitUntil { tab.panes.count == 2 && tab.panes[1].viewer == nil })
            #expect(tab.panes[1].viewMode == .details)
        }

        // Edits not saved in a viewer are never dropped unasked: the same tab view again keeps them; one that closes
        // the viewer asks, Cancel keeping the viewer as it was and Don't Save closing it.
        @Test func aViewersEditsAreAskedAboutBeforeATabViewTakesItsPlace() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let tab = try await harness.open()
            let note = harness.folder.appending("note.txt").path
            tab.updatePreferences {
                $0.tabViews = [
                    viewerView("v", TabViewKeeps(panes: 2, right: PaneKeeps(opensViewer: true, viewerEditing: true))),
                    viewerView("l", TabViewKeeps(panes: 2, right: PaneKeeps(view: FolderViewKeeps(view: .details)))),
                ]
            }
            tab.panes[0].content.select(paths: [note])
            tab.applyTabView(id: "v")
            #expect(await waitUntil { tab.panes.count == 2 && tab.panes[1].viewer?.isEditing == true })
            let viewer = try #require(tab.panes[1].viewer)
            #expect(await waitUntil { viewer.textView.string == "x" })
            viewer.textView.insertText("y", replacementRange: NSRange(location: 1, length: 0))
            #expect(await waitUntil { viewer.isDirty })

            tab.applyTabView(id: "v")
            await settle()
            #expect(tab.frontAlert == nil)
            #expect(tab.panes[1].viewer === viewer && viewer.isDirty && viewer.textView.string == "xy")

            tab.applyTabView(id: "l")
            #expect(
                await waitUntil {
                    tab.frontAlert?.titleLabel.stringValue == "Save changes to \u{201C}note.txt\u{201D}?"
                })
            try SheetInput.press(["Escape"], in: tab.window)
            #expect(await waitUntil { tab.frontAlert == nil })
            #expect(tab.panes[1].viewer === viewer && viewer.isDirty)

            tab.applyTabView(id: "l")
            #expect(await waitUntil { tab.frontAlert != nil })
            let alert = try #require(tab.frontAlert)
            let discard = try #require(alert.buttons.first { $0.title == "Don\u{2019}t Save" })
            discard.performClick(nil)
            #expect(await waitUntil { tab.panes[1].viewer == nil })
            #expect(try String(contentsOfFile: note, encoding: .utf8) == "x")
        }

        // A viewer beside a list the tab view sends to another folder follows that list there, once it has arrived.
        @Test func aViewerWaitsForItsListsFolder() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let tab = try await harness.open()
            tab.openSecondPane()
            await settled(tab)
            let beta = real(harness, "Beta")
            tab.updatePreferences {
                $0.tabViews = [
                    viewerView(
                        "v",
                        TabViewKeeps(
                            panes: 2, left: PaneKeeps(opensViewer: true), right: PaneKeeps(folder: beta)))
                ]
            }
            tab.applyTabView(id: "v")
            #expect(await waitUntil { tab.panes[0].viewer != nil })
            #expect(samePath(tab.panes[1].folderPath, beta))
            #expect(tab.panes[0].viewer?.mode == .following)
        }

        // A one-pane tab view applied with the viewer active keeps the list, never the viewer alone; forgetting the
        // second pane, Two Panes then opens a new list beside it, with no viewer.
        @Test func onePaneOverAnActiveViewerKeepsTheList() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let tab = try await harness.open()
            let note = harness.folder.appending("note.txt").path
            tab.openFileInOtherPane(note)
            #expect(await waitUntil { tab.panes.count == 2 && tab.panes[1].viewer != nil })
            tab.focusPane(tab.panes[1])
            #expect(tab.activePaneIndex == 1)
            tab.updatePreferences {
                $0.tabViews = [viewerView("one", TabViewKeeps(panes: 1, forgetsSecondPane: true))]
            }
            tab.applyTabView(id: "one")
            #expect(await waitUntil { tab.panes.count == 1 })
            #expect(tab.panes[0].viewer == nil && tab.panes[0].folderPath == real(harness))
            #expect(tab.closedSecondPane == nil && tab.closedSecondViewer == nil)
            tab.perform(.toggleTwoPanes)
            #expect(await waitUntil { tab.panes.count == 2 })
            #expect(tab.panes.allSatisfy { $0.viewer == nil })
            #expect(tab.workspace.paneSplit == PaneSplit.even)
        }

        // A pane a one-pane tab view closes with a file's edits not saved asks first: Cancel applies nothing, Don't
        // Save closes it.
        @Test func onePaneAsksAboutTheClosedViewersEdits() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let tab = try await harness.open()
            let note = harness.folder.appending("note.txt").path
            tab.updatePreferences {
                $0.tabViews = [
                    viewerView("v", TabViewKeeps(panes: 2, right: PaneKeeps(opensViewer: true, viewerEditing: true))),
                    viewerView("one", TabViewKeeps(panes: 1, forgetsSecondPane: true)),
                ]
            }
            tab.panes[0].content.select(paths: [note])
            tab.applyTabView(id: "v")
            #expect(await waitUntil { tab.panes.count == 2 && tab.panes[1].viewer?.isEditing == true })
            let viewer = try #require(tab.panes[1].viewer)
            #expect(await waitUntil { viewer.textView.string == "x" })
            viewer.textView.insertText("y", replacementRange: NSRange(location: 1, length: 0))
            #expect(await waitUntil { viewer.isDirty })

            tab.applyTabView(id: "one")
            #expect(await waitUntil { tab.frontAlert != nil })
            try SheetInput.press(["Escape"], in: tab.window)
            #expect(await waitUntil { tab.frontAlert == nil })
            #expect(tab.panes.count == 2 && tab.panes[1].viewer === viewer && viewer.isDirty)

            tab.applyTabView(id: "one")
            #expect(await waitUntil { tab.frontAlert != nil })
            let alert = try #require(tab.frontAlert)
            let discard = try #require(alert.buttons.first { $0.title == "Don\u{2019}t Save" })
            discard.performClick(nil)
            #expect(await waitUntil { tab.panes.count == 1 })
            #expect(tab.closedSecondPane == nil)
            #expect(try String(contentsOfFile: note, encoding: .utf8) == "x")
        }

        // With a viewer, not a list, in the other pane, a pane's viewer has nothing to follow: it opens over its own
        // list on the file selected there, and the other pane's stays.
        @Test func aViewerOpensInPlaceWhereThereIsNoListToFollow() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let tab = try await harness.open()
            let note = harness.folder.appending("note.txt").path
            tab.openFileInOtherPane(note)
            #expect(await waitUntil { tab.panes.count == 2 && tab.panes[1].viewer != nil })
            tab.updatePreferences {
                $0.tabViews = [viewerView("v", TabViewKeeps(panes: 2, left: PaneKeeps(opensViewer: true)))]
            }
            tab.panes[0].content.select(paths: [note])
            tab.applyTabView(id: "v")
            #expect(
                await waitUntil {
                    tab.panes[0].viewer?.mode == .inPlace
                        && tab.panes[0].viewer?.path.map { samePath($0, note) } == true
                })
            #expect(tab.panes[1].viewer?.mode == .following)
        }

        // A tab view of one pane opens the viewer over its list, on the file selected as a step of Back, read or
        // edited as it says; with nothing selected, the viewer opens with nothing in it.
        @Test func aOnePaneTabViewOpensTheViewerInPlace() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let tab = try await harness.open()
            let note = harness.folder.appending("note.txt").path
            tab.updatePreferences {
                $0.tabViews = [
                    viewerView("one", TabViewKeeps(panes: 1, pane: PaneKeeps(opensViewer: true, viewerEditing: true)))
                ]
            }
            let pane = tab.panes[0]
            pane.content.select(paths: [note])
            tab.applyTabView(id: "one")
            #expect(
                await waitUntil {
                    pane.viewer?.mode == .inPlace && pane.viewer?.path.map { samePath($0, note) } == true
                })
            let viewer = try #require(pane.viewer)
            #expect(await waitUntil { viewer.isEditing })
            #expect(pane.navigationHistory.current.map { samePath($0, note) } == true)
            #expect(pane.viewerDefaults.editing)

            #expect(await tab.closeViewer(in: pane))
            pane.content.select(paths: [])
            tab.applyTabView(id: "one")
            #expect(await waitUntil { pane.viewer?.mode == .inPlace })
            #expect(pane.viewer?.path == nil)
        }

        // A second pane closed in another folder than the list's comes back with the viewer the tab view gives it:
        // the pane reading the folder it was closed in is not the pane leaving the viewer's folder.
        @Test func aViewerTabViewShowsInASecondPaneOpenedAgainElsewhere() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let tab = try await harness.open()
            tab.setMode(.icons)
            tab.updatePreferences {
                $0.tabViews = [
                    viewerView(
                        "v",
                        TabViewKeeps(
                            panes: 2, divider: .share(0.2), left: PaneKeeps(view: FolderViewKeeps(view: .details)),
                            right: PaneKeeps(opensViewer: true)))
                ]
            }
            tab.applyTabView(id: "v")
            #expect(await waitUntil { tab.panes.count == 2 && tab.panes[1].viewer != nil })
            await settled(tab)
            let file = real(harness, "Beta") + "/Code.swift"
            try "let x = 1".write(toFile: file, atomically: true, encoding: .utf8)
            await go(tab, harness, "Beta")
            tab.panes[0].content.select(paths: [file])
            #expect(await waitUntil { tab.panes[1].viewer?.path.map { samePath($0, file) } == true })

            // ⌘W in the viewer's pane closes the file, then the pane.
            tab.focusPane(tab.panes[1])
            tab.closePaneLeavingViewer()
            #expect(await waitUntil { tab.panes[1].viewer == nil })
            tab.closePaneLeavingViewer()
            #expect(await waitUntil { tab.panes.count == 1 })
            #expect(tab.closedSecondPane.map { samePath($0.start.path, real(harness)) } == true)

            tab.applyTabView(id: "v")
            #expect(await waitUntil { tab.panes.count == 2 })
            // The pane opened again reads the folder it was closed in, which isn't the list's.
            let reopened = tab.panes[1]
            await withCheckedContinuation { done in reopened.whenFirstReadFinished { _ in done.resume() } }
            #expect(samePath(reopened.folderPath, real(harness)))
            #expect(await waitUntil { reopened.viewer != nil })
            await settled(tab)
            #expect(
                tab.panes[1].viewer?.path.map { samePath($0, file) } == true, "the viewer stays once its pane has read")
            #expect(tab.activePane === tab.panes[0])
        }
    }
}
