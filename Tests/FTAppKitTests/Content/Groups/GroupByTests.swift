import AppKit
import FTFileSystem
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    /// View ▸ Group By in a folder: the groups, their fixed order, the sort inside them, and what keeps the grouping.
    @MainActor
    @Suite struct GroupByTests {
        private func opened(_ harness: ExplorerHarness, view: AppCommand = .viewAsDetails) async throws
            -> MainWindowController
        {
            let tab = try await harness.open(try harness.makeGroupedFolder().path)
            tab.perform(view)
            #expect(await waitUntil { tab.content.entries.count == 6 })
            return tab
        }

        // The groups of a date keep their own order, the newest first, whatever the sort; the sort orders the items
        // inside each group, folders first.
        @Test func aDateGroupsTheItemsAndTheSortOrdersThemInsideEachGroup() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await opened(harness)
            await tab.group(by: .groupByModified, expecting: ["Today", "Yesterday", "2020"])
            #expect(
                tab.groupedNames == [
                    ["Folder", "a-today.pdf", "b-today.txt"], ["c-yesterday.png"], ["d-old.txt", "e-old.swift"],
                ])
            #expect(tab.activePane.groupBy == .modified && tab.menuState.groupBy == .modified)
            // Sorted by Name descending: the groups stay, the items turn around inside them.
            tab.perform(.sortByName)
            #expect(
                await waitUntil {
                    tab.groupedNames == [
                        ["Folder", "b-today.txt", "a-today.pdf"], ["c-yesterday.png"], ["e-old.swift", "d-old.txt"],
                    ]
                })
            #expect(tab.groupTitles == ["Today", "Yesterday", "2020"])
            // The entries are the groups' items in order, and nothing else.
            #expect(tab.content.entries.count == 6 && tab.content.entryPaths.count == 6)
        }

        // Sizes the smallest first, a folder not measured last; kinds A to Z with Folders First's Folders first.
        @Test func sizesAndKindsKeepTheirOwnOrder() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await opened(harness)
            await tab.group(
                by: .groupBySize,
                expecting: ["Zero bytes", "Under 100 KB", "100 KB to 1 MB", "1 to 10 MB", "Not Measured"])
            #expect(tab.groupedNames.last == ["Folder"])
            await tab.group(by: .groupByKind, expecting: ["Folders", "Documents", "Images", "PDFs", "Source Code"])
            tab.perform(.toggleFoldersFirst)
            #expect(await waitUntil { tab.groupTitles == ["Documents", "Folders", "Images", "PDFs", "Source Code"] })
            await tab.group(by: .groupByName, expecting: ["A", "B", "C", "D", "E", "F"])
            await tab.group(by: .groupByNone, expecting: [])
            #expect(tab.content.entries.count == 6)
        }

        // At midnight the date groups move on a day: today's items are yesterday's.
        @Test func theDayChangingMovesTheDateGroupsOn() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await opened(harness)
            await tab.group(by: .groupByModified, expecting: ["Today", "Yesterday", "2020"])
            let tomorrow = Calendar.autoupdatingCurrent.date(byAdding: .day, value: 1, to: Date()) ?? Date()
            tab.content.now = { tomorrow }
            NotificationCenter.default.post(name: .NSCalendarDayChanged, object: nil)
            #expect(await waitUntil { tab.groupTitles == ["Yesterday", "Previous 7 Days", "2020"] })
            // Not grouped by a date, nothing is done.
            await tab.group(by: .groupByKind, expecting: ["Folders", "Documents", "Images", "PDFs", "Source Code"])
            let before = tab.content.groups
            NotificationCenter.default.post(name: .NSCalendarDayChanged, object: nil)
            await settle()
            #expect(tab.content.groups == before)
        }

        // The pane carries its grouping to the next folder, as its order; a tab opened from it, and the tab as it is
        // saved, keep it.
        @Test func thePaneCarriesItsGroupingAndKeepsItWithTheTab() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await opened(harness)
            await tab.group(by: .groupByKind, expecting: ["Folders", "Documents", "Images", "PDFs", "Source Code"])
            #expect(tab.openTab.groupBy == .kind)
            #expect(tab.snapshot.groupBy == .kind)
            #expect(tab.startupTab.groupBy == .kind)
            tab.go(to: harness.folder.appending("Grouped/Folder"))
            #expect(await waitUntil { tab.shownFolderPath.hasSuffix("/Folder") })
            #expect(tab.activePane.shownGroupBy == .kind)
            tab.perform(.groupByNone)
            #expect(tab.openTab.groupBy == nil)
        }

        // A folder's view can keep its grouping: shown there, and given back to the pane, which goes on with its own.
        @Test func aFoldersViewKeepsItsGrouping() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await opened(harness)
            let pane = tab.activePane
            pane.setFolderViewKeeps(.groupBy, true)
            pane.setFolderViewValue(.groupBy) { $0.groupBy = .modified }
            #expect(await waitUntil { tab.groupTitles == ["Today", "Yesterday", "2020"] })
            #expect(pane.folderView?.shown.groupBy == .modified && pane.groupBy == GroupByPreference.none)
            tab.perform(.updateFolderView)
            let path = tab.shownFolderPath
            #expect(pane.folderViews.views.own(path)?.keeps.groupBy == .modified)
            // Another folder shows the pane's own grouping; coming back, the folder's.
            tab.go(to: harness.folder.appending("Grouped/Folder"))
            #expect(await waitUntil { tab.shownFolderPath.hasSuffix("/Folder") && tab.groupTitles.isEmpty })
            tab.go(to: URL(fileURLWithPath: path))
            #expect(await waitUntil { tab.groupTitles == ["Today", "Yesterday", "2020"] })
            // Folder Customization has the row, between View and Sort By.
            #expect(FolderViewPopover.settings(for: .details).prefix(3) == [.view, .groupBy, .sort])
            #expect(
                FolderViewText.value(.groupBy, of: FolderViewKeeps(groupBy: .size), mode: .details, density: .standard)
                    == "Size")
        }

        // Search results group by name, folder or kind; the dates, sizes and tags are dimmed there, Folder is dimmed
        // in a folder.
        @Test func searchResultsHaveTheirOwnGroupsAndOnlyTheFieldsTheyCarry() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await opened(harness)
            #expect(!tab.commandAvailability()(.groupByFolder))
            #expect(tab.commandAvailability()(.groupBySize))
            let root = tab.shownFolderPath
            let results = [
                SearchResults.item(rootPath: root, outputPath: root + "/a-today.pdf"),
                SearchResults.item(rootPath: root, outputPath: root + "/b-today.txt"),
                SearchResults.item(rootPath: root, outputPath: root + "/Folder/inner.txt"),
            ]
            tab.content.showSearch(
                ContentSearchDisplay(
                    rootPath: root, viewKey: "search:\(root):x", results: results, sortBy: .name,
                    sortDirection: .asc, highlight: nil, isRunning: false, error: nil, errorIsQuiet: false))
            tab.content.setSearchGroupBy(.folder)
            #expect(tab.groupTitles == ["Grouped", "Folder"])
            #expect(tab.groupedNames == [["a-today.pdf", "b-today.txt"], ["inner.txt"]])
            tab.content.setSearchGroupBy(.kind)
            #expect(tab.groupTitles == ["Documents", "PDFs"])
            // The folder's grouping is its own, and comes back with the folder.
            tab.content.endSearch()
            #expect(tab.groupTitles.isEmpty)
        }

        // Reverse Group Order turns the groups around, the items inside as they were; it is dimmed while nothing is
        // grouped, and the tab keeps it.
        @Test func reverseGroupOrderTurnsTheGroupsAround() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await opened(harness)
            #expect(!tab.commandAvailability()(.reverseGroupOrder))
            await tab.group(by: .groupByModified, expecting: ["Today", "Yesterday", "2020"])
            #expect(tab.commandAvailability()(.reverseGroupOrder))
            tab.perform(.reverseGroupOrder)
            #expect(tab.groupTitles == ["2020", "Yesterday", "Today"])
            #expect(tab.groupedNames.last == ["Folder", "a-today.pdf", "b-today.txt"])
            #expect(tab.menuState.groupReversed && tab.openTab.groupReversed == true && tab.snapshot.groupReversed)
            // Another grouping keeps the direction.
            await tab.group(
                by: .groupBySize,
                expecting: [
                    "1 to 10 MB", "100 KB to 1 MB", "Under 100 KB", "Zero bytes", "Not Measured",
                ])
            tab.perform(.reverseGroupOrder)
            #expect(tab.groupTitles.first == "Zero bytes" && !tab.menuState.groupReversed)
        }

        // A folder's view that keeps the grouping keeps its direction with it; the pane's own stays as it was.
        @Test func aFoldersViewKeepsTheGroupsDirection() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await opened(harness)
            let pane = tab.activePane
            pane.setFolderViewKeeps(.groupBy, true)
            pane.setFolderViewValue(.groupBy) { $0.groupBy = .modified }
            #expect(await waitUntil { tab.groupTitles == ["Today", "Yesterday", "2020"] })
            tab.perform(.reverseGroupOrder)
            #expect(tab.groupTitles == ["2020", "Yesterday", "Today"])
            #expect(pane.folderView?.shown.groupReversed == true && !pane.groupReversed)
            #expect(
                FolderViewText.value(.groupBy, of: pane.shownKeeps, mode: .details, density: .standard)
                    == "Date Modified, reversed")
            // From Folder Customization's direction pop-up, back in order.
            pane.setFolderViewValue(.groupBy) { $0.groupReversed = nil }
            #expect(tab.groupTitles == ["Today", "Yesterday", "2020"])
        }

        // A pane brought back with search results' groups has its first results grouped so.
        @Test func aPaneBroughtBackKeepsItsSearchResultsGroups() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await opened(harness)
            tab.restoreSecondPane(
                OpenPanePreference(
                    path: tab.shownFolderPath, viewMode: .details, searchViewMode: .details, sortBy: .name,
                    sortDirection: .asc, includeHidden: false, foldersFirst: true, searchGroupBy: .kind,
                    searchGroupReversed: true),
                history: nil, active: false, split: nil)
            let second = try #require(tab.panes.last)
            #expect(second.searchGroupBy == .kind && second.searchGroupReversed)
            #expect(second.content.searchGroupBy == .kind && second.content.searchGroupReversed)
        }
    }
}
