// Checks the search field's text against apps/desktop/src/renderer/styles.css (.search-field-input, input::placeholder)
import AppKit
import FTFoundation
import Testing

@testable import FTAppKit

@MainActor
@Suite struct ThemedSearchFieldTests {
    /// `padding: 0 4px 0 8px`, the 13 pt icon and 6 of gap, then the input with `padding: 0`.
    private static let textStart = 27.0
    private static let theme = Theme(appearance: .light, accentHex: "#007aff")

    private struct Scan {
        /// Where the leftmost ink of the text starts in the field.
        var inkStart: Double
        /// The ink's top and bottom in the field.
        var inkTop: Double
        var inkBottom: Double
        /// The green value of the darkest pixel of the text: its most covered pixels show the color's own alpha.
        var darkest: Int
    }

    /// A field on white in a window that never comes on screen.
    private func make(text: String = "") -> (ThemedSearchField, NSWindow, NSView) {
        _ = NSApplication.shared
        let host = ThemedView(theme: Self.theme)
        host.fill = { _ in RGBA(r: 255, g: 255, b: 255) }
        host.frame = NSRect(x: 0, y: 0, width: 200, height: 24)
        host.appearance = NSAppearance(named: .aqua)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: true)
        window.contentView = host
        let field = ThemedSearchField(placeholder: "Search help", theme: Self.theme)
        field.frame = host.bounds
        field.text = text
        host.addSubview(field)
        host.layoutSubtreeIfNeeded()
        return (field, window, host)
    }

    private func scan(_ host: NSView) throws -> Scan {
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let scale = Double(rep.pixelsWide) / host.bounds.width
        var result = Scan(inkStart: .infinity, inkTop: .infinity, inkBottom: 0, darkest: 255)
        // Past the icon, inside the edge.
        for x in Int(23 * scale)..<(rep.pixelsWide - Int(26 * scale)) {
            for y in Int(2 * scale)..<(rep.pixelsHigh - Int(2 * scale)) {
                var pixel = [0, 0, 0, 0]
                rep.getPixel(&pixel, atX: x, y: y)
                result.darkest = min(result.darkest, pixel[1])
                guard pixel[1] < 225 else { continue }
                result.inkStart = min(result.inkStart, Double(x) / scale)
                result.inkTop = min(result.inkTop, Double(y) / scale)
                result.inkBottom = max(result.inkBottom, Double(y + 1) / scale)
            }
        }
        return result
    }

    /// `rgba(0, 0, 0, 0.26)` over the field's 3% fill on white: 247 × 0.74 = 183. Drawn twice it comes out at 135.
    private func expectPlaceholderDrawnOnce(_ scan: Scan) {
        #expect(scan.darkest >= 178)
    }

    @Test func thePlaceholderStartsAfterTheIconAndItsGap() throws {
        let (_, _, host) = make()
        let scan = try scan(host)
        // The original's ink: x 37.5 in a field at x 10, y 59 to 71.5 in a field at y 52.
        #expect(abs(scan.inkStart - (Self.textStart + 0.5)) <= 0.5)
        #expect(abs(scan.inkTop - 7) <= 0.5 && abs(scan.inkBottom - 19.5) <= 0.5)
    }

    @Test func thePlaceholderIsDrawnOnce() throws {
        let (_, _, host) = make()
        expectPlaceholderDrawnOnce(try scan(host))
    }

    @Test func thePlaceholderInAFocusedEmptyFieldIsDrawnOnceAndStaysPut() throws {
        let (field, window, host) = make()
        #expect(window.makeFirstResponder(field.input))
        #expect(field.input.currentEditor() != nil)
        let scan = try scan(host)
        expectPlaceholderDrawnOnce(scan)
        #expect(abs(scan.inkStart - (Self.textStart + 0.5)) <= 0.5)
    }

    @Test func typedTextStartsWhereThePlaceholderDoes() throws {
        let (_, _, host) = make(text: "zzzqq")
        // The original's ink: x about 37 in a field at x 10.
        #expect(abs(try scan(host).inkStart - Self.textStart) <= 1)
    }

    @Test func textBeingTypedStartsWhereThePlaceholderDoes() throws {
        let (field, window, host) = make()
        #expect(window.makeFirstResponder(field.input))
        let editor = try #require(field.input.currentEditor() as? NSTextView)
        editor.insertText("zzzqq", replacementRange: NSRange(location: 0, length: 0))
        let scan = try scan(host)
        #expect(field.text == "zzzqq")
        #expect(abs(scan.inkStart - Self.textStart) <= 1)
        // The placeholder has gone: the darkest pixel is the typed text's.
        #expect(scan.darkest < 100)
    }
}
