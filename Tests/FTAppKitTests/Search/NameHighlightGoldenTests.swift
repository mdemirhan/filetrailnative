// What a search marks in names, against the reference (tools/parity/golden/name-highlight.ts): the pattern the query
// makes, its match in the name, and where that shows in a label shortened in the middle, with the JavaScript-compatible
// matcher (D-011)
import FTFileSystem
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTAppKit

@Suite struct NameHighlightGoldenTests {
    struct Input: Codable {
        var name: String
        var label: String
        var query: String
        var patternMode: SearchPatternModePreference
        var matchScope: SearchMatchScopePreference
    }

    struct Output: Codable, Equatable {
        var match: HighlightRange?
        var ranges: [HighlightRange]
    }

    // F-792 B-SEL-182 B-SEL-183
    // T-a62c252e
    @Test func marksWhatTheReferenceMarks() throws {
        let cases: [GoldenCase<Input, Output>] = try Golden.load(suite: "name-highlight")
        #expect(cases.count >= 400)
        Golden.expectMatches(cases) { input in
            let pattern = SearchResults.highlightPattern(
                query: input.query, patternMode: input.patternMode, matchScope: input.matchScope)
            let match = NameHighlight.match(pattern, in: input.name)
            let ranges = match.map { NameHighlight.mapToLabel(name: input.name, label: input.label, match: $0) } ?? []
            return Output(match: match, ranges: ranges)
        }
    }
}
