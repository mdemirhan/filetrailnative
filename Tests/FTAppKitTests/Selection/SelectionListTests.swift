import AppKit
import FTFileSystem
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    @MainActor
    @Suite struct SelectionListTests {
        /// The views with this identifier in the tab's window.
        func shown(_ id: String, _ tab: MainWindowController) -> [NSView] {
            identified(id, in: tab.window?.contentView)
        }

        /// Types a name into the rename field, as a person's typing leaves it.
        func enter(_ text: String, in field: InlineRenameField) {
            guard let editor = field.currentEditor() as? NSTextView else {
                Issue.record("the rename field has no editor")
                return
            }
            editor.string = text
            editor.didChangeText()
        }

        // The pointer selects, extends and flips; a plain
        // click on one of several narrows on the click, not on the press.
        @Test func clicksSelectExtendAndToggle() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, list) = try await harness.openList()
            #expect(list.rowNames == ["Alpha", "Beta", "Gamma", "note.txt"])
            #expect(tab.content.selection.isEmpty)
            await list.click(name: "Beta")
            #expect(list.selectedNames == ["Beta"])
            #expect(list.hasKeyboard)
            // ⇧ makes the range from the anchor, in the order shown; clicking back past the anchor reverses it.
            await list.click(name: "note.txt", modifiers: .shift)
            #expect(list.selectedNames == ["Beta", "Gamma", "note.txt"])
            #expect(tab.content.selection.anchorPath?.hasSuffix("Beta") == true)
            await list.click(name: "Alpha", modifiers: .shift)
            #expect(list.selectedNames == ["Alpha", "Beta"])
            // ⌘ flips one item and keeps the order.
            await list.click(name: "note.txt", modifiers: .command)
            #expect(list.selectedNames == ["Alpha", "Beta", "note.txt"])
            await list.click(name: "Beta", modifiers: .command)
            #expect(list.selectedNames == ["Alpha", "note.txt"])
            // ⌘⇧ adds the range from the anchor (the last item flipped in).
            await list.click(name: "Gamma", modifiers: [.command, .shift])
            #expect(list.selectedNames == ["Alpha", "Gamma", "note.txt"])
            // A plain click on one of several narrows to it.
            await list.click(name: "Gamma")
            #expect(list.selectedNames == ["Gamma"])
            await harness.close()
        }

        // Pressing a selected item changes nothing until the click completes, so a drag can
        // still carry the whole selection.
        @Test func pressingASelectedItemKeepsTheSelectionUntilTheClick() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, list) = try await harness.openList()
            tab.content.select(paths: tab.content.entries.prefix(3).map(\.path))
            #expect(list.selectedNames.count == 3)
            // The press alone changes nothing; a drag from it carries the whole selection.
            var narrowedOnPress = true
            var carried: [String] = []
            tab.content.dragHooks.beginDrag = { entries, _, _ in
                carried = entries.map(\.name)
                narrowedOnPress = false
                return true
            }
            let start = list.center(ofRow: 1)
            list.press(at: start, moves: [NSPoint(x: start.x + 40, y: start.y)])
            #expect(!narrowedOnPress)
            #expect(carried == ["Alpha", "Beta", "Gamma"])
            #expect(list.selectedNames == ["Alpha", "Beta", "Gamma"])
            await harness.close()
        }

        // ⌘A selects everything, a press on empty space clears.
        @Test func selectAllAndEmptySpace() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, list) = try await harness.openList()
            list.window.makeFirstResponder(list.table)
            // Edit › Select All, as the menu sends it (the test process need not be the active app).
            tab.perform(.editSelectAll)
            #expect(list.selectedNames == ["Alpha", "Beta", "Gamma", "note.txt"])
            #expect(tab.content.selection.anchorPath?.hasSuffix("Alpha") == true)
            #expect(tab.content.selection.leadPath?.hasSuffix("note.txt") == true)
            // A press on empty space with ⇧ or ⌘ keeps the selection; a plain one clears it.
            await list.click(at: list.emptyPoint(belowRows: 4), modifiers: .shift)
            #expect(list.selectedNames.count == 4)
            await list.click(at: list.emptyPoint(belowRows: 4), modifiers: [])
            #expect(list.selectedNames.isEmpty)
            await harness.close()
        }

        // A right-click on one of the selection keeps it, on another item selects it
        // alone, and on empty space clears the selection.
        @Test func aRightClickKeepsOrReplacesTheSelection() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, list) = try await harness.openList()
            await list.click(name: "Alpha")
            await list.click(name: "Gamma", modifiers: .shift)
            func rightClick(_ point: NSPoint) {
                guard let event = MouseEvents.event(.rightMouseDown, at: point, in: list.window) else { return }
                _ = list.table?.menu(for: event)
            }
            rightClick(list.center(ofRow: 1))
            #expect(list.selectedNames == ["Alpha", "Beta", "Gamma"])
            rightClick(list.center(ofRow: 3))
            #expect(list.selectedNames == ["note.txt"])
            rightClick(list.emptyPoint(belowRows: 4))
            #expect(tab.content.selection.isEmpty)
            await harness.close()
        }

        // A drag from
        // empty space draws a box and selects the rows it touches; the lead is the touched row nearest the pointer;
        // barely moving only clears; ⇧ adds and ⌘ flips.
        @Test func theMarqueeSelectsTheRowsItTouches() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, list) = try await harness.openList()
            let start = list.emptyPoint(belowRows: 4)
            let end = list.center(ofRow: 1)
            await list.drag(from: start, to: end, modifiers: [])
            #expect(list.selectedNames == ["Beta", "Gamma", "note.txt"])
            #expect(tab.content.selection.leadPath?.hasSuffix("Beta") == true)
            #expect(tab.content.selection.anchorPath == tab.content.selection.leadPath)
            // The box is gone when the button is up.
            #expect(identified("marquee", in: list.table as NSView?).isEmpty)
            // A drag of a few points selects nothing and clears.
            await list.drag(from: start, to: NSPoint(x: start.x + 2, y: start.y), modifiers: [])
            #expect(list.selectedNames.isEmpty)
            // ⇧ adds what the box touches to the selection the drag started with.
            await list.click(name: "Alpha")
            await list.drag(from: start, to: list.center(ofRow: 2), modifiers: .shift)
            #expect(list.selectedNames == ["Alpha", "Gamma", "note.txt"])
            // ⌘ flips: Gamma and note.txt go out, Beta comes in.
            await list.drag(from: start, to: list.center(ofRow: 1), modifiers: .command)
            #expect(list.selectedNames == ["Alpha", "Beta"])
            await harness.close()
        }

        // The arrow keys move the lead and
        // select what they land on; ⇧ stretches; Home and End go to the ends; with nothing selected the first item.
        @Test func arrowKeysMoveTheSelection() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, list) = try await harness.openList()
            list.window.makeFirstResponder(list.table)
            list.key("ArrowDown")
            #expect(list.selectedNames == ["Alpha"])
            list.key("ArrowDown")
            list.key("ArrowDown")
            #expect(list.selectedNames == ["Gamma"])
            list.key("ArrowDown", modifiers: .shift)
            #expect(list.selectedNames == ["Gamma", "note.txt"])
            list.key("ArrowDown")
            #expect(list.selectedNames == ["note.txt"])
            list.key("Home")
            #expect(list.selectedNames == ["Alpha"])
            list.key("End", modifiers: .shift)
            #expect(list.selectedNames == ["Alpha", "Beta", "Gamma", "note.txt"])
            list.key("ArrowUp")
            #expect(list.selectedNames == ["Gamma"])
            // Left and Right move through the List as Up and Down do.
            list.key("ArrowRight")
            #expect(list.selectedNames == ["note.txt"])
            // The selected item left the list: the arrow keys carry on from where it stood.
            let removed = try #require(tab.content.entries.first { $0.name == "Beta" })
            tab.content.select(paths: [removed.path])
            try FileManager.default.removeItem(atPath: removed.path)
            tab.refresh()
            #expect(await waitUntil { tab.content.selection.paths.isEmpty && tab.content.entries.count == 3 })
            #expect(tab.content.selection.gapIndex == 1)
            list.key("ArrowDown")
            #expect(list.selectedNames == ["Gamma"])
            await harness.close()
        }

        // A page is the rows that fit less one, half a page half of them; the
        // list scrolls as far as the selection moved only when it lands off screen; ⇧ extends.
        @Test func pagingMovesByRowsAndScrollsToFollow() async throws {
            let harness = try ExplorerHarness.windowless()
            let folder = try harness.makeFolder(named: "Many", files: 200)
            let (tab, list) = try await harness.openList(folder.path)
            let table = try #require(list.table)
            let rowHeight = Int(table.rowHeight)
            let fit = Int(table.superview?.bounds.height ?? 0) / rowHeight
            #expect(fit > 8)
            // Nothing selected: the first item, and the list does not scroll.
            list.window.makeFirstResponder(table)
            list.key("PageDown")
            #expect(list.selectedNames == ["item-000.txt"])
            #expect(table.visibleRect.minY == 0)
            // A page: one row less than fit. The first row lands on screen, so the list stays still.
            list.key("PageDown")
            #expect(list.rowNames.firstIndex(of: list.selectedNames[0]) == fit - 1)
            #expect(table.visibleRect.minY == 0)
            // Half a page: ⌃D.
            list.key("d", modifiers: .control)
            #expect(list.rowNames.firstIndex(of: list.selectedNames[0]) == fit - 1 + fit / 2)
            // Landing off screen scrolls as far as the selection moved: it keeps its place on the screen.
            let before = try #require(list.rowNames.firstIndex(of: list.selectedNames[0]))
            let top = table.visibleRect.minY
            list.key("PageDown")
            let after = try #require(list.rowNames.firstIndex(of: list.selectedNames[0]))
            #expect(after - before == fit - 1)
            #expect(abs(table.visibleRect.minY - top - Double(fit - 1) * Double(rowHeight)) < 1.5)
            // ⇧ extends to the row landed on.
            list.key("PageUp", modifiers: .shift)
            #expect(list.selectedNames.count == fit)
            // Home, then PageUp at the first row with one item selected moves nothing and is not taken.
            list.key("Home")
            list.key("PageUp")
            #expect(list.selectedNames == ["item-000.txt"])
            // End is the last row; the scroll stops at the end of the list.
            list.key("End")
            list.key("PageDown")
            #expect(list.selectedNames == ["item-199.txt"])
            #expect(tab.content.selection.paths.count == 1)
            await harness.close()
        }

        // Typing narrows the list and selects the best match;
        // Backspace edits; Esc brings the list back and keeps the selection. (Space, nothing matching and the ✕ are in
        // SelectionCheckpointTests.)
        @Test func typingFiltersTheList() async throws {
            let harness = try ExplorerHarness.windowless()
            let folder = try harness.makeFolder(named: "Files", files: 0)
            for name in ["Report.txt", "my doc.txt", "Readme.md", "notes.txt", "Amy.txt"] {
                try "x".write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
            }
            let (tab, list) = try await harness.openList(folder.path)
            list.window.makeFirstResponder(list.table)
            list.type("re")
            #expect(list.rowNames == ["Readme.md", "Report.txt"])
            #expect(list.selectedNames == ["Readme.md"])
            let pill = try #require(shown("listFilter", tab).first)
            #expect(!pill.isHidden)
            let count = identified("listFilter.count", in: pill).compactMap { ($0 as? NSTextField)?.stringValue }
            #expect(count == ["2 of 5"])
            #expect(tab.content.filter == "re")
            // Backspace takes a character back; the first name starting with the text is selected again.
            list.type("p")
            #expect(list.rowNames == ["Report.txt"])
            list.key("Backspace")
            #expect(list.rowNames == ["Readme.md", "Report.txt"])
            // Esc brings the whole list back and keeps the selection.
            let selected = list.selectedNames
            list.key("Escape")
            #expect(list.rowNames.count == 5)
            #expect(list.selectedNames == selected)
            #expect(shown("listFilter", tab).isEmpty)
            // The filter belongs to the folder: it goes when another folder opens.
            list.type("a")
            #expect(tab.content.filter == "a")
            await tab.navigate(to: harness.folder.url)
            #expect(tab.content.filter.isEmpty)
            await harness.close()
        }

        // F2 opens the field over
        // the name with the stem selected, Return commits once, and the renamed item is selected.
        @Test func f2RenamesInPlace() async throws {
            let harness = try ExplorerHarness.windowless()
            let writes = try harness.writeOperations()
            defer { withExtendedLifetime(writes) {} }
            let (tab, list) = try await harness.openList()
            await list.click(name: "note.txt")
            list.key("F2")
            let field = try #require(shown("rename.field", tab).first as? InlineRenameField)
            #expect(field.stringValue == "note.txt")
            let editor = try #require(field.currentEditor())
            #expect(editor.selectedRange == NSRange(location: 0, length: 4))
            #expect(field.frame.height == 20)
            // The name is edited in its place, and no pane has the keyboard meanwhile.
            #expect(tab.focusedPane == nil)
            enter("memo.txt", in: field)
            list.key("Enter")
            #expect(await waitUntil { list.rowNames.contains("memo.txt") })
            #expect(!list.rowNames.contains("note.txt"))
            #expect(list.selectedNames == ["memo.txt"])
            #expect(shown("rename.field", tab).isEmpty)
            #expect(FileManager.default.fileExists(atPath: harness.folder.appending("memo.txt").path))
            #expect(list.hasKeyboard)
            // A folder's whole name is selected.
            await list.click(name: "Alpha")
            list.key("F2")
            let folderField = try #require(shown("rename.field", tab).first as? InlineRenameField)
            #expect(folderField.currentEditor()?.selectedRange == NSRange(location: 0, length: 5))
            // Escape gives up.
            list.window.firstResponder?.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
            #expect(shown("rename.field", tab).isEmpty)
            #expect(list.rowNames.contains("Alpha"))
            await harness.close()
        }

        // An unchanged or emptied name cancels; leaving the field
        // commits a changed one.
        @Test func unchangedEmptyAndBlurredNames() async throws {
            let harness = try ExplorerHarness.windowless()
            let writes = try harness.writeOperations()
            defer { withExtendedLifetime(writes) {} }
            let (tab, list) = try await harness.openList()
            await list.click(name: "note.txt")
            list.key("F2")
            list.key("Enter")
            #expect(shown("rename.field", tab).isEmpty)
            #expect(list.rowNames.contains("note.txt"))
            list.key("F2")
            let empty = try #require(shown("rename.field", tab).first as? InlineRenameField)
            enter("  ", in: empty)
            list.key("Enter")
            #expect(shown("rename.field", tab).isEmpty)
            #expect(list.rowNames.contains("note.txt"))
            // A click elsewhere commits the changed name.
            list.key("F2")
            let field = try #require(shown("rename.field", tab).first as? InlineRenameField)
            enter("blur.txt", in: field)
            await list.click(name: "Alpha")
            #expect(await waitUntil { list.rowNames.contains("blur.txt") })
            await harness.close()
        }

        // A refused name keeps the field open with a
        // red ring and the reason under it; the same name is not sent again; leaving the field gives up.
        @Test func aRefusedNameKeepsTheFieldOpen() async throws {
            let harness = try ExplorerHarness.windowless()
            let writes = try harness.writeOperations()
            defer { withExtendedLifetime(writes) {} }
            let (tab, list) = try await harness.openList()
            var sent: [String] = []
            tab.renameItem = { _, name in
                sent.append(name)
                return .refused("Names can’t contain “/”.")
            }
            await list.click(name: "note.txt")
            list.key("F2")
            let field = try #require(shown("rename.field", tab).first as? InlineRenameField)
            enter("a/b.txt", in: field)
            list.key("Enter")
            #expect(await waitUntil { field.error != nil })
            let reason = try #require(shown("rename.error", tab).first)
            #expect(!reason.isHidden)
            #expect(reason.frame.width <= 320)
            #expect(sent == ["a/b.txt"])
            // Return again with the same name sends nothing and keeps the field.
            list.key("Enter")
            await settle()
            #expect(sent == ["a/b.txt"])
            #expect(field.superview != nil)
            // An edited name is sent; a second refusal that reads the same is heard.
            enter("c/d.txt", in: field)
            #expect(!field.isShowingError)
            list.key("Enter")
            #expect(await waitUntil { sent.count == 2 && field.isShowingError })
            // Leaving the field gives up the refused name.
            await list.click(name: "Beta")
            #expect(shown("rename.field", tab).isEmpty)
            #expect(shown("rename.error", tab).isEmpty)
            await harness.close()
        }

        // The name being edited keeps the keyboard and what
        // was typed when its row scrolls away and back, and Escape still gives up.
        @Test func theDraftSurvivesScrolling() async throws {
            let harness = try ExplorerHarness.windowless()
            let writes = try harness.writeOperations()
            defer { withExtendedLifetime(writes) {} }
            let folder = try harness.makeFolder(named: "Long", files: 120)
            let (tab, list) = try await harness.openList(folder.path)
            let table = try #require(list.table)
            await list.click(row: 2)
            list.key("F2")
            let field = try #require(shown("rename.field", tab).first as? InlineRenameField)
            enter("draft-name.txt", in: field)
            table.scrollRowToVisible(119)
            (table.superview as? NSClipView)?.scroll(
                to: NSPoint(x: 0, y: table.rect(ofRow: 119).maxY - (table.superview?.bounds.height ?? 0)))
            let scroll = try #require(table.enclosingScrollView)
            scroll.reflectScrolledClipView(scroll.contentView)
            // The row is out of view; the field is still the one being edited, with the keyboard and its text.
            #expect(!table.visibleRect.intersects(field.frame))
            #expect(field.currentEditor() != nil)
            #expect(field.stringValue == "draft-name.txt")
            table.scroll(.zero)
            #expect(field.currentEditor() != nil && field.stringValue == "draft-name.txt")
            list.window.firstResponder?.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
            #expect(shown("rename.field", tab).isEmpty)
            await harness.close()
        }

        // Return renames,
        // or opens when the Return key setting says; ⌘↓ opens whatever the setting; double-click opens a folder.
        @Test func returnRenamesOrOpensAsTheSettingSays() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, list) = try await harness.openList()
            await list.click(name: "Alpha")
            list.key("Enter")
            #expect(shown("rename.field", tab).count == 1)
            list.window.firstResponder?.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
            // ⌘↓ opens the folder whatever the Return key does.
            await list.click(name: "Alpha")
            list.key("ArrowDown", modifiers: .command)
            #expect(await waitUntil { tab.folder.lastPathComponent == "Alpha" })
            await tab.navigate(to: harness.folder.url)
            // Set to open, Return opens.
            tab.updatePreferences(["returnKeyAction": .string("open")])
            await list.click(name: "Beta")
            list.key("Enter")
            #expect(await waitUntil { tab.folder.lastPathComponent == "Beta" })
            #expect(shown("rename.field", tab).isEmpty)
            await tab.navigate(to: harness.folder.url)
            // A double-click opens a folder in place.
            await list.click(name: "Gamma", count: 2)
            #expect(await waitUntil { tab.folder.lastPathComponent == "Gamma" })
            await harness.close()
        }

        // More items than "open at most N" shows a notice and opens none.
        @Test func tooManyItemsShowANotice() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, list) = try await harness.openList()
            tab.updatePreferences(["openItemLimit": .number(1), "returnKeyAction": .string("open")])
            list.window.makeFirstResponder(list.table)
            // Edit › Select All, as the menu sends it (the test process need not be the active app).
            tab.perform(.editSelectAll)
            #expect(list.selectedNames.count == 4)
            list.key("Enter")
            // The notice is an alert drawn in the window.
            #expect(await waitUntil { tab.frontAlert != nil })
            let alert = try #require(tab.frontAlert)
            #expect(alert.titleLabel.stringValue.hasPrefix("Too Many Items to"))
            DialogKeys.press(36, "\r", in: list.window)
            #expect(await waitUntil { tab.frontAlert == nil })
            #expect(tab.folder == harness.folder.url)
            await harness.close()
        }
    }
}
