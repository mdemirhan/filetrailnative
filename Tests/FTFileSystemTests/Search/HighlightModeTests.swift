// The search highlight: a regular expression in the system's syntax, or the text itself, with fd's smart case
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

    // Case matters only when the query has a capital letter, in both modes.
    @Test func ignoresCaseUnlessTheQueryHasACapital() {
        #expect(match("rep", in: "Report.pdf") == HighlightRange(start: 0, end: 3))
        #expect(match("Rep", in: "report.pdf") == nil)
        #expect(match("rep", .text, in: "REPORT.pdf") == HighlightRange(start: 0, end: 3))
        #expect(match("Rep", .text, in: "report.pdf") == nil)
    }

    // Glob patterns match whole names, so they mark nothing.
    @Test func marksNothingForAGlob() {
        #expect(match("*.pdf", .glob, in: "report.pdf") == nil)
    }
}
