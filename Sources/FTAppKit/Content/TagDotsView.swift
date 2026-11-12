// The colored dots of an item's Finder tags
import AppKit
import FTFileSystem

extension FinderTagColor {
    /// The color of a Finder dot: lighter than a tagged folder's, which is the system color, as measured on Finder's.
    var dotColor: NSColor {
        let color: NSColor
        switch self {
        case .gray: color = .systemGray
        case .green: color = .systemGreen
        case .purple: color = .systemPurple
        case .blue: color = .systemBlue
        case .yellow: color = .systemYellow
        case .red: color = .systemRed
        case .orange: color = .systemOrange
        }
        return color.withAlphaComponent(0.7)
    }

    /// The name macOS gives this tag, which follows the language and a tag renamed in Finder's settings.
    @MainActor var systemName: String {
        let names = NSWorkspace.shared.fileLabels
        return names.indices.contains(rawValue) ? names[rawValue] : String(describing: self).capitalized
    }
}

/// Up to three overlapping dots, as Finder draws them: the item's last three colors, the newest at the left and on top.
/// The pointer goes through to the row. The dots are a picture made once for each set of colors and look, shown as the
/// layer's contents, as `IconTileView` says.
final class TagDotsView: NSView {
    static let diameter: CGFloat = 10
    static let step: CGFloat = 4
    static let gap: CGFloat = 5
    /// The space cut around each dot where the next one overlaps it.
    private static let ring: CGFloat = 1

    var colors: [FinderTagColor] = [] {
        didSet {
            guard colors != oldValue else { return }
            isHidden = colors.isEmpty
            needsDisplay = true
        }
    }

    private static let mostShown = 3
    private var shown: ArraySlice<FinderTagColor> { colors.suffix(Self.mostShown) }

    /// The width the dots of an item with `count` tags take.
    static func width(count: Int) -> CGFloat {
        count == 0 ? 0 : diameter + CGFloat(min(count, mostShown) - 1) * step
    }

    /// The width the dots take.
    var dotsWidth: CGFloat { Self.width(count: colors.count) }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        isHidden = true
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override var wantsUpdateLayer: Bool { true }

    /// The dots at the left edge, in the middle of the view's height.
    override func updateLayer() {
        guard let layer else { return }
        let scale = window?.backingScaleFactor ?? layer.contentsScale
        layer.contents = Self.picture(Array(shown), scale: scale, appearance: effectiveAppearance)
        layer.contentsScale = scale
        layer.contentsGravity = .left
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }

    private static var pictures: [String: CGImage] = [:]

    /// The dots of `colors` (oldest first), `scale` pixels to the point, in the colors of `appearance`.
    static func picture(_ colors: [FinderTagColor], scale: CGFloat, appearance: NSAppearance) -> CGImage? {
        guard !colors.isEmpty, scale > 0 else { return nil }
        let key = "\(colors.map(\.rawValue)) \(scale) \(appearance.name.rawValue)"
        if let picture = pictures[key] { return picture }
        let width = Int((self.width(count: colors.count) * scale).rounded(.up))
        let height = Int((diameter * scale).rounded(.up))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
            let bitmap = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        bitmap.scaleBy(x: scale, y: scale)
        let context = NSGraphicsContext(cgContext: bitmap, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        appearance.performAsCurrentDrawingAppearance { draw(colors, in: context) }
        NSGraphicsContext.restoreGraphicsState()
        let picture = bitmap.makeImage()
        pictures[key] = picture
        return picture
    }

    private static func draw(_ colors: [FinderTagColor], in context: NSGraphicsContext) {
        // Oldest first, so the newer ones cover them.
        for (index, color) in colors.enumerated() {
            let position = colors.count - 1 - index
            let rect = NSRect(x: CGFloat(position) * step, y: 0, width: diameter, height: diameter)
            if index > 0 {
                // The ring cut around the dots already drawn, where this one overlaps them.
                context.compositingOperation = .destinationOut
                NSColor.black.setFill()
                NSBezierPath(ovalIn: rect.insetBy(dx: -ring, dy: -ring)).fill()
                context.compositingOperation = .sourceOver
            }
            color.dotColor.setFill()
            NSBezierPath(ovalIn: rect).fill()
        }
    }
}

/// The row of colors in a menu, as Finder's: choosing one puts it on the items, or takes it off when they all have it.
/// A check marks a color on all of them, a dash one on some.
@MainActor
final class TagColorsMenuRow: NSView {
    private static let inset: CGFloat = 14
    private static let side: CGFloat = 22

    private let choose: (FinderTagColor) -> Void
    private(set) var buttons: [TagColorButton] = []

    init(choose: @escaping (FinderTagColor) -> Void) {
        self.choose = choose
        let count = CGFloat(FinderTagColor.menuOrder.count)
        super.init(
            frame: NSRect(x: 0, y: 0, width: Self.inset * 2 + count * Self.side, height: Self.side + 4))
        for (index, color) in FinderTagColor.menuOrder.enumerated() {
            let button = TagColorButton(color: color) { [weak self] in self?.chosen(color) }
            button.frame = NSRect(x: Self.inset + CGFloat(index) * Self.side, y: 2, width: Self.side, height: Self.side)
            addSubview(button)
            buttons.append(button)
        }
        setAccessibilityIdentifier("contextMenu.tagColors")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ states: [FinderTagColor: FinderTagColorState]) {
        for button in buttons { button.state = states[button.color] }
    }

    private func chosen(_ color: FinderTagColor) {
        enclosingMenuItem?.menu?.cancelTracking()
        choose(color)
    }
}

/// One color of the row.
@MainActor
final class TagColorButton: NSView {
    let color: FinderTagColor
    private let action: () -> Void
    private var hovered = false {
        didSet { needsDisplay = true }
    }
    var state: FinderTagColorState? {
        didSet { needsDisplay = true }
    }

    init(color: FinderTagColor, action: @escaping () -> Void) {
        self.color = color
        self.action = action
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(color.systemName)
        toolTip = color.systemName
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(
            NSTrackingArea(
                rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseUp(with event: NSEvent) { action() }

    override func accessibilityPerformPress() -> Bool {
        action()
        return true
    }

    override func accessibilityValue() -> Any? {
        switch state {
        case .all: "On all"
        case .some: "On some"
        case nil: nil
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let diameter: CGFloat = hovered ? 18 : 15
        let rect = NSRect(
            x: (bounds.width - diameter) / 2, y: (bounds.height - diameter) / 2, width: diameter, height: diameter)
        color.dotColor.setFill()
        NSBezierPath(ovalIn: rect).fill()
        let symbol: String
        switch state {
        case .all: symbol = "checkmark"
        case .some: symbol = "minus"
        case nil: return
        }
        let configuration = NSImage.SymbolConfiguration(pointSize: 8, weight: .bold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        guard
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration)
        else { return }
        image.draw(
            in: NSRect(
                x: (bounds.width - image.size.width) / 2, y: (bounds.height - image.size.height) / 2,
                width: image.size.width, height: image.size.height))
    }
}
