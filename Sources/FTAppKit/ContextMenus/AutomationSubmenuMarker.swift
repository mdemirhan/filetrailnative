#if DEBUG
    import AppKit

    /// A native submenu can't be found in a window's views, so a scenario that opens one (`contextMenu` choosing
    /// "Open With", then `expectSheet` for "context submenu") is shown a one-point marker named for it in the window
    /// for a moment.
    @MainActor
    enum AutomationSubmenuMarker {
        private static weak var marker: NSView?

        static func show(in window: NSWindow?) {
            marker?.removeFromSuperview()
            guard let content = window?.contentView else { return }
            let view = NSView(frame: NSRect(x: content.bounds.midX, y: content.bounds.midY, width: 1, height: 1))
            view.setAccessibilityIdentifier("contextMenu.submenu")
            content.addSubview(view)
            marker = view
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak view] in view?.removeFromSuperview() }
        }
    }
#endif
