// The clipboard's list keeps each row's buttons on the item it shows after the list changes under it
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

    /// A menu of 100 files in a window, so that its list takes mouse events; the list's height is 240.
    private func longMenu() throws -> (menu: ClipboardMenuView, list: ClipboardMenuList, window: NSWindow) {
        let paths = (0..<100).map { "/f/\($0).txt" }
        let state = ClipboardRules.set(.copy, paths, capturedAt: "t")
        let menu = ClipboardMenuView(summary: try #require(ClipboardRules.describe(state)), pasteHint: "")
        menu.frame = NSRect(x: 0, y: 0, width: 300, height: menu.fittingSize(viewportWidth: 1200).height)
        let window = NSWindow(
            contentRect: menu.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = menu
        menu.layoutSubtreeIfNeeded()
        let list = try #require(identified("clipboardPopover.list", in: menu).first as? ClipboardMenuList)
        list.layoutSubtreeIfNeeded()
        return (menu, list, window)
    }

    /// Presses, and optionally drags and lets go, the list's scrollbar at heights in the list.
    private func press(_ list: ClipboardMenuList, at y: Double, dragTo end: Double? = nil, in window: NSWindow) throws {
        func event(_ type: NSEvent.EventType, _ y: Double) throws -> NSEvent {
            let point = list.convert(NSPoint(x: list.bounds.width - 5, y: y), to: nil)
            return try #require(
                NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        let hit = window.contentView?.hitTest(list.convert(NSPoint(x: list.bounds.width - 5, y: y), to: nil))
        #expect(hit === list)
        list.mouseDown(with: try event(.leftMouseDown, y))
        if let end { list.mouseDragged(with: try event(.leftMouseDragged, end)) }
        list.mouseUp(with: try event(.leftMouseUp, end ?? y))
    }

    // Scrolled so that a row straddles the pinned heading's bottom, the row shows only below the heading.
    @Test func rowsDoNotShowBehindThePinnedHeading() throws {
        let (menu, list, _) = try longMenu()
        // A row starts 12 pt into the pinned heading's 24; made active, it has a fill to find.
        list.onScroll(132)
        let row = try #require(rows(menu).first { list.convert($0.bounds, from: $0).minY == 12 })
        row.onHover()
        list.layoutSubtreeIfNeeded()
        let image = try #require(list.bitmapImageRepForCachingDisplay(in: list.bounds))
        list.cacheDisplay(in: list.bounds, to: image)
        let scale = Double(image.pixelsWide) / list.bounds.width
        func alpha(y: Double) -> Double {
            Double(image.colorAt(x: Int(100 * scale), y: Int(y * scale))?.alphaComponent ?? 0)
        }
        #expect(alpha(y: 18) == 0)
        #expect(alpha(y: 30) > 0)
    }

    @Test func draggingTheScrollbarsThumbScrollsTheList() throws {
        let (menu, list, window) = try longMenu()
        let limit = menu.modelForTests.contentHeight - menu.modelForTests.listHeight
        try press(list, at: 5, dragTo: 1000, in: window)
        #expect(menu.modelForTests.scrollTop == limit)
        try press(list, at: 235, dragTo: -5, in: window)
        #expect(menu.modelForTests.scrollTop == 0)
    }

    @Test func clickingTheScrollbarsTrackPagesOrJumpsAsTheSystemIsSet() throws {
        let (menu, list, window) = try longMenu()
        let height = menu.modelForTests.listHeight
        let limit = menu.modelForTests.contentHeight - height
        list.jumpsToClickedSpot = false
        try press(list, at: 200, in: window)
        // A page is what the pinned heading leaves of the list.
        #expect(menu.modelForTests.scrollTop == height - 24)
        list.jumpsToClickedSpot = true
        try press(list, at: height - 1, in: window)
        #expect(menu.modelForTests.scrollTop == limit)
    }

    // The list reads from the top down: the folder's heading, then its items in the order they were copied,
    // none under the pinned heading; the texts are not cut short and start at the padding.
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
        // (The text is cut short when its cell insets it.)
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

    // Once one item is removed, the row that now shows the next one removes and shows that one.
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

    // When the folders shift, a heading kept in its place names the folder under it now.
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
