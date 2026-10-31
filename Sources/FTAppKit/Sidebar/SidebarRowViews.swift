// Port of TreeItemRow and renderSectionHeader (apps/desktop/src/renderer/components/TreePane.tsx) with the sidebar rules of styles.css
import AppKit
import FTFileSystem
import FTFoundation

/// The icon a folder row shows: the macOS icon of the folder once it has arrived, a stand-in folder before.
@MainActor
final class SidebarFolderIcons {
    static let shared = SidebarFolderIcons()
    private let store: FileIconStore

    init(store: FileIconStore = FileIconStore()) {
        self.store = store
    }

    /// The icon for a folder row, if it is known; asks for it otherwise and calls `arrived` when it comes.
    func icon(path: String, alias: Bool, arrived: @escaping @MainActor () -> Void) -> NSImage? {
        let request = IconRequest(entry: IconEntry(path: path, kind: alias ? .symlinkDirectory : .directory))
        switch store.lookup(request) {
        case .image(let image): return image
        case .none: return nil
        case .missing:
            store.load(request) { _ in arrived() }
            return nil
        }
    }
}

/// A flipped view that is not hit by the mouse, for the parts of a row that only draw.
class SidebarPlainView: NSView {
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    // A click in a window that is not in front still reaches the row.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// A symbol that only draws: the press stays the row's.
private final class SidebarSymbolView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The icon of a row: a folder's own, a favorite's or location's symbol, or a heading's line icon. A symbol at the row's icon size is often
/// wider than the icon's box and sits centered over its edges, as the row keeps its widths.
final class SidebarIconView: SidebarPlainView {
    enum Content {
        case none
        case symbol(String, pointSize: Double, color: NSColor)
        case heading(SidebarIcons.Heading, color: NSColor)
        case folder(NSImage?)
    }

    var content: Content = .none {
        didSet {
            applySymbol()
            needsDisplay = true
        }
    }
    private let symbolView = SidebarSymbolView()
    private var shownSymbol: (name: String, pointSize: Double)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = false
        symbolView.imageScaling = .scaleNone
        symbolView.isHidden = true
        symbolView.setAccessibilityElement(false)
        addSubview(symbolView)
        // The Locations' color is a system color, which can change while the app runs.
        NotificationCenter.default.addObserver(
            self, selector: #selector(systemColorsChanged), name: NSColor.systemColorsDidChangeNotification, object: nil
        )
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func systemColorsChanged() { symbolView.needsDisplay = true }

    private func applySymbol() {
        guard case .symbol(let name, let pointSize, let color) = content else {
            symbolView.isHidden = true
            return
        }
        symbolView.isHidden = false
        symbolView.contentTintColor = color
        if shownSymbol?.name != name || shownSymbol?.pointSize != pointSize {
            shownSymbol = (name, pointSize)
            symbolView.image = SidebarIcons.symbol(name, pointSize: pointSize)
            needsLayout = true
        }
    }

    override func layout() {
        super.layout()
        let size = symbolView.image?.size ?? .zero
        symbolView.frame = NSRect(
            x: ((bounds.width - size.width) / 2).rounded(), y: ((bounds.height - size.height) / 2).rounded(),
            width: size.width, height: size.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        switch content {
        case .none, .symbol:
            break
        case .heading(let heading, let color):
            SidebarIcons.drawHeading(heading, in: bounds, color: color)
        case .folder(let image):
            if let image {
                image.draw(
                    in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            } else {
                Self.drawFolderStandIn(in: bounds)
            }
        }
    }

    /// The filled blue folder with a tab that stands in for an icon that has not arrived (`FolderSvg`, a 64-unit box).
    static func drawFolderStandIn(in rect: NSRect) {
        let scale = rect.width / 64
        func point(_ x: Double, _ y: Double) -> NSPoint { NSPoint(x: rect.minX + x * scale, y: rect.minY + y * scale) }
        func rounded(_ x: Double, _ y: Double, _ width: Double, _ height: Double, _ radius: Double) -> NSBezierPath {
            NSBezierPath(
                roundedRect: NSRect(x: point(x, y).x, y: point(x, y).y, width: width * scale, height: height * scale),
                xRadius: radius * scale, yRadius: radius * scale)
        }
        let back = SVGPath.path(
            "M3 12a3.5 3.5 0 0 1 3.5-3.5h13.1a3 3 0 0 1 2.2 1l1.9 2.1a3 3 0 0 0 2.2 1h32.6a3.5 3.5 0 0 1 3.5 3.5V22H3z")
        var transform = AffineTransform(translationByX: rect.minX, byY: rect.minY)
        transform.scale(x: scale, y: scale)
        back.transform(using: transform)
        NSColor(srgbRed: 0x45 / 255, green: 0xaa / 255, blue: 0xe4 / 255, alpha: 1).setFill()
        back.fill()
        NSColor(srgbRed: 0x80 / 255, green: 0xcf / 255, blue: 0xf7 / 255, alpha: 1).setFill()
        rounded(3, 17, 59, 10, 3.2).fill()
        NSColor(srgbRed: 0x67 / 255, green: 0xc0 / 255, blue: 0xef / 255, alpha: 1).setFill()
        rounded(3, 17.8, 59, 37.7, 3.2).fill()
    }
}

/// The disclosure chevron: a button of its own, pointing right, turned 90° when open, invisible when there is nothing to
/// open.
final class SidebarChevronView: SidebarPlainView {
    override func isAccessibilityElement() -> Bool { !isHidden && isVisibleGlyph }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityParent() -> Any? { sidebarAccessibilityParent(of: self) }
    override func isAccessibilityEnabled() -> Bool { isEnabled }
    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        onClick?()
        return true
    }

    var color = NSColor.secondaryLabelColor {
        didSet { needsDisplay = true }
    }
    var strokeWidth = 1.8
    var iconSize = 16.0
    var expanded = false {
        didSet {
            guard expanded != oldValue else { return }
            turnTimer?.invalidate()
            turnTimer = nil
            rotation = expanded ? .pi / 2 : 0
        }
    }
    /// How far it is turned now, which the turn takes it through.
    private(set) var rotation: CGFloat = 0 {
        didSet { needsDisplay = true }
    }
    private var turnTimer: Timer?
    var isTurning: Bool { turnTimer != nil }
    /// `.tree-expand`: `transition: transform var(--duration-fast) ease`.
    private static let turnDuration = 0.12

    /// The row just opened or closed: the chevron, set where it ends, turns there from where it was.
    func turnToWhereItIs() {
        let end: CGFloat = expanded ? .pi / 2 : 0
        let start: CGFloat = expanded ? 0 : .pi / 2
        let began = ProcessInfo.processInfo.systemUptime
        turnTimer?.invalidate()
        rotation = start
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let progress = min(1, (ProcessInfo.processInfo.systemUptime - began) / Self.turnDuration)
                // Close to CSS's `ease`: quick at first, slowing to the end.
                self.rotation = start + (end - start) * CGFloat(1 - pow(1 - progress, 2.4))
                if progress >= 1 {
                    self.turnTimer?.invalidate()
                    self.turnTimer = nil
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        turnTimer = timer
    }

    /// The button is disabled when the folder cannot expand or is being read; it is drawn only when it can.
    var isVisibleGlyph = true {
        didSet { needsDisplay = true }
    }
    var isEnabled = true
    var onClick: (() -> Void)?

    override func draw(_ dirtyRect: NSRect) {
        guard isVisibleGlyph else { return }
        // The 16 pt icon sits centered in its box and overflows it.
        let rect = NSRect(
            x: (bounds.width - iconSize) / 2, y: (bounds.height - iconSize) / 2, width: iconSize, height: iconSize)
        SidebarIcons.drawChevron(
            in: rect, color: color, stroke: strokeWidth, rotation: rotation)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        var inside = true
        while let next = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            inside = bounds.contains(convert(next.locationInWindow, from: nil))
            if next.type == .leftMouseUp { break }
        }
        if inside { onClick?() }
    }
}

/// Finder's Eject button at the end of a disk's row.
final class SidebarEjectView: SidebarPlainView {
    override func isAccessibilityElement() -> Bool { !isHidden }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityParent() -> Any? { sidebarAccessibilityParent(of: self) }
    override func isAccessibilityEnabled() -> Bool { isEnabled }
    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        onClick?()
        return true
    }

    var color = NSColor.secondaryLabelColor {
        didSet { needsDisplay = true }
    }
    var iconSize = 14.0
    var strokeWidth = 1.8
    var isEnabled = true {
        didSet {
            alphaValue = isEnabled ? 1 : DesignTokens.disabledOpacity
            needsDisplay = true
        }
    }
    var onClick: (() -> Void)?
    var onRightClick: ((NSEvent) -> Void)?
    private var isHovered = false
    private var isPressed = false
    var hoverColor = NSColor.labelColor

    override func draw(_ dirtyRect: NSRect) {
        if isPressed, isEnabled {
            let palette = SidebarColors.theme(for: self).palette
            ChromeColors.color(palette.bgHover).setFill()
            NSBezierPath(
                roundedRect: bounds, xRadius: DesignTokens.radii.control, yRadius: DesignTokens.radii.control
            ).fill()
        }
        let rect = NSRect(
            x: (bounds.width - iconSize) / 2, y: (bounds.height - iconSize) / 2, width: iconSize, height: iconSize)
        SidebarIcons.drawEject(in: rect, color: isHovered && isEnabled ? hoverColor : color, stroke: strokeWidth)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(
            NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isPressed = true
        needsDisplay = true
        var inside = true
        while let next = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            inside = bounds.contains(convert(next.locationInWindow, from: nil))
            if isPressed != inside {
                isPressed = inside
                needsDisplay = true
            }
            if next.type == .leftMouseUp { break }
        }
        isPressed = false
        needsDisplay = true
        if inside { onClick?() }
    }

    override func rightMouseDown(with event: NSEvent) {
        if let onRightClick { onRightClick(event) } else { super.rightMouseDown(with: event) }
    }
}

/// A pill of text in a row: the "Alias" badge after a link's name (`.tree-label-badge`), and "Drop here" on a drop target.
final class SidebarBadgeView: SidebarPlainView {
    private let label = TextBoxField(labelWithString: "")
    var fill = NSColor.clear
    var density = Density.comfortable

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = ChromeColors.font(size: DesignTokens.typeScale.mini)
        label.isBordered = false
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var textColor: NSColor {
        get { label.textColor ?? .secondaryLabelColor }
        set { label.textColor = newValue }
    }

    var title: String { label.stringValue }

    /// 1/6 padding around the text, `letter-spacing: 0.02em`.
    func fittingWidth(layout: SidebarLayout) -> Double {
        let size = label.attributedStringValue.size()
        return ceil(size.width) + 2 * layout.badgePaddingX
    }

    func apply(title: String, font: NSFont) {
        label.attributedStringValue = NSAttributedString(
            string: title,
            attributes: [
                .font: font, .foregroundColor: label.textColor ?? .secondaryLabelColor,
                .kern: font.pointSize * 0.02,
            ])
    }

    override func layout() {
        super.layout()
        let size = label.attributedStringValue.size()
        label.frame = NSRect(
            x: (bounds.width - ceil(size.width)) / 2, y: (bounds.height - ceil(size.height)) / 2,
            width: ceil(size.width), height: ceil(size.height))
    }

    override func draw(_ dirtyRect: NSRect) {
        fill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
    }
}

/// A button's row, in the list it is in.
@MainActor
func sidebarAccessibilityParent(of button: NSView) -> Any? {
    var view = button.superview
    while let candidate = view, !(candidate is SidebarOutlineView) { view = candidate.superview }
    return (view as? SidebarOutlineView)?.accessibilityRow(containing: button)
}
