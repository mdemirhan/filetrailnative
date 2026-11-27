// Filter keys typed faster than a large folder draws share one redraw, and nothing acts on a list left undrawn
import AppKit
import FTFileSystem
import FTFoundation
import Testing

@testable import FTAppKit

@MainActor
struct FilterRedrawTests {
    /// More than `ContentPaneController.coalescedFilterMinimum`.
    private static let many = (0..<600).map { String(format: "item-%03d.txt", $0) }

    /// A folder's list in the List, never shown; `waiting` stands in for keys waiting in the app's queue.
    private func pane(
        _ names: [String] = Self.many, waiting: @escaping () -> Bool
    ) -> (content: ContentPaneController, timers: ManualTimers) {
        _ = NSApplication.shared
        let content = ContentPaneController(
            mode: .details, folderSizes: FolderSizeService.shared.sizes(for: 9_004), loaders: .placeholder)
        let timers = ManualTimers()
        content.timers = timers
        content.keyIsWaiting = waiting
        content.view.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        content.show(
            folder: "/f", entries: names.map { ContentModelTests.entry($0) }, selecting: nil, keepingScroll: false)
        return (content, timers)
    }

    /// The rows the List draws now.
    private func rowsDrawn(_ content: ContentPaneController) -> Int {
        (content.pane as? ListViewController)?.table.numberOfRows ?? -1
    }

    private func key(_ characters: String, code: UInt16) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }

    // Each key narrows the list at once; the drawing waits while more keys do, and the last one draws.
    @Test func keysTypedAheadNarrowTheListAndTheLastOneDrawsIt() {
        var waiting = true
        let (content, timers) = pane { waiting }
        content.applyFilterKey(.type("1"))
        #expect(content.entries.count < Self.many.count)
        #expect(rowsDrawn(content) == Self.many.count)
        content.applyFilterKey(.type("2"))
        #expect(content.filter == "12")
        #expect(rowsDrawn(content) == Self.many.count)
        #expect(timers.pending == 1)
        waiting = false
        content.applyFilterKey(.type("3"))
        #expect(rowsDrawn(content) == content.entries.count)
        let afresh = ListFilter.filterByName(content.listed, query: "123", mode: content.filterMode).map(\.name)
        #expect(content.entries.map(\.name) == afresh)
        #expect(timers.pending == 0)
    }

    // The selection a key makes is told to whoever follows it once the list is drawn, even when the last key keeps it.
    @Test func theSelectionIsToldOnceTheListIsDrawn() {
        var waiting = true
        let (content, _) = pane { waiting }
        var told: [ContentSelection] = []
        content.onSelectionChanged = { told.append($0) }
        content.applyFilterKey(.type("i"))
        content.applyFilterKey(.type("t"))
        #expect(told.isEmpty)
        #expect(!content.selection.isEmpty)
        waiting = false
        content.applyFilterKey(.type("e"))
        #expect(told.last == content.selection)
        #expect(told.count == 1)
    }

    // When the key that draws changes the selection too, it is told once; when nothing changed, it isn't told again.
    @Test func theSelectionIsToldOnceWhenTheLastKeyChangesIt() {
        var waiting = true
        let (content, _) = pane { waiting }
        var told: [ContentSelection] = []
        content.onSelectionChanged = { told.append($0) }
        content.applyFilterKey(.type("5"))
        #expect(told.isEmpty)
        waiting = false
        content.applyFilterKey(.type("9"))
        #expect(told == [content.selection])

        told = []
        waiting = true
        content.applyFilterKey(.erase)
        waiting = false
        content.applyPendingFilter()
        content.applyPendingFilter()
        #expect(told == [content.selection])
    }

    // A folder read again while the list waits is drawn whole: no rows of the list before the filter stay.
    @Test func aFolderReadAgainWhileTheListWaitsIsDrawnWhole() {
        let (content, timers) = pane { true }
        content.applyFilterKey(.type("4"))
        #expect(rowsDrawn(content) == Self.many.count)
        let entries = (Self.many + ["item-604-new.txt"]).map { ContentModelTests.entry($0) }
        content.show(
            folder: "/f", entries: entries, selecting: nil, keepingScroll: true, changedPaths: ["/f/item-604-new.txt"])
        #expect(rowsDrawn(content) == content.entries.count)
        #expect(timers.pending == 0)
    }

    // Another folder opened while the list waits is drawn once, and nothing is left to draw after it.
    @Test func anotherFolderOpenedWhileTheListWaitsTakesItsPlace() {
        let (content, timers) = pane { true }
        content.applyFilterKey(.type("6"))
        content.show(
            folder: "/g", entries: ["one.txt", "two.txt"].map { ContentModelTests.entry($0) }, selecting: nil,
            keepingScroll: false)
        #expect(rowsDrawn(content) == 2)
        #expect(timers.pending == 0)
    }

    // The Icons view's context menu draws a waiting filter first, as the List's does.
    @Test func theIconsViewsContextMenuDrawsTheWaitingListFirst() throws {
        _ = NSApplication.shared
        let content = ContentPaneController(
            mode: .icons, folderSizes: FolderSizeService.shared.sizes(for: 9_005), loaders: .placeholder)
        let timers = ManualTimers()
        content.timers = timers
        content.keyIsWaiting = { true }
        content.view.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        content.show(
            folder: "/f", entries: Self.many.map { ContentModelTests.entry($0) }, selecting: nil, keepingScroll: false)
        let grid = try #require(content.pane as? ItemGridPane)
        content.applyFilterKey(.type("3"))
        #expect(grid.collection.numberOfItems(inSection: 0) == Self.many.count)
        let press = try #require(
            NSEvent.mouseEvent(
                with: .rightMouseDown, location: NSPoint(x: 10, y: 10), modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        _ = grid.collection.menu(for: press)
        #expect(grid.collection.numberOfItems(inSection: 0) == content.entries.count)
        #expect(timers.pending == 0)
    }

    // Looking for keys waiting runs nothing else waiting on the main thread: looked at in the default mode, the run
    // loop ran the work waiting there in the middle of a key.
    @Test func lookingForKeysWaitingRunsNothingElse() {
        _ = NSApplication.shared
        let content = ContentPaneController(
            mode: .details, folderSizes: FolderSizeService.shared.sizes(for: 9_006), loaders: .placeholder)
        let flag = RanFlag()
        RunLoop.main.perform(inModes: [.default, .common]) { flag.ran = true }
        #expect(!content.keyIsWaiting())
        #expect(!flag.ran)
    }

    /// Whether the work queued on the main run loop ran; only the main thread reads and sets it.
    private final class RanFlag: @unchecked Sendable {
        var ran = false
    }

    // Return right after typing acts on the list as drawn for the filter, not on the one before.
    @Test func aKeyThatIsNotTheFiltersDrawsTheWaitingListFirst() throws {
        let (content, _) = pane { true }
        content.applyFilterKey(.type("7"))
        #expect(rowsDrawn(content) == Self.many.count)
        var rowsAtReturn = -1
        content.onReturn = { rowsAtReturn = self.rowsDrawn(content) }
        let list = try #require(content.pane as? ListViewController)
        #expect(list.handleKeyDown(key("\r", code: 36)))
        #expect(rowsAtReturn == content.entries.count)
    }

    // A context menu asked for over the list draws a waiting filter first.
    @Test func aContextMenuDrawsTheWaitingListFirst() throws {
        let (content, timers) = pane { true }
        content.applyFilterKey(.type("8"))
        #expect(rowsDrawn(content) == Self.many.count)
        let list = try #require(content.pane as? ListViewController)
        let press = try #require(
            NSEvent.mouseEvent(
                with: .rightMouseDown, location: NSPoint(x: 10, y: 10), modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        _ = list.table.menu(for: press)
        #expect(rowsDrawn(content) == content.entries.count)
        #expect(timers.pending == 0)
    }

    // A list left for a key that went elsewhere is drawn by the timer.
    @Test func theTimerDrawsAListNoKeyDrew() {
        let (content, timers) = pane { true }
        content.applyFilterKey(.type("9"))
        #expect(rowsDrawn(content) == Self.many.count)
        timers.advance(ContentPaneController.filterRedrawLongest)
        #expect(rowsDrawn(content) == content.entries.count)
        #expect(timers.pending == 0)
    }

    // A small folder draws every key, and Esc draws the whole list at once.
    @Test func aSmallFolderAndEscDrawAtOnce() {
        let small = Array(Self.many.prefix(ContentPaneController.coalescedFilterMinimum - 1))
        let (content, _) = pane(small) { true }
        content.applyFilterKey(.type("1"))
        #expect(rowsDrawn(content) == content.entries.count)

        var waiting = false
        let (large, timers) = pane { waiting }
        large.applyFilterKey(.type("1"))
        let narrowed = rowsDrawn(large)
        #expect(narrowed == large.entries.count && narrowed < Self.many.count)
        waiting = true
        large.applyFilterKey(.type("2"))
        #expect(rowsDrawn(large) == narrowed)
        large.applyFilterKey(.clear)
        #expect(large.filter.isEmpty)
        #expect(rowsDrawn(large) == Self.many.count)
        #expect(timers.pending == 0)
    }
}
