// The title of a group of items (View ▸ Group By)
import AppKit
import FTFoundation

/// A group's title: the name alone, in the style of the sidebar's section headings (the small size, semibold, the
/// system's secondary label color, as Finder's, so a title is told from an item). The view draws the text itself: a
/// label draws a color that is partly clear darker than it is, nearly as dark as a name. In the List it is a row's
/// height, lined up with the names, under the space that sets its group apart from the one above; in the Icons view it
/// is over a hairline across the pane, and in the Compact List over one across its column. It takes no clicks: a press
/// on it is a press on the empty space it is in.
final class GroupHeaderView: NSView {
    enum Style {
        case list
        case grid
    }

    /// The height of a grid's header, its hairline included.
    static let gridHeight: CGFloat = 40

    /// Where the title starts.
    var leadingInset: CGFloat = 12 {
        didSet { needsLayout = true }
    }

    /// The List's space above the title, in the title's own row: the title is in the middle of what is left.
    var spaceAbove: CGFloat = 0 {
        didSet { if spaceAbove != oldValue { needsLayout = true } }
    }

    /// The color of the title.
    static let titleColor = NSColor.secondaryLabelColor
    /// The color of a title that goes on with its group from the column before: a step fainter.
    static let continuedTitleColor = NSColor.tertiaryLabelColor

    private var title = ""
    private var drawnColor = GroupHeaderView.titleColor
    private var titleFont = ChromeColors.font(size: DesignTokens.typeScale.small, weight: 600)
    private var style = Style.grid
    private var lineColor = NSColor.separatorColor
    private var backgroundColor = NSColor.clear

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityIdentifier("content.groupHeader")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    // A row or a pane gives its header its width after making it: the title is drawn again at the new width.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    /// `background` is what a grid's header, held at the top over the items scrolling under it, is filled with. A
    /// header that goes on with its group from the column before (`continued`, the Compact List's) is fainter.
    func configure(
        _ shown: ShownGroup, style: Style, theme: Theme, background: NSColor? = nil, continued: Bool = false
    ) {
        self.style = style
        let palette = theme.palette
        title = shown.group.title
        titleFont = ChromeColors.font(size: DesignTokens.typeScale.small, weight: continued ? 400 : 600)
        drawnColor = continued ? Self.continuedTitleColor : Self.titleColor
        lineColor = NSColor(palette.borderLight)
        backgroundColor = style == .grid ? background ?? NSColor(palette.bgBase) : .clear
        // The days of Previous 7 Days and Previous 30 Days, which the name alone doesn't say.
        toolTip = shown.group.detail
        setAccessibilityLabel([shown.group.title, shown.group.detail].compactMap { $0 }.joined(separator: ", "))
        needsLayout = true
        needsDisplay = true
    }

    /// The title as it is drawn: one line, cut short with an ellipsis only where there is no room.
    var titleText: NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        return NSAttributedString(
            string: title,
            attributes: [.font: titleFont, .foregroundColor: drawnColor, .paragraphStyle: paragraph])
    }

    /// Where the title is drawn.
    var titleFrame: NSRect {
        let text = titleText
        let height = ceil(text.size().height)
        // A grid's title sits above its hairline; a row's in its middle.
        let y = style == .grid ? bounds.height - height - 6 : spaceAbove + (bounds.height - spaceAbove - height) / 2
        return NSRect(x: leadingInset + 2, y: y, width: max(0, bounds.width - leadingInset - 12), height: height)
    }

    override func layout() {
        super.layout()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if style == .grid {
            backgroundColor.setFill()
            bounds.fill()
            lineColor.setFill()
            let scale = window?.backingScaleFactor ?? 2
            NSRect(x: 0, y: bounds.height - 1 / scale, width: bounds.width, height: 1 / scale).fill()
        }
        titleText.draw(with: titleFrame, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}
