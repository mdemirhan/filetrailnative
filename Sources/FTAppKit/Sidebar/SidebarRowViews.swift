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

/// The icon of a row: a folder's own, or a favorite's line icon in the accent color.
final class SidebarIconView: SidebarPlainView {
    enum Content {
        case none
        case favorite(FavoriteIconID, color: NSColor)
        case folder(NSImage?)
    }

    var content: Content = .none {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        switch content {
        case .none:
            break
        case .favorite(let icon, let color):
            SidebarIcons.drawFavorite(icon, in: bounds, color: color)
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
    var color = NSColor.secondaryLabelColor {
        didSet { needsDisplay = true }
    }
    var strokeWidth = 1.8
    var iconSize = 16.0
    var expanded = false {
        didSet { if expanded != oldValue { needsDisplay = true } }
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
            in: rect, color: color, stroke: strokeWidth, rotation: expanded ? .pi / 2 : 0)
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

/// The "Alias" badge after a link's name (`.tree-label-badge`).
final class SidebarBadgeView: SidebarPlainView {
    private let label = NSTextField(labelWithString: "Alias")
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

    func apply(layout: SidebarLayout) {
        let font = ChromeColors.font(size: layout.badgeFontSize)
        label.attributedStringValue = NSAttributedString(
            string: "Alias",
            attributes: [
                .font: font, .foregroundColor: label.textColor ?? .secondaryLabelColor,
                .kern: layout.badgeFontSize * 0.02,
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
