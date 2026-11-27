// The name under an icon, wrapped on two lines and shortened in the middle when longer, measured with TextKit in the
// label's font and width
import AppKit
import FTFoundation

/// The text of names under icons, laid out as the label lays it out: centred lines of the label's width, at most two.
@MainActor
enum IconLabelText {
    /// The label's font: the system font at 13 pt (12 pt with Finder's sizes).
    static func font(_ layout: IconGridLayout) -> NSFont {
        ThemeFonts.sans(layout.labelFontSize)
    }

    /// A wrapping engine per font size and label width, kept: making one for each name would be slow.
    @MainActor
    private final class Wrapper {
        let storage = NSTextStorage()
        let manager = NSLayoutManager()
        let container: NSTextContainer
        let font: NSFont

        init(layout: IconGridLayout) {
            font = IconLabelText.font(layout)
            // The label's width less its padding.
            container = NSTextContainer(
                size: NSSize(width: layout.labelTextWidth, height: CGFloat.greatestFiniteMagnitude))
            container.lineFragmentPadding = 0
            container.lineBreakMode = .byWordWrapping
            manager.addTextContainer(container)
            storage.addLayoutManager(manager)
        }

        /// The ranges (UTF-16) of the lines the text wraps into.
        func lines(_ text: String, firstLineIndent: CGFloat = 0) -> [NSRange] {
            let paragraph = NSMutableParagraphStyle()
            paragraph.firstLineHeadIndent = firstLineIndent
            storage.setAttributedString(
                NSAttributedString(string: text, attributes: [.font: font, .paragraphStyle: paragraph]))
            manager.ensureLayout(for: container)
            var ranges: [NSRange] = []
            let glyphs = manager.glyphRange(for: container)
            manager.enumerateLineFragments(forGlyphRange: glyphs) { _, _, _, range, _ in
                ranges.append(self.manager.characterRange(forGlyphRange: range, actualGlyphRange: nil))
            }
            return ranges
        }
    }

    private struct WrapperKey: Hashable {
        var fontSize: Double
        var textWidth: Double
    }

    private static var wrappers: [WrapperKey: Wrapper] = [:]
    private static var fitted: [String: String] = [:]

    private static func wrapper(_ layout: IconGridLayout) -> Wrapper {
        let key = WrapperKey(fontSize: layout.labelFontSize, textWidth: layout.labelTextWidth)
        if let made = wrappers[key] { return made }
        let made = Wrapper(layout: layout)
        wrappers[key] = made
        return made
    }

    /// The lines and the widths of names laid out before, by font size (and width and indent for lines) and name:
    /// laying a name out is most of what an item costs as it comes on screen, and the same names come back on every
    /// filter, scroll back, Back and Forward. They start over past `IconLabel.fittedLabelCacheMax` names, more than
    /// a folder of ten thousand items needs.
    private static var linesCache: [String: [String]] = [:]
    private static var widthCache: [String: Double] = [:]

    /// Lets go of every name remembered: when macOS says memory is short.
    static func forgetNames() {
        fitted = [:]
        linesCache = [:]
        widthCache = [:]
    }

    /// The lines `text` wraps into under an icon.
    static func lines(_ text: String, layout: IconGridLayout, firstLineIndent: CGFloat = 0) -> [String] {
        let key = "\(layout.labelFontSize):\(layout.labelTextWidth):\(firstLineIndent)\0\(text)"
        if let cached = linesCache[key] { return cached }
        let string = text as NSString
        let result = wrapper(layout).lines(text, firstLineIndent: firstLineIndent).map { string.substring(with: $0) }
        if linesCache.count >= IconLabel.fittedLabelCacheMax { linesCache.removeAll() }
        linesCache[key] = result
        return result
    }

    /// The width `text` takes on one line.
    static func width(_ text: String, layout: IconGridLayout) -> Double {
        let key = "\(layout.labelFontSize)\0\(text)"
        if let cached = widthCache[key] { return cached }
        let result = measure(text, layout: layout)
        if widthCache.count >= IconLabel.fittedLabelCacheMax { widthCache.removeAll() }
        widthCache[key] = result
        return result
    }

    /// The width `text` takes on one line, not remembered: the shortenings tried while fitting a name, which would
    /// fill the cache with widths read once.
    private static func measure(_ text: String, layout: IconGridLayout) -> Double {
        Double((text as NSString).size(withAttributes: [.font: wrapper(layout).font]).width)
    }

    /// The name whole when it fits on two lines, shortened in the middle otherwise. The first line stays
    /// as it wraps, after the tag dots if there are any; what follows is shortened to one line. Remembered per font
    /// size, label width, indent and name.
    static func fit(
        name: String, extension fileExtension: String, layout: IconGridLayout, firstLineIndent: CGFloat = 0
    ) -> String {
        let key = "\(layout.labelFontSize):\(layout.labelTextWidth):\(firstLineIndent)\0\(name)"
        if let cached = fitted[key] { return cached }
        let result = fitNow(
            name: name, extension: fileExtension, layout: layout, firstLineIndent: firstLineIndent)
        if fitted.count >= IconLabel.fittedLabelCacheMax { fitted.removeAll() }
        fitted[key] = result
        return result
    }

    private static func fitNow(
        name: String, extension fileExtension: String, layout: IconGridLayout, firstLineIndent: CGFloat
    ) -> String {
        let engine = wrapper(layout)
        let lines = engine.lines(name, firstLineIndent: firstLineIndent)
        if lines.count <= IconLabel.lineCount { return name }
        let string = name as NSString
        let firstLength = lines.first.map { $0.location + $0.length } ?? 0
        // Half a pixel of slack.
        let lineWidth = layout.labelTextWidth + 0.5
        let rest = IconLabel.shortenInMiddle(
            name: string.substring(from: firstLength), extension: fileExtension
        ) { measure($0, layout: layout) <= lineWidth }
        let candidate = string.substring(to: firstLength) + rest
        return engine.lines(candidate, firstLineIndent: firstLineIndent).count <= IconLabel.lineCount ? candidate : name
    }
}
