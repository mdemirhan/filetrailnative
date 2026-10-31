// Covers the Icon view in an explorer window that is never shown, by feature row (IconGridView.test.tsx and the Icons
// cases of ContentPane.test.tsx)
import AppKit
import FTFileSystem
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    @MainActor
    @Suite struct IconsTests {
        // T-6e87c0bd T-f96a5af5 F-757 F-758 F-759 B-VIEW-017 B-VIEW-018 B-VIEW-019 B-VIEW-020 B-VIEW-029: every item shows
        // its name under its icon, 104 by 114 in the middle of columns that share the pane's width, and the arrow keys
        // step by the columns the grid holds.
        @Test func showsEveryItemWithItsNameUnderItsIconInColumns() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, probe) = try await harness.openGrid(.viewAsIcons)
            let icons = try #require(probe.icons)
            let items = probe.iconItems
            #expect(Set(items.keys) == ["Alpha", "Beta", "Gamma", "note.txt"])
            let width = Double(icons.viewport.width)
            let layout = DesignTokens.iconGrid(density: .comfortable)
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
                #expect(item.tile.frame == NSRect(x: 16, y: 5, width: 72, height: 72))
                #expect(item.iconBox.frame == NSRect(x: 4, y: 4, width: 64, height: 64))
                // A short name is one line of 16 on a 1 pt padding, as wide as its text and its 4 pt padding.
                #expect(item.label.frame.minY == 81 && item.label.frame.height == 18)
                #expect(abs(item.label.frame.midX - 52) < 0.01)
                #expect(item.label.font?.pointSize == 13)
            }
            await harness.close()
        }

        // T-81c02106 F-757 F-759 B-VIEW-005 B-VIEW-017: compact icons are smaller and more of them fit.
        @Test func fitsMoreColumnsWhenCompact() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, probe) = try await harness.openGrid(.viewAsIcons)
            let regular = try #require(probe.icons).columns
            tab.updatePreferences(["compactIconView": .bool(true)])
            tab.refreshColumns()
            probe.layout()
            let icons = try #require(probe.icons)
            #expect(icons.density == .compact)
            #expect(icons.columns > regular)
            let item = try #require(probe.iconItems["Alpha"])
            #expect(item.view.frame.size == NSSize(width: 88, height: 92))
            #expect(item.tile.frame == NSRect(x: 16, y: 3, width: 56, height: 56))
            #expect(item.label.font?.pointSize == 12)
            #expect(item.label.frame.height == 17)
            await harness.close()
        }

        // T-0c8c4dbd F-761 B-VIEW-008: a selected item's tile is the text colour at 10% and its name is on the accent with
        // white text while the view has the keyboard; in a view without the keyboard the name's pill is grey.
        // B-SEL-020
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

        // T-604b6bb1 F-760 B-VIEW-025 B-VIEW-069 B-VIEW-071 B-VIEW-073: a press on the tile or the name selects, the space
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

        // T-abb88964 F-758 B-VIEW-010 B-VIEW-019: only the rows near the viewport have items; the content is as tall as
        // every row and the padding.
        // B-VIEW-001
        @Test func mountsOnlyTheRowsNearTheViewport() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, probe) = try await harness.openGrid(.viewAsIcons, files: 600)
            let icons = try #require(probe.icons)
            let grid = try #require(probe.grid)
            let columns = icons.columns
            let layout = DesignTokens.iconGrid(density: .comfortable)
            #expect(Double(grid.frame.height) == layout.contentHeight(itemCount: 600, columns: columns))
            let shown = grid.indexPathsForVisibleItems().count
            #expect(shown > 0 && shown < 600)
            #expect(tab.content.entries.count == 600)
            await harness.close()
        }

        // B-VIEW-028 B-VIEW-030 B-VIEW-087 B-VIEW-089: arrows move an item or a row, the lead is brought into view with the
        // least scroll, and a page moves by the rows that fit.
        // B-NAV-144 B-NAV-147 B-NAV-148 B-NAV-155 B-NAV-165 B-SEL-046 B-SEL-050 B-SEL-062 T-2df6b189
        // T-39bda507
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
            let layout = DesignTokens.iconGrid(density: .comfortable)
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

        // T-5b2c54f7 T-8b04180b F-759 B-VIEW-090: a name is edited in place under its icon, in a field as wide as the
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

        // T-d2171882 F-778 B-VIEW-027: the empty folder's message is drawn in place of the items.
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

        // B-VIEW-021 B-VIEW-022: a name too long for two lines keeps its first line and is shortened in the middle,
        // keeping the end of the stem and the extension.
        @Test func longNamesAreShortenedInTheMiddle() {
            let name = "Panorama of the Miradouro da Senhora do Monte at sunset.jpeg"
            let fitted = IconLabelText.fit(name: name, extension: "jpeg", density: .comfortable)
            #expect(fitted != name)
            #expect(fitted.contains(IconLabel.ellipsis))
            #expect(fitted.hasSuffix("unset.jpeg"))
            #expect(IconLabelText.lines(fitted, density: .comfortable).count == 2)
            #expect(IconLabelText.fit(name: "note.txt", extension: "txt", density: .comfortable) == "note.txt")
        }

        // B-VIEW-024: an item on the clipboard gets an 18 pt badge on the corner of its tile, 4 pt out.
        // B-VIEW-076 T-dc1fd0e6
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

        // T-b690c3e9 T-e76bca54 B-VIEW-026: when the Info panel opens the items go to their new columns at once and each
        // glides from where it was; a resize for another reason moves them without the glide.
        // B-INFO-186 B-VIEW-104
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

        // T-6e87c0bd B-VIEW-020: an item names itself in its tooltip, so a name shortened in the middle can be read
        // whole (`title={entry.name}`).
        @Test func itemsCarryTheirNameAsTooltip() async throws {
            let harness = try ExplorerHarness.windowless()
            let (_, probe) = try await harness.openGrid(.viewAsIcons)
            let item = try #require(probe.iconItems["note.txt"])
            #expect(item.view.toolTip == "note.txt")
            await harness.close()
        }

        // F-758 B-VIEW-028: a change of the layout (a narrower pane, a lower one, the density) keeps the lead in view,
        // unless the grid was scrolled since (useRevealIndex's keepInView).
        // B-NAV-051 B-SEL-065
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
            tab.updatePreferences(["compactIconView": .bool(true)])
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

        // F-757: the Icons view doesn't read the details of the items on screen; only the List shows them.
        // B-VIEW-012
        @Test func doesNotReadTheDetailsOfTheItemsOnScreen() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, _) = try await harness.openGrid(.viewAsIcons, files: 20)
            try await Task.sleep(for: .milliseconds(600))
            #expect(tab.content.entries.allSatisfy { tab.content.metadata(for: $0.path) == nil })
            await harness.close()
        }
    }
}
