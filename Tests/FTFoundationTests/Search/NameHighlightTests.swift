// Port of apps/desktop/src/renderer/lib/nameHighlight.test.tsx
import Foundation
import Testing

@testable import FTFoundation

@Suite struct NameHighlightTests {
    private func pattern(_ source: String, ignoreCase: Bool = false) -> JSLegacyRegExp? {
        try? JSLegacyRegExp(source: source, ignoreCase: ignoreCase)
    }

    // T-8f3e7ab6
    @Test func findsTheMatchAndNothingForAnEmptyOne() {
        #expect(
            NameHighlight.match(pattern("rep", ignoreCase: true), in: "Annual Report.pdf")
                == HighlightRange(start: 7, end: 10))
        #expect(NameHighlight.match(pattern("x*"), in: "Report.pdf") == nil)
        #expect(NameHighlight.match(nil, in: "Report.pdf") == nil)
    }

    // T-4885dae3
    // B-VIEW-023
    @Test func marksTheMatchWhereItShowsInALabelShortenedInTheMiddle() {
        let name = "Panorama from the Miradouro do Monte.jpeg"
        let label = "Panorama from the…Monte.jpeg"
        let labelUnits = Array(label.utf16)
        func at(_ text: String) -> HighlightRange {
            let start = (name as NSString).range(of: text).location
            return HighlightRange(start: start, end: start + text.utf16.count)
        }
        func shown(_ text: String) -> [String] {
            NameHighlight.mapToLabel(name: name, label: label, match: at(text)).map {
                String(decoding: labelUnits[$0.start..<$0.end], as: UTF16.self)
            }
        }
        // Before the "…" and after it, as they are.
        #expect(shown("Panorama") == ["Panorama"])
        #expect(shown("Monte") == ["Monte"])
        // Gone in the middle: the "…" stands for it.
        #expect(shown("Miradouro") == ["…"])
        // Across the cut: what shows of it, and the "…", as one mark.
        #expect(shown("the Miradouro") == ["the…"])
        #expect(shown("do Monte") == ["…Monte"])
        // A label that is the whole name.
        #expect(
            NameHighlight.mapToLabel(name: "a.txt", label: "a.txt", match: HighlightRange(start: 0, end: 1))
                == [HighlightRange(start: 0, end: 1)])
    }

    // T-8b4f6a96
    // T-a62c252e
    @Test func drawsTheMarks() {
        // `renderMarkedText`: the marks of a text, the rest plain; the text itself is unchanged.
        #expect(
            NameHighlight.marks(in: "report.ts", ranges: [HighlightRange(start: 0, end: 3)]) == [
                HighlightRange(start: 0, end: 3)
            ])
        // Across a stem and its extension: each part marks its own share, counted from its own start.
        let ranges = [HighlightRange(start: 4, end: 8)]
        #expect(NameHighlight.marks(in: "repo", ranges: ranges) == [])
        #expect(NameHighlight.marks(in: "report", ranges: ranges) == [HighlightRange(start: 4, end: 6)])
        #expect(NameHighlight.marks(in: ".ts", ranges: ranges, offset: 6) == [HighlightRange(start: 0, end: 2)])
        #expect(NameHighlight.marks(in: "abc", ranges: [HighlightRange(start: 5, end: 9)]) == [])
    }
}
