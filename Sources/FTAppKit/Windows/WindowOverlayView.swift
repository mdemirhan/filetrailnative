// Port of the stacking of apps/desktop/src/renderer/styles.css: the app's menus and tooltips (z-index over
// .window-toolbar) and the window-toolbar header taking its right-click (ExplorerWorkspace.tsx handleToolbarContextMenu)
import AppKit

/// The explorer window's top layer, over the title bar and the system toolbar the window's frame draws above its
/// content. The app's menus and tooltips go here, so the part of them in the toolbar band is drawn over the band and
/// takes its presses, as the original's sit over its toolbar.
///
/// Anything else goes through to the views below: the toolbar's items and its empty room are the system's.
final class WindowOverlayView: NSView {
    override var isFlipped: Bool { true }

    /// Puts the layer over the frame's other views of `window` (once).
    @discardableResult
    static func install(in window: NSWindow) -> WindowOverlayView? {
        guard let content = window.contentView, let frameView = content.superview else { return nil }
        let overlay =
            frameView.subviews.lazy.compactMap { $0 as? WindowOverlayView }.first
            ?? WindowOverlayView(frame: content.frame)
        overlay.autoresizingMask = [.width, .height]
        overlay.raise(over: content)
        return overlay
    }

    /// The window's layer, if it has one, left where it is.
    static func existing(in window: NSWindow) -> WindowOverlayView? {
        window.contentView?.superview?.subviews.lazy.compactMap { $0 as? WindowOverlayView }.first
    }

    /// The window's layer, kept over the frame's other views: nil in a window that has none.
    @discardableResult
    static func host(of window: NSWindow) -> WindowOverlayView? {
        guard let content = window.contentView, let frameView = content.superview,
            let overlay = frameView.subviews.lazy.compactMap({ $0 as? WindowOverlayView }).first
        else { return nil }
        overlay.raise(over: content)
        return overlay
    }

    /// Back over the frame's other views and over the content, which AppKit may have put back on top of it (a tab
    /// bar coming or going, the toolbar's views made again). `positioned:` keeps AppKit from warning about an unknown
    /// view of the frame.
    func raise(over content: NSView) {
        guard let frameView = content.superview else { return }
        if frame != content.frame { frame = content.frame }
        if superview !== frameView || frameView.subviews.last !== self {
            frameView.addSubview(self, positioned: .above, relativeTo: nil)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, frame.contains(point) else { return nil }
        let local = convert(point, from: superview)
        for view in subviews.reversed() {
            if let hit = view.hitTest(local) { return hit }
        }
        return nil
    }

    // MARK: Presses over the title bar

    /// The view a forwarded press went to, which gets the drags and the release that follow.
    private var pressTarget: NSView?

    /// An event on its way to the window: true when it was handed to the layer's views here. AppKit takes a press in
    /// the title bar as one on the title bar, never asking the window's hit view, so a press on a menu, a tooltip or
    /// there (or on a menu anywhere) goes straight to the view under it, and its drags and release
    /// follow it. The traffic lights, the tab bar and everything else are AppKit's.
    func forward(_ event: NSEvent) -> Bool {
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            // A press whose release never came (a right-click that was only resolved) must not take the next release.
            pressTarget = nil
            // A sheet or a modal window keeps the window's presses from it, as AppKit does.
            guard let window = event.window ?? self.window, window === self.window, window.attachedSheet == nil,
                NSApp.modalWindow == nil || NSApp.modalWindow === window, let frameView = superview,
                let hit = hitTest(frameView.convert(event.locationInWindow, from: nil))
            else { return false }
            if !window.isKeyWindow, window.canBecomeKey { window.makeKey() }
            pressTarget = hit
            switch event.type {
            case .leftMouseDown:
                // A field already editing keeps its editor (the hit view when the press is on the text).
                let editing = (window.firstResponder as? NSText)?.delegate === hit
                if hit.acceptsFirstResponder, window.firstResponder !== hit, !editing {
                    window.makeFirstResponder(hit)
                }
                hit.mouseDown(with: event)
            case .rightMouseDown: hit.rightMouseDown(with: event)
            default: hit.otherMouseDown(with: event)
            }
            return true
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            guard let target = pressTarget else { return false }
            switch event.type {
            case .leftMouseDragged: target.mouseDragged(with: event)
            case .rightMouseDragged: target.rightMouseDragged(with: event)
            default: target.otherMouseDragged(with: event)
            }
            return true
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            guard let target = pressTarget else { return false }
            pressTarget = nil
            switch event.type {
            case .leftMouseUp: target.mouseUp(with: event)
            case .rightMouseUp: target.rightMouseUp(with: event)
            default: target.otherMouseUp(with: event)
            }
            return true
        default:
            return false
        }
    }
}
