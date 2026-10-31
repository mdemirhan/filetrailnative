// The loop a press runs to follow the pointer until the button goes up (a click, a drag, a marquee)
import AppKit

/// Where a press gets the events that follow it. A view that tracks the mouse reads them from the window's queue; a test
/// that has no event loop sets `source` to events it holds.
@MainActor
enum PointerTracker {
    /// The next event of the kinds asked for, waiting up to `until` (nil: for ever); nil when none came in time.
    static var source: (NSWindow, NSEvent.EventTypeMask, Date?) -> NSEvent? = { window, mask, until in
        window.nextEvent(matching: mask, until: until ?? .distantFuture, inMode: .eventTracking, dequeue: true)
    }

    static func next(in window: NSWindow, matching mask: NSEvent.EventTypeMask, until: Date? = nil) -> NSEvent? {
        source(window, mask, until)
    }
}
