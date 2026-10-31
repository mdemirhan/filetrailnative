// Covers the Compact List in an explorer window that is never shown, by feature row (the Compact List cases of
// ContentPane.test.tsx)
import AppKit
import FTFileSystem
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    @MainActor
    @Suite struct CompactListTests {
        // F-776 F-777 B-VIEW-031 B-VIEW-032 B-VIEW-033 B-VIEW-038: items fill a column top to bottom, then the next;
        // each is as wide as its icon and name, its highlight hugging them, in `padding: 8 10 4`.
        // B-VIEW-001
        @Test func itemsFillAColumnThenTheNextAndHugTheirNames() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, probe) = try await harness.openGrid(.viewAsList, files: 120)
            let compact = try #require(probe.compact)
            let layout = DesignTokens.flowList(density: .comfortable)
            let rows = compact.rowsPerColumn
            #expect(rows == layout.rowsPerColumn(containerHeight: Double(compact.viewport.height)))
            #expect(compact.itemsPerLine == rows)
            let items = probe.compactItems
            for index in [0, 1, rows, rows + 2] where index < 120 {
                let name = tab.content.entries[index].name
                let item = try #require(items[name])
                let column = index / rows
                let row = index % rows
                #expect(Double(item.view.frame.minX) == 10 + Double(column) * 310)
                #expect(Double(item.view.frame.minY) == 8 + Double(row) * 28)
                #expect(item.view.frame.height == 28)
                let nameWidth = (name as NSString).size(withAttributes: [.font: compact.nameFont]).width
                #expect(abs(item.view.frame.width - min(292, nameWidth + 50)) < 0.01)
                #expect(item.iconView.frame == NSRect(x: 12, y: 5, width: 18, height: 18))
                #expect(item.label.frame.minX == 38)
                #expect(item.label.font?.pointSize == 14)
            }
            let columns = (120 + rows - 1) / rows
            #expect(Double(probe.grid?.frame.width ?? 0) == 20 + Double(columns) * 292 + Double(columns - 1) * 18)
            await harness.close()
        }

        // T-f76e6635 F-776 B-VIEW-035: the wheel's up and down scroll the list sideways; a mostly sideways gesture is
        // left to the scroll view.
        // B-SEL-069
        @Test func turnsTheWheelsUpAndDownIntoSidewaysScroll() async throws {
            let harness = try ExplorerHarness.windowless()
            let (_, probe) = try await harness.openGrid(.viewAsList, files: 400)
            let compact = try #require(probe.compact)
            #expect(compact.scroll.wheelScrollsSideways)
            let event = try #require(
                CGEvent(
                    scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: -60, wheel2: 0, wheel3: 0
                ).flatMap { NSEvent(cgEvent: $0) })
            compact.scroll.scrollWheel(with: event)
            #expect(compact.scroll.contentView.bounds.origin.x == 60)
            #expect(compact.scroll.contentView.bounds.origin.y == 0)
            compact.scroll.scrollSideways(by: -1000)
            #expect(compact.scroll.contentView.bounds.origin.x == 0)
            await harness.close()
        }

        // T-6eedbcad B-VIEW-036 B-VIEW-037 B-VIEW-087 B-VIEW-088: ←/→ move by a column and ↑/↓ by an item, and the lead's
        // column is kept in view sideways; a page moves by the columns that fit.
        // B-NAV-144 B-NAV-148 B-NAV-155 B-NAV-166 B-SEL-046 B-SEL-050 B-SEL-062 T-39bda507 T-ed1ee8c6
        @Test func arrowsMoveByAColumnAndKeepTheItemHorizontallyVisible() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, probe) = try await harness.openGrid(.viewAsList, files: 400)
            let compact = try #require(probe.compact)
            tab.content.focusList()
            let rows = compact.rowsPerColumn
            probe.key("ArrowDown")
            probe.key("ArrowDown")
            #expect(probe.selectedNames == ["item-001.txt"])
            probe.key("ArrowRight")
            #expect(probe.selectedNames == [String(format: "item-%03d.txt", 1 + rows)])
            probe.key("ArrowLeft")
            #expect(probe.selectedNames == ["item-001.txt"])
            probe.key("End")
            #expect(probe.selectedNames == ["item-399.txt"])
            let layout = DesignTokens.flowList(density: .comfortable)
            let clip = compact.scroll.contentView.bounds
            let right = Double(399 / rows) * layout.columnStep + layout.itemWidth
            #expect(abs(Double(clip.origin.x) - (right - (Double(clip.width) - 20))) <= 1 || clip.maxX >= right)
            probe.key("Home")
            #expect(compact.scroll.contentView.bounds.origin.x == 0)
            let lines = SelectionNavigation.pageStepLineCount(
                viewportSize: Double(clip.width) - 20 + 18, lineExtent: layout.columnStep, size: .full)
            probe.key("PageDown")
            #expect(probe.selectedNames == [String(format: "item-%03d.txt", lines * rows)])
            await harness.close()
        }

        // T-3af848da T-5335903c F-777 B-VIEW-069 B-VIEW-070 B-VIEW-072 B-VIEW-073: a press on an item selects it, ⇧ extends,
        // a press past the end of a name is empty space, and a right-click there clears the selection and asks for the
        // background's menu.
        // B-VIEW-204
        @Test func forwardsModifierSelectionAndBackgroundMenus() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, probe) = try await harness.openGrid(.viewAsList)
            var menus: [[String]?] = []
            tab.content.contextMenuProvider = { entries in
                menus.append(entries?.map(\.name))
                return nil
            }
            let items = probe.compactItems
            let alpha = try #require(items["Alpha"])
            let gamma = try #require(items["Gamma"])
            probe.press(at: probe.point(in: alpha.root))
            #expect(probe.selectedNames == ["Alpha"])
            probe.press(at: probe.point(in: gamma.root), modifiers: .shift)
            #expect(probe.selectedNames == ["Alpha", "Beta", "Gamma"])
            // Pressing a selected item narrows the selection to it on the click, not on the press.
            probe.press(at: probe.point(in: alpha.root))
            #expect(probe.selectedNames == ["Alpha"])
            let grid = try #require(probe.grid)
            let past = NSPoint(x: alpha.view.frame.maxX + 20, y: alpha.view.frame.midY)
            _ = probe.pane?.menu(forEventAt: past)
            #expect(probe.selectedNames.isEmpty)
            _ = probe.pane?.menu(forEventAt: NSPoint(x: gamma.view.frame.midX, y: gamma.view.frame.midY))
            #expect(menus == [nil, ["Gamma"]])
            #expect(grid.window?.firstResponder === grid)
            await harness.close()
        }

        // F-777 B-VIEW-005 B-VIEW-031: compact density: rows of 24, columns of 252 and 13 pt names.
        @Test func compactDensityHasShorterRowsAndNarrowerColumns() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, probe) = try await harness.openGrid(.viewAsList, files: 80)
            tab.updatePreferences(["compactListView": .bool(true)])
            tab.refreshColumns()
            probe.layout()
            let compact = try #require(probe.compact)
            #expect(compact.density == .compact)
            let rows = compact.rowsPerColumn
            #expect(
                rows
                    == DesignTokens.flowList(density: .compact).rowsPerColumn(
                        containerHeight: Double(compact.viewport.height)))
            let second = try #require(probe.compactItems[tab.content.entries[rows].name])
            #expect(Double(second.view.frame.minX) == 10 + 270)
            #expect(second.view.frame.height == 24)
            #expect(second.label.font?.pointSize == 13)
            await harness.close()
        }

        // The collection view takes its scroll view's horizontal scroller away under a custom layout: the Compact List
        // keeps it, so its thumb shows when End scrolls sideways (106, 107). F-776 B-VIEW-036
        @Test func keepsItsHorizontalScrollerWhenItOverflows() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, probe) = try await harness.openGrid(.viewAsList, files: 200)
            let compact = try #require(probe.compact)
            #expect(compact.scroll.hasHorizontalScroller)
            #expect(compact.scroll.horizontalScroller?.isHidden == false)
            // An overlay scroller leaves the columns their room.
            #expect(compact.viewport.height == compact.scroll.frame.height)
            compact.scroll.scrollSideways(by: 500)
            #expect(compact.scroll.horizontalScroller?.isHidden == false)
            #expect(compact.scroll.horizontalScroller?.doubleValue ?? 0 > 0)
            withExtendedLifetime(tab) {}
            await harness.close()
        }

        // T-8b04180b B-VIEW-090: a name is edited in its item, which keeps its column's width for the field.
        @Test func editsANameInItsItem() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, probe) = try await harness.openGrid(.viewAsList)
            let note = try #require(tab.content.entries.first { $0.name == "note.txt" })
            tab.content.select(paths: [note.path])
            #expect(tab.content.beginRename(path: note.path))
            probe.layout()
            let compact = try #require(probe.compact)
            let field = try #require(compact.renameField)
            let item = try #require(probe.compactItems["note.txt"])
            #expect(item.view.frame.width == 292)
            let frame = item.view.frame
            #expect(field.frame == NSRect(x: frame.minX + 33, y: frame.minY + 4, width: 292 - 33 - 15, height: 20))
            #expect(field.font?.pointSize == 14)
            tab.content.endRename()
            probe.layout()
            #expect(compact.renameField == nil)
            #expect(item.view.frame.width < 292)
            await harness.close()
        }

        // T-6c281f26 B-VIEW-014: the folder read again with an item more keeps where the list was scrolled.
        // B-SEL-067
        @Test func staysWhereItWasScrolledWhenTheFolderIsReadAgain() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, probe) = try await harness.openGrid(.viewAsList, files: 400)
            let compact = try #require(probe.compact)
            compact.scroll.scrollSideways(by: 500)
            let folder = tab.content.folderPath
            try "y".write(
                to: URL(fileURLWithPath: folder).appendingPathComponent("item-999.txt"), atomically: true,
                encoding: .utf8)
            let entries = try await DirectoryService().snapshot(path: folder, includeHidden: false).entries
            tab.content.show(folder: folder, entries: entries, selecting: nil, keepingScroll: true)
            #expect(tab.content.entries.count == 401)
            #expect(compact.scroll.contentView.bounds.origin.x == 500)
            await harness.close()
        }

        // F-776 B-VIEW-038: an item names itself in its tooltip (`title={entry.name}`).
        @Test func itemsCarryTheirNameAsTooltip() async throws {
            let harness = try ExplorerHarness.windowless()
            let (_, probe) = try await harness.openGrid(.viewAsList)
            let item = try #require(probe.compactItems["note.txt"])
            #expect(item.view.toolTip == "note.txt")
            await harness.close()
        }

        // F-776 B-VIEW-037: a lower pane puts fewer items in a column; the lead's column is kept in view.
        @Test func keepsTheLeadInViewWhenTheHeightChanges() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, probe) = try await harness.openGrid(.viewAsList, files: 400)
            let compact = try #require(probe.compact)
            let layout = DesignTokens.flowList(density: .comfortable)
            let columnsInView = Int((Double(compact.viewport.width) - 20) / layout.columnStep)
            let lead = max(0, columnsInView * compact.rowsPerColumn - 1)
            tab.content.select(paths: [tab.content.entries[lead].path])
            probe.layout()
            #expect(compact.isWhollyInView(index: lead))
            let rows = compact.rowsPerColumn
            let window = try #require(tab.window)
            window.setContentSize(NSSize(width: window.frame.width, height: window.frame.height - 200))
            harness.layout(tab)
            probe.layout()
            #expect(compact.rowsPerColumn < rows)
            #expect(compact.isWhollyInView(index: lead))
            await harness.close()
        }

        // F-776: the Compact List doesn't read the details of the items on screen; only the List shows them.
        @Test func doesNotReadTheDetailsOfTheItemsOnScreen() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, _) = try await harness.openGrid(.viewAsList, files: 20)
            try await Task.sleep(for: .milliseconds(600))
            #expect(tab.content.entries.allSatisfy { tab.content.metadata(for: $0.path) == nil })
            await harness.close()
        }
    }
}
