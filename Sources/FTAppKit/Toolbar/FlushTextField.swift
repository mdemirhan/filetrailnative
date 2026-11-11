// Text drawn from its box's edge
import AppKit

/// A label whose text starts at its frame's edge and may reach the other edge: a `TextBoxField`, so a frame as wide as
/// the measured text draws all of it.
final class FlushTextField: TextBoxField {
    override class var cellClass: AnyClass? {
        get { FlushTextFieldCell.self }
        set {}
    }
}

final class FlushTextFieldCell: TextBoxCell {
    /// What a plain label's cell keeps between its frame and its text on each side.
    static let inset = 2.0
}
