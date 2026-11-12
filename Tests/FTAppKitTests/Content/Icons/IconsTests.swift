import AppKit
import FTFileSystem
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    @MainActor
    @Suite struct IconsTests {
        // Every item shows
        // its name under its icon, 104 by 114 in the middle of columns that share the pane's width, and the arrow keys
        // step by the columns the grid holds.
        @Test func showsEveryItemWithItsNameUnderItsIconInColumns() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, probe) = try await harness.openGrid(.viewAsIcons)
            let icons = try #require(probe.icons)
            let items = probe.iconItems
            #expect(Set(items.keys) == ["Alpha", "Beta", "Gamma", "note.txt"])
            let width = Double(icons.viewport.width)
            let layout = DesignTokens.iconGrid(density: .standard)
            let columns = layout.columns(containerWidth: width)
            #expect(icons.columns == columns && icons.itemsPerLine == columns)
            let columnWidth = (width - 32) / Double(columns)
            for (index, entry) in tab.content.entries.enumerated() {
                let item = try #require(items[entry.name])
                let frame = item.view.frame
                #expect(frame.size == NSSize(width: 104, height: 114))
                #expect(abs(Double(frame.minX) - (16 + (Double(index) + 0.5) * columnWidth - 52)) < 0.01)
                #expect(frame.minY == 10)
                #expect(item.root.accessibilityLabel() == entry.name)
                #expect(item.label.stringValue == entry.name)
                // Its tooltip, so a name shortened in the middle can be read whole.
                #expect(item.view.toolTip == entry.name)
                #expect(item.tile.frame == NSRect(x: 16, y: 5, width: 72, height: 72))
                #expect(item.iconBox.frame == NSRect(x: 4, y: 4, width: 64, height: 64))
                // A short name is one line of 16 on a 1 pt padding, as wide as its text and its 4 pt padding.
                #expect(item.label.frame.minY == 81 && item.label.frame.height == 18)
                #expect(abs(item.label.frame.midX - 52) < 0.01)
                #expect(item.label.font?.pointSize == 13)
            }
            await harness.close()
        }

        // Finder's sizes keep the icons and the grid, with Finder's 12 point names.
        @Test func findersSizesKeepTheGridAndTakeSmallerNames() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, probe) = try await harness.openGrid(.viewAsIcons)
            let regular = try #require(probe.icons).columns
            tab.updatePreferences { $0.density = .finder }
            tab.refreshColumns()
            probe.layout()
            let icons = try #require(probe.icons)
            #expect(icons.density == .finder)
            #expect(icons.columns == regular)
            let item = try #require(probe.iconItems["Alpha"])
            #expect(item.view.frame.size == NSSize(width: 104, height: 114))
            #expect(item.tile.frame == NSRect(x: 16, y: 5, width: 72, height: 72))
            #expect(item.label.font?.pointSize == 12)
            #expect(item.label.frame.height == 17)
            await harness.close()
        }

        // A selected item's tile is the text colour at 10% and its name is on the accent with
        // white text while the view has the keyboard; in a view without the keyboard the name's pill is grey.
        @Test func marksTheSelectionAndTellsAnUnfocusedOneApart() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, probe) = try await harness.openGrid(.viewAsIcons)
            let beta = try #require(tab.content.entries.first { $0.name == "Beta" })
            tab.content.select(paths: [beta.path])
            let item = try #require(probe.iconItems["Beta"])
            let theme = tab.content.theme
            #expect(item.tile.backdrop == NSColor(theme.palette.textPrimary.withAlpha(0.1)))
            #expect(!item.pill.isHidden)
            tab.window?.makeFirstResponder(nil)
            #expect(item.label.pillColor == NSColor(theme.palette.bgActiveInactive))
            #expect(item.label.textColor == NSColor(theme.palette.textPrimary))
            tab.content.focusList()
            #expect(probe.pane?.hasKeyboard == true)
            let colors = GridSelectionColors.make(
                theme: theme, selected: true, paneFocused: true, windowActive: tab.content.windowIsActive)
            #expect(item.label.pillColor == colors.background.map { NSColor($0) })
            #expect(
                GridSelectionColors.make(theme: theme, selected: true, paneFocused: true, windowActive: true)
                    == GridSelectionColors(
                        background: theme.accent.selectionBg, text: theme.accent.onSelection,
                        softText: theme.accent.onSelectionSoft))
            let alpha = try #require(probe.iconItems["Alpha"])
            #expect(alpha.tile.backdrop == nil && alpha.label.pillColor == nil && alpha.pill.isHidden)
            await harness.close()
        }

        // A press on the tile or the name selects, the space
        // around them is empty space that clears the selection, and a double-click opens.
        @Test func forwardsSelectionGesturesOpeningAndClicksOnTheEmptySpace() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, probe) = try await harness.openGrid(.viewAsIcons)
            var opened: [String] = []
            tab.content.onActivate = { entries, _ in opened += entries.map(\.name) }
            let beta = try #require(probe.iconItems["Beta"])
            probe.press(at: probe.point(in: beta.tile))
            #expect(probe.selectedNames == ["Beta"])
            #expect(probe.pane?.hasKeyboard == true)
            let gamma = try #require(probe.iconItems["Gamma"])
            probe.press(at: probe.point(in: gamma.label), modifiers: .command)
            #expect(probe.selectedNames == ["Beta", "Gamma"])
            // Beside the tile, inside the item: empty space.
            probe.press(at: probe.point(in: gamma.root, at: NSPoint(x: 4, y: 40)))
            #expect(probe.selectedNames.isEmpty)
            probe.press(at: probe.point(in: beta.tile), count: 2)
            #expect(opened == ["Beta"])
            await harness.close()
        }

        // Only the rows near the viewport have items; the content is as tall as
        // every row and the padding.
        @Test func mountsOnlyTheRowsNearTheViewport() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, probe) = try await harness.openGrid(.viewAsIcons, files: 600)
            let icons = try #require(probe.icons)
            let grid = try #require(probe.grid)
            let columns = icons.columns
            let layout = DesignTokens.iconGrid(density: .standard)
            #expect(Double(grid.frame.height) == layout.contentHeight(itemCount: 600, columns: columns))
            let shown = grid.indexPathsForVisibleItems().count
            #expect(shown > 0 && shown < 600)
            #expect(tab.content.entries.count == 600)
            await harness.close()
        }

        // Arrows move an item or a row, the lead is brought into view with the
        // least scroll, and a page moves by the rows that fit.
        @Test func arrowsAndPagesMoveByRowsAndKeepTheLeadInView() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, probe) = try await harness.openGrid(.viewAsIcons, files: 300)
            let icons = try #require(probe.icons)
            tab.content.focusList()
            let columns = icons.columns
            probe.key("ArrowDown")
            #expect(probe.selectedNames == ["item-000.txt"])
            probe.key("ArrowRight")
            probe.key("ArrowDown")
            #expect(probe.selectedNames == [String(format: "item-%03d.txt", 1 + columns)])
            probe.key("End")
            #expect(probe.selectedNames == ["item-299.txt"])
            let layout = DesignTokens.iconGrid(density: .standard)
            let clip = icons.scroll.contentView.bounds
            let lastRow = 299 / columns
            let bottom = layout.paddingTop + Double(lastRow + 1) * layout.rowHeight + layout.paddingBottom
            #expect(abs(Double(clip.maxY) - bottom) <= 1)
            probe.key("Home")
            #expect(probe.selectedNames == ["item-000.txt"])
            #expect(icons.scroll.contentView.bounds.origin.y == 0)
            let lines = SelectionNavigation.pageStepLineCount(
                viewportSize: Double(clip.height), lineExtent: layout.rowHeight, size: .full)
            probe.key("PageDown")
            #expect(probe.selectedNames == [String(format: "item-%03d.txt", lines * columns)])
            await harness.close()
        }

        // A name is edited in place under its icon, in a field as wide as the
        // label, centred, 20 tall; the item is drawn selected without the keyboard meanwhile.
        @Test func editsANameInPlaceUnderItsIcon() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, probe) = try await harness.openGrid(.viewAsIcons)
            let note = try #require(tab.content.entries.first { $0.name == "note.txt" })
            tab.content.select(paths: [note.path])
            #expect(tab.content.beginRename(path: note.path))
            let icons = try #require(probe.icons)
            let field = try #require(icons.renameField)
            let item = try #require(probe.iconItems["note.txt"])
            let itemFrame = item.view.frame
            #expect(field.frame == NSRect(x: itemFrame.minX + 1, y: itemFrame.minY + 81, width: 102, height: 20))
            #expect(field.alignment == .center)
            #expect(field.font?.pointSize == 13)
            #expect(item.label.isHidden && !item.tile.isHidden)
            #expect(item.label.pillColor == NSColor(tab.content.theme.palette.bgActiveInactive))
            tab.content.endRename()
            #expect(icons.renameField == nil && !item.label.isHidden)
            await harness.close()
        }

        // The empty folder's message is drawn in place of the items.
        @Test func drawsTheEmptyMessageInPlaceOfItems() async throws {
            let harness = try ExplorerHarness.windowless()
            let empty = harness.folder.appending("Empty")
            try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
            let tab = try await harness.open(empty.path)
            tab.perform(.viewAsIcons)
            #expect(await waitUntil { tab.content.container(for: .empty(text: "Empty folder")) })
            #expect(GridProbe(tab: tab).grid?.numberOfItems(inSection: 0) == 0)
            await harness.close()
        }

        // A name too long for two lines keeps its first line and is shortened in the middle,
        // keeping the end of the stem and the extension.
        @Test func longNamesAreShortenedInTheMiddle() {
            let name = "Panorama of the Miradouro da Senhora do Monte at sunset.jpeg"
            let fitted = IconLabelText.fit(
                name: name, extension: "jpeg", layout: DesignTokens.iconGrid(density: .standard))
            #expect(fitted != name)
            #expect(fitted.contains(IconLabel.ellipsis))
            #expect(fitted.hasSuffix("unset.jpeg"))
            #expect(IconLabelText.lines(fitted, layout: DesignTokens.iconGrid(density: .standard)).count == 2)
            #expect(
                IconLabelText.fit(name: "note.txt", extension: "txt", layout: DesignTokens.iconGrid(density: .standard))
                    == "note.txt")
        }

        // An item on the clipboard gets an 18 pt badge on the corner of its tile, 4 pt out.
        @Test func anItemOnTheClipboardGetsABadge() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, probe) = try await harness.openGrid(.viewAsIcons)
            let note = try #require(tab.content.entries.first { $0.name == "note.txt" })
            tab.content.clipboardMarksChanged(
                ClipboardMarks(ClipboardRules.set(.cut, [note.path], capturedAt: "t"), enabled: true), flash: false)
            let item = try #require(probe.iconItems["note.txt"])
            #expect(!item.badge.isHidden && item.badge.mark == .cut)
            #expect(item.badge.frame == NSRect(x: 88 + 4 - 18, y: 5 - 4, width: 18, height: 18))
            #expect(probe.iconItems["Alpha"]?.badge.isHidden == true)
            tab.content.clipboardMarksChanged(nil, flash: false)
            #expect(item.badge.isHidden)
            await harness.close()
        }

        // When the Info panel opens the items go to their new columns at once and each
        // glides from where it was; a resize for another reason moves them without the glide.
        @Test func itemsGlideToTheirNewPlacesWhenTheInfoPanelOpens() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, probe) = try await harness.openGrid(.viewAsIcons, files: 40)
            let icons = try #require(probe.icons)
            let before = icons.columns
            tab.perform(.toggleInfoPanel)
            probe.layout()
            #expect(icons.columns < before)
            let moved = probe.iconItems.values.filter {
                $0.view.layer?.animation(forKey: IconViewController.glideKey) != nil
            }
            // The panel slides unless Reduce Motion is on; the items glide with it.
            #expect(moved.isEmpty == NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
            for item in probe.iconItems.values { item.view.layer?.removeAllAnimations() }
            // A narrower window moves them without a glide.
            let columns = icons.columns
            #expect(await waitUntil { tab.workspace.slide == nil })
            if let window = tab.window {
                window.setContentSize(NSSize(width: window.frame.width - 300, height: window.frame.height))
            }
            harness.layout(tab)
            probe.layout()
            #expect(icons.columns < columns)
            #expect(
                probe.iconItems.values.allSatisfy {
                    $0.view.layer?.animation(forKey: IconViewController.glideKey) == nil
                })
            await harness.close()
        }

        // A change of the layout (a narrower pane, a lower one, the density) keeps the lead in view,
        // unless the grid was scrolled since.
        @Test func keepsTheLeadInViewWhenTheLayoutChangesUnlessScrolledSince() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, probe) = try await harness.openGrid(.viewAsIcons, files: 400)
            let icons = try #require(probe.icons)
            let rows = Int((Double(icons.viewport.height) - 10) / 116)
            let lead = max(0, rows * icons.columns - 1)
            tab.content.select(paths: [tab.content.entries[lead].path])
            probe.layout()
            #expect(icons.isWhollyInView(index: lead))
            let before = icons.columns
            let window = try #require(tab.window)
            window.setContentSize(NSSize(width: window.frame.width - 300, height: window.frame.height))
            harness.layout(tab)
            probe.layout()
            #expect(icons.columns < before)
            #expect(icons.isWhollyInView(index: lead))
            window.setContentSize(NSSize(width: window.frame.width, height: window.frame.height - 200))
            harness.layout(tab)
            probe.layout()
            #expect(icons.isWhollyInView(index: lead))
            tab.updatePreferences { $0.density = .finder }
            tab.refreshColumns()
            probe.layout()
            #expect(icons.isWhollyInView(index: lead))
            // Scrolled away since: the grid stays where it was scrolled.
            icons.scrollPosition = (0, 0)
            #expect(!icons.isWhollyInView(index: lead))
            window.setContentSize(NSSize(width: window.frame.width + 100, height: window.frame.height))
            harness.layout(tab)
            probe.layout()
            #expect(icons.scroll.contentView.bounds.origin.y == 0)
            await harness.close()
        }

        // The Icons view doesn't read the details of the items on screen; only the List shows them.
        @Test func doesNotReadTheDetailsOfTheItemsOnScreen() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, _) = try await harness.openGrid(.viewAsIcons, files: 20)
            await settle()
            #expect(!tab.content.isReadingDetails)
            #expect(tab.content.entries.allSatisfy { tab.content.metadata(for: $0.path) == nil })
            await harness.close()
        }

        // The status bar's slider sets the icon size in steps of 8: the grid follows it as it moves, and the size is
        // saved once the slider is let go. The slider shows the icon size in the Icons view.
        @Test func theSliderSetsTheIconSize() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, probe) = try await harness.openGrid(.viewAsIcons)
            let bar = tab.content.contentShell.pathBarRow
            let slider = bar.sizeSlider
            #expect(bar.showsSizeSlider && !slider.isHidden)
            #expect(slider.minValue == 32 && slider.maxValue == 128 && slider.doubleValue == 64)
            #expect(slider.toolTip == "Icon Size")
            #expect(bar.sizeLabel.stringValue == "64 pt" && bar.sizeLabel.isHidden)
            tab.content.iconSizeChanged(125, save: false)
            #expect(bar.sizeLabel.stringValue == "128 pt")
            probe.layout()
            let icons = try #require(probe.icons)
            #expect(icons.layout.iconSize == 128)
            #expect(tab.preferences.iconSizes.standard == 64)
            let item = try #require(probe.iconItems["Alpha"])
            #expect(item.view.frame.size == NSSize(width: 168, height: 178))
            #expect(item.tile.frame == NSRect(x: 16, y: 5, width: 136, height: 136))
            #expect(item.iconBox.frame == NSRect(x: 4, y: 4, width: 128, height: 128))
            // Let go: the slider's own action, outside a drag, saves the size.
            slider.doubleValue = 41
            _ = slider.sendAction(slider.action, to: slider.target)
            probe.layout()
            #expect(icons.layout.iconSize == 40)
            #expect(slider.doubleValue == 40)
            // The size shows in place of the status text while the slider moves, and goes once it is still.
            #expect(bar.sizeLabel.stringValue == "40 pt" && !bar.sizeLabel.isHidden)
            #expect(bar.status.alphaValue == 0)
            #expect(await waitUntil(timeout: .seconds(5)) { bar.sizeLabel.isHidden })
            #expect(bar.status.alphaValue == 1)
            #expect(tab.preferences.iconSizes == DensitySizes(standard: 40, finder: 64))
            // The Compact List's slider is the column width; the List has none.
            tab.perform(.viewAsList)
            #expect(slider.toolTip == "Column Width" && slider.doubleValue == 292)
            #expect(bar.sizeLabel.stringValue == "292 pt")
            tab.perform(.viewAsDetails)
            #expect(!bar.showsSizeSlider && slider.isHidden && bar.sizeLabel.isHidden)
            await harness.close()
        }

        // View ▸ Make Icons Bigger, Make Icons Smaller and Default Icon Size step the icon size by 8 and save it; the
        // slider follows, and the size shows over the status text as it does while the slider moves.
        @Test func theSizeCommandsStepTheIconSize() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, probe) = try await harness.openGrid(.viewAsIcons)
            let bar = tab.content.contentShell.pathBarRow
            let icons = try #require(probe.icons)
            #expect(tab.menuState.disabledCommands.filter { ViewSize.Change($0) != nil } == [.resetSize])
            tab.perform(.increaseSize)
            probe.layout()
            #expect(icons.layout.iconSize == 72 && bar.sizeSlider.doubleValue == 72)
            #expect(tab.preferences.iconSizes == DensitySizes(standard: 72, finder: 64))
            #expect(bar.sizeLabel.stringValue == "72 pt" && !bar.sizeLabel.isHidden && bar.status.alphaValue == 0)
            for _ in 0..<5 { tab.perform(.decreaseSize) }
            #expect(tab.preferences.iconSizes.standard == 32 && bar.sizeLabel.stringValue == "32 pt")
            #expect(tab.menuState.disabledCommands.contains(.decreaseSize))
            #expect(!tab.menuState.disabledCommands.contains(.increaseSize))
            // At its end the size still shows, and stays.
            tab.perform(.decreaseSize)
            #expect(tab.preferences.iconSizes.standard == 32 && !bar.sizeLabel.isHidden)
            tab.perform(.resetSize)
            probe.layout()
            #expect(icons.layout.iconSize == 64 && bar.sizeSlider.doubleValue == 64)
            #expect(tab.preferences.iconSizes.standard == 64 && bar.sizeLabel.stringValue == "64 pt")
            #expect(await waitUntil(timeout: .seconds(5)) { bar.sizeLabel.isHidden })
            // The List has no size: the commands are dimmed and do nothing.
            tab.perform(.viewAsDetails)
            #expect(Set(tab.menuState.disabledCommands).isSuperset(of: [.increaseSize, .decreaseSize, .resetSize]))
            tab.perform(.increaseSize)
            #expect(tab.preferences.iconSizes.standard == 64 && bar.sizeLabel.isHidden)
            await harness.close()
        }
    }
}
