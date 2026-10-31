// Checks what the Swift driver does for the capture to be honest: hover, on a real tracking area, as the pointer Playwright
// moves in the original's captures; no TypeScript source
import AppKit
import Testing

@testable import FTAppKit

@MainActor
@Suite struct AutomationPointerTests {
    private final class Tracked: NSView {
        var crossings: [String] = []

        override init(frame: NSRect) {
            super.init(frame: frame)
            addTrackingArea(
                NSTrackingArea(
                    rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func mouseEntered(with event: NSEvent) { crossings.append("entered") }
        override func mouseExited(with event: NSEvent) { crossings.append("exited") }
    }

    // 265, a09: the clicked control shows its hover in the capture, and the one left doesn't.
    @Test func movingThePointerTellsTheViewsItEntersAndLeaves() throws {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered,
            defer: true)
        window.isReleasedWhenClosed = false
        let one = Tracked(frame: NSRect(x: 0, y: 0, width: 50, height: 50))
        let two = Tracked(frame: NSRect(x: 100, y: 0, width: 50, height: 50))
        let host = try #require(window.contentView)
        host.addSubview(one)
        host.addSubview(two)
        MouseEvents.movePointer(to: MouseEvents.center(of: one), in: window)
        #expect(one.crossings == ["entered"])
        #expect(two.crossings.isEmpty)
        MouseEvents.movePointer(to: MouseEvents.center(of: one), in: window)
        #expect(one.crossings == ["entered"])
        MouseEvents.movePointer(to: MouseEvents.center(of: two), in: window)
        #expect(one.crossings == ["entered", "exited"])
        #expect(two.crossings == ["entered"])
        MouseEvents.movePointer(to: NSPoint(x: 80, y: 80), in: window)
        #expect(two.crossings == ["entered", "exited"])
    }
}
