import AppKit

/// A picture the viewer shows, in the middle of the pane: shrunk to fit as it opens and never enlarged, then zoomed in
/// and out, at its actual size (its pixels as points, as a browser shows it) or fitted to the pane, enlarged if small.
/// The arrows move a picture larger than the pane.
final class ViewerImageView: NSScrollView {
    /// The scale changed: the menus and the pane's bottom bar say so.
    var onChange: () -> Void = {}
    private let picture = ViewerPictureView()
    /// How the picture is sized: to fit as it opens (never enlarged), to fit (enlarged too), or a scale chosen.
    private(set) var fit = Fit.opening
    /// The picture's size in pixels, drawn as so many points at 100%.
    private(set) var pixelSize = NSSize.zero

    enum Fit: Equatable { case opening, fit, none }

    /// The room left around a fitted picture.
    private static let margin: CGFloat = 16
    static let scales: ClosedRange<CGFloat> = 0.02...16
    static let step: CGFloat = 1.25

    override init(frame: NSRect) {
        super.init(frame: frame)
        contentView = CenteringClipView()
        documentView = picture
        drawsBackground = false
        contentView.drawsBackground = false
        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = true
        borderType = .noBorder
        automaticallyAdjustsContentInsets = false
        allowsMagnification = true
        minMagnification = Self.scales.lowerBound
        maxMagnification = Self.scales.upperBound
        picture.imageScaling = .scaleAxesIndependently
        picture.focusRingType = .none
        picture.setAccessibilityIdentifier("textViewer.image")
        picture.onKey = { [weak self] event in self?.key(event) ?? false }
        NotificationCenter.default.addObserver(
            self, selector: #selector(pinched), name: NSScrollView.didEndLiveMagnifyNotification, object: self)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// What takes the keyboard.
    var keyboardView: NSView { picture }

    var image: NSImage? {
        get { picture.image }
        set {
            picture.image = newValue
            pixelSize = newValue.map(Self.pixels) ?? .zero
            picture.frame = NSRect(origin: .zero, size: pixelSize)
        }
    }

    /// Shows `image` as it opens, or at `kept`, the zoom the picture before it had.
    func show(_ image: NSImage?, kept: Fit, scale: CGFloat) {
        self.image = image
        fit = kept
        if kept == .none {
            set(scale)
        } else {
            refit()
        }
        onChange()
    }

    /// The largest of its representations' pixels, as a photo with a resolution of its own has fewer points than pixels.
    private static func pixels(_ image: NSImage) -> NSSize {
        let reps = image.representations.filter { $0.pixelsWide > 0 && $0.pixelsHigh > 0 }
        guard let largest = reps.max(by: { $0.pixelsWide < $1.pixelsWide }) else { return image.size }
        return NSSize(width: largest.pixelsWide, height: largest.pixelsHigh)
    }

    // MARK: Zoom

    var scale: CGFloat { magnification }
    var canZoomIn: Bool { image != nil && scale < Self.scales.upperBound - 0.001 }
    var canZoomOut: Bool { image != nil && scale > Self.scales.lowerBound + 0.001 }
    var isActualSize: Bool { abs(scale - 1) < 0.001 }
    var fits: Bool { fit == .fit && abs(scale - fitScale) < 0.001 }

    /// The scale at which the whole picture is in the pane, its margin around it.
    private var fitScale: CGFloat {
        guard pixelSize.width > 0, pixelSize.height > 0 else { return 1 }
        let room = NSSize(width: bounds.width - 2 * Self.margin, height: bounds.height - 2 * Self.margin)
        guard room.width > 0, room.height > 0 else { return 1 }
        return min(
            max(min(room.width / pixelSize.width, room.height / pixelSize.height), Self.scales.lowerBound),
            Self.scales.upperBound)
    }

    func zoomInStep() { setChosen(scale * Self.step) }
    func zoomOutStep() { setChosen(scale / Self.step) }
    func actualSize() { setChosen(1) }

    func fitToPane() {
        fit = .fit
        refit()
        onChange()
    }

    private func setChosen(_ scale: CGFloat) {
        fit = .none
        set(scale)
        onChange()
    }

    private func set(_ scale: CGFloat) {
        let visible = contentView.bounds
        setMagnification(
            min(max(scale, Self.scales.lowerBound), Self.scales.upperBound),
            centeredAt: NSPoint(x: visible.midX, y: visible.midY))
    }

    private func refit() {
        switch fit {
        case .opening: set(min(1, fitScale))
        case .fit: set(fitScale)
        case .none: break
        }
    }

    override func layout() {
        super.layout()
        // A fitted picture stays fitted as the pane is resized.
        if fit != .none { refit() }
    }

    @objc private func pinched() {
        fit = .none
        onChange()
    }

    // MARK: Moving

    /// Moves the picture by `pages` of the pane's height, down or up (negative); false when it is all in the pane.
    func scroll(pages: CGFloat) -> Bool {
        scroll(by: NSPoint(x: 0, y: contentView.bounds.height * pages))
    }

    @discardableResult
    private func scroll(by delta: NSPoint) -> Bool {
        let clip = contentView
        var bounds = clip.bounds
        bounds.origin.x += delta.x
        bounds.origin.y += (picture.isFlipped ? 1 : -1) * delta.y
        let next = clip.constrainBoundsRect(bounds).origin
        guard next != clip.bounds.origin else { return false }
        clip.scroll(to: next)
        reflectScrolledClipView(clip)
        return true
    }

    /// The arrows move a picture larger than the pane by a tenth of it, Space and Shift-Space by a page; Space is the
    /// picture's even with nothing to move, never Quick Look's.
    private func key(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if event.charactersIgnoringModifiers == " ", flags.isEmpty || flags == .shift {
            _ = scroll(pages: flags.isEmpty ? 1 : -1)
            return true
        }
        guard flags.isEmpty else { return false }
        let step = NSPoint(x: contentView.bounds.width / 10, y: contentView.bounds.height / 10)
        switch event.charactersIgnoringModifiers?.unicodeScalars.first.map({ Int($0.value) }) {
        case NSUpArrowFunctionKey: scroll(by: NSPoint(x: 0, y: -step.y))
        case NSDownArrowFunctionKey: scroll(by: NSPoint(x: 0, y: step.y))
        case NSLeftArrowFunctionKey: scroll(by: NSPoint(x: -step.x, y: 0))
        case NSRightArrowFunctionKey: scroll(by: NSPoint(x: step.x, y: 0))
        default: return false
        }
        return true
    }
}

/// The picture itself, which takes the keyboard so the arrows reach it.
private final class ViewerPictureView: NSImageView {
    var onKey: (NSEvent) -> Bool = { _ in false }
    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override func keyDown(with event: NSEvent) {
        if onKey(event) { return }
        super.keyDown(with: event)
    }
}

/// Keeps a picture smaller than the pane in its middle.
private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposed: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposed)
        guard let document = documentView else { return rect }
        let size = document.frame.size
        if size.width < rect.width { rect.origin.x = (size.width - rect.width) / 2 }
        if size.height < rect.height { rect.origin.y = (size.height - rect.height) / 2 }
        return rect
    }
}
