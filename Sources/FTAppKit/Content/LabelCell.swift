import AppKit

/// A table cell with an optional icon before its text, built in code.
/// Laid out by hand rather than with constraints: a folder of rows lays out
/// several times faster this way.
final class LabelCell: NSTableCellView {
    private let iconSize: CGFloat?

    init(identifier: NSUserInterfaceItemIdentifier, iconSize: CGFloat?, alignment: NSTextAlignment = .left) {
        self.iconSize = iconSize
        super.init(frame: .zero)
        self.identifier = identifier

        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = .byTruncatingMiddle
        text.alignment = alignment
        addSubview(text)
        textField = text

        if iconSize != nil {
            let image = NSImageView()
            image.imageScaling = .scaleProportionallyUpOrDown
            addSubview(image)
            imageView = image
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        var x: CGFloat = 2
        if let iconSize, let imageView {
            imageView.frame = NSRect(
                x: x, y: ((bounds.height - iconSize) / 2).rounded(), width: iconSize, height: iconSize)
            x += iconSize + 6
        }
        guard let textField else { return }
        let height = textField.intrinsicContentSize.height
        textField.frame = NSRect(
            x: x, y: ((bounds.height - height) / 2).rounded(),
            width: max(0, bounds.width - x - 2), height: height)
    }
}
