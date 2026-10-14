// Ports apps/desktop/src/renderer/lib/titleTooltips.test.ts (the DOM timing rows, as the AppKit tooltip's delays)
import Foundation
import Testing

@testable import FTAppKit

@MainActor
final class FakeAnchor: TooltipAnchor {
    var tooltipText: String
    var tooltipIsQuiet = false

    init(_ text: String) {
        tooltipText = text
    }
}

/// A clock and timers the test moves by hand, as vitest's fake timers do.
@MainActor
final class FakeTimers {
    private(set) var now: TimeInterval = 1000
    private var pending: [(id: Int, at: TimeInterval, fire: @MainActor () -> Void)] = []
    private var nextID = 0

    func schedule(_ seconds: TimeInterval, _ fire: @escaping @MainActor () -> Void) -> () -> Void {
        nextID += 1
        let id = nextID
        pending.append((id, now + seconds, fire))
        return { [weak self] in self?.pending.removeAll { $0.id == id } }
    }

    func advance(milliseconds: Double) {
        let end = now + milliseconds / 1000
        while let next = pending.filter({ $0.at <= end }).min(by: { $0.at < $1.at }) {
            pending.removeAll { $0.id == next.id }
            now = next.at
            next.fire()
        }
        now = end
    }
}

@MainActor
struct TooltipSchedulerTests {
    let timers = FakeTimers()
    let scheduler: TooltipScheduler
    let trash = FakeAnchor("Trash")
    let help = FakeAnchor("Help")
    var shown: [String] { box.shown }
    let box = Box()

    final class Box {
        var shown: [String] = []
        var text: String? { shown.last }
    }

    init() {
        let timers = timers
        scheduler = TooltipScheduler(now: { timers.now }, schedule: { timers.schedule($0, $1) })
        let box = box
        scheduler.onShow = { _, text in box.shown.append(text) }
        scheduler.onHide = { box.shown.append("") }
    }

    /// The tooltip on screen now, or nil.
    var tooltip: String? { scheduler.isShowing ? box.text : nil }

    // T-9e960311 F-829 B-VIEW-120
    @Test func showsAControlsTitleAfterThePointerRestsOnIt() {
        scheduler.hover(trash)
        #expect(tooltip == nil)
        timers.advance(milliseconds: 600)
        #expect(tooltip == "Trash")
    }

    // T-cc926cf5: an icon inside a button is part of it (the icon view lets the pointer through to the button), so
    // hovering the icon is hovering the button.
    @Test func findsTheTitleFromAnIconInsideTheControl() {
        scheduler.hover(trash)
        scheduler.hover(trash)
        timers.advance(milliseconds: 600)
        #expect(tooltip == "Trash")
        #expect(box.shown == ["Trash"])
    }

    // T-1849bac0: the system's own tooltip is never set on the app's buttons, so it can't show beside this one;
    // leaving the control drops the waiting tooltip.
    @Test func takesTheTitleOffWhileHoveringAndPutsItBackAfterwards() {
        scheduler.hover(trash)
        scheduler.hover(nil)
        timers.advance(milliseconds: 1000)
        #expect(tooltip == nil)
        #expect(trash.tooltipText == "Trash")
    }

    // T-91fc6643 F-829
    @Test func showsTheNextControlsTooltipAtOnceWhenMovingStraightAcross() {
        scheduler.hover(trash)
        timers.advance(milliseconds: 600)
        scheduler.hover(help)
        timers.advance(milliseconds: 0)
        #expect(tooltip == "Help")
        #expect(box.shown == ["Trash", "", "Help"])
    }

    // T-4e5d4df9
    @Test func waitsAgainOnceThePointerHasBeenAwayForAWhile() {
        scheduler.hover(trash)
        timers.advance(milliseconds: 600)
        scheduler.hover(nil)
        timers.advance(milliseconds: 1000)
        scheduler.hover(help)
        timers.advance(milliseconds: 100)
        #expect(tooltip == nil)
        timers.advance(milliseconds: 500)
        #expect(tooltip == "Help")
    }

    // T-34663665
    @Test func hidesOnClickAndStaysQuietUntilThePointerLeavesTheControl() {
        scheduler.hover(trash)
        timers.advance(milliseconds: 600)
        scheduler.press(trash)
        #expect(tooltip == nil)
        scheduler.hover(trash)
        timers.advance(milliseconds: 1000)
        #expect(tooltip == nil)
        scheduler.hover(nil)
        timers.advance(milliseconds: 1000)
        scheduler.hover(trash)
        timers.advance(milliseconds: 600)
        #expect(tooltip == "Trash")
    }

    // T-6005952a
    @Test func staysQuietOverAButtonWhoseMenuIsOpen() {
        help.tooltipIsQuiet = true
        scheduler.hover(help)
        timers.advance(milliseconds: 1000)
        #expect(tooltip == nil)
        scheduler.hover(nil)
        help.tooltipIsQuiet = false
        timers.advance(milliseconds: 1000)
        scheduler.hover(help)
        timers.advance(milliseconds: 600)
        #expect(tooltip == "Help")
    }

    // T-16801ecd: a key, a scroll and the pointer leaving the window all come here as `dismiss`.
    @Test func hidesWhenAKeyIsPressedTheViewScrollsOrThePointerLeavesTheWindow() {
        for _ in 0..<3 {
            scheduler.hover(nil)
            timers.advance(milliseconds: 1000)
            scheduler.hover(trash)
            timers.advance(milliseconds: 600)
            #expect(tooltip == "Trash")
            scheduler.dismiss()
            #expect(tooltip == nil)
        }
    }

    // T-5c9514b8
    @Test func followsATitleThatChangesWhileTheTooltipIsShowing() {
        scheduler.hover(trash)
        timers.advance(milliseconds: 600)
        trash.tooltipText = "Empty Trash"
        scheduler.refresh()
        #expect(tooltip == "Empty Trash")
    }

    // T-bea514b5: rows, labelled buttons and controls in rows never adopt `TooltipAnchor`; over them the pointer is
    // over no anchor.
    @Test func leavesFileAndFolderRowsLabelledButtonsAndRowControlsToThemselves() {
        scheduler.hover(nil)
        timers.advance(milliseconds: 1000)
        #expect(tooltip == nil)
        #expect(!(AppMenuRow(item: AppMenuItem(title: "Row"), keyboard: false) is TooltipAnchor))
    }

    // T-f8d9bae2
    @Test func showsNothingForEmptyTitlesAndStopsWhenUninstalled() {
        help.tooltipText = "  "
        scheduler.hover(help)
        timers.advance(milliseconds: 600)
        #expect(tooltip == nil)
        scheduler.uninstall()
        scheduler.hover(trash)
        timers.advance(milliseconds: 600)
        #expect(tooltip == nil)
    }
}
