// What `new RegExp(source, "" | "i").exec(text)` finds, as JavaScript's default mode (ECMA-262 Annex B) reads the
// pattern: the matcher of the search highlight (buildSearchHighlightPattern of
// apps/desktop/src/renderer/lib/searchResults.ts)
import Foundation
import Testing

@testable import FTFoundation

@Suite struct JSLegacyRegExpTests {
    private func found(_ source: String, _ text: String, ignoreCase: Bool = false) -> [Int]? {
        guard let regex = try? JSLegacyRegExp(source: source, ignoreCase: ignoreCase) else { return [-1] }
        return regex.firstMatch(in: text).map { [$0.range.location, $0.range.location + $0.range.length] }
    }

    private func refuses(_ source: String) -> Bool {
        (try? JSLegacyRegExp(source: source, ignoreCase: false)) == nil
    }

    @Test func readsAnnexBSyntax() {
        #expect(found("foo\\-bar", "foo-bar.txt") == [0, 7])
        #expect(found("a]", "a].txt") == [0, 2])
        #expect(found("x{", "ax{b") == [1, 3])
        #expect(found("}", "a}") == [1, 2])
        #expect(found("x{,3}", "x{,3}") == [0, 5])
        #expect(found("\\p{L}", "ap{L}") == [1, 5])
        #expect(found("\\u{2}", "uu") == [0, 2])
        #expect(found("\\k", "k.txt") == [0, 1])
        #expect(found("\\8", "a8") == [1, 2])
        #expect(found("\\1", "a\u{1}") == [1, 2])
        #expect(found("\\101", "xA") == [1, 2])
        #expect(found("\\x4", "x4") == [0, 2])
        #expect(found("\\c", "a\\c") == [1, 3])
        #expect(found("\\cA", "\u{1}") == [0, 1])
        #expect(found("[\\w-]+", "a-b c") == [0, 3])
        #expect(found("[\\w-z]+", "z-y!") == [0, 3])
        #expect(found("[\\B]", "aB") == [1, 2])
        #expect(found("[]a]", "a]") == nil)
        #expect(found("[^]", "\n") == [0, 1])
        #expect(found("(?=a)*b", "ab") == [1, 2])
        #expect(found("(?=a)+a", "ba") == [1, 2])
        #expect(found("(a)\\1", "xaa") == [1, 3])
        #expect(found("(?<n>a)\\k<n>", "aa") == [0, 2])
        #expect(found("(?<=a)b", "abab") == [1, 2])
        #expect(found("\\bMon", "a Monte") == [2, 5])
        #expect(found("e$", "one\n") == nil)
    }

    @Test func refusesWhatJavaScriptRefuses() {
        #expect(refuses("("))
        #expect(refuses("["))
        #expect(refuses("*a"))
        #expect(refuses("a**"))
        #expect(refuses("\\"))
        #expect(refuses("{2}"))
        #expect(refuses("a{2,1}"))
        #expect(refuses("^*"))
        #expect(refuses("(?<=a)*"))
        #expect(refuses("[z-a]"))
        #expect(refuses("(?<n>a)\\k"))
        #expect(refuses("a)"))
    }

    @Test func matchesUTF16Units() {
        #expect(found("^.", "🎉 party") == [0, 1])
        #expect(found("^.{2}", "🎉x") == [0, 2])
        #expect(found("[🎉]", "x🎉") == [1, 2])
        #expect(found("🎉+", "🎉🎉") == [0, 2])
        #expect(found("\\uDF89", "🎉") == [1, 2])
        #expect(found("party", "🎉 party") == [3, 8])
        #expect(found("[^a]", "🎉") == [0, 1])
    }

    @Test func foldsCaseByUppercaseForms() {
        #expect(found("s", "ſ", ignoreCase: true) == nil)
        #expect(found("k", "\u{212A}", ignoreCase: true) == nil)
        #expect(found("µ", "Μ", ignoreCase: true) == [0, 1])
        #expect(found("ß", "SS ß", ignoreCase: true) == [3, 4])
        #expect(found("[a-c]+", "xABC", ignoreCase: true) == [1, 4])
        #expect(found("[^a]", "A", ignoreCase: true) == nil)
        #expect(found("σ", "Σς", ignoreCase: true) == [0, 1])
        #expect(found("\\w+", "é", ignoreCase: true) == nil)
        #expect(found("rep", "Annual Report.pdf", ignoreCase: true) == [7, 10])
        #expect(found("Rep", "report", ignoreCase: false) == nil)
    }

    @Test func plainTextIsLiteral() throws {
        let regex = try JSLegacyRegExp(literal: "(1).p", ignoreCase: true)
        #expect(regex.firstMatch(in: "Scan (1).PDF")?.range == NSRange(location: 5, length: 5))
        let emoji = try JSLegacyRegExp(literal: "🎉", ignoreCase: true)
        #expect(emoji.firstMatch(in: "a🎉")?.range == NSRange(location: 1, length: 2))
    }
}
