// The search highlight's pattern is compiled as buildSearchHighlightPattern of
// apps/desktop/src/renderer/lib/searchResults.ts compiles it: `new RegExp(source, "" | "i")`, without the unicode flag
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

    // B-SEL-182: an escape of a character that names nothing is the character.
    @Test func identityEscapeIsMarked() {
        #expect(match("foo\\-bar", in: "foo-bar.txt") == HighlightRange(start: 0, end: 7))
    }

    // B-SEL-182: a lone bracket is a character.
    @Test func loneBracketIsMarked() {
        #expect(match("a]", in: "a].txt") == HighlightRange(start: 0, end: 2))
    }

    // B-SEL-182: `.` is one UTF-16 unit.
    @Test func dotIsOneCodeUnit() {
        #expect(match("^.", in: "🎉 party.txt") == HighlightRange(start: 0, end: 1))
    }

    // B-SEL-182: smart case folds as JavaScript's default mode does, in plain text too.
    @Test func caseFoldsByUppercaseForms() {
        #expect(match("ſ", in: "Sun.txt") == nil)
        #expect(match("ſ", .text, in: "Sun.txt") == nil)
        #expect(match("µ", .text, in: "ΜΑΘ.txt") == HighlightRange(start: 0, end: 1))
        #expect(match("k", .text, in: "\u{212A}elvin k.txt") == HighlightRange(start: 7, end: 8))
    }
}
