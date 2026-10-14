// Port of apps/desktop/src/renderer/components/ToolbarIcon.tsx and MenuCheck.tsx
import AppKit
import FTFoundation

/// The original's stroke icons, redrawn from the same SVG shapes: round caps and joins, no fill, in a 24-unit box
/// (16 for clear, stop and the vertical separator), stroked in the view's color.
enum ToolbarGlyph {
    enum Shape {
        case path(String, strokeWidth: Double? = nil)
        case rect(x: Double, y: Double, width: Double, height: Double, radius: Double)
        case circle(x: Double, y: Double, radius: Double)
        case line(x1: Double, y1: Double, x2: Double, y2: Double)
    }

    struct Drawing {
        var box: Double = 24
        var shapes: [Shape]
    }

    static let folderOutline = "M22 19a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5l2 3h9a2 2 0 0 1 2 2z"

    static func drawing(_ name: ToolbarIconName) -> Drawing {
        switch name {
        case .more:
            return Drawing(shapes: [
                .circle(x: 12, y: 12, radius: 9), .circle(x: 8, y: 12, radius: 0.9),
                .circle(x: 12, y: 12, radius: 0.9), .circle(x: 16, y: 12, radius: 0.9),
            ])
        case .icons:
            return Drawing(shapes: [
                .rect(x: 4, y: 4, width: 6.5, height: 6.5, radius: 1.5),
                .rect(x: 13.5, y: 4, width: 6.5, height: 6.5, radius: 1.5),
                .rect(x: 4, y: 13.5, width: 6.5, height: 6.5, radius: 1.5),
                .rect(x: 13.5, y: 13.5, width: 6.5, height: 6.5, radius: 1.5),
            ])
        case .list:
            return Drawing(shapes: [
                .path("M9 6h11M9 12h11M9 18h11"), .path("M4.5 6h.01M4.5 12h.01M4.5 18h.01", strokeWidth: 2.6),
            ])
        case .details:
            return Drawing(shapes: [
                .rect(x: 3, y: 4.5, width: 18, height: 15, radius: 2.5), .path("M3 10h18M3 15h18M9 10v9.5"),
            ])
        case .sort:
            return Drawing(shapes: [.path("M8 4v16M4 16l4 4 4-4M16 20V4M12 8l4-4 4 4")])
        case .search:
            return Drawing(shapes: [.circle(x: 11, y: 11, radius: 7), .line(x1: 16.5, y1: 16.5, x2: 21, y2: 21)])
        case .clear:
            return Drawing(
                box: 16,
                shapes: [
                    .circle(x: 8, y: 8, radius: 6), .line(x1: 5.7, y1: 5.7, x2: 10.3, y2: 10.3),
                    .line(x1: 10.3, y1: 5.7, x2: 5.7, y2: 10.3),
                ])
        case .stop:
            return Drawing(box: 16, shapes: [.rect(x: 4, y: 4, width: 8, height: 8, radius: 1.5)])
        case .separatorVertical:
            return Drawing(box: 16, shapes: [.line(x1: 8, y1: 2.5, x2: 8, y2: 13.5)])
        case .newTab:
            return Drawing(shapes: [
                .rect(x: 3, y: 4.5, width: 18, height: 15, radius: 2.5), .path("M3 9h18"),
                .path("M12 11.5v5.5M9.25 14.25h5.5"),
            ])
        case .hiddenShown:
            return Drawing(shapes: [
                .path("M2 12s3.6-7 10-7 10 7 10 7-3.6 7-10 7-10-7-10-7z"), .circle(x: 12, y: 12, radius: 3),
            ])
        case .quickLook:
            return Drawing(shapes: [
                .rect(x: 4, y: 4, width: 16, height: 16, radius: 2), .path("M14 7h3v3M10 17H7v-3M17 7l-4 4M7 17l4-4"),
            ])
        case .showInFinder:
            return Drawing(shapes: [
                .path(folderOutline), .circle(x: 11.5, y: 13, radius: 2.5), .path("M13.5 15l2.5 2.5"),
            ])
        case .revealInFolder:
            return Drawing(shapes: [.path(folderOutline), .path("M12 10h6"), .path("M15 7l3 3-3 3")])
        case .calculateSize:
            return Drawing(shapes: [.path("M21.21 15.89A10 10 0 1 1 8 2.83"), .path("M22 12A10 10 0 0 0 12 2v10z")])
        case .title:
            return Drawing(shapes: [.path("M4 9h15", strokeWidth: 2.6), .path("M4 15.5h9")])
        case .copy:
            return Drawing(shapes: [
                .rect(x: 9, y: 9, width: 13, height: 13, radius: 2),
                .path("M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"),
            ])
        case .cut:
            return Drawing(shapes: [
                .circle(x: 6, y: 6, radius: 3), .circle(x: 6, y: 18, radius: 3), .path("M20 4 8.5 15.5"),
                .path("M20 20 10.5 10.5"),
            ])
        case .duplicate:
            return Drawing(shapes: [
                .rect(x: 8, y: 8, width: 13, height: 13, radius: 2),
                .path("M16 8V6a2 2 0 0 0-2-2H6a2 2 0 0 0-2 2v8a2 2 0 0 0 2 2h2"), .path("M14.5 11.5v6M11.5 14.5h6"),
            ])
        case .newFolder:
            return Drawing(shapes: [
                .path(folderOutline), .line(x1: 12, y1: 11, x2: 12, y2: 17), .line(x1: 9, y1: 14, x2: 15, y2: 14),
            ])
        case .copyPath:
            return Drawing(shapes: [
                .path("M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71"),
                .path("M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71"),
            ])
        case .sidebar:
            return Drawing(shapes: [.rect(x: 3, y: 4.5, width: 18, height: 15, radius: 2.5), .path("M9 4.5v15")])
        case .drawer:
            return Drawing(shapes: [.rect(x: 3, y: 4.5, width: 18, height: 15, radius: 2.5), .path("M15 4.5v15")])
        case .foldersFirst:
            return Drawing(shapes: [.path("M4 4h4l1.5 2H20v3H4z"), .path("M4 12h16M4 16h16M4 20h12")])
        default:
            return Drawing(shapes: [.path(singlePath(name))])
        }
    }

    /// The icons drawn as one path.
    static func singlePath(_ name: ToolbarIconName) -> String {
        switch name {
        case .back: "M15 18l-6-6 6-6"
        case .forward: "M9 18l6-6-6-6"
        case .up: "M18 15l-6-6-6 6"
        case .location: "M12 20s6-5.2 6-10a6 6 0 1 0-12 0c0 4.8 6 10 6 10m0-8a2 2 0 1 1 0-4a2 2 0 0 1 0 4"
        case .hidden:
            "M17.94 17.94A10.07 10.07 0 0 1 12 20c-7 0-11-8-11-8a18.45 18.45 0 0 1 5.06-5.94M14.12 14.12A3 3 0 0 1 9.88 9.88M9.9 4.24A9.12 9.12 0 0 1 12 4c7 0 11 8 11 8a18.5 18.5 0 0 1-2.16 3.19M1 1l22 22"
        case .refresh: "M1 4v6h6M3.51 15a9 9 0 1 0 2.13-9.36L1 10"
        case .edit: "M11 4H6a2 2 0 0 0-2 2v12a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-5M18.5 2.5a2.12 2.12 0 0 1 3 3L12 15l-4 1 1-4Z"
        case .theme:
            "M12 2v2M12 20v2M4.93 4.93l1.41 1.41M17.66 17.66l1.41 1.41M2 12h2M20 12h2M6.34 17.66l-1.41 1.41M19.07 4.93l-1.41 1.41M12 16a4 4 0 1 0 0-8a4 4 0 0 0 0 8"
        case .chevron: "M9.5 7l5 5-5 5"
        case .overflow: "M6.5 7l5 5-5 5M12.5 7l5 5-5 5"
        case .close: "M6 6l12 12M18 6l-12 12"
        case .sortAsc: "M12 5v14M5 12l7-7 7 7"
        case .sortDesc: "M12 19V5M5 12l7 7 7-7"
        case .help: "M12 22a10 10 0 1 0 0-20a10 10 0 0 0 0 20M9.1 9a3 3 0 1 1 5.8 1c0 2-3 2-3 4M12 17h.01"
        case .settings:
            "M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 0 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-4 0v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 0 1-2.83-2.83l.06-.06A1.65 1.65 0 0 0 4.68 15a1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1 0-4h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 0 1 2.83-2.83l.06.06A1.65 1.65 0 0 0 9 4.68a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 0 1 2.83 2.83l-.06.06A1.65 1.65 0 0 0 19.4 9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1zM12 15a3 3 0 1 1 0-6 3 3 0 0 1 0 6z"
        case .trash: "M8 6h8M10 6V4h4v2M6 6h12l-1 13a2 2 0 0 1-2 1.85H9A2 2 0 0 1 7 19L6 6M10 10v6M14 10v6"
        case .infoRow: "M3 15h18M3 19h18M4 5h16v6H4z"
        case .paste:
            "M9 4h6M10 2h4a1 1 0 0 1 1 1v2H9V3a1 1 0 0 1 1-1m-3 4h10a2 2 0 0 1 2 2v13a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2m3 5h6m-6 4h6"
        case .move: "M3 12h8M8 9l3 3-3 3M14 8h6l2 2v8a2 2 0 0 1-2 2h-8a2 2 0 0 1-2-2v-2"
        case .terminal: "M4 5h16a2 2 0 0 1 2 2v10a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V7a2 2 0 0 1 2-2m3 4l3 3-3 3m5 2h4"
        case .rename: "M5 5.5h14a2 2 0 0 1 2 2v9a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-9a2 2 0 0 1 2-2zM8.5 9v6M7 9h3M7 15h3"
        default: "M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6M15 3h6v6M10 14L21 3"
        }
    }

    /// Strokes `name` into `rect` in the current context, `strokeWidth` in box units, as `.toolbar-icon` does.
    static func draw(_ name: ToolbarIconName, in rect: NSRect, strokeWidth: Double, color: NSColor, flipped: Bool) {
        let drawing = drawing(name)
        let scale = rect.width / drawing.box
        var transform = AffineTransform(translationByX: rect.minX, byY: flipped ? rect.minY : rect.maxY)
        transform.scale(x: scale, y: flipped ? scale : -scale)
        color.setStroke()
        for shape in drawing.shapes {
            let path: NSBezierPath
            var width = strokeWidth
            switch shape {
            case .path(let data, let override):
                path = SVGPath.path(data)
                if let override { width = override }
            case .rect(let x, let y, let w, let h, let radius):
                path = NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: h), xRadius: radius, yRadius: radius)
            case .circle(let x, let y, let radius):
                path = NSBezierPath(ovalIn: NSRect(x: x - radius, y: y - radius, width: 2 * radius, height: 2 * radius))
            case .line(let x1, let y1, let x2, let y2):
                path = NSBezierPath()
                path.move(to: NSPoint(x: x1, y: y1))
                path.line(to: NSPoint(x: x2, y: y2))
            }
            path.transform(using: transform)
            path.lineWidth = width * scale
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.stroke()
        }
    }

    /// `MenuCheck`'s tick: an 11 pt mark in a 12-unit box, stroke 1.8.
    static func drawCheck(in rect: NSRect, color: NSColor, flipped: Bool) {
        let path = SVGPath.path("M2.5 6.3 5 8.8l4.6-5.6")
        let scale = rect.width / 12
        var transform = AffineTransform(translationByX: rect.minX, byY: flipped ? rect.minY : rect.maxY)
        transform.scale(x: scale, y: flipped ? scale : -scale)
        path.transform(using: transform)
        path.lineWidth = 1.8 * scale
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        color.setStroke()
        path.stroke()
    }
}

/// A stroke icon of its own, as `<ToolbarIcon>` puts one in a button.
final class ToolbarIconView: NSView {
    var name: ToolbarIconName {
        didSet { needsDisplay = true }
    }
    var color: NSColor = .labelColor {
        didSet { needsDisplay = true }
    }
    var strokeWidth: Double {
        didSet { needsDisplay = true }
    }

    init(_ name: ToolbarIconName, strokeWidth: Double = DesignTokens.toolbar.iconStrokeWidth) {
        self.name = name
        self.strokeWidth = strokeWidth
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        ToolbarGlyph.draw(name, in: bounds, strokeWidth: strokeWidth, color: color, flipped: true)
    }
}
