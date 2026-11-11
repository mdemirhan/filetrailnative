import AppKit

extension ThemedText {
    /// The height of the text at this width, each line taking the font's rounded ascent and descent (15 at 13 pt, 14
    /// at 12, 13 at 11), where AppKit's line is taller by a fraction.
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

    /// The width of the text on one line, not rounded up.
    var exactWidth: CGFloat { attributedStringValue.size().width }
}
