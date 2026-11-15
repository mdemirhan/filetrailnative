// A search's mark stays on its letters when the name it is in is cut short with an ellipsis
import AppKit
import FTFoundation
import Testing

@testable import FTAppKit

@MainActor
struct MarkedNameTests {
    static let name = "-Users-demo-src-swiftproj-filetrail--claude-worktrees-code-audit-followup-9419c2"

    /// The pixels of `line` drawn `width` wide, at two to the point, in the columns before `upTo` points.
    func pixels(_ line: MarkedName.Line, width: CGFloat, upTo: CGFloat, font: NSFont) -> [[UInt8]] {
        let size = NSSize(width: 700, height: 24)
        guard
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(size.width) * 2, pixelsHigh: Int(size.height) * 2,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: rep),
            let data = rep.bitmapData
        else { return [] }
        NSGraphicsContext.saveGraphicsState()
        context.cgContext.scaleBy(x: 2, y: 2)
        context.cgContext.translateBy(x: 0, y: size.height)
        context.cgContext.scaleBy(x: 1, y: -1)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
        MarkedName.draw(
            line, at: NSPoint(x: 0, y: 2), width: width, lineHeight: 20, font: font, color: .black,
            underlined: false, truncates: true, in: NSView())
        NSGraphicsContext.restoreGraphicsState()
        let columns = Int(upTo * 2) * 4
        return (0..<rep.pixelsHigh).map { row in
            Array(UnsafeBufferPointer(start: data + row * rep.bytesPerRow, count: columns))
        }
    }

    @Test func aMarkStaysOnItsLettersWhenTheNameIsCutShort() throws {
        let font = NSFont.systemFont(ofSize: 13)
        let start = (Self.name as NSString).range(of: "filetrail").location
        let match = HighlightRange(start: start, end: start + "filetrail".utf16.count)
        let line = MarkedName.Line(
            Self.name, marks: [match], attributes: [.font: font, .foregroundColor: NSColor.black], padding: 2)
        let markEnd = line.offset(match.end)
        // Cut well after the mark, so what is up to its end shows in both: it draws the same as in the whole name.
        let cut = markEnd + 120
        try #require(cut < line.width)
        let whole = pixels(line, width: line.width + 10, upTo: markEnd, font: font)
        let short = pixels(line, width: cut, upTo: markEnd, font: font)
        try #require(!whole.isEmpty && whole.count == short.count)
        let differing = zip(whole, short).reduce(0) { count, rows in
            count + zip(rows.0, rows.1).filter { $0 != $1 }.count
        }
        #expect(differing == 0)
    }
}
