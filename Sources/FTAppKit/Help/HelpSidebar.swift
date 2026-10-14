// Port of the topic buttons and icons of apps/desktop/src/renderer/components/HelpView.tsx (.help-topic, .help-topic-icon)
import AppKit
import FTFoundation

/// The icon of a topic, drawn from the same 24 by 24 artwork as the original: strokes of 1.7, round caps and joins.
enum HelpTopicIcon {
    static func path(for id: HelpTopicID) -> NSBezierPath {
        let path = NSBezierPath()
        func line(_ points: [(Double, Double)], close: Bool = false) {
            guard let first = points.first else { return }
            path.move(to: NSPoint(x: first.0, y: first.1))
            for point in points.dropFirst() { path.line(to: NSPoint(x: point.0, y: point.1)) }
            if close { path.close() }
        }
        func ellipse(_ cx: Double, _ cy: Double, _ r: Double) {
            path.append(NSBezierPath(ovalIn: NSRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r)))
        }
        /// A quarter circle from `from` to `to` around `center`, as a curve toward the square's corner.
        func corner(from: (Double, Double), to: (Double, Double), center: (Double, Double)) {
            let k = 0.5523
            let start = NSPoint(x: from.0, y: from.1)
            let end = NSPoint(x: to.0, y: to.1)
            let meeting =
                from.1 == center.1 ? NSPoint(x: from.0, y: to.1) : NSPoint(x: to.0, y: from.1)
            path.curve(
                to: end,
                controlPoint1: NSPoint(x: start.x + (meeting.x - start.x) * k, y: start.y + (meeting.y - start.y) * k),
                controlPoint2: NSPoint(x: end.x + (meeting.x - end.x) * k, y: end.y + (meeting.y - end.y) * k))
        }
        switch id {
        case .navigation:
            ellipse(12, 12, 8.5)
            line([(15.5, 8.5), (13.5, 13.5), (8.5, 15.5), (10.5, 10.5)], close: true)
        case .files:
            path.move(to: NSPoint(x: 8, y: 3.5))
            path.line(to: NSPoint(x: 14, y: 3.5))
            path.line(to: NSPoint(x: 18, y: 7.5))
            path.line(to: NSPoint(x: 18, y: 17))
            corner(from: (18, 17), to: (16.5, 18.5), center: (16.5, 17))
            path.line(to: NSPoint(x: 8, y: 18.5))
            corner(from: (8, 18.5), to: (6.5, 17), center: (8, 17))
            path.line(to: NSPoint(x: 6.5, y: 5))
            corner(from: (6.5, 5), to: (8, 3.5), center: (8, 5))
            path.close()
            line([(14, 3.5), (14, 8), (18, 8)])
        case .search:
            ellipse(11, 11, 6.5)
            line([(16, 16), (20.5, 20.5)])
        case .views:
            path.append(NSBezierPath(roundedRect: NSRect(x: 3.5, y: 5, width: 17, height: 14), xRadius: 2.5, yRadius: 2.5))
            line([(9.5, 5), (9.5, 19)])
        case .shortcuts:
            path.append(NSBezierPath(roundedRect: NSRect(x: 2.5, y: 6.5, width: 19, height: 11), xRadius: 2.5, yRadius: 2.5))
            for x in [6.5, 10, 13.5, 17] { line([(x, 10.5), (x + 0.01, 10.5)]) }
            line([(8, 14), (16, 14)])
        }
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        return path
    }

    /// Draws the icon in a square at `origin`, `size` wide.
    static func draw(_ id: HelpTopicID, at origin: NSPoint, size: CGFloat, color: NSColor) {
        let path = path(for: id)
        let scale = size / 24
        var transform = AffineTransform()
        transform.translate(x: origin.x, y: origin.y)
        transform.scale(scale)
        path.transform(using: transform)
        path.lineWidth = 1.7 * scale
        color.setStroke()
        path.stroke()
    }
}

/// A topic in the sidebar: 28 tall, an icon and the title; the page on screen is marked.
final class HelpTopicButton: NSControl, ThemeApplying {
    let topic: HelpTopic
    var isCurrent = false { didSet { needsDisplay = true; setAccessibilityValue(isCurrent ? "page" : nil) } }
    private(set) var theme: Theme
    private var isHovering = false { didSet { needsDisplay = true } }
    private var trackingArea: NSTrackingArea?

    static let height = 28.0
    private static let iconSize = 15.0

    init(topic: HelpTopic, theme: Theme) {
        self.topic = topic
        self.theme = theme
        super.init(frame: .zero)
        setAccessibilityRole(.button)
        setAccessibilityLabel(topic.title)
        setAccessibilityIdentifier("help.topic")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    private var titleFont: NSFont { ThemeFonts.sans(DesignTokens.typeScale.body, isCurrent ? .semibold : .regular) }

    /// padding 0 8; the icon, 8 of gap, the title.
    var preferredWidth: CGFloat {
        8 + CGFloat(Self.iconSize) + 8 + ceil((topic.title as NSString).size(withAttributes: [.font: titleFont]).width) + 8
    }

    func applyTheme(_ theme: Theme) {
        self.theme = theme
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
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
        let attributes: [NSAttributedString.Key: Any] = [.font: titleFont, .foregroundColor: NSColor(textColor)]
        let size = (topic.title as NSString).size(withAttributes: attributes)
        (topic.title as NSString).draw(
            at: NSPoint(x: 8 + CGFloat(Self.iconSize) + 8, y: ((bounds.height - size.height) / 2).rounded()),
            withAttributes: attributes)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true }
    override func mouseExited(with event: NSEvent) { isHovering = false }

    override func mouseDown(with event: NSEvent) {
        sendAction(action, to: target)
    }

    /// Clicks the topic.
    func perform() { sendAction(action, to: target) }
}
