// Port of the text boxes of apps/desktop/src/renderer/styles.css (.toolbar-title, .toolbar-menu-label,
// .history-menu-name): text drawn from its box's edge
import AppKit

/// A label whose text starts at its frame's edge and may reach the other edge, as a CSS text box does. A plain label
/// keeps 2 pt between its frame and its text on each side, so a frame laid out from the original's boxes would draw its
/// text 2 pt in, and cut it 2 pt short.
final class FlushTextField: NSTextField {
    override class var cellClass: AnyClass? {
        get { FlushTextFieldCell.self }
        set {}
    }
}

final class FlushTextFieldCell: NSTextFieldCell {
    /// What a label's cell keeps between its frame and its text on each side.
    static let inset = 2.0

    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        super.drawingRect(forBounds: rect.insetBy(dx: -Self.inset, dy: 0))
    }
}
