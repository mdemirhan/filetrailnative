// Port of the mouse actions of tools/capture/electron/driver.ts (Playwright clicks); no TypeScript source.
#if DEBUG
    import AppKit

    /// Synthesized mouse events, delivered through `NSApp`: no Accessibility permission is needed, and the
    /// app doesn't have to be frontmost.
    @MainActor
    enum MouseEvents {
        /// The center of a view, in its window's base coordinates.
        static func center(of view: NSView) -> NSPoint {
            let rect = view.convert(view.bounds, to: nil)
            return NSPoint(x: rect.midX, y: rect.midY)
        }

        static func event(
            _ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow, clickCount: Int = 1,
            modifiers: NSEvent.ModifierFlags = []
        ) -> NSEvent? {
            NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clickCount,
                pressure: type == .leftMouseUp || type == .rightMouseUp ? 0 : 1)
        }

        /// The down and up events of `count` left clicks: the second pair has a click count of 2, as a
        /// double click does.
        static func clicks(
            at point: NSPoint, in window: NSWindow, count: Int, modifiers: NSEvent.ModifierFlags
        ) -> [(down: NSEvent, up: NSEvent)] {
            (1...max(1, count)).compactMap { number in
                guard let down = event(.leftMouseDown, at: point, in: window, clickCount: number, modifiers: modifiers),
                    let up = event(.leftMouseUp, at: point, in: window, clickCount: number, modifiers: modifiers)
                else { return nil }
                return (down, up)
            }
        }

        /// Clicks: each mouse-up is queued before its mouse-down is sent, so a view that tracks the mouse
        /// in a loop of its own (a table row, a button) finds it there and the loop ends.
        static func click(
            at point: NSPoint, in window: NSWindow, count: Int, modifiers: NSEvent.ModifierFlags
        ) async -> Bool {
            let pairs = clicks(at: point, in: window, count: count, modifiers: modifiers)
            guard pairs.count == max(1, count) else { return false }
            for (down, up) in pairs {
                NSApp.postEvent(up, atStart: false)
                NSApp.sendEvent(down)
                // Lets the run loop take the queued mouse-up if the view didn't.
                try? await Task.sleep(for: .milliseconds(30))
            }
            return true
        }

        /// A press held for a while, then released. Both go through the event queue: a view tracking the
        /// press runs its own loop, and the main queue (this task) still runs inside it, so the release
        /// arrives on time.
        static func press(
            at point: NSPoint, in window: NSWindow, holdMilliseconds: Int, modifiers: NSEvent.ModifierFlags
        ) async -> Bool {
            guard let down = event(.leftMouseDown, at: point, in: window, modifiers: modifiers) else { return false }
            NSApp.postEvent(down, atStart: false)
            try? await Task.sleep(for: .milliseconds(holdMilliseconds))
            guard let up = event(.leftMouseUp, at: point, in: window, modifiers: modifiers) else { return false }
            NSApp.postEvent(up, atStart: false)
            try? await Task.sleep(for: .milliseconds(50))
            return true
        }

        /// A press, a drag in steps, and a release. A view that starts a native drag session (`NSDraggingSession`)
        /// can't be driven this way: the window server runs that session, not these events.
        static func drag(
            from start: NSPoint, to end: NSPoint, in window: NSWindow, modifiers: NSEvent.ModifierFlags
        ) async -> Bool {
            guard let down = event(.leftMouseDown, at: start, in: window, modifiers: modifiers),
                let up = event(.leftMouseUp, at: end, in: window, modifiers: modifiers)
            else { return false }
            let steps = 8
            var moves: [NSEvent] = []
            for step in 1...steps {
                let fraction = Double(step) / Double(steps)
                let point = NSPoint(
                    x: start.x + (end.x - start.x) * fraction, y: start.y + (end.y - start.y) * fraction)
                if let move = event(.leftMouseDragged, at: point, in: window, modifiers: modifiers) {
                    moves.append(move)
                }
            }
            for move in moves { NSApp.postEvent(move, atStart: false) }
            NSApp.postEvent(up, atStart: false)
            NSApp.sendEvent(down)
            try? await Task.sleep(for: .milliseconds(60))
            return true
        }
    }
#endif
