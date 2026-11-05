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

    @Test func showsAControlsTitleAfterThePointerRestsOnIt() {
        scheduler.hover(trash)
        #expect(tooltip == nil)
        timers.advance(milliseconds: 600)
        #expect(tooltip == "Trash")
    }

    // An icon inside a button is part of it (the icon view lets the pointer through to the button), so
    // hovering the icon is hovering the button: told of it again, the wait goes on and it shows once.
    @Test func theSameControlHoveredAgainShowsOnce() {
        scheduler.hover(trash)
        scheduler.hover(trash)
        timers.advance(milliseconds: 600)
        #expect(tooltip == "Trash")
        #expect(box.shown == ["Trash"])
    }

    // The system's own tooltip is never set on the app's buttons, so it can't show beside this one;
    // leaving the control drops the waiting tooltip.
    @Test func leavingTheControlDropsTheWaitingTooltip() {
        scheduler.hover(trash)
        scheduler.hover(nil)
        timers.advance(milliseconds: 1000)
        #expect(tooltip == nil)
    }

    @Test func showsTheNextControlsTooltipAtOnceWhenMovingStraightAcross() {
        scheduler.hover(trash)
        timers.advance(milliseconds: 600)
        scheduler.hover(help)
        timers.advance(milliseconds: 0)
        #expect(tooltip == "Help")
        #expect(box.shown == ["Trash", "", "Help"])
    }

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

    // A key, a scroll and the pointer leaving the window all come here as `dismiss`.
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

    @Test func followsATitleThatChangesWhileTheTooltipIsShowing() {
        scheduler.hover(trash)
        timers.advance(milliseconds: 600)
        trash.tooltipText = "Empty Trash"
        scheduler.refresh()
        #expect(tooltip == "Empty Trash")
    }

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
