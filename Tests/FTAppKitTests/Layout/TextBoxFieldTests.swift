// Checkpoint resume-2026-10-19 (143, 148, 156, 159, 59): a label laid out at the original's text width draws its whole
// text, left, centered or right-aligned, on one line or wrapped
import AppKit
import Testing

@testable import FTAppKit

@MainActor
struct TextBoxFieldTests {
    static let samples = [
        "1 of 14 selected · 46 B", "14 items", "TripCard.jsx", "Document · 46 B", "Open in Zed", "filetrail-dev",
    ]
    static let fonts: [NSFont] = [
        tabularFont(11), tabularFont(13), ChromeColors.font(size: 15, weight: 600), ChromeColors.font(size: 13),
    ]

    /// The pixels the label draws, at two to the point, in a frame at x of the given width.
    func pixels(_ field: NSTextField, x: Double, width: Double) -> [UInt8] {
        let size = NSSize(width: 360, height: 40)
        guard
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(size.width) * 2, pixelsHigh: Int(size.height) * 2,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: rep)
        else { return [] }
        field.frame = NSRect(x: x, y: 4, width: width, height: 30)
        NSGraphicsContext.saveGraphicsState()
        // A Retina screen's two pixels to the point.
        context.cgContext.scaleBy(x: 2, y: 2)
        context.cgContext.translateBy(x: x, y: size.height - 4)
        context.cgContext.scaleBy(x: 1, y: -1)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
        field.cell?.draw(withFrame: field.bounds, in: field)
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.bitmapData else { return [] }
        return Array(UnsafeBufferPointer(start: data, count: rep.bytesPerRow * rep.pixelsHigh))
    }

    func field(_ text: String, _ font: NSFont, _ alignment: NSTextAlignment) -> TextBoxField {
        let field = TextBoxField(labelWithString: text)
        field.font = font
        field.alignment = alignment
        field.lineBreakMode = .byTruncatingTail
        field.textColor = .black
        return field
    }

    @Test(arguments: [NSTextAlignment.left, .center, .right])
    func aFrameAsWideAsTheTextDrawsAllOfIt(_ alignment: NSTextAlignment) {
        for font in Self.fonts {
            for text in Self.samples {
                let label = field(text, font, alignment)
                let width = textExtent(text, font)
                let cell = label.cell as? TextBoxCell
                #expect(cell?.truncates(in: NSSize(width: width, height: 30)) == false, "\(text) \(font.pointSize)")
                #expect(cell?.truncates(in: NSSize(width: width - 6, height: 30)) == true, "\(text) \(font.pointSize)")
                // The same pixels as in a frame 40 wider, with the text in the same place: nothing is cut.
                let shift = alignment == .left ? 0 : alignment == .center ? 20 : 40
                let exact = pixels(label, x: 20.3, width: width)
                let roomy = pixels(label, x: 20.3 - Double(shift), width: width + 40)
                #expect(exact == roomy, "\(text) \(font.pointSize) \(alignment.rawValue)")
                #expect(pixels(label, x: 20.3, width: width - 6) != exact, "\(text) \(font.pointSize)")
            }
        }
    }

    @Test func aPlainLabelCutsTheSameText() {
        // What the checkpoint saw: AppKit's own label draws "TripCard.j…" in the text's width.
        let font = ChromeColors.font(size: 15, weight: 600)
        let plain = NSTextField(labelWithString: "TripCard.jsx")
        plain.font = font
        plain.alignment = .center
        plain.lineBreakMode = .byTruncatingTail
        plain.textColor = .black
        let width = textExtent("TripCard.jsx", font)
        #expect(pixels(plain, x: 20.3, width: width) != pixels(plain, x: 0.3, width: width + 40))
    }

    @Test func textStartsAtTheFramesEdge() throws {
        func firstInk(_ field: NSTextField) -> Int? {
            let drawn = pixels(field, x: 20, width: 200)
            let row = 4 * 2 * 360
            return (0..<(360 * 2)).first { x in (0..<80).contains { y in drawn[y * row + x * 4 + 3] > 0 } }
        }
        let font = ChromeColors.font(size: 13)
        let plain = NSTextField(labelWithString: "TripCard.jsx")
        plain.font = font
        plain.textColor = .black
        let box = try #require(firstInk(field("TripCard.jsx", font, .left)))
        // 2 pt (4 pixels) nearer the frame's edge than a plain label's text.
        let plainInk = try #require(firstInk(plain))
        #expect(plainInk - box == 4, "\(plainInk) \(box)")
        #expect(box < 40 + 2)
    }

    // P5-11: the other labels laid out at their text's width are text boxes too: FlushTextField (the Info Row, folder
    // sizes, menus, the toolbar's title) and ListLabel's ThemedTextCell, with its leading inset.
    @Test func flushAndListLabelsDrawTheirWholeText() throws {
        #expect(FlushTextField(labelWithString: "x").cell is TextBoxCell)
        #expect(ListLabel().cell is TextBoxCell)
        let font = ChromeColors.font(size: 13)
        for text in Self.samples {
            let width = textExtent(text, font)
            let flush = FlushTextField(labelWithString: text)
            let list = ListLabel()
            list.stringValue = text
            for label in [flush, list] as [NSTextField] {
                label.font = font
                label.textColor = .black
                label.lineBreakMode = .byTruncatingTail
                #expect(pixels(label, x: 20.3, width: width) == pixels(label, x: 20.3, width: width + 40), "\(text)")
            }
            let inset = try #require(list.cell as? ThemedTextCell)
            inset.leadingInset = 10
            #expect(pixels(list, x: 20.3, width: width + 10) == pixels(list, x: 20.3, width: width + 50), "\(text)")
            #expect(pixels(list, x: 20.3, width: width + 4) != pixels(list, x: 20.3, width: width + 50), "\(text)")
        }
    }

    @Test func aWrappedLabelTruncatesItsLastLine() {
        let label = TextBoxField(wrappingLabelWithString: String(repeating: "word ", count: 30))
        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byTruncatingTail
        label.font = ChromeColors.font(size: 13)
        let cell = label.cell as? TextBoxCell
        #expect(cell?.isMultiline == true)
        #expect(cell?.truncates(in: NSSize(width: 120, height: 32)) == true)
        #expect(cell?.truncates(in: NSSize(width: 2000, height: 32)) == false)
        #expect(TextBoxField(labelWithString: "x").cell.map { ($0 as? TextBoxCell)?.isMultiline } == false)
    }
}
