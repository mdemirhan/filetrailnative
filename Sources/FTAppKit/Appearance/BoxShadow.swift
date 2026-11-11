import AppKit
import FTFoundation

/// A box's soft drops, around it and not under it; a drop with a positive y falls below the box wherever the view is
/// drawn. In the view's own context a shadow's offset goes up or down by how the view reaches the screen or a capture
/// (`NSShadow` turns it over in a flipped context, and a layer under a flipped ancestor is turned over again), while an
/// image lands the right way up in all of them. So the drops are drawn apart.
@MainActor
enum BoxShadow {
    /// A soft edge loses nothing at this density on any screen.
    private static let pixelsPerPoint: CGFloat = 2

    /// Draws `drops` of the rounded `rect` into the current context, last drop first, so the first lies on top. Drops
    /// with no blur and no offset are the caller's: they are an edge, not a shadow.
    static func draw(_ drops: [ShadowLayer], around rect: NSRect, radius: CGFloat) {
        let soft = drops.filter { $0.blur > 0 || $0.x != 0 || $0.y != 0 }
        guard !soft.isEmpty, let image = image(of: soft, size: rect.size, radius: radius) else { return }
        let room = room(for: soft)
        NSImage(cgImage: image, size: NSSize(width: rect.width + 2 * room, height: rect.height + 2 * room)).draw(
            in: rect.insetBy(dx: -room, dy: -room), from: .zero, operation: .sourceOver, fraction: 1,
            respectFlipped: true, hints: nil)
    }

    /// How far past the box the widest drop reaches.
    static func room(for drops: [ShadowLayer]) -> CGFloat {
        let reach = drops.map { CGFloat($0.blur * 1.5 + max(abs($0.x), abs($0.y)) + $0.spread) }.max() ?? 0
        return ceil(reach) + 1
    }

    /// Up is up in this context, whose matrix stays as it is: a shadow's numbers are the context's pixels, so a drop
    /// that falls below the box falls below it in the image.
    private static func image(of drops: [ShadowLayer], size: NSSize, radius: CGFloat) -> CGImage? {
        let scale = pixelsPerPoint
        let room = room(for: drops)
        let width = (size.width + 2 * room) * scale
        let height = (size.height + 2 * room) * scale
        guard width >= 1, height >= 1,
            let context = CGContext(
                data: nil, width: Int(ceil(width)), height: Int(ceil(height)), bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let box = CGRect(x: room * scale, y: room * scale, width: size.width * scale, height: size.height * scale)
        let corner = min(radius * scale, min(box.width, box.height) / 2)
        let shape = CGPath(roundedRect: box, cornerWidth: corner, cornerHeight: corner, transform: nil)
        context.addRect(CGRect(x: 0, y: 0, width: width, height: height))
        context.addPath(shape)
        context.clip(using: .evenOdd)
        context.setFillColor(NSColor.black.cgColor)
        for drop in drops.reversed() {
            context.saveGState()
            context.setShadow(
                offset: CGSize(width: CGFloat(drop.x) * scale, height: -CGFloat(drop.y) * scale),
                blur: CGFloat(drop.blur) * scale, color: NSColor(drop.color).cgColor)
            context.addPath(shape)
            context.fillPath()
            context.restoreGState()
        }
        return context.makeImage()
    }
}

/// The push button's bezel: the 0.5 edge and the soft line under it, outside the button as a box shadow is. The app's
/// other push buttons (a pop-up, a small button) draw theirs with this as well.
@MainActor
func drawPushButtonBezel(_ palette: ThemePalette, around bounds: NSRect, radius: CGFloat) {
    BoxShadow.draw(palette.pushButtonBezel.filter { $0.blur > 0 }, around: bounds, radius: radius)
    for layer in palette.pushButtonBezel.reversed() where layer.blur == 0 && layer.spread > 0 {
        let half = CGFloat(layer.spread) / 2
        let edge = NSBezierPath(
            roundedRect: bounds.insetBy(dx: -half, dy: -half), xRadius: radius + half, yRadius: radius + half)
        edge.lineWidth = CGFloat(layer.spread)
        NSColor(layer.color).setStroke()
        edge.stroke()
    }
}
