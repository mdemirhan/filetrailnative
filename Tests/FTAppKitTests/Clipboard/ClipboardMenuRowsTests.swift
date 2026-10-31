// Port by feature of the rows of components/ClipboardButton.test.tsx: the clipboard's list keeps each row's buttons on
// the item it shows, as the original's rows keyed by path do, after the list changes under it
import AppKit
import FTFoundation
import Testing

@testable import FTAppKit

@MainActor
@Suite struct ClipboardMenuRowsTests {
    private func rows(_ view: NSView) -> [ClipboardMenuItemRow] {
        var found: [ClipboardMenuItemRow] = []
        func walk(_ view: NSView) {
            if let row = view as? ClipboardMenuItemRow { found.append(row) }
            view.subviews.forEach(walk)
        }
        walk(view)
        return found.sorted { $0.frame.minY < $1.frame.minY }
    }

    private func headings(_ view: NSView) -> [ClipboardMenuHeadingRow] {
        var found: [ClipboardMenuHeadingRow] = []
        func walk(_ view: NSView) {
            if let row = view as? ClipboardMenuHeadingRow, row.accessibilityIdentifier() == "clipboardPopover.heading" {
                found.append(row)
            }
            view.subviews.forEach(walk)
        }
        walk(view)
        return found.sorted { $0.frame.minY < $1.frame.minY }
    }

    private func menu(_ state: CopyPasteClipboard) throws -> ClipboardMenuView {
        let menu = ClipboardMenuView(summary: try #require(ClipboardRules.describe(state)), pasteHint: "")
        menu.frame = NSRect(x: 0, y: 0, width: 300, height: 400)
        menu.layoutSubtreeIfNeeded()
        return menu
    }

    // F-800 F-801: the list reads from the top down: the folder's heading, then its items in the order they were copied,
    // none under the pinned heading; the texts are not cut short and start at the padding, as the original's.
    @Test func theListIsDrawnFromTheTopDown() throws {
        let file = ClipboardSourceEntry(kind: .file, isSymlink: false)
        let both = ClipboardRules.set(
            .copy, ["/f/Avatar.jsx", "/f/Toast.jsx"], capturedAt: "t",
            entries: ["/f/Avatar.jsx": file, "/f/Toast.jsx": file])
        let menu = ClipboardMenuView(summary: try #require(ClipboardRules.describe(both)), pasteHint: "Paste with ⌘V")
        menu.frame = NSRect(x: 0, y: 0, width: 260, height: menu.fittingSize(viewportWidth: 1200).height)
        menu.layoutSubtreeIfNeeded()
        #expect(menu.frame.height == 169)
        func top(_ view: NSView) -> Double { Double(menu.convert(view.bounds, from: view).minY) }
        let heading = try #require(headings(menu).first)
        let items = rows(menu)
        #expect(items.map(\.toolTip) == ["/f/Avatar.jsx", "/f/Toast.jsx"])
        #expect(top(heading) == 56.5)
        #expect(items.map(top) == [80.5, 104.5])
        func text(_ id: String) throws -> ClipboardMenuText {
            try #require(identified(id, in: menu).first as? ClipboardMenuText)
        }
        let title = try text("clipboardPopover.title")
        // (P5-14 finding: the text is cut short when its cell insets it.)
        #expect(title.frame.width >= 92)
        #expect(title.frame.height == 15)
        #expect(title.frame.minY == 9.5)
        // The cell draws from the frame's edge, so a frame the text's width doesn't cut it.
        let drawn = try #require(title.cell?.drawingRect(forBounds: title.bounds))
        #expect(drawn.width >= title.textWidth)
        #expect(try text("clipboardPopover.hint").frame.minY == 11.5)
        let breakdown = try text("clipboardPopover.breakdown")
        #expect(breakdown.frame == NSRect(x: 5.5, y: 28.5, width: 249, height: 17))
    }

    // F-800 B-CLIP-029: once one item is removed, the row that now shows the next one removes and shows that one.
    @Test func aRowThatShiftsActsOnTheItemItShows() throws {
        let both = ClipboardRules.set(.copy, ["/f/a.txt", "/f/b.txt"], capturedAt: "t")
        let menu = try menu(both)
        var removed: [String] = []
        var revealed: [String] = []
        menu.onRemove = { removed.append($0) }
        menu.onReveal = { revealed.append($0) }
        rows(menu).first?.onRemove()
        menu.update(try #require(ClipboardRules.describe(ClipboardRules.removeItem(both, "/f/a.txt"))))
        menu.layoutSubtreeIfNeeded()
        rows(menu).first?.onRemove()
        rows(menu).first?.onReveal()
        #expect(removed == ["/f/a.txt", "/f/b.txt"])
        #expect(revealed == ["/f/b.txt"])
        #expect(rows(menu).first?.toolTip == "/f/b.txt")
    }

    // F-800 B-CLIP-024: when the folders shift, a heading kept in its place names the folder under it now.
    @Test func aHeadingThatShiftsNamesItsFolder() throws {
        let three = ClipboardRules.set(.copy, ["/f/a.txt", "/f/b.txt", "/g/c.txt"], capturedAt: "t")
        let menu = try menu(three)
        let before = headings(menu).map(\.toolTip)
        #expect(before == ["/f", "/g"])
        var state = ClipboardRules.removeItem(three, "/f/a.txt")
        state = ClipboardRules.removeItem(state, "/f/b.txt")
        menu.update(try #require(ClipboardRules.describe(state)))
        menu.layoutSubtreeIfNeeded()
        #expect(headings(menu).first?.toolTip == "/g")
        #expect(rows(menu).map(\.toolTip) == ["/g/c.txt"])
    }
}
