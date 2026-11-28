import AppKit
import FTFoundation

/// An item's icon, given to its layer as a picture drawn once at the size it is shown, for the screen's scale and the
/// window's appearance. The system's icons hold many sizes and are drawn on the CPU each time an image view shows one:
/// a folder of the same few kinds drew the same icon hundreds of times on going in. Here one drawing serves every item
/// showing that icon at that size (`IconPictures`). It is drawn again when the screen's scale or the appearance
/// changes, and a new icon (a custom one, the accent's folder) is a new image, so a new drawing.
final class IconPictureView: PassThroughView {
    /// The icon shown, fitted to the view in its own proportions.
    var image: NSImage? {
        didSet {
            guard image !== oldValue else { return }
            refresh()
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.contentsGravity = .resize
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { refresh() }

    /// What draws the view where its layer isn't used: a picture of the window taken by drawing its views.
    override func draw(_ dirtyRect: NSRect) {
        guard let image, image.size.width > 0, image.size.height > 0 else { return }
        image.draw(
            in: IconPictures.fitted(image.size, in: bounds.size), from: .zero, operation: .sourceOver, fraction: 1,
            respectFlipped: true, hints: nil)
    }

    override func layout() {
        super.layout()
        refresh()
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { refresh() }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        refresh()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }

    /// The drawing given to the layer, for a test.
    var picture: CGImage? { shown?.picture }
    private var shown: IconPictures.Drawn?

    private func refresh() {
        guard let layer else { return }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        guard let image, bounds.width >= 1, bounds.height >= 1 else {
            if shown != nil || layer.contents != nil {
                shown = nil
                Self.withoutAnimation { layer.contents = nil }
            }
            return
        }
        let wanted = IconPictures.Key(
            image: ObjectIdentifier(image), width: Int((bounds.width * scale).rounded()),
            height: Int((bounds.height * scale).rounded()), appearance: effectiveAppearance.name.rawValue)
        guard shown?.key != wanted else { return }
        let drawn = IconPictures.picture(of: image, key: wanted, scale: scale, appearance: effectiveAppearance)
        shown = drawn
        Self.withoutAnimation {
            layer.contents = drawn?.picture
            layer.contentsScale = scale
        }
    }

    private static func withoutAnimation(_ change: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        change()
        CATransaction.commit()
    }
}

/// The icons drawn for `IconPictureView`, up to `memoryLimit` bytes, the least recently used let go first, and all of
/// them when macOS is short of memory. A drawing is found by its image's identity, and used only while that image is
/// still the one it was drawn from.
@MainActor
enum IconPictures {
    struct Key: Hashable {
        var image: ObjectIdentifier
        var width: Int
        var height: Int
        var appearance: String
    }

    struct Drawn {
        var key: Key
        var picture: CGImage
        /// The image drawn, not kept: the icon store keeps its icons as long as it wants them, and a drawing whose image
        /// is gone is no one's (`key.image` may be another's by then).
        weak var image: NSImage?
        /// When it was last asked for.
        var used = 0
        var bytes: Int { picture.bytesPerRow * picture.height }
    }

    /// Enough for every kind of icon of a large folder at the largest sizes; 32 pt on a Retina screen is 16 KB.
    static let memoryLimit = 48 * 1024 * 1024

    private static var drawings: [Key: Drawn] = [:]
    private static var bytes = 0
    private static var uses = 0

    static var count: Int { drawings.count }

    static func picture(of image: NSImage, key: Key, scale: CGFloat, appearance: NSAppearance) -> Drawn? {
        uses += 1
        watchMemory()
        if let kept = drawings[key] {
            if kept.image === image {
                drawings[key]?.used = uses
                return drawings[key]
            }
            // Its image is gone, and this one took its identity.
            drawings[key] = nil
            bytes -= kept.bytes
        }
        guard let picture = draw(image, width: key.width, height: key.height, scale: scale, appearance: appearance)
        else { return nil }
        let drawn = Drawn(key: key, picture: picture, image: image, used: uses)
        drawings[key] = drawn
        bytes += drawn.bytes
        if bytes > memoryLimit { trim() }
        return drawn
    }

    /// Lets the least recently used go down to three quarters of the limit, so that trimming is rare.
    private static func trim() {
        for drawn in drawings.values.sorted(by: { $0.used < $1.used }) {
            guard bytes > memoryLimit * 3 / 4 else { break }
            drawings[drawn.key] = nil
            bytes -= drawn.bytes
        }
    }

    /// Tells of macOS running short of memory, for as long as the app runs.
    private static var memoryPressure: (any DispatchSourceMemoryPressure)?

    private static func watchMemory() {
        guard memoryPressure == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { MainActor.assumeIsolated { forget() } }
        source.resume()
        memoryPressure = source
    }

    /// Lets every drawing go; the views showing one keep theirs.
    static func forget() {
        drawings = [:]
        bytes = 0
    }

    /// A picture of `size` fitted into `room` in its own proportions, in the middle.
    nonisolated static func fitted(_ size: NSSize, in room: NSSize) -> NSRect {
        let fit = min(room.width / size.width, room.height / size.height)
        let drawn = NSSize(width: size.width * fit, height: size.height * fit)
        return NSRect(
            x: (room.width - drawn.width) / 2, y: (room.height - drawn.height) / 2, width: drawn.width,
            height: drawn.height)
    }

    /// The image fitted into `width` × `height` pixels in its own proportions, centred, as an image view scales it.
    private static func draw(
        _ image: NSImage, width: Int, height: Int, scale: CGFloat, appearance: NSAppearance
    ) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.displayP3),
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        let points = NSSize(width: CGFloat(width) / scale, height: CGFloat(height) / scale)
        guard image.size.width > 0, image.size.height > 0 else { return nil }
        let rect = fitted(image.size, in: points)
        context.scaleBy(x: scale, y: scale)
        context.interpolationQuality = .high
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        appearance.performAsCurrentDrawingAppearance {
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        }
        return context.makeImage()
    }
}
