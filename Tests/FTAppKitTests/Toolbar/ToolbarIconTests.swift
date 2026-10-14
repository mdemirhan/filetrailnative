// Ports apps/desktop/src/renderer/components/ToolbarIcon.test.tsx
import AppKit
import FTFoundation
import Testing

@testable import FTAppKit

@MainActor
struct ToolbarIconTests {
    /// The icon's strokes, as one path in its own 24 (or 16) unit box.
    func outline(_ name: ToolbarIconName) -> NSBezierPath {
        let combined = NSBezierPath()
        for shape in ToolbarGlyph.drawing(name).shapes {
            switch shape {
            case .path(let data, _): combined.append(SVGPath.path(data))
            case .rect(let x, let y, let w, let h, let r):
                combined.append(
                    NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: h), xRadius: r, yRadius: r))
            case .circle(let x, let y, let r):
                combined.append(NSBezierPath(ovalIn: NSRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)))
            case .line(let x1, let y1, let x2, let y2):
                combined.move(to: NSPoint(x: x1, y: y1))
                combined.line(to: NSPoint(x: x2, y: y2))
            }
        }
        return combined
    }

    func signature(_ name: ToolbarIconName) -> String {
        let path = outline(name)
        var points: [String] = []
        var buffer = [NSPoint](repeating: .zero, count: 3)
        for index in 0..<path.elementCount {
            let kind = path.element(at: index, associatedPoints: &buffer)
            points.append("\(kind.rawValue):\(Int(buffer[0].x * 10)),\(Int(buffer[0].y * 10))")
        }
        return points.joined(separator: " ")
    }

    // T-041e07d7 F-830 B-VIEW-121
    @Test func rendersAnIconForEverySupportedToolbarGlyphName() {
        for name in ToolbarIconName.allCases {
            let path = outline(name)
            #expect(!path.isEmpty, "\(name)")
            let box = ToolbarGlyph.drawing(name).box
            #expect(path.bounds.maxX <= box + 1 && path.bounds.maxY <= box + 1, "\(name)")
        }
        // Every toolbar item's icon is one of them.
        for id in ToolbarItemID.allCases { #expect(!outline(ToolbarItems.definition(id).icon).isEmpty) }
    }

    // T-09f56d9d
    @Test func rendersSpecializedShapesForListDetailsSearchClearAndStopIcons() {
        let shapes: [ToolbarIconName] = [.list, .details, .search, .clear, .stop]
        #expect(Set(shapes.map(signature)).count == shapes.count)
        #expect(ToolbarGlyph.drawing(.clear).box == 16)
        #expect(ToolbarGlyph.drawing(.stop).box == 16)
    }

    // T-b37e3307
    @Test func rendersTheExternalOpenIconForTheOpenAction() {
        #expect(ToolbarItems.definition(.openSelection).icon == .open)
        #expect(ToolbarGlyph.singlePath(.open).hasPrefix("M18 13v6"))
    }

    // T-93d6707c
    @Test func rendersDistinctIconsForCopyVsCopyPath() {
        #expect(signature(.copy) != signature(.copyPath))
    }

    // T-f5eb72c4
    @Test func centersTheDisclosureChevronInItsBoxSoItTurnsInPlaceWhenRotated() {
        let bounds = outline(.chevron).bounds
        #expect(abs(bounds.midX - 12) < 0.01)
        #expect(abs(bounds.midY - 12) < 0.01)
    }

    // T-f9b932ba
    @Test func rendersDistinctIconsForEditVsRename() {
        #expect(signature(.edit) != signature(.rename))
    }

    @Test func readsArcsAndSmoothCurves() {
        // The hidden-files eye uses `s`; the location pin uses arcs.
        #expect(outline(.hiddenShown).bounds.width > 19)
        let pin = outline(.location).bounds
        #expect(abs(pin.midX - 12) < 0.5)
    }
}
