// Port of the .pane-resizer of apps/desktop/src/renderer/components/ExplorerWorkspace.tsx, its drag in
// hooks/useExplorerPaneLayout.ts and its keys in hooks/useExplorerNavigationController.ts:2072-2086
import AppKit
import FTFoundation

/// The 8 pt gutter between two panes: a 1 pt hairline in its middle (the accent's border color under the pointer),
/// a resize cursor, a drag that moves the pane's edge, and ←/→ (12 pt, 24 with ⇧) once it has the keyboard. The tree's
/// is the sidebar's own edge instead: the sidebar's material shows all through it (D-017).
final class PaneResizerView: NSView {
    let pane: PaneWidths.Pane
    /// Where the pointer went down, in window coordinates.
    var onDragStart: (_ x: Double) -> Void = { _ in }
    var onDrag: (_ x: Double) -> Void = { _ in }
    var onDragEnd: () -> Void = {}
    /// A key step: the width change, positive to widen.
    var onNudge: (_ delta: Double) -> Void = { _ in }
    /// Tab or Shift-Tab, when this resizer has somewhere for the keyboard to go.
    var onTab: ((_ backward: Bool) -> Void)?
    /// The tree's resizer: nothing of its own at rest, and under the pointer the accent's line on the sidebar's edge.
    var isSidebarEdge = false {
        didSet { needsDisplay = true }
    }
    /// Where the panes start, in this view's coordinates: the system's title bar is above it, so this gutter draws
    /// nothing there (D-015). The tree's resizer runs from the window's top; the Info panel's starts at the panes.
    var panesTop: Double = 0 {
        didSet { if panesTop != oldValue { needsDisplay = true } }
    }
    private var hovered = false {
        didSet { needsDisplay = true }
    }

    init(pane: PaneWidths.Pane, identifier: String, label: String) {
        self.pane = pane
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
        setAccessibilityIdentifier(identifier)
        setAccessibilityLabel(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var focusRingType: NSFocusRingType {
        get { .none }
        set {}
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(
            NSTrackingArea(
                rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    override func mouseDown(with event: NSEvent) {
        onDragStart(event.locationInWindow.x)
        NSCursor.resizeLeftRight.push()
    }

    override func mouseDragged(with event: NSEvent) {
        onDrag(event.locationInWindow.x)
    }

    override func mouseUp(with event: NSEvent) {
        NSCursor.pop()
        onDragEnd()
    }

    override func keyDown(with event: NSEvent) {
        let layout = WindowMetrics.standard.explorer
        let step = event.modifierFlags.contains(.shift) ? layout.paneResizeStepLarge : layout.paneResizeStep
        // The tree grows to the right, the Info panel to the left.
        let grows: Double = pane == .tree ? 1 : -1
        switch event.keyCode {
        case 123: onNudge(-step * grows)
        case 124: onNudge(step * grows)
        case 48:
            if let onTab, event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
                onTab(event.modifierFlags.contains(.shift))
            } else {
                super.keyDown(with: event)
            }
        default: super.keyDown(with: event)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let palette = ChromeColors.palette(for: self)
        let half = bounds.width / 2
        let height = max(0, bounds.height - panesTop)
        if isSidebarEdge {
            guard hovered else { return }
            ChromeColors.color(ChromeColors.accent(for: self).border).setFill()
            NSRect(x: bounds.maxX - 1, y: panesTop, width: 1, height: height).fill()
            return
        }
        // The opaque part of the window.
        ChromeColors.contentBackground(for: self).setFill()
        NSRect(x: 0, y: panesTop, width: bounds.width, height: height).fill()
        let line = hovered ? ChromeColors.accent(for: self).border : palette.border
        ChromeColors.color(line).setFill()
        NSRect(x: half - 0.5, y: panesTop, width: 1, height: height).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
