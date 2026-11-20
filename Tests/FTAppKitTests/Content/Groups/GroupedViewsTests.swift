import AppKit
import FTFileSystem
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    /// How each view shows the groups: the List's rows and its column header, the grids' titles and places, the arrows
    /// from one group to the next, Previews' label, and the menus and the toolbar that group.
    @MainActor
    @Suite struct GroupedViewsTests: ToolbarTesting, ListTesting {
        private func opened(_ harness: ExplorerHarness, view: AppCommand) async throws -> MainWindowController {
            let tab = try await harness.open(try harness.makeGroupedFolder().path)
            tab.perform(view)
            #expect(await waitUntil { tab.content.entries.count == 6 })
            await tab.group(by: .groupByModified, expecting: ["Today", "Yesterday", "2020"])
            harness.layout(tab)
            return tab
        }

        private func list(_ tab: MainWindowController) throws -> ListViewController {
            try #require(descendants(of: tab.window?.contentView, ListTableView.self).first?.pane)
        }

        // The List as Finder's: the first group's items, its name in the Name column's title, then for each other
        // group an empty row, its title, and its items. Neither of the two extra rows is an item.
        @Test func theListPutsAnEmptyRowAndATitleBeforeEachGroupButTheFirst() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await opened(harness, view: .viewAsDetails)
            let pane = try list(tab)
            #expect(pane.rows.count == 6 + 2 * 2)
            #expect(pane.rows.prefix(4) == [.entry(0), .entry(1), .entry(2), .gap])
            #expect(pane.rows[4] == .header(1))
            #expect(pane.groupIndex(atRow: 4) == 1 && pane.entryIndex(atRow: 4) == nil)
            #expect(pane.entryIndex(atRow: 5) == 3 && pane.tableRow(ofEntry: 3) == 5)
            #expect(pane.rowPaths.filter(\.isEmpty).count == 4)
            #expect(header(tab)?.nameTitle == "Today")
            // A press on a title selects nothing; a press on an item selects that item.
            let table = pane.table
            // As a person presses: the release is queued, so the press ends.
            let probe = ListProbe(tab: tab)
            probe.press(at: probe.center(ofRow: 4))
            #expect(tab.content.selection.paths.isEmpty)
            #expect(!pane.tableView(table, shouldSelectRow: 3) && pane.tableView(table, shouldSelectRow: 5))
            tab.content.select(paths: [tab.content.entries[3].path])
            #expect(table.selectedRowIndexes == [5])
            // Selected from outside (a scenario, accessibility), a title's row is passed over.
            pane.selectFromOutside([4, 5])
            #expect(tab.content.selection.paths == [tab.content.entries[3].path])
            // A drag-to-select from a title down over the next group's item selects the item, never the title.
            probe.press(at: probe.center(ofRow: 4), moves: [probe.center(ofRow: 5)])
            #expect(tab.content.selection.paths == [tab.content.entries[3].path])
            #expect(pane.isWhollyInView(index: 3))
            // Not grouped, a row is an entry again and Name is Name.
            await tab.group(by: .groupByNone, expecting: [])
            #expect(pane.rows.isEmpty && pane.rowCount == 6 && pane.tableRow(ofEntry: 3) == 3)
            #expect(header(tab)?.nameTitle == nil)
        }

        // Scrolled, the Name column's title names the group at the top of the list.
        @Test func theNameColumnsTitleFollowsTheGroupAtTheTop() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await opened(harness, view: .viewAsDetails)
            // A window short enough for the list to scroll.
            tab.window?.setContentSize(NSSize(width: 900, height: 260))
            harness.layout(tab)
            let pane = try list(tab)
            pane.scrollPosition = (Double(pane.table.rect(ofRow: 5).minY), 0)
            #expect(await waitUntil { header(tab)?.nameTitle == "Yesterday" })
            pane.scrollPosition = (0, 0)
            #expect(await waitUntil { header(tab)?.nameTitle == "Today" })
        }

        // The column header's menu groups by the column clicked, and checked, groups by none.
        @Test func theColumnHeadersMenuGroupsByItsColumn() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await opened(harness, view: .viewAsDetails)
            let menu = tab.headerMenu(for: .modified, in: tab.activePane)
            let item = try #require(menu.items.first { $0.title == "Group by “Date Modified”" })
            #expect(item.state == .on)
            menu.performActionForItem(at: menu.index(of: item))
            #expect(await waitUntil { tab.groupTitles.isEmpty })
            let size = try #require(
                tab.headerMenu(for: .size, in: tab.activePane).items.first { $0.title == "Group by “Size”" })
            #expect(size.state == .off)
            #expect(
                !tab.headerMenu(for: .permissions, in: tab.activePane).items.contains { $0.title.hasPrefix("Group by") }
            )
        }

        // Icons: each group starts a new row under its title; the title stays at the top while its group scrolls
        // under it; ↓ crosses into the next group.
        @Test func iconsStartEachGroupOnANewRowUnderItsTitle() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await opened(harness, view: .viewAsIcons)
            let probe = GridProbe(tab: tab)
            probe.layout()
            let icons = try #require(probe.icons)
            let viewport = icons.viewport
            let lines = try #require(icons.groupedLines)
            #expect(lines.groups.map(\.count) == [3, 1, 2])
            let todayLast = icons.itemFrame(at: 2, viewport: viewport)
            let yesterday = icons.itemFrame(at: 3, viewport: viewport)
            #expect(yesterday.minY >= todayLast.maxY + CGFloat(GroupHeaderView.gridHeight) - 1)
            #expect(yesterday.minX == icons.itemFrame(at: 0, viewport: viewport).minX)
            #expect(icons.items(in: NSRect(x: 0, y: yesterday.minY, width: 10, height: 1), viewport: viewport) == 3..<4)
            let headers = descendants(of: probe.grid, GroupHeaderView.self)
            #expect(headers.count == 3)
            #expect(icons.headerFrames(viewport: viewport).count == 3)
            #expect(icons.contentSize(viewport: viewport).height >= CGFloat(lines.end))
            // ↓ from the first group's last item: the next group's only item, then the one under it.
            tab.content.select(paths: [tab.content.entries[2].path])
            probe.key("ArrowDown")
            #expect(tab.content.selection.paths == [tab.content.entries[3].path])
            probe.key("ArrowDown")
            #expect(tab.content.selection.paths == [tab.content.entries[4].path])
            probe.key("ArrowUp")
            #expect(tab.content.selection.paths == [tab.content.entries[3].path])
            probe.key("ArrowRight")
            #expect(tab.content.selection.paths == [tab.content.entries[4].path])
            // A drag-to-select over the second group's item finds it, each group a grid of its own.
            let box = DragSelectionBox(
                left: Double(yesterday.minX), top: Double(yesterday.minY) + 2, right: Double(yesterday.maxX),
                bottom: Double(yesterday.maxY) - 2)
            #expect(icons.marqueeHits(box: box, sizes: [:]).map(\.path) == [tab.content.entries[3].path])
            // Brought into view below the title held at the top.
            let offset = try #require(icons.revealOffset(for: 5))
            #expect(offset.y >= 0)
        }

        // The Compact List: the groups side by side, each starting a column of its own under its title.
        @Test func theCompactListStartsEachGroupInAColumnOfItsOwn() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await opened(harness, view: .viewAsList)
            let probe = GridProbe(tab: tab)
            probe.layout()
            let compact = try #require(probe.compact)
            let viewport = compact.viewport
            let lines = try #require(compact.groupedLines)
            #expect(lines.groups.map(\.count) == [3, 1, 2])
            let first = compact.itemFrame(at: 0, viewport: viewport)
            let second = compact.itemFrame(at: 3, viewport: viewport)
            #expect(second.minX > compact.itemFrame(at: 2, viewport: viewport).minX)
            #expect(second.minY == first.minY)
            #expect(first.minY >= CGFloat(GroupHeaderView.gridHeight))
            let frames = compact.headerFrames(viewport: viewport)
            #expect(frames.count == 3 && frames[1].minX == CGFloat(lines.groups[1].linesStart))
            // → from the first group's first item goes to the next group's column.
            tab.content.select(paths: [tab.content.entries[0].path])
            probe.key("ArrowRight")
            #expect(tab.content.selection.paths == [tab.content.entries[3].path])
            probe.key("ArrowDown")
            #expect(tab.content.selection.paths == [tab.content.entries[4].path])
            #expect(compact.revealOffset(for: 5) != nil)
            // A drag-to-select over the second group's column finds its item.
            let box = DragSelectionBox(
                left: Double(second.minX) + 1, top: Double(second.minY) + 1, right: Double(second.minX) + 4,
                bottom: Double(second.maxY) - 1)
            #expect(compact.marqueeHits(box: box, sizes: [:]).map(\.path) == [tab.content.entries[3].path])
        }

        // Previews: no title rows, each group on a row of its own, and the label names the group on screen.
        @Test func previewsStartEachGroupOnARowAndNameIt() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await opened(harness, view: .viewAsPreviews)
            let probe = GridProbe(tab: tab)
            probe.layout()
            let previews = try #require(probe.pane as? PreviewsViewController)
            #expect(previews.groupHeaderExtent == 0)
            #expect(previews.headerFrames(viewport: previews.viewport).isEmpty)
            let lines = try #require(previews.groupedLines)
            #expect(lines.items(onLine: 0).lowerBound == 0)
            #expect(
                previews.itemFrame(at: 3, viewport: previews.viewport).minY
                    > previews.itemFrame(
                        at: 2, viewport: previews.viewport
                    ).minY)
            let label = try #require(descendants(of: previews.root, GroupLabelView.self).first)
            #expect(!label.isHidden && label.accessibilityLabel() == "Today")
            // At 1 at a time the label says which of the group's files is on screen, and a scroll that rests on a
            // file selects it, the rows counted across the groups.
            tab.perform(.showPreviews1)
            probe.layout()
            previews.placeGroupHeaders()
            #expect(label.accessibilityLabel() == "Today, 1 of 3")
            tab.content.select(paths: [tab.content.entries[3].path])
            #expect(await waitUntil { previews.scrollPosition.top > 0 })
            previews.placeGroupHeaders()
            #expect(label.accessibilityLabel() == "Yesterday, 1 of 1")
            await tab.group(by: .groupByNone, expecting: [])
            previews.placeGroupHeaders()
            #expect(label.isHidden)
        }

        // The toolbar's Sort menu ends with the groups; the Group button lists them too, checked as they are.
        @Test func theToolbarGroups() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await opened(harness, view: .viewAsDetails)
            setItems(tab, [.title, .sort, .groupBy, .search], harness)
            let sort = try #require(button(tab, .sort))
            #expect(sort.tooltip == "Group By: Date Modified \u{00B7} Sort By: Name, Ascending")
            let group = try #require(button(tab, .groupBy))
            #expect(group.isOn && group.tooltip == "Group By: Date Modified")
            _ = group.accessibilityPerformPress()
            #expect(
                titles(menu) == [
                    "None", "-", "Name", "Date Modified", "Date Created", "Date Last Opened", "Date Added", "Size",
                    "Kind", "Tags",
                ])
            #expect(menu?.items.first { $0.title == "Date Modified" }?.checked == true)
            choose("Kind")
            #expect(await waitUntil { tab.activePane.groupBy == .kind })
            let overflow = try #require(tab.explorerToolbar.overflowEntry(.groupBy)?.submenu)
            #expect(overflow.items.first { $0.title == "Group by Kind" }?.state == .on)
            #expect(overflow.items.first { $0.title == "Group by Folder" } == nil)
        }
    }
}
