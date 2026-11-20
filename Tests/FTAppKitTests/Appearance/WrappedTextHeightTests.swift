// Wrapped text takes the height of the lines it is drawn on
import AppKit
import FTFoundation
import Testing

@testable import FTAppKit

@MainActor
@Suite struct WrappedTextHeightTests {
    /// The row of the lowest ink a view draws, in points from its top.
    private func inkBottom(_ view: NSView) throws -> Double {
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        var lowest = -1
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.2 {
                lowest = y
                break
            }
        }
        return Double(lowest + 1) * Double(view.bounds.height) / Double(rep.pixelsHigh)
    }

    // A description whose first line is a fraction of a point wider than its frame is drawn whole on that line (the
    // cell's box is the frame and its slack). Measured at the frame's width it counted a line more, and its Settings
    // row was a line too tall, with the space under the text.
    @Test func aLineAFractionWiderThanTheFrameIsMeasuredAsItIsDrawn() throws {
        let words =
            "Where a mounted disk image opens, and where an extracted archive opens when it goes to a folder "
            + "not on screen."
        let text = ThemedText(words, style: SettingsStyle.description, wrapping: true)
        let string = text.attributedStringValue
        func lines(_ width: Double) -> Double {
            string.boundingRect(with: NSSize(width: width, height: 10_000), options: [.usesLineFragmentOrigin]).height
        }
        // A frame at which the text, measured at the frame's own width, wraps onto one line more than it does in the
        // box the cell draws it in, the slack wider.
        let slack = Double(TextBoxCell.slack)
        var width = 200.0
        while width < 400, lines(width) == lines(width + slack) { width += 0.5 }
        try #require(width < 400)
        let height = text.height(forWidth: width)
        // To a hundredth: the heights are sums of line heights that aren't whole numbers.
        #expect(abs(height - lines(width + slack)) < 0.01)
        #expect(height < lines(width))
        // And it is drawn on those lines: its ink ends inside the measured height.
        text.frame = NSRect(x: 0, y: 0, width: width, height: lines(width))
        let bottom = try inkBottom(text)
        #expect(bottom > 0)
        #expect(bottom <= height + 0.01)
    }
}
