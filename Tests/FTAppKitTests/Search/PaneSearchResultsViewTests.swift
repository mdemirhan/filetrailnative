// Checks what a pane keeps of its own: its List columns, its search results' view, order and sizes, and its search
// options; the menus that sort and group search results; and a tab view that keeps the search results' view
import AppKit
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    @MainActor
    @Suite struct PaneSearchResultsViewTests {
        private struct Opened {
            let harness: ExplorerHarness
            let tab: MainWindowController
            let engine: FakeSearchEngine
            let timers: ManualTimers
        }

        private func open() async throws -> Opened {
            let harness = try ExplorerHarness.windowless()
            let (tab, _) = try await harness.openList()
            let engine = FakeSearchEngine()
            let timers = ManualTimers()
            tab.search.session.engine = engine
            tab.search.session.timers = timers
            engine.finds = { _ in (["note.txt", "notes.md"], false, false) }
            return Opened(harness: harness, tab: tab, engine: engine, timers: timers)
        }

        private func search(_ text: String, _ opened: Opened) throws {
            let field = try #require(opened.tab.searchField)
            field.stringValue = text
            opened.tab.search.controlTextDidChange(
                Notification(name: NSControl.textDidChangeNotification, object: field))
            opened.timers.advance(0.4)
        }

        private func titles(_ menu: NSMenu?) -> [String] { menu?.items.map(\.title) ?? [] }

        @Test func sortByRunsOverSearchResultsWithFolderAndWithoutFoldersFirst() async throws {
            let opened = try await open()
            let tab = opened.tab
            // Over a folder: Folder is dimmed, Folders First is there.
            #expect(!tab.canPerform(.sortByFolder))
            #expect(tab.canPerform(.toggleFoldersFirst))
            let folderOrder = tab.activePane.sortBy
            try search("no", opened)
            #expect(tab.searchRootPath != nil)
            #expect(tab.canPerform(.sortByFolder) && tab.canPerform(.sortByName) && tab.canPerform(.sortBySize))
            #expect(!tab.canPerform(.toggleFoldersFirst))

            // Results start ordered by their folder: by name first, then by folder again.
            tab.perform(.sortByName)
            #expect(tab.search.session.sortBy == .name && tab.menuState.resultsSortBy == .name)
            tab.perform(.sortByFolder)
            #expect(tab.search.session.sortBy == .path && tab.search.session.sortDirection == .asc)
            #expect(tab.menuState.resultsSortBy == .path)
            // The pane's own from now on, and the app's, which a pane with nothing to copy starts from.
            #expect(tab.activePane.shownPreferences(tab.preferences).searchResultsSortBy == .path)
            #expect(tab.preferences.searchResultsSortBy == .path)
            // The same field again turns the order around, as a click on its column's title does.
            tab.perform(.sortByFolder)
            #expect(tab.search.session.sortDirection == .desc)
            tab.perform(.sortBySize)
            #expect(tab.search.session.sortBy == .size)
            // The folder's order isn't touched.
            #expect(tab.activePane.sortBy == folderOrder)
            await opened.harness.close()
        }

        @Test func theHeaderMenuGroupsResultsByTheColumnClicked() async throws {
            let opened = try await open()
            let tab = opened.tab
            try search("no", opened)
            let pane = tab.activePane
            let menu = tab.headerMenu(for: .folder, in: pane)
            #expect(titles(menu).contains("Group by \u{201C}Folder\u{201D}"))
            let kind = tab.headerMenu(for: .kind, in: pane)
            #expect(titles(kind).contains("Group by \u{201C}Kind\u{201D}"))
            await opened.harness.close()
        }

        @Test func emptySpaceUnderResultsHasViewAsGroupByAndSortByOnly() async throws {
            let opened = try await open()
            let tab = opened.tab
            try search("no", opened)
            let menu = try #require(tab.contextMenus.contentMenu(for: nil))
            let shown = menu.items.filter { !$0.isSeparatorItem && !$0.isHidden }.map(\.title)
            #expect(shown == ["View As", "Group By", "Sort By"])
            let sortBy = try #require(menu.items.first { $0.title == "Sort By" }?.submenu)
            #expect(titles(sortBy).prefix(2) == ["Name", "Folder"])
            await opened.harness.close()
        }

        @Test func aTabViewShowsItsSearchResultsViewOnTheResultsAtOnce() async throws {
            let opened = try await open()
            let tab = opened.tab
            try search("no", opened)
            let folderMode = tab.activePane.viewMode
            var own = tab.activePane.shownPreferences(tab.preferences)
            own.searchResultsSortBy = .kind
            own.searchResultsSortDirection = .desc
            own.searchColumns[.kind].toggle()
            own.searchIconSizes[tab.preferences.density] = 96
            let results = SearchResultsKeeps(own, view: .icons, groupBy: .kind, groupReversed: true)
            tab.updatePreferences {
                $0.tabViews = [
                    TabView(id: "tv", name: "Results", keeps: TabViewKeeps(pane: PaneKeeps(searchResults: results)))
                ]
            }
            tab.applyTabView(id: "tv")
            let pane = tab.activePane
            #expect(tab.searchRootPath != nil)
            #expect(pane.searchResultsState == results)
            #expect(tab.search.session.sortBy == .kind && tab.search.session.sortDirection == .desc)
            #expect(pane.content.mode == .icons)
            #expect(pane.activeGroupBy == .kind && pane.activeGroupReversed)
            // The folder's own view is left as it was.
            #expect(pane.viewMode == folderMode)
            await opened.harness.close()
        }

        @Test func resultsViewAndGroupsSetInAPaneAreTheAppsWhicheverPaneIsInFront() async throws {
            let opened = try await open()
            let tab = opened.tab
            let right = tab.openSecondPane()
            #expect(await waitUntil { right.loaded && right.hasShownFolder && !right.isNavigating })
            let left = tab.panes[0]
            tab.activate(left)
            try search("no", opened)
            #expect(left.showsSearchResults)
            tab.perform(.viewAsIcons)
            tab.perform(.groupByKind)
            tab.perform(.reverseGroupOrder)
            #expect(left.searchViewMode == .icons && left.searchGroupBy == .kind && left.searchGroupReversed)
            #expect(tab.preferences.searchViewMode == .icons)
            #expect(tab.preferences.searchGroupBy == .kind && tab.preferences.searchGroupReversed)
            // The other pane in front and the window saved: its own are as they were, and the app's the ones set last.
            tab.activate(right)
            tab.group?.saveSession()
            #expect(right.searchViewMode == .details && right.searchGroupBy == .none)
            #expect(tab.preferences.searchViewMode == .icons && tab.preferences.searchGroupBy == .kind)
            // A tab with none to copy starts from them.
            var none = tab.preferences
            none.openTabs = []
            let start = StartupTabs.resolve(none, homePath: "/", startupFolderPath: nil, restoreTabs: false).tabs.first
            #expect(start?.searchViewMode == .icons)
            #expect(start?.searchGroupBy == .kind && start?.searchGroupReversed == true)
            await opened.harness.close()
        }

        @Test func aSizeSetOverResultsLeavesATabViewsHoldOnTheFoldersSize() async throws {
            let opened = try await open()
            let tab = opened.tab
            let sizes = FolderViewSizes(
                iconSizes: DensitySizes(standard: 96, finder: 96), compactListWidths: .compactListDefaults,
                previewCounts: .previewCountDefaults)
            tab.updatePreferences {
                $0.tabViews = [
                    TabView(
                        id: "tv", name: "Sizes",
                        keeps: TabViewKeeps(
                            pane: PaneKeeps(view: FolderViewKeeps(size: sizes), folderViews: .tabViewFirst)))
                ]
            }
            tab.applyTabView(id: "tv")
            let pane = tab.activePane
            #expect(pane.tabViewOverride?.kept.contains(.size) == true)
            try search("no", opened)
            #expect(pane.showsSearchResults)
            pane.content.onIconSizeChanged?(.standard, 48)
            pane.content.onCompactListWidthChanged?(.standard, 400)
            pane.content.onPreviewCountChanged?(.standard, 9)
            #expect(pane.tabViewOverride?.kept.contains(.size) == true)
            let own = pane.shownPreferences(tab.preferences)
            #expect(own.searchIconSizes.standard == 48 && own.iconSizes.standard == 96)
            #expect(own.searchCompactListWidths.standard == 400 && own.searchPreviewCounts.standard == 9)
            await opened.harness.close()
        }

        @Test func columnsShownAreEachPanesOwn() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, _) = try await harness.openList()
            let right = tab.openSecondPane()
            #expect(await waitUntil { right.loaded && right.hasShownFolder && !right.isNavigating })
            let left = tab.panes[0]
            let before = right.shownPreferences(tab.preferences).detailColumns[.size]
            tab.toggleColumn(.size, in: left)
            #expect(left.shownPreferences(tab.preferences).detailColumns[.size] != before)
            #expect(right.shownPreferences(tab.preferences).detailColumns[.size] == before)
            // The app's is the last set anywhere: what a pane with nothing to copy starts from.
            #expect(tab.preferences.detailColumns[.size] != before)
            await harness.close()
        }

        @Test func aNewTabTakesThePanesSearchResultsViewAndOptions() async throws {
            let opened = try await open()
            let tab = opened.tab
            try search("no", opened)
            tab.perform(.sortByKind)
            tab.activePane.changeOwnSettings { $0.searchRecursive = false }
            // Another pane sets the app's since: the new tab still takes this pane's.
            tab.updatePreferences {
                $0.searchResultsSortBy = .size
                $0.searchRecursive = true
            }
            let group = try #require(tab.group)
            group.openNewTab(from: tab)
            let made = try #require(group.tabs.last)
            #expect(made !== tab)
            #expect(await waitUntil { made.activePane.loaded })
            let own = made.activePane.shownPreferences(made.preferences)
            #expect(own.searchResultsSortBy == .kind)
            #expect(own.searchRecursive == false)
            #expect(made.search.session.sortBy == .kind && made.search.session.recursive == false)
            await opened.harness.close()
        }
    }
}
