// The search highlight: a regular expression in the system's syntax with fd's smart case, or Plain Text as the filters match
import FTFileSystem
import FTFoundation
import Testing

@Suite struct HighlightModeTests {
    private func match(_ query: String, _ mode: SearchPatternModePreference = .regex, in name: String)
        -> HighlightRange?
    {
        let pattern = SearchResults.highlightPattern(query: query, patternMode: mode, matchScope: .name)
        return NameHighlight.match(pattern, in: name)
    }

    // A regular expression marks what it matches, in UTF-16 units of the name.
    @Test func marksWhatARegularExpressionMatches() {
        #expect(match("re[a-z]+", in: "Annual report.pdf") == HighlightRange(start: 7, end: 13))
        #expect(match("^.", in: "🎉 party.txt") == HighlightRange(start: 0, end: 2))
        #expect(match("\\d+", in: "IMG_0042.jpg") == HighlightRange(start: 4, end: 8))
    }

    // One the system doesn't take marks nothing; the search itself is fd's.
    @Test func marksNothingForAPatternTheSystemDoesntTake() {
        #expect(match("a(", in: "a(.txt") == nil)
        #expect(match("[", in: "[.txt") == nil)
    }

    // Plain text is found as typed: its regex characters are themselves.
    @Test func findsPlainTextAsTyped() {
        #expect(match("a.c", .text, in: "abc a.c") == HighlightRange(start: 4, end: 7))
        #expect(match("(1)", .text, in: "report (1).pdf") == HighlightRange(start: 7, end: 10))
    }

    // A regular expression ignores case only without a capital letter; Plain Text always does.
    @Test func ignoresCaseUnlessARegularExpressionHasACapital() {
        #expect(match("rep", in: "Report.pdf") == HighlightRange(start: 0, end: 3))
        #expect(match("Rep", in: "report.pdf") == nil)
        #expect(match("rep", .text, in: "REPORT.pdf") == HighlightRange(start: 0, end: 3))
        #expect(match("Rep", .text, in: "report.pdf") == HighlightRange(start: 0, end: 3))
    }

    // Plain Text marks an accented letter found by a plain one, the accent kept apart included.
    @Test func marksPlainTextAsTheFiltersMatch() {
        #expect(match("cafe", .text, in: "Caf\u{E9}.txt") == HighlightRange(start: 0, end: 4))
        #expect(match("cafe", .text, in: "Cafe\u{301}.txt") == HighlightRange(start: 0, end: 5))
        #expect(match("caf\u{E9}", .text, in: "cafe.txt") == nil)
    }

    // Glob patterns match whole names, so they mark nothing.
    @Test func marksNothingForAGlob() {
        #expect(match("*.pdf", .glob, in: "report.pdf") == nil)
    }
}
