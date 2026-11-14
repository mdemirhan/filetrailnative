// The Undo History list tells how long ago each operation was, and tells it again as time passes while it is open
import AppKit
import FTFoundation
import FTOperations
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    @MainActor
    @Suite struct UndoHistoryTimesTests {
        @MainActor
        private final class Clock {
            var now = Date(timeIntervalSince1970: 1_700_000_000)
        }

        private func details(_ view: UndoHistoryView) -> [String] {
            descendants(of: view, UndoHistoryView.TwoLineRow.self).map(\.second.stringValue)
        }

        @Test func theTimesAreToldAgainAsTheyPassWhileTheListIsOpen() throws {
            let clock = Clock()
            let history = UndoHistory(clock: { clock.now })
            history.record(UndoToolbarTests.rename("/p/a", "/p/b"))
            clock.now += 90
            history.record(UndoToolbarTests.rename("/p/c", "/p/d"))
            let view = UndoHistoryView(
                content: UndoHistoryRows.content(history, homePath: "/Users/demo"), undoKey: "⌘Z", redoKey: "⇧⌘Z",
                now: { clock.now })
            #expect(details(view) == ["in p · Just now", "in p · 1 min ago"])
            // Not in a window, nothing waits for the time to pass.
            #expect(!view.followsTheTime)

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless],
                backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            window.contentView?.addSubview(view)
            #expect(view.followsTheTime)

            // Two and a half minutes on, each row says so, and its label for VoiceOver with it.
            clock.now += 150
            view.tellTimes()
            #expect(details(view) == ["in p · 2 min ago", "in p · 4 min ago"])
            let row = try #require(descendants(of: view, UndoHistoryView.UndoHistoryRowView.self).first)
            #expect(row.accessibilityLabel() == "Rename, in p · 2 min ago")
            #expect(view.followsTheTime)

            // A change of the history while it is open keeps it waiting; closed, it stops.
            history.record(UndoToolbarTests.rename("/p/e", "/p/f"))
            view.update(UndoHistoryRows.content(history, homePath: "/Users/demo"))
            #expect(details(view).first == "in p · Just now")
            #expect(view.followsTheTime)
            view.removeFromSuperview()
            #expect(!view.followsTheTime)

            // Operations over an hour old read by their time of day: nothing to wait for.
            clock.now += 2 * 3_600
            window.contentView?.addSubview(view)
            #expect(!view.followsTheTime)
            view.removeFromSuperview()
            window.close()
        }
    }
}
