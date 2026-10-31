// Port of the focus Playwright gives the original's window in tools/capture/electron/driver.ts; no TypeScript source.
#if DEBUG
    import AppKit

    /// The capture's window has the look a user's has: the app in front and the window key or main.
    ///
    /// A run starts in the background. While another app has the front, macOS's cooperative activation refuses
    /// `NSApp.activate()` and `NSRunningApplication.activate(options:)`, so captures came out inactive for as long as
    /// someone else held the front, whatever their steps. `activate(ignoringOtherApps:)` still takes it from an ordinary
    /// app, but not from a system dialog (UserNotificationCenter): then the snapshot is reported as unfocused.
    @MainActor
    enum AutomationFocus {
        /// Seconds a snapshot waits for the front before it is taken anyway, and reported as unfocused.
        static let timeout = 2.0

        /// What a capture draws as active: traffic lights, default buttons and accent selection.
        static func isFocused(_ window: NSWindow) -> Bool {
            NSApp.isActive && (window.isMainWindow || window.isKeyWindow)
        }

        /// What the report says of a snapshot taken without the focus.
        static func whyUnfocused(_ window: NSWindow) -> String {
            guard !NSApp.isActive else { return "taken with the window unfocused: it is not key" }
            let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "another app"
            return "taken with the window unfocused: \(front) has the front and didn't give it up"
        }

        /// Takes the front from whichever app has it.
        static func activate() {
            guard !NSApp.isActive else { return }
            NSApp.activate(ignoringOtherApps: true)
        }

        /// Brings the window forward if it lost the focus, and waits for it. Answers whether it has it. A window under
        /// a modal panel stays where it is: the panel has the keyboard, as it does for a user.
        static func ensure(_ window: NSWindow) async -> Bool {
            if isFocused(window) { return true }
            activate()
            let deadline = ContinuousClock.now + .seconds(timeout)
            repeat {
                if NSApp.isActive, !window.isMainWindow, !window.isKeyWindow, NSApp.modalWindow == nil {
                    window.makeKeyAndOrderFront(nil)
                }
                if isFocused(window) {
                    // The title bar and the controls redraw in the active look on the next pass.
                    try? await Task.sleep(for: .milliseconds(100))
                    window.displayIfNeeded()
                    return true
                }
                try? await Task.sleep(for: .milliseconds(50))
            } while ContinuousClock.now < deadline
            return false
        }
    }
#endif
