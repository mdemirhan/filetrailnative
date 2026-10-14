// Port of apps/desktop/src/renderer/components/ToastViewport.tsx and styles.css:1560-1630, 1727-1738
import AppKit
import FTFoundation

/// The surface of menus, notifications and the progress card: the opaque menu color, a half-point edge, the menu radius
/// and its shadow (`--context-menu-bg`, `-border`, `-shadow`, `--radius-menu`).
@MainActor
enum MenuSurface {
    static func apply(to layer: CALayer?, theme: Theme, borderWidth: Double) {
        let palette = theme.palette
        layer?.backgroundColor = NSColor(palette.contextMenuBg).cgColor
        layer?.borderColor = NSColor(palette.contextMenuBorder).cgColor
        layer?.borderWidth = CGFloat(borderWidth)
        layer?.cornerRadius = CGFloat(DesignTokens.radii.menu)
        layer?.masksToBounds = false
        // The first shadow layer carries the look (offset 8, blur 32); CSS blur is twice the radius of a CALayer's.
        if let main = palette.contextMenuShadow.first {
            layer?.shadowColor = NSColor(main.color.withAlpha(1)).cgColor
            layer?.shadowOpacity = Float(main.color.alpha)
            layer?.shadowRadius = CGFloat(main.blur / 2)
            layer?.shadowOffset = CGSize(width: main.x, height: -main.y)
        }
    }
}

/// The filled mark of a notification: a disc in the text color with the sign cut out of it in the card's color.
final class ToastIconView: NSView, ThemeApplying {
    var kind: ToastKind = .info { didSet { needsDisplay = true } }
    private var theme: Theme

    init(theme: Theme) {
        self.theme = theme
        super.init(frame: .zero)
        setAccessibilityIdentifier("toast.icon")
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func applyTheme(_ theme: Theme) {
        self.theme = theme
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        // `viewBox="0 0 16 16"` drawn at 18.
        let scale = bounds.width / 16
        var transform = AffineTransform(scaleByX: scale, byY: scale)
        transform.translate(x: 0, y: 0)
        let disc = NSBezierPath(ovalIn: NSRect(x: 1, y: 1, width: 14, height: 14))
        disc.transform(using: transform)
        NSColor(theme.palette.textPrimary).setFill()
        disc.fill()
        let signs: [String] = kind == .success ? ["M5 8.3l2.1 2.1L11.2 6"] : ["M8 7.6v3.6", "M8 4.9h.01"]
        NSColor(theme.palette.contextMenuBg).setStroke()
        for data in signs {
            let path = SVGPath.path(data)
            path.transform(using: transform)
            path.lineWidth = CGFloat(DesignTokens.toast.iconSignStrokeWidth) * scale
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.stroke()
        }
    }
}

/// One notification: the mark, the title, and the detail after it, in one line.
@MainActor
final class ToastCardView: NSView, ThemeApplying {
    let entry: ToastEntry
    private let icon: ToastIconView
    private let title: ThemedText
    private let detail: ThemedText?
    private var theme: Theme
    private var metrics: ToastLayout { DesignTokens.toast }

    /// Text of a notification: the page's body type in its text color.
    private static func style(_ theme: Theme) -> TextStyle {
        TextStyle(font: ThemeFonts.sans(DesignTokens.typeScale.body), color: { $0.palette.textPrimary })
    }

    init(entry: ToastEntry, theme: Theme) {
        self.entry = entry
        self.theme = theme
        icon = ToastIconView(theme: theme)
        icon.kind = entry.kind
        title = ThemedText(entry.title, style: Self.style(theme))
        title.setAccessibilityIdentifier("toast.title")
        if let message = entry.message {
            let text = ThemedText(message, style: Self.style(theme))
            text.lineBreakMode = .byTruncatingTail
            text.setAccessibilityIdentifier("toast.detail")
            detail = text
        } else {
            detail = nil
        }
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityIdentifier("toast")
        setAccessibilityRole(.staticText)
        setAccessibilityLabel([entry.title, entry.message].compactMap { $0 }.joined(separator: " "))
        for view in [icon, title] + (detail.map { [$0] } ?? []) { addSubview(view) }
        applyTheme(theme)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func applyTheme(_ theme: Theme) {
        self.theme = theme
        MenuSurface.apply(to: layer, theme: theme, borderWidth: metrics.borderWidth)
        for view in subviews { view.applyTheme(theme, throughSubviews: true) }
    }

    private var lineHeight: CGFloat { max(title.height(forWidth: 10_000), 0) }

    /// The card's size in a window `available` wide: as wide as its text, up to 420 and the window less a margin on
    /// each side. The detail is shortened when they do not fit; the title stays whole.
    func fittingSize(availableWidth: CGFloat) -> NSSize {
        let limit = min(metrics.maxWidth, Double(availableWidth) - metrics.windowMargin)
        let chrome = 2 * metrics.borderWidth + metrics.paddingLeading + metrics.paddingTrailing + metrics.iconSize
            + metrics.bodyGap
        let titleWidth = Double(title.naturalWidth)
        let detailWidth = detail.map { Double($0.naturalWidth) } ?? 0
        var copy = titleWidth + (detail == nil ? 0 : metrics.bodyGap + detailWidth)
        copy = min(copy, max(titleWidth, limit - chrome))
        let body = max(metrics.iconSize, Double(lineHeight))
        return NSSize(
            width: (chrome + copy).rounded(.up),
            height: 2 * metrics.borderWidth + metrics.paddingTop + body + metrics.paddingBottom)
    }

    override func layout() {
        super.layout()
        let border = metrics.borderWidth
        let body = max(metrics.iconSize, Double(lineHeight))
        let top = border + metrics.paddingTop
        var x = border + metrics.paddingLeading
        icon.frame = NSRect(x: x, y: top + (body - metrics.iconSize) / 2, width: metrics.iconSize, height: metrics.iconSize)
        x += metrics.iconSize + metrics.bodyGap
        let line = lineHeight
        let textY = top + (CGFloat(body) - line) / 2
        let end = Double(bounds.width) - border - metrics.paddingTrailing
        let titleWidth = min(Double(title.naturalWidth), end - x)
        title.frame = NSRect(x: x, y: textY, width: titleWidth, height: line)
        if let detail {
            let start = x + titleWidth + metrics.bodyGap
            detail.frame = NSRect(x: start, y: textY, width: max(0, end - start), height: line)
        }
    }
}
