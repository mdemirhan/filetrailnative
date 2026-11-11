import AppKit
import FTFoundation

/// The icon of a topic, a system symbol.
enum HelpTopicIcon {
    static func symbolName(for id: HelpTopicID) -> String {
        switch id {
        case .navigation: "location.north.circle"
        case .files: "document"
        case .search: CommandIcon.search.symbolName
        case .views: CommandIcon.folderTree.symbolName
        case .shortcuts: "keyboard"
        }
    }

    /// Draws the icon as large as fits in a square at `origin`, `size` wide.
    static func draw(_ id: HelpTopicID, at origin: NSPoint, size: CGFloat, color: NSColor) {
        SymbolGlyph.draw(
            symbolName(for: id), in: NSRect(x: origin.x, y: origin.y, width: size, height: size), color: color)
    }
}

/// A topic in the sidebar: 28 tall, an icon and the title; the page on screen is marked.
final class HelpTopicButton: TextControl {
    let topic: HelpTopic
    var isCurrent = false {
        didSet {
            applyStyle()
            setAccessibilityValue(isCurrent ? "page" : nil)
        }
    }

    static let height = 28.0
    private static let iconSize = 15.0

    init(topic: HelpTopic, theme: Theme) {
        self.topic = topic
        super.init(text: topic.title, theme: theme)
        (cell as? ThemedTextCell)?.leadingInset = 8 + CGFloat(Self.iconSize) + 8
        setAccessibilityRole(.button)
        setAccessibilityLabel(topic.title)
        setAccessibilityIdentifier("help.topic")
        applyStyle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isHovering: Bool {
        get { super.isHovering }
        set {
            super.isHovering = newValue
            applyStyle()
        }
    }

    private func applyStyle() {
        font = titleFont
        let palette = theme.palette
        textColor = NSColor(isCurrent || super.isHovering ? palette.textPrimary : palette.textSecondary)
    }

    private var titleFont: NSFont { ThemeFonts.sans(DesignTokens.typeScale.body, isCurrent ? .semibold : .regular) }

    /// padding 0 8; the icon, 8 of gap, the title.
    var preferredWidth: CGFloat {
        8 + CGFloat(Self.iconSize) + 8 + ceil((topic.title as NSString).size(withAttributes: [.font: titleFont]).width)
            + 8
    }

    override func applyTheme(_ theme: Theme) {
        super.applyTheme(theme)
        applyStyle()
    }

    override func drawChrome() {
        let palette = theme.palette
        let radius = CGFloat(DesignTokens.radii.control)
        if isCurrent {
            NSColor(palette.bgActiveInactive).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        } else if isHovering {
            NSColor(palette.bgHover).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        }
        let textColor = isCurrent || isHovering ? palette.textPrimary : palette.textSecondary
        let iconColor = isCurrent ? theme.accent.solid : textColor
        HelpTopicIcon.draw(
            topic.id, at: NSPoint(x: 8, y: (bounds.height - CGFloat(Self.iconSize)) / 2), size: CGFloat(Self.iconSize),
            color: NSColor(iconColor))
    }

    override func mouseDown(with event: NSEvent) {
        perform()
    }
}
