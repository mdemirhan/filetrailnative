// Views that draw with the app's palette (apps/desktop/src/renderer/styles.css), redrawn when the theme changes
import AppKit
import FTFoundation

/// A view that draws with the theme and is told when it changes.
@MainActor
public protocol ThemeApplying: AnyObject {
    func applyTheme(_ theme: Theme)
}

extension NSView {
    /// Gives `theme` to this view and every view below it that draws with it, and has them redraw.
    public func applyTheme(_ theme: Theme, throughSubviews: Bool) {
        (self as? any ThemeApplying)?.applyTheme(theme)
        needsDisplay = true
        if throughSubviews { for child in subviews { child.applyTheme(theme, throughSubviews: true) } }
    }
}

/// A flipped box with a themed fill, an optional rounded border and hairlines along its edges.
public class ThemedView: NSView, ThemeApplying {
    /// A color of the palette or the accent, for the theme at hand.
    public typealias ColorProvider = @MainActor @Sendable (Theme) -> RGBA

    public enum Edge: Hashable, Sendable { case top, bottom, leading, trailing }

    public final var fill: ColorProvider? = nil { didSet { needsDisplay = true } }
    /// Hairlines of 1 pt along the edges.
    public final var edges: [Edge: ColorProvider] = [:] { didSet { needsDisplay = true } }
    /// A 1 pt border inside the bounds, with this corner radius (zero radius draws a square border).
    public final var borderColor: ColorProvider? = nil { didSet { needsDisplay = true } }
    public final var cornerRadius: CGFloat = 0 { didSet { needsDisplay = true } }
    public private(set) var theme: Theme

    public init(frame: NSRect = .zero, theme: Theme = AppearanceModel.shared.theme) {
        self.theme = theme
        super.init(frame: frame)
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    public override var isFlipped: Bool { true }
    public override var isOpaque: Bool { false }

    public func applyTheme(_ theme: Theme) {
        self.theme = theme
        needsDisplay = true
    }

    public override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius)
        if let color = fill?(theme) {
            NSColor(color).setFill()
            shape.fill()
        }
        for (edge, provider) in edges {
            NSColor(provider(theme)).setFill()
            switch edge {
            case .top: NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
            case .bottom: NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
            case .leading: NSRect(x: 0, y: 0, width: 1, height: bounds.height).fill()
            case .trailing: NSRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height).fill()
            }
        }
        if let color = borderColor?(theme) {
            let inset = NSBezierPath(
                roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: max(0, cornerRadius - 0.5),
                yRadius: max(0, cornerRadius - 0.5))
            inset.lineWidth = 1
            NSColor(color).setStroke()
            inset.stroke()
        }
    }
}

/// A text cell with no inset, so the text starts at the left edge of its frame as a web page's does.
final class ThemedTextCell: NSTextFieldCell {
    /// Space before the text, for a control that draws something there.
    var leadingInset: CGFloat = 0
    /// The text is centered in the frame's height (a control), instead of starting at its top.
    var verticallyCentered = false

    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        // The cell draws its text 2 pt in from this rectangle on each side; the rectangle is made wider to cancel it.
        var area = rect.insetBy(dx: -2, dy: 0)
        area.origin.x += leadingInset
        area.size.width = max(0, area.width - leadingInset)
        if verticallyCentered {
            let height = ceil(attributedStringValue.boundingRect(with: NSSize(width: 10_000, height: 10_000), options: [.usesFontLeading]).height)
            area.origin.y += ((area.height - height) / 2).rounded()
            area.size.height = height
        }
        return area
    }

    override func titleRect(forBounds rect: NSRect) -> NSRect { drawingRect(forBounds: rect) }

    override func cellSize(forBounds rect: NSRect) -> NSSize {
        // The text itself, wrapped to the width: no border or inset around it.
        let size = attributedStringValue.boundingRect(
            with: NSSize(width: rect.width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin])
        return NSSize(width: ceil(size.width), height: size.height)
    }
}

/// Text that is rebuilt from the theme: one line or wrapped, selectable when it is worth copying.
public final class ThemedText: NSTextField, ThemeApplying {
    public override class var cellClass: AnyClass? {
        get { ThemedTextCell.self }
        set {}
    }

    /// The text as the theme draws it.
    public var content: @MainActor (Theme) -> NSAttributedString {
        didSet { applyTheme(AppearanceModel.shared.theme) }
    }

    public init(wrapping: Bool = false, selectable: Bool = false, content: @escaping @MainActor (Theme) -> NSAttributedString) {
        self.content = content
        super.init(frame: .zero)
        isEditable = false
        isBordered = false
        drawsBackground = false
        isSelectable = selectable
        allowsEditingTextAttributes = false
        focusRingType = .none
        lineBreakMode = wrapping ? .byWordWrapping : .byClipping
        usesSingleLineMode = !wrapping
        cell?.wraps = wrapping
        cell?.isScrollable = false
        applyTheme(AppearanceModel.shared.theme)
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    public override var isFlipped: Bool { true }

    public func applyTheme(_ theme: Theme) {
        let text = content(theme)
        // The field's own font and color say what it shows (accessibility, the geometry dumps); the string keeps its runs.
        if text.length > 0 {
            font = text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont ?? font
            textColor =
                text.attribute(.reportedColor, at: 0, effectiveRange: nil) as? NSColor
                ?? text.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor ?? textColor
        }
        attributedStringValue = text
    }

    /// The height the text takes at this width, as CSS lays it out (a line of 19.5 stays 19.5).
    public func height(forWidth width: CGFloat) -> CGFloat {
        let size = attributedStringValue.boundingRect(
            with: NSSize(width: max(1, width), height: CGFloat.greatestFiniteMagnitude), options: [.usesLineFragmentOrigin])
        return size.height
    }

    /// The width the text takes on one line.
    public var naturalWidth: CGFloat {
        ceil(attributedStringValue.boundingRect(with: NSSize(width: 10_000, height: 10_000), options: []).width)
    }
}

extension NSAttributedString.Key {
    /// The color a run is meant to have, with its alpha: the run itself is drawn in that color flattened onto its
    /// background (AppKit draws a translucent text color of an attributed string as an opaque one).
    static let reportedColor = NSAttributedString.Key("filetrail.reportedColor")
}

extension RGBA {
    /// This color over an opaque `background`, as one opaque color.
    public func flattened(over background: RGBA) -> RGBA {
        RGBA(
            red: red * alpha + background.red * (1 - alpha), green: green * alpha + background.green * (1 - alpha),
            blue: blue * alpha + background.blue * (1 - alpha))
    }
}

/// Styles for the text of the stylesheet: font, color and line height.
public struct TextStyle {
    public var font: NSFont
    public var color: @MainActor (Theme) -> RGBA
    /// What the text lies on, for a translucent color to be flattened onto; the page's background by default.
    public var background: @MainActor (Theme) -> RGBA = { $0.palette.bgBase }
    /// CSS `line-height` as a multiple of the font size; nil is the font's own.
    public var lineHeight: Double?
    public var alignment: NSTextAlignment = .left
    /// CSS `letter-spacing` in points.
    public var kern: Double = 0

    public init(
        font: NSFont, color: @escaping @MainActor (Theme) -> RGBA, lineHeight: Double? = nil,
        alignment: NSTextAlignment = .left, kern: Double = 0
    ) {
        self.font = font
        self.color = color
        self.lineHeight = lineHeight
        self.alignment = alignment
        self.kern = kern
    }

    @MainActor
    public func attributes(_ theme: Theme) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byWordWrapping
        if let lineHeight {
            let height = CGFloat(Double(font.pointSize) * lineHeight)
            paragraph.minimumLineHeight = height
            paragraph.maximumLineHeight = height
        }
        let wanted = color(theme)
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor(wanted.alpha < 1 ? wanted.flattened(over: background(theme)) : wanted),
            .paragraphStyle: paragraph, .reportedColor: NSColor(wanted),
        ]
        if kern != 0 { attributes[.kern] = kern }
        return attributes
    }

    /// With CSS's half-leading: a line box taller than the glyphs puts the extra above and below the text equally.
    @MainActor
    public func string(_ text: String, _ theme: Theme) -> NSAttributedString {
        var attributes = attributes(theme)
        if let lineHeight {
            // The line a font takes by itself: the extra of a taller line goes half above and half below, as in CSS.
            let natural = NSAttributedString(string: "H", attributes: [.font: font])
                .boundingRect(with: NSSize(width: 100, height: 100), options: [.usesLineFragmentOrigin]).height
            let extra = CGFloat(Double(font.pointSize) * lineHeight) - natural
            if abs(extra) > 0.01 { attributes[.baselineOffset] = extra / 2 }
        }
        return NSAttributedString(string: text, attributes: attributes)
    }
}

extension ThemedText {
    /// A label with a single style.
    public convenience init(_ text: String, style: TextStyle, wrapping: Bool = false, selectable: Bool = false) {
        self.init(wrapping: wrapping, selectable: selectable) { style.string(text, $0) }
    }
}

