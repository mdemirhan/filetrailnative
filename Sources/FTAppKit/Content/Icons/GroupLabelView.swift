// The label over Previews that names the group on screen (View ▸ Group By)
import AppKit
import FTFoundation

/// The name of the group whose files are on screen in Previews, which draws no header rows: on glass at the pane's
/// top left corner, in the style of the group titles of the other views, with "2 of 3" at 1 at a time. It takes no
/// clicks.
final class GroupLabelView: NSView {
    private let text = NSTextField(labelWithString: "")
    private static let padding = NSSize(width: 12, height: 5)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        text.setAccessibilityElement(false)
        addSubview(text)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityIdentifier("previews.groupLabel")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(title: String, place: String?, theme: Theme) {
        let font = ChromeColors.font(size: DesignTokens.typeScale.small, weight: 600)
        let line = NSMutableAttributedString(
            string: title, attributes: [.font: font, .foregroundColor: NSColor(theme.palette.textPrimary)])
        if let place {
            line.append(
                NSAttributedString(
                    string: "  \(place)",
                    attributes: [
                        .font: ChromeColors.font(size: DesignTokens.typeScale.small),
                        .foregroundColor: NSColor(theme.palette.textSecondary),
                    ]))
        }
        text.attributedStringValue = line
        setAccessibilityLabel(place.map { "\(title), \($0)" } ?? title)
        let size = text.intrinsicContentSize
        setFrameSize(
            NSSize(
                width: ceil(size.width) + 4 + Self.padding.width * 2,
                height: ceil(size.height) + Self.padding.height * 2))
        needsLayout = true
    }

    override var fittingSize: NSSize { frame.size }

    override func layout() {
        super.layout()
        text.frame = bounds.insetBy(dx: Self.padding.width, dy: Self.padding.height)
        GlassSurface.installFloating(in: self, radius: bounds.height / 2)
    }
}
