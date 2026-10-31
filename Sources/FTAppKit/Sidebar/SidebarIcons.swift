// Port of resolveFavoriteIconPath and FavoriteItemIcon (apps/desktop/src/renderer/lib/fileIcons.tsx), EjectIcon.tsx and the chevron of ToolbarIcon.tsx
import AppKit
import FTFoundation

/// The icons of favorites and locations, the system's symbols as Finder's (D-021); the headings, the eject and the
/// chevron stay the original's line icons.
enum SidebarIcons {
    /// A heading's line icon, in the original's SVG path: 24-unit box, stroke 1.7, round caps and joins, no fill.
    enum Heading {
        case favorites
        case locations

        var path: String {
            switch self {
            case .favorites: "M12 4.5l2.2 4.45 4.9.7-3.55 3.46.84 4.89L12 15.7 7.6 18l.84-4.89L4.9 9.65l4.9-.7z"
            case .locations:
                "M5 7.5h14l1.5 4.5H3.5zM5.5 12h13l-1 5.5a1.5 1.5 0 0 1-1.47 1.23H7.97A1.5 1.5 0 0 1 6.5 17.5zM16.5 15.75h.01M13.5 15.75h.01"
            }
        }
    }

    static let headingStroke = 1.7

    /// Strokes a heading's icon into `rect` (a flipped context), in `color`.
    static func drawHeading(_ heading: Heading, in rect: NSRect, color: NSColor) {
        stroke(SVGPath.path(heading.path), box: 24, in: rect, width: headingStroke, color: color)
    }

    /// The symbol of an icon. The saved preference stays the original's id.
    static func symbolName(for icon: FavoriteIconID) -> String {
        switch icon {
        case .home: "house"
        case .applications: "square.grid.2x2"
        case .desktop: "menubar.dock.rectangle"
        case .documents: "doc"
        case .downloads: "arrow.down.circle"
        case .trash: "trash"
        case .folder: "folder"
        case .star: "star"
        case .drive: "externaldrive"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .terminal: "terminal"
        case .globe: "globe"
        case .music: "music.note"
        case .photos: "photo"
        case .videos: "film"
        case .archive: "archivebox"
        case .cloud: "icloud"
        case .server: "server.rack"
        case .projects: "square.stack.3d.up"
        case .books: "books.vertical"
        case .camera: "camera"
        case .toolbox: "wrench.and.screwdriver"
        case .network: "network"
        }
    }

    /// The symbol of a row under Locations: the startup disk has its own, and a share, which the list marks as a
    /// server, is a network place as in Finder.
    static func locationSymbolName(for icon: FavoriteIconID, path: String?) -> String {
        if path == "/" { return "internaldrive" }
        return icon == .server ? "network" : symbolName(for: icon)
    }

    /// A symbol at a point size, a template that takes the color of whatever shows it.
    static func symbol(_ name: String, pointSize: Double) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular))
    }

    /// Draws the favorite's symbol into `rect` (a flipped context) in `color`, as large as fits there, for the fixed
    /// boxes of the Settings picker.
    static func drawFavorite(_ icon: FavoriteIconID, in rect: NSRect, color: NSColor) {
        guard
            let image = symbol(symbolName(for: icon), pointSize: rect.height)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [color]))
        else { return }
        let scale = min(1, rect.width / image.size.width, rect.height / image.size.height)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let fitted = NSRect(
            x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
        image.draw(in: fitted, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    /// Finder's eject symbol: a triangle over a bar (`EjectIcon`).
    static func drawEject(in rect: NSRect, color: NSColor, stroke width: Double) {
        let triangle = SVGPath.path("M12 5.5l7 8H5z")
        let bar = SVGPath.path("M5 18.5h14")
        stroke(triangle, box: 24, in: rect, width: width, color: color)
        stroke(bar, box: 24, in: rect, width: width, color: color)
    }

    /// The disclosure chevron of rows (`ToolbarIcon name="chevron"`), pointing right; `rotation` turns it about the
    /// center of `rect` (90° when open).
    static func drawChevron(in rect: NSRect, color: NSColor, stroke width: Double, rotation: CGFloat) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        if rotation != 0 {
            let transform = NSAffineTransform()
            transform.translateX(by: rect.midX, yBy: rect.midY)
            transform.rotate(byRadians: rotation)
            transform.translateX(by: -rect.midX, yBy: -rect.midY)
            transform.concat()
        }
        ToolbarGlyph.draw(.chevron, in: rect, strokeWidth: width, color: color, flipped: true)
    }

    private static func stroke(_ path: NSBezierPath, box: Double, in rect: NSRect, width: Double, color: NSColor) {
        let scale = rect.width / box
        var transform = AffineTransform(translationByX: rect.minX, byY: rect.minY)
        transform.scale(x: scale, y: scale)
        path.transform(using: transform)
        path.lineWidth = width * scale
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        color.setStroke()
        path.stroke()
    }
}
