// Port of how Chromium measures the text of apps/desktop/src/renderer/styles.css where it sets no line height
// (`line-height: normal`) and no width (a box as wide as its text, to the fraction)
import AppKit

extension ThemedText {
    /// The height CSS gives the text at this width with `line-height: normal`: each line takes the font's rounded
    /// ascent and descent (15 at 13 pt, 14 at 12, 13 at 11), where AppKit's line is taller by a fraction.
    func normalLineBoxHeight(forWidth width: CGFloat) -> CGFloat {
        let raw = height(forWidth: width)
        guard raw > 0, attributedStringValue.length > 0,
            let font = attributedStringValue.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        else {
            return raw
        }
        let natural = font.ascender - font.descender + font.leading
        return max(1, (raw / natural).rounded()) * ThemeFonts.normalLineHeight(font)
    }

    /// The width of the text on one line, not rounded up, as a CSS box as wide as its text.
    var exactWidth: CGFloat { attributedStringValue.size().width }
}
