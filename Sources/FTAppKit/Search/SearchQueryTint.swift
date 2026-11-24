// The condition words of a search's text, tinted where the text is typed: the toolbar's field and the Edit Search box.
// Drawn over the text, never stored in it: what the field holds stays plain text.
import AppKit
import FTFoundation

@MainActor
enum SearchQueryTint {
    private static let keys: [NSAttributedString.Key] = [
        .foregroundColor, .backgroundColor, .underlineStyle, .underlineColor,
    ]

    /// What each part of `text` is drawn with: a condition word on the accent's soft fill, its word and colon in the
    /// accent; a word whose value can't be read, marked once the caret (`caret`) has left it, or at once when more
    /// typing can't make it one.
    static func spans(_ text: String, caret: Int?, theme: Theme) -> [(NSRange, [NSAttributedString.Key: Any])] {
        var spans: [(NSRange, [NSAttributedString.Key: Any])] = []
        for word in SearchQuery.words(text) where word.key != nil {
            if word.role == .unfinished {
                // Left alone while typed in, if more typing can still make it a value.
                let typing = caret.map { $0 >= word.range.location && $0 <= NSMaxRange(word.range) } ?? false
                guard !(typing && word.canStillBeRead) else { continue }
                spans.append(
                    (
                        word.range,
                        [
                            .underlineStyle: NSUnderlineStyle.thick.rawValue | NSUnderlineStyle.patternDot.rawValue,
                            .underlineColor: NSColor(theme.palette.danger),
                        ]
                    ))
                continue
            }
            spans.append((word.range, [.backgroundColor: NSColor(theme.accent.softBg)]))
            spans.append(
                (
                    NSRange(location: word.range.location, length: word.keyLength),
                    [.foregroundColor: NSColor(theme.accent.solid)]
                ))
        }
        return spans
    }

    /// Takes the tint away: the window's field editor goes on to other fields.
    static func clear(_ textView: NSTextView) {
        if let layout = textView.textLayoutManager {
            for key in keys { layout.removeRenderingAttribute(key, for: layout.documentRange) }
        } else if let layout = textView.layoutManager {
            let all = NSRange(location: 0, length: (textView.string as NSString).length)
            for key in keys { layout.removeTemporaryAttribute(key, forCharacterRange: all) }
        }
    }

    /// Tints `textView`'s text as it is now.
    /// `marksAll`: every word that can't be read is marked, the one at the caret too (Return found them).
    static func apply(to textView: NSTextView, theme: Theme = AppearanceModel.shared.theme, marksAll: Bool = false) {
        let text = textView.string
        let selection = textView.selectedRange()
        let caret = marksAll || selection.length > 0 ? nil : selection.location
        let spans = spans(text, caret: caret, theme: theme)
        // A text view on TextKit 2 has rendering attributes; asking one for its layout manager would turn it back.
        if let layout = textView.textLayoutManager {
            let all = layout.documentRange
            for key in keys { layout.removeRenderingAttribute(key, for: all) }
            guard let content = layout.textContentManager else { return }
            for (range, attributes) in spans {
                guard let start = content.location(all.location, offsetBy: range.location),
                    let end = content.location(start, offsetBy: range.length),
                    let textRange = NSTextRange(location: start, end: end)
                else { continue }
                for (key, value) in attributes { layout.addRenderingAttribute(key, value: value, for: textRange) }
            }
        } else if let layout = textView.layoutManager {
            let all = NSRange(location: 0, length: (text as NSString).length)
            for key in keys { layout.removeTemporaryAttribute(key, forCharacterRange: all) }
            for (range, attributes) in spans { layout.addTemporaryAttributes(attributes, forCharacterRange: range) }
        }
    }
}
