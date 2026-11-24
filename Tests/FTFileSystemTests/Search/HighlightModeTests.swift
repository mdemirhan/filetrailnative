// The search highlight: a regular expression in the system's syntax with the search's smart case, or Plain Text as the filters match
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

    private func marks(_ query: String, _ mode: SearchPatternModePreference = .text, in name: String)
        -> [HighlightRange]
    {
        let pattern = SearchResults.highlightPattern(query: query, patternMode: mode, matchScope: .name)
        return NameHighlight.marks(pattern, in: name)
    }

    private func range(_ start: Int, _ end: Int) -> HighlightRange { HighlightRange(start: start, end: end) }

    // Plain Text marks each word where it is, in the name's order, whatever order they were typed in.
    @Test func plainTextMarksEachWord() {
        #expect(marks("annual report", in: "annual report.pdf") == [range(0, 6), range(7, 13)])
        #expect(marks("report annual", in: "annual report.pdf") == [range(0, 6), range(7, 13)])
        #expect(marks("report   annual", in: "Report, Annual.pdf") == [range(0, 6), range(8, 14)])
        // Each word's first run, even inside another word.
        #expect(marks("do monte", in: "Miradouro do Monte.jpg") == [range(4, 6), range(13, 18)])
        #expect(marks("rep", in: "rep rep.txt") == [range(0, 3)])
    }

    @Test func aPhraseIsMarkedAsOneRun() {
        #expect(marks("\"annual report\"", in: "My annual report.pdf") == [range(3, 16)])
        #expect(marks("\"annual  report\"", in: "annual  report.pdf") == [range(0, 14)])
        #expect(marks("\"annual report\" pdf", in: "annual report.pdf") == [range(0, 13), range(14, 17)])
        #expect(marks("\"kind:pdf\"", in: "kind:pdf notes") == [range(0, 8)])
    }

    // Words that meet or overlap are one mark; a word given twice is marked once.
    @Test func marksThatMeetAreOne() {
        #expect(marks("ab cd", in: "abcd.txt") == [range(0, 4)])
        #expect(marks("ann annual", in: "annual.txt") == [range(0, 6)])
        #expect(marks("nua ann", in: "annual.txt") == [range(0, 5)])
        #expect(marks("a a", in: "a.txt") == [range(0, 1)])
    }

    // Marks are in UTF-16 units of the name as stored, an accent composed or not.
    @Test func wordsAreMarkedInTheNamesOwnUnits() {
        #expect(marks("cafe menu", in: "caf\u{E9} menu.txt") == [range(0, 4), range(5, 9)])
        #expect(marks("cafe menu", in: "cafe\u{301} menu.txt") == [range(0, 5), range(6, 10)])
        #expect(marks("party \u{1F389}", in: "\u{1F389} party.txt") == [range(0, 2), range(3, 8)])
        #expect(marks("\u{65E5}\u{672C} txt", in: "\u{65E5}\u{672C}.txt") == [range(0, 2), range(3, 6)])
    }

    // A name that doesn't hold every word is no result, but each word it holds is still marked where it shows.
    @Test func aNameMissingAWordMarksWhatItHolds() {
        #expect(marks("annual zzz", in: "annual.pdf") == [range(0, 6)])
        #expect(marks("zzz", in: "annual.pdf").isEmpty)
    }

    // A word left out is never marked: a name that has it is no result.
    @Test func wordsLeftOutAreNotMarked() {
        #expect(marks("report !draft", in: "report.pdf") == [range(0, 6)])
        #expect(marks("!draft", in: "notes.txt").isEmpty)
        #expect(marks("annual !\"old copy\" report", in: "annual report.pdf") == [range(0, 6), range(7, 13)])
    }

    // A glob marks nothing, a regular expression its first match, spaces and all.
    @Test func globAndRegexKeepOneMark() {
        #expect(marks("annual *", .glob, in: "annual report.pdf").isEmpty)
        #expect(marks("annual report", .regex, in: "my annual report") == [range(3, 16)])
        #expect(marks("a", .regex, in: "banana") == [range(1, 2)])
        // Searched by path, names are not marked.
        let path = SearchResults.highlightPattern(query: "annual report", patternMode: .text, matchScope: .path)
        #expect(path == nil)
    }

    // In a label that lost its middle, each word shows where it is, a word in the missing middle marking the "…".
    @Test func eachWordShowsInAShortenedLabel() {
        let name = "Panorama from the Miradouro do Monte.jpeg"
        let label = "Panorama from the\u{2026}Monte.jpeg"
        func shown(_ query: String) -> [HighlightRange] {
            NameHighlight.mapToLabel(name: name, label: label, marks: marks(query, in: name))
        }
        #expect(shown("panorama monte") == [range(0, 8), range(18, 23)])
        #expect(shown("panorama miradouro") == [range(0, 8), range(17, 18)])
        // The "…" and what touches it are one mark.
        #expect(shown("the miradouro") == [range(14, 18)])
        #expect(shown("miradouro monte") == [range(17, 23)])
        #expect(shown("\"from the miradouro\"") == [range(9, 18)])
        #expect(shown("zzz").isEmpty)
    }

    // A regular expression marks what it matches, in UTF-16 units of the name.
    @Test func marksWhatARegularExpressionMatches() {
        #expect(match("re[a-z]+", in: "Annual report.pdf") == HighlightRange(start: 7, end: 13))
        #expect(match("^.", in: "🎉 party.txt") == HighlightRange(start: 0, end: 2))
        #expect(match("\\d+", in: "IMG_0042.jpg") == HighlightRange(start: 4, end: 8))
    }

    // One the system doesn't take marks nothing, and the search itself says the pattern isn't valid.
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
