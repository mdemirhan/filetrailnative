// Port of fitIconLabel and its measurer (apps/desktop/src/renderer/lib/iconLabel.ts:55-177): the name under an icon,
// wrapped on two lines and shortened in the middle when longer, measured with TextKit in the label's font and width
import AppKit
import FTFoundation

/// The text of names under icons, laid out as `.icon-item-label` lays it out: centred lines of the label's width, at
/// most two.
@MainActor
enum IconLabelText {
    /// The label's font: 13 px (compact 12 px), the sans font.
    static func font(_ layout: IconGridLayout) -> NSFont {
        ThemeFonts.sans(layout.labelFontSize)
    }

    /// A wrapping engine per density, kept: making one for each name would be slow.
    @MainActor
    private final class Wrapper {
        let storage = NSTextStorage()
        let manager = NSLayoutManager()
        let container: NSTextContainer
        let font: NSFont

        init(layout: IconGridLayout) {
            font = IconLabelText.font(layout)
            // `.icon-label-measurer`: the label's width less its padding.
            container = NSTextContainer(
                size: NSSize(width: layout.labelTextWidth, height: CGFloat.greatestFiniteMagnitude))
            container.lineFragmentPadding = 0
            container.lineBreakMode = .byWordWrapping
            manager.addTextContainer(container)
            storage.addLayoutManager(manager)
        }

        /// The ranges (UTF-16) of the lines the text wraps into.
        func lines(_ text: String) -> [NSRange] {
            storage.setAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
            manager.ensureLayout(for: container)
            var ranges: [NSRange] = []
            let glyphs = manager.glyphRange(for: container)
            manager.enumerateLineFragments(forGlyphRange: glyphs) { _, _, _, range, _ in
                ranges.append(self.manager.characterRange(forGlyphRange: range, actualGlyphRange: nil))
            }
            return ranges
        }
    }

    private static var wrappers: [Density: Wrapper] = [:]
    private static var fitted: [String: String] = [:]

    private static func wrapper(_ density: Density) -> Wrapper {
        if let made = wrappers[density] { return made }
        let made = Wrapper(layout: DesignTokens.iconGrid(density: density))
        wrappers[density] = made
        return made
    }

    /// The lines `text` wraps into under an icon.
    static func lines(_ text: String, density: Density) -> [String] {
        let string = text as NSString
        return wrapper(density).lines(text).map { string.substring(with: $0) }
    }

    /// The width `text` takes on one line.
    static func width(_ text: String, density: Density) -> Double {
        Double((text as NSString).size(withAttributes: [.font: wrapper(density).font]).width)
    }

    /// `fitIconLabel`: the name whole when it fits on two lines, shortened in the middle otherwise. The first line stays
    /// as it wraps; what follows is shortened to one line. Remembered per density and name.
    static func fit(name: String, extension fileExtension: String, density: Density) -> String {
        let key = "\(density.isCompact ? "c" : "r")\0\(name)"
        if let cached = fitted[key] { return cached }
        let result = fitNow(name: name, extension: fileExtension, density: density)
        if fitted.count >= IconLabel.fittedLabelCacheMax { fitted.removeAll() }
        fitted[key] = result
        return result
    }

    private static func fitNow(name: String, extension fileExtension: String, density: Density) -> String {
        let engine = wrapper(density)
        let layout = DesignTokens.iconGrid(density: density)
        let lines = engine.lines(name)
        if lines.count <= IconLabel.lineCount { return name }
        let string = name as NSString
        let firstLength = lines.first.map { $0.location + $0.length } ?? 0
        // Half a pixel of slack, as the original's measurer allows.
        let lineWidth = layout.labelTextWidth + 0.5
        let rest = IconLabel.shortenInMiddle(
            name: string.substring(from: firstLength), extension: fileExtension
        ) { width($0, density: density) <= lineWidth }
        let candidate = string.substring(to: firstLength) + rest
        return engine.lines(candidate).count <= IconLabel.lineCount ? candidate : name
    }
}
