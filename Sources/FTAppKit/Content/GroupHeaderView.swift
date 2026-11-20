// The title of a group of items (View ▸ Group By)
import AppKit
import FTFoundation

/// A group's title: the name alone, in the style of the sidebar's section headings (the small size, semibold, the
/// secondary color). In the List it is a row's height, lined up with the names; in the Icons view and the Compact List
/// it is over a hairline across the pane. It takes no clicks: a press on it is a press on the empty space it is in.
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

    private let title = NSTextField(labelWithString: "")
    private var style = Style.grid
    private var lineColor = NSColor.separatorColor
    private var backgroundColor = NSColor.clear

    override init(frame: NSRect) {
        super.init(frame: frame)
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 1
        title.setAccessibilityElement(false)
        addSubview(title)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityIdentifier("content.groupHeader")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    // A row or a pane gives its header its width after making it: the title is placed again at the new width.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    /// `background` is what a grid's header, held at the top over the items scrolling under it, is filled with.
    func configure(_ shown: ShownGroup, style: Style, theme: Theme, background: NSColor? = nil) {
        self.style = style
        let palette = theme.palette
        title.stringValue = shown.group.title
        title.font = ChromeColors.font(size: DesignTokens.typeScale.small, weight: 600)
        title.textColor = NSColor(palette.textSecondary)
        lineColor = NSColor(palette.borderLight)
        backgroundColor = style == .grid ? background ?? NSColor(palette.bgBase) : .clear
        // The days of Previous 7 Days and Previous 30 Days, which the name alone doesn't say.
        toolTip = shown.group.detail
        setAccessibilityLabel([shown.group.title, shown.group.detail].compactMap { $0 }.joined(separator: ", "))
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        // The width the header has, not the title's measured one: a title is cut short only where there is no room.
        let width = max(0, bounds.width - leadingInset - 8)
        let height = ceil(title.intrinsicContentSize.height)
        // A grid's title sits above its hairline; a row's in its middle.
        let y = style == .grid ? bounds.height - height - 6 : (bounds.height - height) / 2
        title.frame = NSRect(x: leadingInset, y: y, width: width, height: height)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard style == .grid else { return }
        backgroundColor.setFill()
        bounds.fill()
        lineColor.setFill()
        let scale = window?.backingScaleFactor ?? 2
        NSRect(x: 0, y: bounds.height - 1 / scale, width: bounds.width, height: 1 / scale).fill()
    }
}
