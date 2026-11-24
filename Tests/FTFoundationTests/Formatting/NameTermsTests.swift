// Plain Text a search finds names by, as words: how the text is cut into words, what a name must hold, what is marked
// in it, and when one search's text finds no more than another's.
import FTFoundation
import Foundation
import Testing

@Suite struct NameTermsTests {
    private func matches(_ text: String, _ name: String) -> Bool { NameTerms(text)?.matches(name) ?? true }

    // MARK: Words

    @Test func whiteSpaceSeparatesWords() {
        #expect(NameTerms.words("annual report") == ["annual", "report"])
        #expect(NameTerms.words("  annual    report  ") == ["annual", "report"])
        #expect(NameTerms.words("a\tb\nc") == ["a", "b", "c"])
        #expect(NameTerms.words("a\u{00A0}b") == ["a", "b"])
        #expect(NameTerms.words("").isEmpty)
        #expect(NameTerms.words("   ").isEmpty)
    }

    @Test func quotesKeepAPhraseAsTyped() {
        #expect(NameTerms.words("\"annual  report\" 2025") == ["annual  report", "2025"])
        #expect(NameTerms.words("2025 \"annual report\"") == ["2025", "annual report"])
        #expect(NameTerms.words("\"a\" \"b c\"") == ["a", "b c"])
        #expect(NameTerms.words("\"   \"") == ["   "])
        #expect(NameTerms.words("\"Café Noir\"") == ["Café Noir"])
        // Right after the closing quote, a new word starts.
        #expect(NameTerms.words("\"a b\"c") == ["a b", "c"])
    }

    @Test func emptyQuotesAreNoWord() {
        #expect(NameTerms.words("\"\"").isEmpty)
        #expect(NameTerms.words("\"\" a") == ["a"])
        #expect(NameTerms("\"\"") == nil)
    }

    // A quote that opens no phrase is a character of its word.
    @Test func aLoneQuoteIsACharacter() {
        #expect(NameTerms.words("\"annual report") == ["\"annual", "report"])
        #expect(NameTerms.words("5\" floppy") == ["5\"", "floppy"])
        #expect(NameTerms.words("a\"b c\"") == ["a\"b", "c\""])
        #expect(NameTerms.words("\"") == ["\""])
        // Three quotes: a phrase, then a lone one.
        #expect(NameTerms.words("\"a\" \"") == ["a", "\""])
    }

    // MARK: Matching

    @Test func everyWordMustBeInTheName() {
        #expect(matches("annual report", "annual report 2025.pdf"))
        #expect(matches("annual report", "Report, Annual.pdf"))
        #expect(matches("report annual", "annual_report.pdf"))
        #expect(!matches("annual report", "annual.pdf"))
        #expect(!matches("annual report", "report.pdf"))
        // Extra spaces between words change nothing.
        #expect(matches("annual     report", "annual report.pdf"))
    }

    @Test func aPhraseMustBeInTheNameAsTyped() {
        #expect(matches("\"annual report\"", "My Annual Report.pdf"))
        #expect(!matches("\"annual report\"", "report annual.pdf"))
        #expect(!matches("\"annual report\"", "annual_report.pdf"))
        #expect(matches("\"annual  report\"", "annual  report.pdf"))
        #expect(!matches("\"annual  report\"", "annual report.pdf"))
        #expect(matches("\"kind:pdf\"", "kind:pdf notes.txt"))
    }

    @Test func eachWordMatchesAsContainsDoes() {
        #expect(matches("cafe", "Café.txt"))
        #expect(!matches("café", "Cafe.txt"))
        #expect(matches("REPORT", "report.pdf"))
        #expect(matches("rep 25", "report-2025.pdf"))
        // A word given twice is still one word to find.
        #expect(matches("a a", "a.txt"))
    }

    @Test func textWithNoWordFindsEverything() {
        #expect(NameTerms("") == nil)
        #expect(NameTerms("   ") == nil)
    }

    @Test func asciiBytesAreMatchedWordByWord() {
        let terms = NameTerms("annual report")!
        func bytes(_ name: String) -> Bool? {
            Array(name.utf8).withUnsafeBufferPointer { terms.matches(asciiBytes: $0) }
        }
        #expect(bytes("report-annual.pdf") == true)
        #expect(bytes("annual.pdf") == false)
        // A word beyond ASCII can't be told from the bytes.
        let accented = NameTerms("café report")!
        let unknown = Array("cafe report.pdf".utf8).withUnsafeBufferPointer { accented.matches(asciiBytes: $0) }
        #expect(unknown == nil || unknown == false)
    }

    // MARK: Marks

    @Test func eachWordIsMarked() {
        let terms = NameTerms("report annual")!
        #expect(
            terms.marks(in: "annual report.pdf") == [
                HighlightRange(start: 0, end: 6), HighlightRange(start: 7, end: 13),
            ])
        // Words that overlap or meet are one mark.
        #expect(NameTerms("ann annual")!.marks(in: "annual.pdf") == [HighlightRange(start: 0, end: 6)])
        #expect(NameTerms("ab cd")!.marks(in: "abcd") == [HighlightRange(start: 0, end: 4)])
        #expect(NameTerms("\"l r\"")!.marks(in: "annual report") == [HighlightRange(start: 5, end: 8)])
        #expect(NameTerms("zzz")!.marks(in: "annual").isEmpty)
    }

    // MARK: Narrowing

    @Test func longerTextIsNarrower() {
        #expect(NameTerms.isNarrower(base: "rep", next: "report"))
        #expect(!NameTerms.isNarrower(base: "report", next: "rep"))
        #expect(NameTerms.isNarrower(base: "report", next: "report annual"))
        #expect(NameTerms.isNarrower(base: "a b", next: "b a"))
        #expect(NameTerms.isNarrower(base: "a b", next: "ab"))
        #expect(!NameTerms.isNarrower(base: "a b", next: "a"))
        #expect(NameTerms.isNarrower(base: "cafe", next: "café"))
        #expect(!NameTerms.isNarrower(base: "", next: "a"))
        #expect(!NameTerms.isNarrower(base: "a", next: ""))
    }

    // A phrase is narrower only than a phrase or word that holds it whole.
    @Test func phrasesNarrowAsTheirRuns() {
        #expect(NameTerms.isNarrower(base: "\"a b\"", next: "\"a b c\""))
        #expect(!NameTerms.isNarrower(base: "\"a b\"", next: "a b"))
        #expect(NameTerms.isNarrower(base: "a b", next: "\"a b\""))
        // Typing the closing quote: "\"annual re" has the word `"annual`, which the phrase doesn't hold.
        #expect(!NameTerms.isNarrower(base: "\"annual re", next: "\"annual report\""))
    }
    // MARK: Words left out

    private func terms(_ text: String) -> [NameTerms.Term] { NameTerms.terms(text) }
    private func kept(_ text: String) -> NameTerms.Term { NameTerms.Term(text: text, leftOut: false) }
    private func out(_ text: String) -> NameTerms.Term { NameTerms.Term(text: text, leftOut: true) }

    @Test func aWordAfterAnExclamationMarkIsLeftOut() {
        #expect(terms("!draft") == [out("draft")])
        #expect(terms("report !draft") == [kept("report"), out("draft")])
        #expect(terms("!draft report") == [out("draft"), kept("report")])
        #expect(terms("!\"old copy\" report") == [out("old copy"), kept("report")])
        #expect(terms("!a !b") == [out("a"), out("b")])
        // Only before a word: in it, or alone, or in quotes, it is a character.
        #expect(terms("a!b") == [kept("a!b")])
        #expect(terms("draft!") == [kept("draft!")])
        #expect(terms("!") == [kept("!")])
        #expect(terms("! draft") == [kept("!"), kept("draft")])
        #expect(terms("draft !") == [kept("draft"), kept("!")])
        #expect(terms("\"!draft\"") == [kept("!draft")])
        #expect(terms("!!draft") == [out("!draft")])
        #expect(terms("!\"\"") == [])
        #expect(terms("!\"unclosed words") == [out("\"unclosed"), kept("words")])
        #expect(NameTerms.words("report !draft") == ["report"])
        #expect(NameTerms.leftOut("report !draft !old") == ["draft", "old"])
    }

    @Test func aNameWithAWordLeftOutIsNoMatch() {
        #expect(matches("report !draft", "report.pdf"))
        #expect(!matches("report !draft", "report-draft.pdf"))
        #expect(!matches("report !draft", "DRAFT report.pdf"))
        #expect(matches("!draft", "notes.txt"))
        #expect(!matches("!draft", "draft.txt"))
        #expect(!matches("!draft !old", "old notes.txt"))
        #expect(matches("!draft !old", "notes.txt"))
        #expect(!matches("report !\"old copy\"", "old copy of report.pdf"))
        #expect(matches("report !\"old copy\"", "old report copy.pdf"))
        // As Contains matches: a plain letter left out leaves out its accented forms.
        #expect(!matches("!cafe", "Café.txt"))
        #expect(matches("!café", "Cafe.txt"))
        // A word both asked for and left out finds nothing.
        #expect(!matches("annual !annual", "annual.pdf"))
        // Left out alone is still a search.
        #expect(NameTerms("!draft") != nil)
    }

    @Test func wordsLeftOutAreToldFromTheBytesToo() {
        func bytes(_ text: String, _ name: String) -> Bool? {
            let terms = NameTerms(text)!
            return Array(name.utf8).withUnsafeBufferPointer { terms.matches(asciiBytes: $0) }
        }
        #expect(bytes("report !draft", "report.pdf") == true)
        #expect(bytes("report !draft", "report-draft.pdf") == false)
        #expect(bytes("!draft", "notes.txt") == true)
        #expect(bytes("!draft", "draft.txt") == false)
        // A word beyond ASCII left out can't be told from the bytes, unless another word already said no.
        #expect(bytes("!café", "cafe.txt") == nil || bytes("!café", "cafe.txt") == true)
        #expect(bytes("zzz !café", "cafe.txt") == false)
    }

    @Test func wordsLeftOutAreNotMarked() {
        #expect(NameTerms("report !draft")!.marks(in: "report.pdf") == [HighlightRange(start: 0, end: 6)])
        #expect(NameTerms("!draft")!.marks(in: "notes.txt").isEmpty)
    }

    // Leaving out more is narrower, as is leaving out less of a word: what holds "draft" holds "dra".
    @Test func leavingOutNarrows() {
        #expect(NameTerms.isNarrower(base: "report", next: "report !draft"))
        #expect(NameTerms.isNarrower(base: "report !draft", next: "report !dra"))
        #expect(!NameTerms.isNarrower(base: "report !dra", next: "report !draft"))
        #expect(!NameTerms.isNarrower(base: "report !draft", next: "report"))
        #expect(NameTerms.isNarrower(base: "!draft", next: "!draft !old"))
        #expect(NameTerms.isNarrower(base: "!draft", next: "report !draft"))
        #expect(!NameTerms.isNarrower(base: "!draft", next: "!old"))
        #expect(NameTerms.isNarrower(base: "!\"old copy\"", next: "!old"))
    }
    // Narrowing keeps the results on screen and drops what no longer matches, instead of searching again: so whenever
    // one text is narrower than another, everything it finds the other found. Every pair of these, on these names.
    @Test func whatIsNarrowerFindsNothingTheOtherDidnt() {
        let names = [
            "annual report.pdf", "Report, annual.txt", "report-draft.pdf", "old copy of report.pdf", "draft notes.txt",
            "annual  report.key", "caf\u{E9} menu.txt", "r\u{E9}sum\u{E9}.pdf", "a.txt", "ab.txt", "b a.txt",
            "!draft.md",
        ]
        let texts = [
            "a", "an", "ann", "annual", "annual r", "annual re", "annual report", "report annual", "\"annual report\"",
            "\"annual\"", "\"annual r", "report", "report !d", "report !dr", "report !draft", "!draft", "!dra", "!d",
            "!draft !old", "!\"old copy\"", "!old", "cafe", "caf\u{E9}", "!cafe", "r\u{E9}sum\u{E9}", "resume", "b a",
            "\"b a\"", "ab", "a b", "!a", "\"!draft\"", "!", "txt", "!txt", "pdf !draft", "  annual  ",
        ]
        let matched = Dictionary(
            uniqueKeysWithValues: texts.map { text in
                (text, Set(names.filter { name in NameTerms(text)?.matches(name) ?? true }))
            })
        var narrower = 0
        for base in texts {
            for next in texts where NameTerms.isNarrower(base: base, next: next) {
                narrower += 1
                #expect(matched[next]!.isSubset(of: matched[base]!), "\(next) is narrower than \(base)")
            }
        }
        // Enough pairs were narrower to say something.
        #expect(narrower > 60)
    }
}
