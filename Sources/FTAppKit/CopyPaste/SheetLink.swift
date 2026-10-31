// Port of .copy-paste-sheet-link (apps/desktop/src/renderer/styles.css): a button that reads as text in the accent
import AppKit
import FTFoundation

/// A link of the copy and paste sheets ("Show 3 new items", "Show all 1,200"): text in the accent, a button for the
/// keyboard (Tab reaches it; Return and Space press it).
@MainActor
final class SheetLink: TextControl {
    private static let font = ThemeFonts.sans(DesignTokens.typeScale.body)
    private var focused = false { didSet { needsDisplay = true } }

    init(title: String) {
        super.init(text: title, theme: AppearanceModel.shared.theme)
        font = Self.font
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        textColor = NSColor(theme.accent.solid)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var acceptsFirstResponder: Bool { isEnabled }

    var preferredSize: NSSize {
        let size = (title as NSString).size(withAttributes: [.font: Self.font])
        return NSSize(width: ceil(size.width), height: ceil(size.height))
    }

    override func applyTheme(_ theme: Theme) {
        super.applyTheme(theme)
        textColor = NSColor(theme.accent.solid)
    }

    override func drawChrome() {
        guard focused else { return }
        let radius = CGFloat(DesignTokens.radii.xs)
        let ring = NSBezierPath(
            roundedRect: bounds.insetBy(dx: -1.5, dy: -1.5), xRadius: radius + 1.5, yRadius: radius + 1.5)
        ring.lineWidth = CGFloat(DesignTokens.focusRingWidth)
        NSColor(theme.accent.solid.withAlpha(0.5)).setStroke()
        ring.stroke()
    }

    override func becomeFirstResponder() -> Bool {
        focused = NSApp.currentEvent?.type != .leftMouseDown
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        focused = false
        return super.resignFirstResponder()
    }

    override func mouseDown(with event: NSEvent) {
        if isEnabled, track() { perform() }
    }

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " || KeyCode.isReturn(event) {
            perform()
        } else {
            super.keyDown(with: event)
        }
    }
}

/// One line of text cut short with an ellipsis (`text-overflow: ellipsis; white-space: nowrap`).
@MainActor
func singleLineText(_ runs: [(String, NSFont, RGBA)], background: RGBA) -> NSAttributedString {
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byTruncatingTail
    let text = NSMutableAttributedString()
    for (string, font, color) in runs {
        let shown = color.alpha < 1 ? color.flattened(over: background) : color
        text.append(
            NSAttributedString(
                string: string,
                attributes: [
                    .font: font, .foregroundColor: NSColor(shown), .paragraphStyle: paragraph,
                    .reportedColor: NSColor(color),
                ]))
    }
    return text
}
