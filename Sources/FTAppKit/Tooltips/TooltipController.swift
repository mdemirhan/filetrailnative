// Port of the drawing of apps/desktop/src/renderer/lib/titleTooltips.ts and the .app-tooltip rule of styles.css
import AppKit
import FTFoundation

/// The tooltips of one window, drawn by the app: a bubble under the control (above it near the bottom), kept inside
/// the window. Controls report the pointer coming and going (`hover`); clicks, keys and scrolls are watched here.
@MainActor
final class TooltipController {
    private weak var window: NSWindow?
    let scheduler: TooltipScheduler
    private let bubble = TooltipBubble()

    private static var controllers: [ObjectIdentifier: TooltipController] = [:]

    /// The window's controller, made the first time it is asked for.
    static func of(_ window: NSWindow) -> TooltipController {
        if let existing = controllers[ObjectIdentifier(window)] { return existing }
        let made = TooltipController(window: window)
        controllers[ObjectIdentifier(window)] = made
        return made
    }

    static func remove(_ window: NSWindow) {
        controllers.removeValue(forKey: ObjectIdentifier(window))?.uninstall()
    }

    init(window: NSWindow, scheduler: TooltipScheduler = TooltipScheduler()) {
        self.window = window
        self.scheduler = scheduler
        scheduler.onShow = { [weak self] anchor, text in self?.show(text, at: anchor) }
        scheduler.onHide = { [weak self] in self?.bubble.removeFromSuperview() }
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduler.dismiss() }
        }
    }

    private var observer: (any NSObjectProtocol)?

    /// An event on its way to the window: a press hides the tooltip (and quiets the control pressed); a key, a
    /// scroll or the pointer leaving the window hides it.
    func observe(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            let hit = window?.contentView?.superview?.hitTest(event.locationInWindow)
            scheduler.press(Self.anchor(above: hit))
        case .keyDown, .scrollWheel:
            scheduler.dismiss()
        default:
            break
        }
    }

    func uninstall() {
        scheduler.uninstall()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        bubble.removeFromSuperview()
    }

    /// The pointer came over a control (nil: left it).
    func hover(_ anchor: TooltipAnchor?) {
        scheduler.hover(anchor)
    }

    private static func anchor(above view: NSView?) -> TooltipAnchor? {
        var current = view
        while let candidate = current {
            if let anchor = candidate as? TooltipAnchor { return anchor }
            current = candidate.superview
        }
        return nil
    }

    private func show(_ text: String, at anchor: TooltipAnchor) {
        guard let window, let host = window.contentView, let control = anchor as? NSView, control.window === window
        else { return }
        bubble.text = text
        let size = bubble.fittingSize(maxWidth: host.bounds.width)
        let rect = control.convert(control.bounds, to: host)
        let top = host.isFlipped ? rect.minY : host.bounds.height - rect.maxY
        let place = TitleTooltips.placement(
            anchor: .init(left: rect.minX, top: top, right: rect.maxX, bottom: top + rect.height, width: rect.width),
            bubble: .init(width: size.width, height: size.height),
            viewport: .init(width: host.bounds.width, height: host.bounds.height))
        let y = host.isFlipped ? place.top.rounded() : host.bounds.height - place.top.rounded() - size.height
        bubble.frame = NSRect(x: place.left.rounded(), y: y, width: size.width, height: size.height)
        if bubble.superview !== host { host.addSubview(bubble) }
        bubble.needsDisplay = true
    }
}

/// `.app-tooltip`: 11 pt text on the menu background, 3/8 padding, a hairline edge, radius 6, a soft shadow.
final class TooltipBubble: NSView {
    private let label = NSTextField(labelWithString: "")
    private static let padding = NSEdgeInsets(top: 3, left: 8, bottom: 3, right: 8)
    private static let maxWidth = 420.0
    private static let lineHeight = 1.35

    var text: String {
        get { label.stringValue }
        set {
            label.stringValue = newValue
            label.setAccessibilityLabel(newValue)
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setAccessibilityIdentifier("tooltip")
        label.font = ChromeColors.font(size: DesignTokens.typeScale.small)
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.setAccessibilityIdentifier("tooltip.text")
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func fittingSize(maxWidth limit: Double) -> NSSize {
        let font = label.font ?? .systemFont(ofSize: DesignTokens.typeScale.small)
        let line = (font.pointSize * Self.lineHeight).rounded(.up)
        let insets = Self.padding.left + Self.padding.right + 1
        let width = min(Self.maxWidth, limit - 2 * TitleTooltips.edgeMargin) - insets
        let bounds = (text as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin],
            attributes: [.font: font])
        let lines = max(1, (bounds.height / font.boundingRectForFont.height).rounded())
        return NSSize(
            width: (min(width, bounds.width.rounded(.up)) + insets).rounded(.up),
            height: lines * line + Self.padding.top + Self.padding.bottom + 1)
    }

    override func layout() {
        super.layout()
        label.frame = NSRect(
            x: Self.padding.left + 0.5, y: Self.padding.bottom + 0.5,
            width: bounds.width - Self.padding.left - Self.padding.right - 1,
            height: bounds.height - Self.padding.top - Self.padding.bottom - 1)
    }

    override func updateLayer() {
        let palette = ChromeColors.palette(for: self)
        layer?.backgroundColor = ChromeColors.color(palette.contextMenuBg).cgColor
        layer?.borderColor = ChromeColors.color(palette.contextMenuBorder).cgColor
        layer?.borderWidth = 0.5
        layer?.cornerRadius = DesignTokens.radii.control
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.16
        layer?.shadowRadius = 4
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        layer?.masksToBounds = false
        label.textColor = ChromeColors.color(palette.contextMenuText)
    }

    override var wantsUpdateLayer: Bool { true }
}
