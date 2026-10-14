// Port of the explorer window's frame in apps/desktop/src/main/main.ts (titleBarStyle "hiddenInset",
// trafficLightPosition { x: 14, y: 16 }) and the toolbar band of styles.css (.window-toolbar, min-height 52)
import AppKit
import FTFoundation

/// The window's frame as the original has it: no title bar of its own, no system toolbar and no lines; the app's
/// toolbar is drawn in the window's top 52 points, the traffic lights sit 14 points in and 16 down, and the system
/// tab bar (D-001) shows under the toolbar band, where the original's tab strip is.
///
/// A system `NSToolbar` is not used: its band is 66 points tall on this macOS (40 compact), its items keep insets
/// and an overflow of their own, and its sidebar separator draws a line through the title bar. The toolbar is a view
/// of the window's content instead, and the title bar's container is made as tall as the band.
@MainActor
enum WindowChrome {
    /// `trafficLightPosition`.
    static let trafficLights = NSPoint(x: 14, y: 16)

    static func configure(_ window: NSWindow) {
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.toolbar = nil
    }

    /// The title bar's own height (32 on macOS 26 and later), without a tab bar.
    static func titlebarHeight(_ window: NSWindow) -> Double {
        var mask = window.styleMask
        mask.remove(.fullSizeContentView)
        let frame = window.frame
        return frame.height - NSWindow.contentRect(forFrameRect: frame, styleMask: mask).height
    }

    /// The system tab bar's height while it shows, else 0.
    static func tabBarHeight(_ window: NSWindow) -> Double {
        guard !window.styleMask.contains(.fullScreen), window.tabGroup?.isTabBarVisible == true else { return 0 }
        let natural = window.frame.height - window.contentLayoutRect.maxY
        return max(0, natural - titlebarHeight(window))
    }

    private static func container(_ window: NSWindow) -> NSView? {
        window.standardWindowButton(.closeButton)?.superview?.superview
    }

    /// Makes the title bar container as tall as the toolbar band (plus the tab bar), so the tab bar shows under the
    /// band, and puts the traffic lights where the original puts them. AppKit sets the container back on every
    /// layout of the frame, so the window's content calls this as it lays out.
    static func apply(_ window: NSWindow, bandHeight: Double) {
        guard !window.styleMask.contains(.fullScreen), let container = container(window) else { return }
        let height = bandHeight + tabBarHeight(window)
        var frame = container.frame
        if abs(frame.height - height) > 0.5 {
            frame.size.height = height
            frame.origin.y = (container.superview?.bounds.height ?? window.frame.height) - height
            container.frame = frame
        }
        let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        guard let close = window.standardWindowButton(.closeButton), let titlebar = close.superview,
            let mini = window.standardWindowButton(.miniaturizeButton)
        else { return }
        let spacing = mini.frame.minX - close.frame.minX
        for (index, type) in buttons.enumerated() {
            guard let button = window.standardWindowButton(type) else { continue }
            let top = trafficLights.y
            let y = titlebar.isFlipped ? top : titlebar.bounds.height - top - button.frame.height
            let origin = NSPoint(x: trafficLights.x + Double(index) * spacing, y: y)
            if button.frame.origin != origin { button.setFrameOrigin(origin) }
        }
    }
}
