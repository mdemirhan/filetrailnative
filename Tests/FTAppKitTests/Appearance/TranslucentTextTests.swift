// What AppKit does with a translucent text color, which decides how the app's labels and fields draw theirs
import AppKit
import FTFoundation
import Testing

@testable import FTAppKit

@MainActor
@Suite struct TranslucentTextTests {
    /// Black at half alpha. Drawn once on white its most covered pixels come out at 127 or 128; drawn twice, at 63 or
    /// 64; drawn opaque, at 0.
    private static let halfBlack = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.5)
    private static let font = NSFont.systemFont(ofSize: 40, weight: .black)

    private final class WhiteHost: NSView {
        override var isFlipped: Bool { true }
        override func draw(_ dirtyRect: NSRect) {
            NSColor.white.setFill()
            bounds.fill()
        }
    }

    /// The green value of the darkest pixel `view` draws on white, in a window that never comes on screen: the text's
    /// most covered pixels.
    private func darkest(_ view: NSView) throws -> Int {
        _ = NSApplication.shared
        let host = WhiteHost(frame: NSRect(x: 0, y: 0, width: 300, height: 80))
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: true)
        window.contentView = host
        view.frame = NSRect(x: 10, y: 10, width: 280, height: 60)
        host.addSubview(view)
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        var result = 255
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh {
                var pixel = [0, 0, 0, 0]
                rep.getPixel(&pixel, atX: x, y: y)
                result = min(result, pixel[1])
            }
        }
        return result
    }

    private func drawnOnce(_ value: Int) -> Bool { (120...135).contains(value) }
    private func drawnTwice(_ value: Int) -> Bool { (56...72).contains(value) }

    private func unbordered(_ field: NSTextField) -> NSTextField {
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.placeholderAttributedString = NSAttributedString(
            string: "HHH", attributes: [.font: Self.font, .foregroundColor: Self.halfBlack])
        return field
    }

    // MARK: An unbordered cell with no field editor draws a translucent color twice

    @Test func aLabelDrawsATranslucentTextColorTwice() throws {
        let label = NSTextField(labelWithString: "HHH")
        label.font = Self.font
        label.textColor = Self.halfBlack
        #expect(drawnTwice(try darkest(label)))
    }

    @Test func aPlainLabelDrawsItOnce() throws {
        let label = PlainLabel(labelWithString: "HHH")
        label.font = Self.font
        label.textColor = Self.halfBlack
        #expect(drawnOnce(try darkest(label)))
    }

    @Test func anUnborderedFieldDrawsATranslucentPlaceholderTwice() throws {
        let field = unbordered(NSTextField(string: ""))
        #expect(field.currentEditor() == nil)
        #expect(drawnTwice(try darkest(field)))
    }

    @Test func theSearchFieldsTextFieldDrawsItOnce() throws {
        #expect(drawnOnce(try darkest(unbordered(SearchTextField(string: "")))))
    }
}
