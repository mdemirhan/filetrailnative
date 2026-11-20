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

        // The List: every group has its title in a row of its own, the first as the others. A title's row is not an
        // item.
        @Test func theListPutsATitleBeforeEachGroup() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await opened(harness, view: .viewAsDetails)
            let pane = try list(tab)
            #expect(pane.rows.count == 6 + 3)
            #expect(pane.rows.prefix(6) == [.header(0), .entry(0), .entry(1), .entry(2), .header(1), .entry(3)])
            #expect(pane.groupIndex(atRow: 0) == 0 && pane.entryIndex(atRow: 0) == nil)
            #expect(pane.groupIndex(atRow: 4) == 1 && pane.entryIndex(atRow: 4) == nil)
            #expect(pane.entryIndex(atRow: 5) == 3 && pane.tableRow(ofEntry: 3) == 5)
            #expect(pane.rowPaths.filter(\.isEmpty).count == 3)
            // The titles on screen, the first group's among them.
            let titles = descendants(of: pane.table, GroupHeaderView.self).compactMap { $0.accessibilityLabel() }
            #expect(Set(titles) == ["Today", "Yesterday", "2020"])
            // A press on a title selects nothing; a press on an item selects that item.
            let table = pane.table
            // As a person presses: the release is queued, so the press ends.
            let probe = ListProbe(tab: tab)
            probe.press(at: probe.center(ofRow: 4))
            #expect(tab.content.selection.paths.isEmpty)
            probe.press(at: probe.center(ofRow: 0))
            #expect(tab.content.selection.paths.isEmpty)
            #expect(!pane.tableView(table, shouldSelectRow: 0) && !pane.tableView(table, shouldSelectRow: 4))
            #expect(pane.tableView(table, shouldSelectRow: 5))
            tab.content.select(paths: [tab.content.entries[3].path])
            #expect(table.selectedRowIndexes == [5])
            // Selected from outside (a scenario, accessibility), a title's row is passed over.
            pane.selectFromOutside([4, 5])
            #expect(tab.content.selection.paths == [tab.content.entries[3].path])
            // A drag-to-select from a title down over the next group's item selects the item, never the title.
            probe.press(at: probe.center(ofRow: 4), moves: [probe.center(ofRow: 5)])
            #expect(tab.content.selection.paths == [tab.content.entries[3].path])
            #expect(pane.isWhollyInView(index: 3))
            // Not grouped, a row is an entry again.
            await tab.group(by: .groupByNone, expecting: [])
            #expect(pane.rows.isEmpty && pane.rowCount == 6 && pane.tableRow(ofEntry: 3) == 3)
        }

        // The groups are half a row apart: a title's row is as high as an item's, every title but the first has half
        // a row above it in its own row, and there is no empty row between two groups. The rows are where their
        // heights put them, for a press, a drag-to-select across groups, the arrows and the stripes; not grouped,
        // every row is as high again.
        @Test func theListsGroupsAreHalfARowApart() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await opened(harness, view: .viewAsDetails)
            let pane = try list(tab)
            let table = pane.table
            let row = table.rowHeight
            let space = pane.groupSpace
            #expect(space == (row / 2).rounded() && space > 0)
            // Today's title and three items, Yesterday's title under its space, its item, 2020's title, two items.
            #expect(table.rect(ofRow: 0) == NSRect(x: 0, y: 0, width: table.bounds.width, height: row))
            #expect(table.rect(ofRow: 3).maxY == 4 * row)
            #expect(table.rect(ofRow: 4).height == row + space && table.rect(ofRow: 4).minY == 4 * row)
            #expect(table.rect(ofRow: 5).minY == 5 * row + space && table.rect(ofRow: 5).height == row)
            #expect(table.rect(ofRow: 8).maxY == 9 * row + 2 * space)
            #expect(pane.groupedRowsHeight == 9 * row + 2 * space)
            #expect(table.frame.height >= 9 * row + 2 * space)
            // A title sits in the row's height at the bottom of its row, the space above it.
            let titles = descendants(of: table, GroupHeaderView.self)
            let yesterday = try #require(titles.first { $0.accessibilityLabel() == "Yesterday" })
            let today = try #require(titles.first { $0.accessibilityLabel() == "Today" })
            #expect(yesterday.spaceAbove == space && today.spaceAbove == 0)
            #expect(yesterday.frame.height == row + space && today.frame.height == row)
            // A press at a row's place selects that row's item.
            let probe = ListProbe(tab: tab)
            probe.press(at: probe.center(ofRow: 7))
            #expect(tab.content.selection.paths == [tab.content.entries[4].path])
            // A drag-to-select from Yesterday's title down to 2020's first item takes the items on the way, across
            // 2020's title, and no more.
            probe.press(at: probe.center(ofRow: 4), moves: [probe.center(ofRow: 7)])
            #expect(Set(tab.content.selection.paths) == Set(tab.content.entries[3...4].map(\.path)))
            // ↓ from a group's last item goes to the next group's first, over the title.
            tab.content.select(paths: [tab.content.entries[2].path])
            probe.key("ArrowDown")
            #expect(tab.content.selection.paths == [tab.content.entries[3].path])
            #expect(table.selectedRowIndexes == [5])
            // The stripes start again under each title: a group's first item has none, its second has one.
            let odd = Set(listViews("list.row.odd", in: table).compactMap { table.row(for: $0) })
            #expect(odd == [2, 8])
            // Not grouped, every row is as high.
            await tab.group(by: .groupByNone, expecting: [])
            harness.layout(tab)
            #expect(pane.groupedRowsHeight == nil && table.rect(ofRow: 5).minY == 5 * row)
            #expect(table.rect(ofRow: 5).height == row)
            #expect(!pane.responds(to: #selector(NSTableViewDelegate.tableView(_:heightOfRow:))))
            // Grouped again, they are apart again.
            await tab.group(by: .groupByModified, expecting: ["Today", "Yesterday", "2020"])
            harness.layout(tab)
            #expect(table.rect(ofRow: 5).minY == 5 * row + space)
        }

        // Grouped, the first column's title is still Name, with its sort arrow, wherever the list is scrolled: a
        // group's name there read as the column's.
        @Test func theNameColumnsTitleStaysNameWhileGrouped() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await opened(harness, view: .viewAsDetails)
            // A window short enough for the list to scroll.
            tab.window?.setContentSize(NSSize(width: 900, height: 260))
            harness.layout(tab)
            let pane = try list(tab)
            let name = try #require(header(tab)?.cell(for: .name))
            #expect(name.title.stringValue == "Name" && name.active && !name.chevron.isHidden)
            pane.scrollPosition = (Double(pane.table.rect(ofRow: 5).minY), 0)
            harness.layout(tab)
            #expect(name.title.stringValue == "Name")
        }

        // Grouped, the list has one more row for each group, so the rows on screen at its end are
        // numbered past its last item: the details asked for are those of the items on those rows, where the rows'
        // numbers taken for items' made a range that ends before it starts, and the app stopped.
        @Test func aGroupedListScrolledToItsEndAsksForTheDetailsOfItsLastItems() async throws {
            let harness = try ExplorerHarness.windowless()
            let url = harness.folder.appending("Letters")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let letters = (0..<26).map { String(UnicodeScalar(UInt8(97 + $0))) }
            for letter in letters {
                FileManager.default.createFile(atPath: url.appendingPathComponent("\(letter).txt").path, contents: nil)
            }
            let tab = try await harness.open(url.path)
            tab.perform(.viewAsDetails)
            #expect(await waitUntil { tab.content.entries.count == 26 })
            tab.perform(.groupByName)
            #expect(await waitUntil { tab.groupTitles.count == 26 })
            tab.window?.setContentSize(NSSize(width: 900, height: 260))
            harness.layout(tab)
            let pane = try list(tab)
            #expect(pane.rowCount == 26 + 26)
            pane.scrollPosition = (Double(pane.table.rect(ofRow: pane.rowCount - 1).maxY), 0)
            let rows = pane.table.rows(in: pane.table.visibleRect)
            // The case: the first row on screen, less the ten before it, is past the last item.
            #expect(rows.location - 10 > 26)
            let near = try #require(pane.entriesNearScreen)
            #expect(near.upperBound == 26 && near.lowerBound < 25 && near.lowerBound >= 0)
            let first = try #require(
                pane.entryIndex(atRow: rows.location) ?? pane.entryIndex(atRow: rows.location + 1)
                    ?? pane.entryIndex(atRow: rows.location + 2))
            #expect(near.lowerBound == max(0, first - 10))
            // At the top, the first items and ten after those on screen.
            pane.scrollPosition = (0, 0)
            #expect(pane.entriesNearScreen?.lowerBound == 0)
            await harness.close()
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
            // Scrolled, the first group's title is held at the top over its items: a press on the title is on none
            // of them, where it selected, opened or gave the menu of the item under it.
            tab.window?.setContentSize(NSSize(width: 900, height: 220))
            probe.layout()
            let firstItem = icons.itemFrame(at: 0, viewport: icons.viewport)
            icons.scrollPosition = (Double(firstItem.minY) + 20, 0)
            probe.layout()
            icons.placeGroupHeaders()
            let held = try #require(
                descendants(of: probe.grid, GroupHeaderView.self).first { $0.frame.intersects(firstItem) })
            let onTitle = NSPoint(x: firstItem.midX, y: held.frame.midY)
            #expect(
                firstItem.contains(onTitle) && icons.itemIndex(at: onTitle) == nil && icons.entry(at: onTitle) == nil)
            let below = NSPoint(x: firstItem.midX, y: held.frame.maxY + 4)
            #expect(icons.itemIndex(at: below) == 0)
        }

        // The Compact List: the groups one after another down a column, each under its title, going on in the next
        // column only when there is no room left; a column that goes on with a group starts with its title again.
        @Test func theCompactListGroupsFollowOneAnotherDownTheColumns() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await opened(harness, view: .viewAsList)
            let probe = GridProbe(tab: tab)
            probe.layout()
            let compact = try #require(probe.compact)
            let viewport = compact.viewport
            let columns = try #require(compact.columns(height: viewport.height))
            #expect(columns.columnCount == 1 && columns.headers.count == 3)
            let first = compact.itemFrame(at: 0, viewport: viewport)
            let todayLast = compact.itemFrame(at: 2, viewport: viewport)
            let second = compact.itemFrame(at: 3, viewport: viewport)
            // Yesterday starts in the same column, under its title, under Today's last item.
            #expect(second.minX == first.minX)
            #expect(second.minY >= todayLast.maxY + CGFloat(GroupHeaderView.gridHeight))
            #expect(first.minY >= CGFloat(GroupHeaderView.gridHeight))
            let places = compact.headerPlaces(viewport: viewport)
            #expect(places.map(\.group) == [0, 1, 2] && !places.contains(where: \.continued))
            #expect(places[1].frame.minY >= todayLast.maxY && places[1].frame.maxY <= second.minY)
            // ↓ crosses from Today into Yesterday.
            tab.content.select(paths: [tab.content.entries[2].path])
            probe.key("ArrowDown")
            #expect(tab.content.selection.paths == [tab.content.entries[3].path])
            #expect(compact.revealOffset(for: 5) != nil)
            // A drag-to-select over Yesterday's item finds it.
            let box = DragSelectionBox(
                left: Double(second.minX) + 1, top: Double(second.minY) + 1, right: Double(second.minX) + 4,
                bottom: Double(second.maxY) - 1)
            #expect(compact.marqueeHits(box: box, sizes: [:]).map(\.path) == [tab.content.entries[3].path])
            // A press on Yesterday's title is on no item.
            #expect(compact.itemIndex(at: NSPoint(x: places[1].frame.midX, y: places[1].frame.midY)) == nil)

            // In a pane too short for them all, a group goes on in the next column under its title again, and → goes
            // to the item beside it there.
            tab.window?.setContentSize(NSSize(width: 900, height: 230))
            probe.layout()
            let short = try #require(compact.columns(height: compact.viewport.height))
            #expect(short.columnCount > 1)
            let secondColumn = try #require(short.runs.first { $0.column == 1 })
            #expect(short.headers.contains { $0.column == 1 && $0.top == 0 })
            compact.placeGroupHeaders()
            let shown = descendants(of: probe.grid, GroupHeaderView.self)
            #expect(shown.contains { $0.frame.minX == CGFloat(short.columnStart(1)) })
            tab.content.select(paths: [tab.content.entries[0].path])
            probe.key("ArrowRight")
            #expect(tab.content.selection.paths == [tab.content.entries[secondColumn.firstItem].path])
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

        // A group's title is in the system's secondary label color in every view, so it is told from an item's name:
        // semibold still, and drawn as light as that color is (a label would draw it nearly as dark as a name).
        @Test func aTitleIsInTheSecondaryColor() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await opened(harness, view: .viewAsDetails)
            func titleColors() -> [NSColor] {
                descendants(of: tab.window?.contentView, GroupHeaderView.self).compactMap {
                    $0.titleText.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
                }
            }
            #expect(titleColors().count == 3 && titleColors().allSatisfy { $0 == .secondaryLabelColor })
            let header = try #require(descendants(of: try list(tab).table, GroupHeaderView.self).first)
            let font = try #require(header.titleText.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
            #expect(font == ChromeColors.font(size: DesignTokens.typeScale.small, weight: 600))
            for view in [AppCommand.viewAsIcons, .viewAsList] {
                tab.perform(view)
                let probe = GridProbe(tab: tab)
                probe.layout()
                #expect(titleColors().count == 3 && titleColors().allSatisfy { $0 == .secondaryLabelColor })
            }
            // Previews' label: the group's name in that color too.
            tab.perform(.viewAsPreviews)
            let probe = GridProbe(tab: tab)
            probe.layout()
            let previews = try #require(probe.pane as? PreviewsViewController)
            let label = try #require(descendants(of: previews.root, GroupLabelView.self).first)
            let text = try #require(descendants(of: label, NSTextField.self).first).attributedStringValue
            #expect(text.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == .secondaryLabelColor)

            // Drawn on white in the light appearance, the title's darkest point is a medium gray, not a name's black.
            let drawn = GroupHeaderView(frame: NSRect(x: 0, y: 0, width: 200, height: GroupHeaderView.gridHeight))
            drawn.appearance = NSAppearance(named: .aqua)
            drawn.configure(
                tab.content.groups[0], style: .grid, theme: Theme(appearance: .light, accentHex: "#007aff"),
                background: .white)
            let bitmap = try #require(drawn.bitmapImageRepForCachingDisplay(in: drawn.bounds))
            drawn.cacheDisplay(in: drawn.bounds, to: bitmap)
            var darkest = 1.0
            let frame = drawn.titleFrame
            let scale = CGFloat(bitmap.pixelsWide) / drawn.bounds.width
            for y in Int(frame.minY * scale)..<Int(frame.maxY * scale) {
                for x in Int(frame.minX * scale)..<Int(frame.maxX * scale) {
                    darkest = min(darkest, Double(bitmap.colorAt(x: x, y: y)?.redComponent ?? 1))
                }
            }
            #expect(darkest > 0.4 && darkest < 0.6, "the title's darkest point is \(darkest)")
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
                    "Kind", "Tags", "-", "Reverse Group Order",
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
