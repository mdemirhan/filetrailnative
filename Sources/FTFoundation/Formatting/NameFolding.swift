// Names as typed text is compared with them: case aside, and an accented letter the same however it is stored
import Foundation

/// A name compared with what is typed: lowercased, with each accented letter as one character. Disks and apps store
/// some names as a letter followed by its accent, and the keyboard types the composed letter; Swift's `==` takes them
/// as equal, but a search through the text's units does not. Only the comparison uses this: a stored name is never
/// changed.
public enum NameFolding {
    /// `text` lowercased, each accented letter composed.
    public static func folded(_ text: String) -> String {
        let lowered = JSString.lowercased(text)
        return isASCII(lowered) ? lowered : lowered.precomposedStringWithCanonicalMapping
    }

    /// `text` folded as UTF-16 units, with where each unit's character starts and ends in `text`, so that a range
    /// found in the folded text can be marked in the text as stored.
    public struct Mapped: Sendable {
        public let units: [UInt16]
        /// For each unit of `units`, the stored text's units its character spans.
        let spans: [Range<Int>]

        /// A range of `units` as the stored text's units, widened to whole characters.
        public func original(_ range: Range<Int>) -> Range<Int> {
            guard !range.isEmpty, range.lowerBound < spans.count else { return range }
            return spans[range.lowerBound].lowerBound..<spans[min(range.upperBound, spans.count) - 1].upperBound
        }
    }

    public static func mapped(_ text: String) -> Mapped {
        if isASCII(text) {
            let units = Array(JSString.lowercased(text).utf16)
            return Mapped(units: units, spans: units.indices.map { $0..<($0 + 1) })
        }
        // Folded whole, as a letter's case can depend on its neighbours (a final sigma); each character of the folded
        // text is the fold of the stored one at the same place. Should the count differ, each is folded on its own.
        let whole = folded(text)
        let pieces = whole.count == text.count ? whole.map { String($0) } : text.map { folded(String($0)) }
        var units: [UInt16] = []
        var spans: [Range<Int>] = []
        var offset = 0
        for (character, piece) in zip(text, pieces) {
            let stored = String(character).utf16.count
            let foldedUnits = piece.utf16
            units.append(contentsOf: foldedUnits)
            spans.append(contentsOf: repeatElement(offset..<(offset + stored), count: foldedUnits.count))
            offset += stored
        }
        return Mapped(units: units, spans: spans)
    }

    private static func isASCII(_ text: String) -> Bool {
        text.utf8.allSatisfy { $0 < 0x80 }
    }
}
