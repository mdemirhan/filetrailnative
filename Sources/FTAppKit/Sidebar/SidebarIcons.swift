// Port of resolveFavoriteIconPath and FavoriteItemIcon (apps/desktop/src/renderer/lib/fileIcons.tsx), EjectIcon.tsx and the chevron of ToolbarIcon.tsx
import AppKit
import FTFoundation

/// The line icons of favorites, locations and headings, drawn from the original's SVG paths: 24-unit box, stroke 1.7,
/// round caps and joins, no fill.
enum SidebarIcons {
    static let favoriteStroke = 1.7

    /// The path data of an icon (`resolveFavoriteIconPath`); the globe is the fallback there and has its own id here.
    static func path(for icon: FavoriteIconID) -> String {
        switch icon {
        case .home: "M4 10.2L12 4l8 6.2V20a1.5 1.5 0 0 1-1.5 1.5h-4.25V14h-4.5v7.5H5.5A1.5 1.5 0 0 1 4 20z"
        case .applications: "M5 5h5v5H5zM14 5h5v5h-5zM5 14h5v5H5zM14 14h5v5h-5z"
        case .desktop: "M4 5.5h16v10H4zM9 18.5h6M12 15.5v3"
        case .documents:
            "M8 3.5h6l4 4V20a1.5 1.5 0 0 1-1.5 1.5h-9A1.5 1.5 0 0 1 6 20V5a1.5 1.5 0 0 1 1.5-1.5zM14 3.5V8h4"
        case .downloads: "M12 4v10M8.5 10.5L12 14l3.5-3.5M5 18.5h14"
        case .trash:
            "M8 6.5h8M9 6.5V5h6v1.5M7 6.5l.8 12a1.5 1.5 0 0 0 1.5 1.4h5.4a1.5 1.5 0 0 0 1.5-1.4L17 6.5M10 10v6M14 10v6"
        case .folder:
            "M3.5 7.5V18A1.5 1.5 0 0 0 5 19.5h14A1.5 1.5 0 0 0 20.5 18V9.5A1.5 1.5 0 0 0 19 8h-7.2a1.5 1.5 0 0 1-1.25-.67l-.6-.9A1.5 1.5 0 0 0 8.7 5.5H5A1.5 1.5 0 0 0 3.5 7z"
        case .star: "M12 4.5l2.2 4.45 4.9.7-3.55 3.46.84 4.89L12 15.7 7.6 18l.84-4.89L4.9 9.65l4.9-.7z"
        case .drive:
            "M5 7.5h14l1.5 4.5H3.5zM5.5 12h13l-1 5.5a1.5 1.5 0 0 1-1.47 1.23H7.97A1.5 1.5 0 0 1 6.5 17.5zM16.5 15.75h.01M13.5 15.75h.01"
        case .code: "M9.5 8L5 12l4.5 4M14.5 8L19 12l-4.5 4M13 6l-2 12"
        case .terminal:
            "M4.5 5.5h15A1.5 1.5 0 0 1 21 7v10a1.5 1.5 0 0 1-1.5 1.5h-15A1.5 1.5 0 0 1 3 17V7a1.5 1.5 0 0 1 1.5-1.5zM7 9l3 3-3 3M12.5 15h4"
        case .music: "M14 5v10.5a2.5 2.5 0 1 1-1.5-2.3V7.4l6-1.4v8.1a2.5 2.5 0 1 1-1.5-2.3V4.2z"
        case .photos:
            "M12 4.5l1.7 2.8 3.2-.3-.8 3.1 2.7 1.7-2.7 1.7.8 3.1-3.2-.3L12 19.5l-1.7-2.8-3.2.3.8-3.1-2.7-1.7 2.7-1.7-.8-3.1 3.2.3z"
        case .videos: "M5.5 6.5h9A1.5 1.5 0 0 1 16 8v8a1.5 1.5 0 0 1-1.5 1.5h-9A1.5 1.5 0 0 1 4 16V8a1.5 1.5 0 0 1 1.5-1.5zM16 10l4-2v8l-4-2"
        case .archive: "M5 6.5h14v3H5zM6.5 9.5h11v9A1.5 1.5 0 0 1 16 20h-8A1.5 1.5 0 0 1 6.5 18.5zM10 12h4"
        case .cloud: "M8.5 18.5h8a3.5 3.5 0 0 0 .4-7A5.5 5.5 0 0 0 6.2 9.6A4 4 0 0 0 8.5 18.5z"
        case .server:
            "M5.5 6.5h13a1.5 1.5 0 0 1 1.5 1.5v2a1.5 1.5 0 0 1-1.5 1.5h-13A1.5 1.5 0 0 1 4 10V8a1.5 1.5 0 0 1 1.5-1.5zM5.5 12.5h13A1.5 1.5 0 0 1 20 14v2a1.5 1.5 0 0 1-1.5 1.5h-13A1.5 1.5 0 0 1 4 16v-2a1.5 1.5 0 0 1 1.5-1.5zM7.5 9h.01M7.5 15h.01"
        case .projects: "M4.5 7.5h6v9h-6zM13.5 7.5h6v4h-6zM13.5 13.5h6v3h-6z"
        case .books: "M6 5.5h4.5A1.5 1.5 0 0 1 12 7v11.5H7.5A1.5 1.5 0 0 1 6 17zM12 7a1.5 1.5 0 0 1 1.5-1.5H18V18.5h-4.5A1.5 1.5 0 0 0 12 20"
        case .camera:
            "M7.5 7.5L9 5.5h6l1.5 2h2A1.5 1.5 0 0 1 20 9v8a1.5 1.5 0 0 1-1.5 1.5h-13A1.5 1.5 0 0 1 4 17V9a1.5 1.5 0 0 1 1.5-1.5zM12 10a3.5 3.5 0 1 0 0 7a3.5 3.5 0 0 0 0-7z"
        case .toolbox:
            "M4.5 8.5h15A1.5 1.5 0 0 1 21 10v7a1.5 1.5 0 0 1-1.5 1.5h-15A1.5 1.5 0 0 1 3 17v-7a1.5 1.5 0 0 1 1.5-1.5zM9 8.5V7A1.5 1.5 0 0 1 10.5 5.5h3A1.5 1.5 0 0 1 15 7v1.5M3 13h18"
        case .network:
            "M12 5.5a2 2 0 1 1 0 4a2 2 0 0 1 0-4zM6 14.5a2 2 0 1 1 0 4a2 2 0 0 1 0-4zM18 14.5a2 2 0 1 1 0 4a2 2 0 0 1 0-4zM12 9.5v3M10.5 14h-3M13.5 14h3"
        case .globe:
            "M12 4a8 8 0 1 0 0 16a8 8 0 0 0 0-16M4.5 12h15M12 4.5a12.8 12.8 0 0 1 0 15M12 4.5a12.8 12.8 0 0 0 0 15"
        }
    }

    /// Strokes the favorite icon into `rect` (a flipped context), in `color`.
    static func drawFavorite(_ icon: FavoriteIconID, in rect: NSRect, color: NSColor) {
        stroke(SVGPath.path(path(for: icon)), box: 24, in: rect, width: favoriteStroke, color: color)
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
