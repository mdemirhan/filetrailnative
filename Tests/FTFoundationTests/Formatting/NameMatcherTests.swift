import Testing

@testable import FTFoundation

struct NameMatcherTests {
    private func marks(_ query: String, _ name: String, _ mode: NameMatchMode = .fuzzy) -> [String] {
        guard let matcher = NameMatcher(query, mode: mode) else { return [] }
        let units = Array(name.utf16)
        return matcher.marks(in: name).map { String(decoding: units[$0.start..<$0.end], as: UTF16.self) }
    }

    @Test func textThatFoldsToNothingMakesNoMatcher() {
        #expect(NameMatcher("", mode: .fuzzy) == nil)
        #expect(NameMatcher(" ", mode: .contains) != nil)
    }

    @Test func marksARunWhereItFirstIs() {
        #expect(marks("port", "report-port.txt", .contains) == ["port"])
        #expect(marks("port", "report-port.txt") == ["port"])
        #expect(marks("zzz", "report.txt", .contains) == [])
    }

    @Test func marksTheLettersAFuzzyMatchFitsBest() {
        // The letters starting words, not the first t and s along the way.
        #expect(marks("fts", "FileTrailSettings.swift") == ["F", "T", "S"])
        #expect(marks("rpt", "report.pdf") == ["r", "p", "t"])
        // Letters side by side are marked as one.
        #expect(marks("filset", "FileTrailSettings.swift") == ["Fil", "Set"])
        #expect(marks("tpr", "report.pdf") == [])
    }

    @Test func marksTheLettersAsTheNameStoresThem() {
        // "é" stored as "e" and its accent: the mark takes both.
        let decomposed = "Cafe\u{301} menu"
        #expect(marks("cafe", decomposed, .contains) == ["Cafe\u{301}"])
        #expect(marks("\u{E9}", decomposed, .contains) == ["e\u{301}"])
        #expect(marks("cm", decomposed) == ["C", "m"])
    }

    @Test func comparesLettersOneWayForAccents() {
        func matches(_ query: String, _ name: String) -> Bool {
            NameMatcher(query, mode: .contains)?.matches(name) ?? false
        }
        #expect(matches("e", "\u{E9}t\u{E9}"))
        #expect(matches("E", "\u{C9}T\u{C9}"))
        #expect(!matches("\u{E9}", "ete"))
        #expect(matches("\u{E9}", "e\u{301}te"))
        // Greek: a plain vowel finds the accented one, and either sigma finds the other.
        #expect(matches("σισυφος", "Σίσυφος"))
        #expect(matches("ς", "σοφία"))
        #expect(matches("σ", "ΟΔΟΣ"))
        // Letters of their own, and scripts whose marks are not accents on a Latin, Greek or Cyrillic letter.
        #expect(!matches("o", "ø"))
        #expect(!matches("l", "ł"))
        #expect(!matches("か", "が"))
        #expect(matches("i", "İzmir"))
        #expect(!matches("ı", "izmir"))
    }

    @Test func fuzzyScoresLettersSideBySideAndAtWordStartsHigher() throws {
        let matcher = try #require(NameMatcher("fts", mode: .fuzzy))
        let wordStarts = try #require(matcher.score("FileTrailSettings.swift"))
        let scattered = try #require(matcher.score("afterthoughts.txt"))
        #expect(wordStarts > scattered)
        #expect(matcher.score("nothing here") == nil)
        let run = try #require(NameMatcher("rep", mode: .fuzzy))
        #expect(try #require(run.score("report")) > (try #require(run.score("ramp-equipment"))))
    }

    @Test func tellsAPrefixAndARunWhateverTheMode() throws {
        let matcher = try #require(NameMatcher("doc", mode: .fuzzy))
        #expect(matcher.isPrefix(of: "Documents"))
        #expect(!matcher.isPrefix(of: "my doc.txt"))
        #expect(matcher.isContained(in: "my doc.txt"))
        #expect(!matcher.isContained(in: "d-o-c"))
        #expect(matcher.matches("d-o-c"))
    }
}
