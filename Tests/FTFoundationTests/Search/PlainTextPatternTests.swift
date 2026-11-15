// The pattern a Plain Text search hands fd finds every name the list filter would
import Foundation
import Testing

@testable import FTFoundation

struct PlainTextPatternTests {
    /// Whether the pattern for `text` finds `name`, with the system's regular expressions standing in for fd's.
    private func finds(_ text: String, _ name: String) throws -> Bool {
        let regex = try NSRegularExpression(pattern: PlainTextPattern.regex(for: text))
        return regex.firstMatch(in: name, range: NSRange(location: 0, length: name.utf16.count)) != nil
    }

    private static let names = [
        "q\u{303}1x.txt", "7\u{301}up", "report (1).pdf", "c++ notes.txt", "Cafe\u{301}", "Caf\u{E9}", "CAF\u{C9}",
        "cafe",
        "Stra\u{DF}e", "STRASSE", "\u{3A3}\u{3AF}\u{3C3}\u{3C5}\u{3C6}\u{3BF}\u{3C2}", "\u{39F}\u{394}\u{39F}\u{3A3}",
        "Sm\u{F8}rrebr\u{F8}d", "\u{130}zmir", "\u{131}sl\u{131}k", "Nai\u{308}ve", "README.md",
        "Vie\u{302}\u{301}t Nam",
        "\u{FB01}le.txt", "o\u{FB03}ce", "wa\u{FB04}e", "be\u{FB06}", "\u{FB05}op", "\u{FB00}\u{FB00}", "f\u{FB01}",
        "\u{FB01}\u{301}x", "\u{FF21}\u{FF22}\u{FF23} \u{FF11}\u{FF12}", "a\u{FF0E}txt", "\u{65E5}\u{672C}\u{8A9E}.txt",
        "a\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}b", "\u{1F1F9}\u{1F1F7} trip", "x-y_z [2] {3} ^$ #&~|",
        "ffffffffffff",
        "\u{FB00}\u{FB00}\u{FB00}\u{FB00}\u{FB00}\u{FB00}", "stiff fist", "A\u{30A}ngstro\u{308}m", "\u{17F}un",
        "kelvin \u{212A}", "a\u{2260}b.txt", "x\u{226E}y",
    ]

    private static let queries = [
        "q1", "q", "1", "7u", "(1)", "c++", "cafe", "caf\u{E9}", "cafe\u{301}", "e", "\u{E9}", "ss", "\u{DF}",
        "\u{3C3}\u{3B9}\u{3C3}", "\u{3C2}", "\u{3BF}\u{3B4}\u{3BF}\u{3C3}", "smorrebrod", "izmir", "\u{131}", "i",
        "naive",
        "readme", "viet", "vi\u{EA}\u{301}t", "fi", "file", "ffi", "fic", "offic", "of", "ff", "fl", "affle", "st", "t",
        "s", "f",
        "l", "fff", "fix", "\u{FB01}", "\u{FB00}", "abc", "ABC 12", "\u{FF41}", "a.t", ".", "\u{65E5}\u{672C}", "ab",
        "\u{1F469}", "tr", "[2]", "{3}", "^$", "#&~|", "-y_", "ffffffffff", "ffffffffffff", "fffffffffffff", "stiff",
        "f f",
        "angstrom", "\u{E5}", "sun", "k", " ", "=", "<", "a=b",
    ]

    // Every name the filter keeps in Contains is one the pattern finds: fd may hand over more, which the matcher then
    // drops, but never fewer.
    @Test func findsEveryNameTheFilterKeeps() throws {
        var kept = 0
        for query in Self.queries {
            let matcher = try #require(NameMatcher(query, mode: .contains))
            for name in Self.names where matcher.matches(name) {
                kept += 1
                #expect(try finds(query, name), "\(query) in \(name): \(PlainTextPattern.regex(for: query))")
            }
        }
        #expect(kept > 150)
    }

    // The same over names and texts put together at random from letters, marks, ligatures and full-width forms.
    @Test func findsEveryNameTheFilterKeepsAmongNamesMadeAtRandom() throws {
        let pieces = [
            "f", "i", "l", "s", "t", "F", "e", "q", "1", ".", " ", "\u{301}", "\u{303}", "\u{E9}", "\u{FB00}",
            "\u{FB01}", "\u{FB02}",
            "\u{FB03}", "\u{FB04}", "\u{FB05}", "\u{FB06}", "\u{FF46}", "\u{FF29}", "\u{FF11}", "\u{17F}",
        ]
        var generator = SystemRandomNumberGenerator()
        func made(_ length: ClosedRange<Int>) -> String {
            (0..<Int.random(in: length, using: &generator)).map { _ in pieces.randomElement(using: &generator)! }
                .joined()
        }
        for _ in 0..<300 {
            let query = made(1...5)
            guard let matcher = NameMatcher(query, mode: .contains) else { continue }
            let regex = try NSRegularExpression(pattern: PlainTextPattern.regex(for: query))
            for _ in 0..<20 {
                let name = made(1...10)
                guard matcher.matches(name) else { continue }
                let found = regex.firstMatch(in: name, range: NSRange(location: 0, length: name.utf16.count)) != nil
                #expect(found, "\(Array(query.unicodeScalars)) in \(Array(name.unicodeScalars))")
            }
        }
    }

    @Test func aPlainCharacterTakesTheMarksANameKeepsAfterIt() throws {
        #expect(try finds("q1", "q\u{303}1x.txt"))
        #expect(try finds("7u", "7\u{301}up"))
        #expect(PlainTextPattern.regex(for: "q") == "(?i)[q\u{FF31}\u{FF51}]\\p{M}*")
    }

    // A character beyond Latin, Greek and Cyrillic that a name may store decomposed is found either way: a kana and
    // its mark, a Hangul syllable as its jamo.
    @Test func aComposedCharacterOfAnyScriptIsFoundDecomposed() throws {
        let names = [
            "\u{304B}\u{3099}\u{304F}", "\u{30CF}\u{309A}\u{30EA}", "\u{1112}\u{1161}\u{11AB}\u{1100}\u{1173}\u{11AF}",
            "\u{D558}\u{11AB}\u{AE00}", "\u{1112}\u{1161}",
        ]
        let queries = ["\u{304C}", "\u{304C}\u{304F}", "\u{30D1}\u{30EA}", "\u{D55C}", "\u{D55C}\u{AE00}", "\u{D558}"]
        var kept = 0
        for query in queries {
            let matcher = try #require(NameMatcher(query, mode: .contains))
            for name in names where matcher.matches(name) {
                kept += 1
                #expect(try finds(query, name), "\(query) in \(Array(name.unicodeScalars))")
            }
        }
        #expect(kept == 7)
    }

    @Test func aLigatureStandsForTheLettersTypedAndTheLettersForIt() throws {
        #expect(try finds("fi", "\u{FB01}le"))
        #expect(try finds("ffic", "o\u{FB03}ce"))
        #expect(try finds("\u{FB01}le", "FILE"))
        // Not found where the letters are neither there nor in a ligature.
        #expect(try !finds("fi", "fl\u{FB02}"))
        #expect(try !finds("file", "\u{FB02}e"))
    }

    // A long chain of the letters ligatures are made of is written loosely, and stays short.
    @Test func aLongChainOfLigatureLettersStaysAShortPattern() {
        let pattern = PlainTextPattern.regex(for: String(repeating: "f", count: 60))
        #expect(pattern.utf16.count < 4_000)
        #expect(PlainTextPattern.regex(for: String(repeating: "fi", count: 4)).utf16.count < 4_000)
    }
}
