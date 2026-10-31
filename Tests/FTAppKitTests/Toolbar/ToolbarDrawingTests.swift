// Checks the toolbar's text against the rules of apps/desktop/src/renderer/styles.css (.toolbar-menu,
// .history-menu-item, .toolbar-title)
import AppKit
import FTFoundation
import Testing

@testable import FTAppKit

/// Where a view's drawing puts ink, in points from its top left.
struct Ink {
    var minX: Double
    var maxX: Double
    var minY: Double
    var maxY: Double
}

@MainActor
enum InkScan {
    /// The ink of `view` drawn alone (light appearance), within `region` (points from the top left) when given: the
    /// pixels `isInk` picks, by default those mostly opaque.
    static func ink(
        _ view: NSView, in region: NSRect? = nil, isInk: (NSColor) -> Bool = { $0.alphaComponent > 0.3 }
    ) -> Ink? {
        view.appearance = NSAppearance(named: .aqua)
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        let scale = Double(rep.pixelsWide) / view.bounds.width
        let area = region ?? view.bounds
        var ink: Ink?
        for px in 0..<rep.pixelsWide {
            for py in 0..<rep.pixelsHigh {
                let x = Double(px) / scale
                let y = Double(py) / scale
                guard area.contains(NSPoint(x: x, y: y)), let color = rep.colorAt(x: px, y: py), isInk(color)
                else { continue }
                let right = x + 1 / scale
                let bottom = y + 1 / scale
                if var found = ink {
                    found.minX = min(found.minX, x)
                    found.maxX = max(found.maxX, right)
                    found.minY = min(found.minY, y)
                    found.maxY = max(found.maxY, bottom)
                    ink = found
                } else {
                    ink = Ink(minX: x, maxX: right, minY: y, maxY: bottom)
                }
            }
        }
        return ink
    }

    /// The ink of `text` drawn from x = 0 as the original's text box draws it.
    static func ink(of text: String, font: NSFont) -> Ink? {
        let width = (text as NSString).size(withAttributes: [.font: font]).width
        let view = TextBox(frame: NSRect(x: 0, y: 0, width: width + 20, height: 30))
        view.text = text
        view.font = font
        return ink(view)
    }

    final class TextBox: NSView {
        var text = ""
        var font = NSFont.systemFont(ofSize: 13)
        override var isFlipped: Bool { true }
        override func draw(_ dirtyRect: NSRect) {
            (text as NSString).draw(at: .zero, withAttributes: [.font: font, .foregroundColor: NSColor.black])
        }
    }
}

@MainActor
struct ToolbarDrawingTests {
    // The toolbar's title starts at the block's padding: no inset of a text field's own on top.
    @Test func drawsTheTitleFromItsBoxesEdge() throws {
        let title = ToolbarTitleView(frame: NSRect(x: 0, y: 0, width: 260, height: ToolbarTitleView.height))
        title.field.stringValue = "components"
        title.field.textColor = .black
        let titleFont = try #require(title.field.font)
        let titleExpected = try #require(InkScan.ink(of: "components", font: titleFont))
        let titleInk = try #require(InkScan.ink(title))
        #expect(abs(titleInk.minX - (DesignTokens.toolbar.titlePaddingLeading + titleExpected.minX)) < 0.6)
    }
}
