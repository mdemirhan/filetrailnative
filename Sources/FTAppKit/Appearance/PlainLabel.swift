// Port of the text of apps/desktop/src/renderer/styles.css in a see-through color (var(--text-secondary) and the like)
import AppKit

/// A label where a plain one has its text, with the text drawn once. An unbordered cell with no field editor draws text
/// in a color with alpha twice, so `rgba(0, 0, 0, 0.5)` comes out as 0.75. Any label in such a color wants this, or
/// `TextBoxField` when its frame starts at the text.
final class PlainLabel: TextBoxField {
    override class var cellClass: AnyClass? {
        get { PlainLabelCell.self }
        set {}
    }
}

final class PlainLabelCell: TextBoxCell {
    /// What a plain label's cell keeps between its frame and its text on each side.
    static let inset: CGFloat = 2

    override func textFrame(forBounds rect: NSRect) -> NSRect {
        rect.insetBy(dx: Self.inset, dy: 0)
    }
}
