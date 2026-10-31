// No TypeScript source: the system's popover for the panels the original draws itself (ClipboardButton, FavoriteIconPicker)
import AppKit

/// An `NSPopover` under a control. The app closes it (a press outside the control's own toggle has to go on to where it
/// was pressed), and the window it hangs from keeps the keyboard. A window that isn't on screen (a windowless test) shows
/// nothing, and the view is only sized.
@MainActor
final class AnchoredPopover {
    private let popover = NSPopover()
    private let content: NSView

    init(content: NSView, size: NSSize) {
        self.content = content
        let controller = NSViewController()
        controller.view = content
        popover.contentViewController = controller
        popover.behavior = .applicationDefined
        popover.animates = false
        setSize(size)
    }

    /// The window it is shown in, while it is.
    var window: NSWindow? { popover.isShown ? content.window : nil }

    func setSize(_ size: NSSize) {
        popover.contentSize = size
        if !popover.isShown {
            content.frame.size = size
            content.layoutSubtreeIfNeeded()
        }
    }

    /// Under `anchor`, or, when it isn't in view (in the toolbar's » menu), under the top right of `window`'s content.
    func show(from anchor: NSView, in window: NSWindow) {
        guard window.isVisible else { return }
        if anchor.window === window, !anchor.isHiddenOrHasHiddenAncestor {
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: anchor.isFlipped ? .maxY : .minY)
        } else if let host = window.contentView {
            let corner = NSRect(x: host.bounds.maxX - 40, y: host.isFlipped ? 0 : host.bounds.maxY, width: 1, height: 1)
            popover.show(relativeTo: corner, of: host, preferredEdge: host.isFlipped ? .maxY : .minY)
        }
    }

    /// The control moved (the page scrolled).
    func reposition(for anchor: NSView) {
        guard popover.isShown else { return }
        popover.positioningRect = anchor.bounds
    }

    func close() {
        popover.close()
    }
}
