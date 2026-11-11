import AppKit
import FTFoundation

/// The 8 pt gutter between two panes: a 1 pt hairline in its middle (the accent's border color under the pointer),
/// a resize cursor, a drag that moves the pane's edge, and ←/→ (12 pt, 24 with ⇧) once it has the keyboard. The tree's
/// is the sidebar's own edge instead: the sidebar's material shows all through it.
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
    /// The tree's resizer: nothing of its own at rest, and under the pointer the accent's line on the sidebar's edge, from
    /// the window's top.
    var isSidebarEdge = false {
        didSet { needsDisplay = true }
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
        if isSidebarEdge {
            guard hovered else { return }
            ChromeColors.color(ChromeColors.accent(for: self).border).setFill()
            NSRect(x: bounds.maxX - 1, y: 0, width: 1, height: bounds.height).fill()
            return
        }
        let line = hovered ? ChromeColors.accent(for: self).border : palette.border
        ChromeColors.color(line).setFill()
        NSRect(x: half - 0.5, y: 0, width: 1, height: bounds.height).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
