// Port of ContextMenuIcon (apps/desktop/src/renderer/components/ItemContextMenu.tsx) and EjectIcon.tsx
import AppKit
import FTFoundation

/// The right-click menu's line icons, redrawn from the same SVG shapes as 14 pt template images.
enum ContextMenuGlyph {
    private typealias Shape = ToolbarGlyph.Shape

    private static let folder = ToolbarGlyph.folderOutline
    private static let trashCan = "M8 6h8M10 6V4h4v2M6 6h12l-1 13a2 2 0 0 1-2 1.85H9A2 2 0 0 1 7 19L6 6M10 10v6M14 10v6"

    static func drawing(_ name: ContextMenuIconName) -> ToolbarGlyph.Drawing {
        let shapes: [Shape]
        switch name {
        case .eject:
            shapes = [.path("M12 5.5l7 8H5z"), .path("M5 18.5h14")]
        case .revealInFolder:
            shapes = [.path(folder), .path("M12 10h6"), .path("M15 7l3 3-3 3")]
        case .revealInTree:
            shapes = [.path("M4 6h16"), .path("M4 12h10"), .path("M4 18h10"), .path("M16 9l4 3-4 3")]
        case .rootTreeHere:
            shapes = [
                .path("M4 5h8"), .path("M8 5v12h6"), .path("M8 11h6"), .path("M17 9l3 2-3 2"), .path("M17 15l3 2-3 2"),
            ]
        case .openFile:
            shapes = [
                .path("M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8z"),
                .path("M14 3v5h5M9.5 15.5l5-5M11 10.5h3.5V14"),
            ]
        case .quickLook:
            shapes = [
                .rect(x: 4, y: 4, width: 16, height: 16, radius: 2), .path("M14 7h3v3M10 17H7v-3M17 7l-4 4M7 17l4-4"),
            ]
        case .viewAs:
            shapes = [
                .rect(x: 4, y: 4, width: 6.5, height: 6.5, radius: 1.5),
                .rect(x: 13.5, y: 4, width: 6.5, height: 6.5, radius: 1.5),
                .rect(x: 4, y: 13.5, width: 6.5, height: 6.5, radius: 1.5),
                .rect(x: 13.5, y: 13.5, width: 6.5, height: 6.5, radius: 1.5),
            ]
        case .sortBy:
            shapes = [.path("M8 4v16M4 16l4 4 4-4M16 20V4M12 8l4-4 4 4")]
        case .open:
            shapes = [.path(folder)]
        case .openInNewTab:
            shapes = [.path("M3 19V7a2 2 0 0 1 2-2h5l2 3h7a2 2 0 0 1 2 2v9z"), .path("M12 12v5M9.5 14.5h5")]
        case .openInNewWindow:
            shapes = [.rect(x: 3, y: 4, width: 18, height: 16, radius: 2), .path("M3 8h18M12 11v6M9 14h6")]
        case .openWith:
            shapes = [
                .path("M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6"), .path("M15 3 21 3 21 9"),
                .line(x1: 10, y1: 14, x2: 21, y2: 3),
            ]
        case .showInfo:
            shapes = [
                .circle(x: 12, y: 12, radius: 10), .line(x1: 12, y1: 16, x2: 12, y2: 12),
                .line(x1: 12, y1: 8, x2: 12.01, y2: 8),
            ]
        case .calculateSize:
            // A pie chart: how much the folder takes up.
            shapes = [.path("M21.21 15.89A10 10 0 1 1 8 2.83"), .path("M22 12A10 10 0 0 0 12 2v10z")]
        case .favorite:
            shapes = [.path("m12 17.27-5.18 3.05 1.39-5.88L3 9.97l6.01-.5L12 4l2.99 5.47 6.01.5-5.21 4.47 1.39 5.88Z")]
        case .edit:
            shapes = [
                .path("M11 4H6a2 2 0 0 0-2 2v12a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-5"),
                .path("M18.5 2.5a2.12 2.12 0 0 1 3 3L12 15l-4 1 1-4Z"),
            ]
        case .copy:
            shapes = [
                .rect(x: 9, y: 9, width: 13, height: 13, radius: 2),
                .path("M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"),
            ]
        case .cut:
            shapes = [
                .circle(x: 6, y: 6, radius: 3), .circle(x: 6, y: 18, radius: 3), .path("M20 4 8.5 15.5"),
                .path("M20 20 10.5 10.5"),
            ]
        case .paste:
            shapes = [
                .path(
                    "M9 4h6M10 2h4a1 1 0 0 1 1 1v2H9V3a1 1 0 0 1 1-1m-3 4h10a2 2 0 0 1 2 2v13a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2m3 5h6m-6 4h6"
                )
            ]
        case .move:
            shapes = [.path("M3 12h8M8 9l3 3-3 3M14 8h6l2 2v8a2 2 0 0 1-2 2h-8a2 2 0 0 1-2-2v-2")]
        case .rename:
            shapes = [
                .path("M5 5.5h14a2 2 0 0 1 2 2v9a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-9a2 2 0 0 1 2-2zM8.5 9v6M7 9h3M7 15h3")
            ]
        case .duplicate:
            shapes = [
                .rect(x: 8, y: 8, width: 13, height: 13, radius: 2),
                .path("M16 8V6a2 2 0 0 0-2-2H6a2 2 0 0 0-2 2v8a2 2 0 0 0 2 2h2"),
                .path("M14.5 11.5v6M11.5 14.5h6"),
            ]
        case .newFolder:
            shapes = [.path(folder), .line(x1: 12, y1: 11, x2: 12, y2: 17), .line(x1: 9, y1: 14, x2: 15, y2: 14)]
        case .terminal:
            shapes = [.path("M4 5h16a2 2 0 0 1 2 2v10a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V7a2 2 0 0 1 2-2m3 4l3 3-3 3m5 2h4")]
        case .showInFinder:
            shapes = [.path(folder), .circle(x: 11.5, y: 13, radius: 2.5), .path("M13.5 15l2.5 2.5")]
        case .copyPath:
            shapes = [
                .path("M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71"),
                .path("M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71"),
            ]
        case .showPackageContents:
            shapes = [.rect(x: 3, y: 3, width: 18, height: 18, radius: 2), .path("M9 3v18M3 9h6")]
        case .deleteImmediately, .emptyTrash, .trash:
            shapes = [.path(trashCan)]
        }
        return ToolbarGlyph.Drawing(shapes: shapes)
    }

    /// The icon as the menu draws it: 14 pt, stroked 1.8, a template image so the menu tints it like its text.
    @MainActor
    static func image(_ name: ContextMenuIconName) -> NSImage {
        let size = NSSize(width: DesignTokens.menu.iconSize, height: DesignTokens.menu.iconSize)
        let drawing = drawing(name)
        let image = NSImage(size: size, flipped: true) { rect in
            ToolbarGlyph.draw(
                drawing, in: rect, strokeWidth: DesignTokens.menu.iconStrokeWidth, color: .black, flipped: true)
            return true
        }
        image.isTemplate = true
        return image
    }
}
