// Port of apps/desktop/src/renderer/lib/nameHighlight.tsx (findNameMatch, mapMatchToLabel, and the ranges renderMarkedText draws)
import Foundation

/// A stretch of a string, in UTF-16 units as JavaScript counts them: `start` up to, not including, `end`.
public struct HighlightRange: Equatable, Sendable, Codable {
    public var start: Int
    public var end: Int

    public init(start: Int, end: Int) {
        self.start = start
        self.end = end
    }

    public var nsRange: NSRange { NSRange(location: start, length: end - start) }
}

/// What a search matched in names, marked in every view while search results are shown.
public enum NameHighlight {
    private static let ellipsis = UInt16(0x2026)

    /// `findNameMatch`: where `pattern` matches in `name`; nil when it does not, or matches nothing.
    public static func match(_ pattern: JSLegacyRegExp?, in name: String) -> HighlightRange? {
        guard let found = pattern?.firstMatch(in: name), found.range.length > 0 else { return nil }
        return HighlightRange(start: found.range.location, end: found.range.location + found.range.length)
    }

    /// `mapMatchToLabel`: the match in a name as it shows in a label that may have lost its middle
    /// ("Annual…Report.pdf"). The part before the "…" is the start of the name and the part after it the end. What of
    /// the match is still on show is marked; a match (or part of one) that fell in the missing middle marks the "…", so
    /// it is not lost from sight. Ranges side by side come back as one.
    public static func mapToLabel(name: String, label: String, match: HighlightRange) -> [HighlightRange] {
        let nameUnits = Array(name.utf16)
        let labelUnits = Array(label.utf16)
        if nameUnits == labelUnits { return [match] }
        var at = labelUnits.firstIndex(of: ellipsis)
        while let cut = at {
            let head = labelUnits[..<cut]
            let tail = labelUnits[(cut + 1)...]
            if nameUnits.starts(with: head), nameUnits.reversed().starts(with: tail.reversed()),
                head.count + tail.count <= nameUnits.count
            {
                let tailStart = nameUnits.count - tail.count
                var ranges: [HighlightRange] = []
                if match.start < head.count {
                    ranges.append(HighlightRange(start: match.start, end: min(match.end, head.count)))
                }
                if match.end > head.count, match.start < tailStart {
                    ranges.append(HighlightRange(start: cut, end: cut + 1))
                }
                if match.end > tailStart {
                    let start = max(match.start, tailStart) - tailStart + cut + 1
                    ranges.append(HighlightRange(start: start, end: match.end - tailStart + cut + 1))
                }
                return merged(ranges)
            }
            at = labelUnits[(cut + 1)...].firstIndex(of: ellipsis)
        }
        return []
    }

    private static func merged(_ ranges: [HighlightRange]) -> [HighlightRange] {
        var result: [HighlightRange] = []
        for range in ranges {
            if let last = result.last, last.end == range.start {
                result[result.count - 1].end = range.end
            } else {
                result.append(range)
            }
        }
        return result
    }

    /// The marks `renderMarkedText` draws in `text`, whose first unit is at `offset` of the string the ranges count
    /// in: each range cut to the text, in the text's own units. Empty ones, and ones before what was already marked,
    /// are left out.
    public static func marks(in text: String, ranges: [HighlightRange], offset: Int = 0) -> [HighlightRange] {
        let length = text.utf16.count
        var at = 0
        var marks: [HighlightRange] = []
        for range in ranges {
            let start = max(at, range.start - offset)
            let end = min(length, range.end - offset)
            if start >= end { continue }
            marks.append(HighlightRange(start: start, end: end))
            at = end
        }
        return marks
    }
}
