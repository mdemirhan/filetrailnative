import AppKit
import FTFileSystem
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    @MainActor
    @Suite struct CompactListTests {
        // Items fill a column top to bottom, then the next;
        // each is as wide as its icon and name, its highlight hugging them, inside 8 of padding at the top, 10 at the
        // sides and 4 at the bottom.
        @Test func itemsFillAColumnThenTheNextAndHugTheirNames() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, probe) = try await harness.openGrid(.viewAsList, files: 120)
            let compact = try #require(probe.compact)
            let layout = DesignTokens.flowList(density: .standard)
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
                let entry = tab.content.entries[index]
                let nameWidth = SplitName.width(name, extension: entry.fileExtension, marks: [], font: compact.nameFont)
                #expect(abs(item.view.frame.width - min(292, nameWidth + 50)) < 0.01)
                #expect(item.iconView.frame == NSRect(x: 12, y: 5, width: 18, height: 18))
                #expect(item.label.frame.minX == 38)
                #expect(item.label.font?.pointSize == 14)
            }
            let columns = (120 + rows - 1) / rows
            #expect(Double(probe.grid?.frame.width ?? 0) == 20 + Double(columns) * 292 + Double(columns - 1) * 18)
            await harness.close()
        }

        // A tagged item grows by its dots, so its name keeps all its room, and shrinks back when they go.
        @Test func anItemIsWiderByItsTagDotsAndItsNameKeepsItsRoom() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, probe) = try await harness.openGrid(.viewAsList, files: 4)
            let compact = try #require(probe.compact)
            let entry = tab.content.entries[1]
            defer { try? FinderTags.write([], to: entry.path) }
            // The name as its label draws it: the stem and the extension, each in whole points.
            let nameWidth = SplitName.width(
                entry.name, extension: entry.fileExtension, marks: [], font: compact.nameFont)
            let plainWidth = nameWidth + 50

            try FinderTags.write(
                [
                    FinderTag(name: "Red", color: .red), FinderTag(name: "Blue", color: .blue),
                    FinderTag(name: "Green", color: .green), FinderTag(name: "Gray", color: .gray),
                ], to: entry.path)
            tab.content.tagsChanged([entry.path])
            // Three of the four dots show: 10 wide, each next one 4 further, 5 after the name.
            let dots = TagDotsView.gap + TagDotsView.diameter + 2 * TagDotsView.step
            let width = { probe.compactItems[entry.name]?.view.frame.width ?? 0 }
            #expect(await waitUntil { abs(width() - plainWidth - dots) < 0.01 })
            let item = try #require(probe.compactItems[entry.name])
            #expect(!item.tagDots.isHidden)
            #expect(item.tagDots.dotsWidth == dots - TagDotsView.gap)
            #expect(abs(item.label.frame.width - nameWidth) < 0.01)
            #expect(abs(item.tagDots.frame.minX - (item.label.frame.maxX + TagDotsView.gap)) < 0.01)
            #expect(abs(item.tagDots.frame.maxX - (item.view.bounds.width - 12)) < 0.01)

            try FinderTags.write([], to: entry.path)
            tab.content.tagsChanged([entry.path])
            #expect(await waitUntil { abs(width() - plainWidth) < 0.01 })
            await harness.close()
        }

        // The wheel's up and down scroll the list sideways; a mostly sideways gesture is
        // left to the scroll view.
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

        // ←/→ move by a column and ↑/↓ by an item, and the lead's
        // column is kept in view sideways; a page moves by the columns that fit.
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
            let layout = DesignTokens.flowList(density: .standard)
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

        // A press on an item selects it, ⇧ extends,
        // a press past the end of a name is empty space, and a right-click there clears the selection and asks for the
        // background's menu.
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
            // An item names itself in its tooltip.
            #expect(alpha.view.toolTip == "Alpha")
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

        // Finder's sizes: rows of 24, columns of 252 and 13 pt names.
        @Test func findersSizesHaveShorterRowsAndNarrowerColumns() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, probe) = try await harness.openGrid(.viewAsList, files: 80)
            tab.updatePreferences { $0.density = .finder }
            tab.refreshColumns()
            probe.layout()
            let compact = try #require(probe.compact)
            #expect(compact.density == .finder)
            let rows = compact.rowsPerColumn
            #expect(
                rows
                    == DesignTokens.flowList(density: .finder).rowsPerColumn(
                        containerHeight: Double(compact.viewport.height)))
            let second = try #require(probe.compactItems[tab.content.entries[rows].name])
            #expect(Double(second.view.frame.minX) == 10 + 270)
            #expect(second.view.frame.height == 24)
            #expect(second.label.font?.pointSize == 13)
            await harness.close()
        }

        // The collection view takes its scroll view's horizontal scroller away under a custom layout: the Compact List
        // keeps it, so its thumb shows when End scrolls sideways.
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

        // A name is edited in its item, which keeps its column's width for the field.
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

        // A lower pane puts fewer items in a column; the lead's column is kept in view.
        @Test func keepsTheLeadInViewWhenTheHeightChanges() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, probe) = try await harness.openGrid(.viewAsList, files: 400)
            let compact = try #require(probe.compact)
            let layout = DesignTokens.flowList(density: .standard)
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

        // The Compact List doesn't read the details of the items on screen; only the List shows them.
        @Test func doesNotReadTheDetailsOfTheItemsOnScreen() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, _) = try await harness.openGrid(.viewAsList, files: 20)
            await settle()
            #expect(!tab.content.isReadingDetails)
            #expect(tab.content.entries.allSatisfy { tab.content.metadata(for: $0.path) == nil })
            await harness.close()
        }

        // The status bar's slider is the column width in the Compact List, at the width saved for the density on
        // screen; the List has none.
        @Test func theColumnWidthSliderShowsInTheCompactListOnly() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, probe) = try await harness.openGrid(.viewAsList, files: 12)
            let bar = tab.content.contentShell.pathBarRow
            #expect(bar.showsSizeSlider && !bar.sizeSlider.isHidden)
            #expect(bar.sizeSlider.doubleValue == 292)
            #expect(bar.sizeSlider.minValue == 160 && bar.sizeSlider.maxValue == 600)
            probe.layout()
            bar.layoutSubtreeIfNeeded()
            #expect(bar.sizeSlider.frame.maxX == bar.bounds.width - 10)
            #expect(bar.sizeLabel.frame.maxX + 6 == bar.sizeSlider.frame.minX && bar.sizeLabel.isHidden)
            #expect(bar.status.frame.maxX <= bar.sizeSlider.frame.minX)
            tab.perform(.viewAsIcons)
            #expect(bar.showsSizeSlider && bar.sizeSlider.toolTip == "Icon Size (⌘+ bigger, ⌘- smaller, ⌘0 default)")
            tab.perform(.viewAsDetails)
            #expect(bar.sizeSlider.isHidden)
            tab.perform(.viewAsList)
            #expect(!bar.sizeSlider.isHidden)
            // The tooltip names the keys of the size commands, as chosen in Settings.
            #expect(bar.sizeSlider.toolTip == "Column Width (⌘+ wider, ⌘- narrower, ⌘0 default)")
            tab.updatePreferences { $0.shortcutOverrides = ["increaseSize": ["Ctrl+Cmd+="], "resetSize": []] }
            #expect(await waitUntil { bar.sizeSlider.toolTip == "Column Width (⌃⌘= wider, ⌘- narrower)" })
            await harness.close()
        }

        // View ▸ Make Columns Wider and Narrower go to the next whole 40 points, Default Column Width back to the
        // density's width, and save it. The width shows over the status text, as it does while the slider moves. ⌘=,
        // Make Bigger's other key, reaches it from the list.
        @Test func theSizeCommandsStepTheColumnWidthAndShowIt() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, probe) = try await harness.openGrid(.viewAsList, files: 12)
            let compact = try #require(probe.compact)
            let bar = tab.content.contentShell.pathBarRow
            #expect(bar.sizeLabel.isHidden)
            tab.perform(.increaseSize)
            probe.layout()
            #expect(compact.layout.itemWidth == 320 && bar.sizeSlider.doubleValue == 320)
            #expect(tab.preferences.compactListWidths == DensitySizes(standard: 320, finder: 252))
            #expect(bar.sizeLabel.stringValue == "320 pt" && !bar.sizeLabel.isHidden && bar.status.alphaValue == 0)
            tab.perform(.decreaseSize)
            tab.perform(.decreaseSize)
            #expect(tab.preferences.compactListWidths.standard == 240 && bar.sizeLabel.stringValue == "240 pt")
            tab.perform(.resetSize)
            probe.layout()
            #expect(compact.layout.itemWidth == 292 && tab.preferences.compactListWidths.standard == 292)
            #expect(tab.menuState.disabledCommands.contains(.resetSize))
            #expect(await waitUntil(timeout: .seconds(5)) { bar.sizeLabel.isHidden })
            // ⌘= in the list.
            let window = try #require(tab.window)
            tab.content.focusList()
            window.firstResponder?.keyDown(with: try systemKeyEvent(24, [.maskCommand]))
            #expect(tab.preferences.compactListWidths.standard == 320 && !bar.sizeLabel.isHidden)
            // ⌘- and ⌘0 work from the list as well; in the app the menu takes them first.
            window.firstResponder?.keyDown(with: try systemKeyEvent(27, [.maskCommand]))
            #expect(tab.preferences.compactListWidths.standard == 280)
            window.firstResponder?.keyDown(with: try systemKeyEvent(29, [.maskCommand]))
            #expect(tab.preferences.compactListWidths.standard == 292)
            await harness.close()
        }

        // Moving the slider resizes every column as it goes; the column at the left of the view keeps its left edge.
        // The width is saved once the slider is let go, for the density on screen.
        @Test func theSliderResizesTheColumnsAndSavesTheWidthWhenLetGo() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, probe) = try await harness.openGrid(.viewAsList, files: 120)
            let compact = try #require(probe.compact)
            let clip = compact.scroll.contentView
            let rows = compact.rowsPerColumn
            clip.scroll(to: NSPoint(x: 10 + 2 * 310 + 40, y: 0))
            compact.scroll.reflectScrolledClipView(clip)
            let leftEdge = { (width: Double) in 10 + 2 * (width + 18) - Double(clip.bounds.minX) }
            let before = leftEdge(292)
            tab.content.compactListWidthChanged(352, save: false)
            probe.layout()
            #expect(compact.layout.itemWidth == 352)
            #expect(leftEdge(352) == before)
            #expect(tab.preferences.compactListWidths.standard == 292)
            let third = try #require(probe.compactItems[tab.content.entries[2 * rows].name])
            #expect(Double(third.view.frame.minX) == 10 + 2 * 370)
            let columns = (120 + rows - 1) / rows
            #expect(Double(probe.grid?.frame.width ?? 0) == 20 + Double(columns) * 352 + Double(columns - 1) * 18)
            // Let go: the slider's own action, outside a drag, saves.
            let slider = tab.content.contentShell.pathBarRow.sizeSlider
            slider.doubleValue = 9000
            _ = slider.sendAction(slider.action, to: slider.target)
            #expect(compact.layout.itemWidth == 600)
            #expect(tab.preferences.compactListWidths == DensitySizes(standard: 600, finder: 252))
            // The width shows over the status text while the slider moves, as the icon size does in the Icons view.
            let bar = tab.content.contentShell.pathBarRow
            #expect(bar.sizeLabel.stringValue == "600 pt" && !bar.sizeLabel.isHidden && bar.status.alphaValue == 0)
            await harness.close()
        }
    }
}
