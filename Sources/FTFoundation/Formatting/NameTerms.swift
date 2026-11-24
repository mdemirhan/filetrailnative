// Plain Text a search finds names by, taken as words: each must be in the name, in any order, as Contains matches
// one; a run in double quotes is one word, its spaces and all; a word after `!` must not be in it.
import Foundation

public struct NameTerms: Sendable {
    /// One for each word a name must hold, in the order typed.
    public let matchers: [NameMatcher]
    /// One for each word it must not (`!draft`).
    public let excluded: [NameMatcher]
    /// Both, in that order: a folder is folded once for each (`FoldedFolder`).
    public var allMatchers: [NameMatcher] { matchers + excluded }

    /// Nil for text with no word in it, which finds everything.
    public init?(_ text: String) {
        let terms = Self.terms(text)
        let matchers = terms.filter { !$0.leftOut }.compactMap { NameMatcher($0.text, mode: .contains) }
        let excluded = terms.filter(\.leftOut).compactMap { NameMatcher($0.text, mode: .contains) }
        guard !matchers.isEmpty || !excluded.isEmpty else { return nil }
        self.matchers = matchers
        self.excluded = excluded
    }

    /// A word of the text, and whether a name must not hold it.
    public struct Term: Equatable, Sendable {
        public var text: String
        public var leftOut: Bool

        public init(text: String, leftOut: Bool) {
            self.text = text
            self.leftOut = leftOut
        }
    }

    /// The words of `text`: what white space separates, and what is between a pair of double quotes, as typed and
    /// without its quotes (`"annual  report" 2025` is "annual  report" and "2025"). A quote with no other after it is
    /// an ordinary character, as one in a word is (`5"`). A word after `!` is left out (`!draft`, `!"old copy"`); `!`
    /// alone, or in quotes (`"!draft"`), is text.
    public static func terms(_ text: String) -> [Term] {
        var terms: [Term] = []
        var current = ""
        var leftOut = false
        func end() {
            if !current.isEmpty { terms.append(Term(text: current, leftOut: false)) }
            current = ""
        }
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character.isWhitespace {
                if leftOut, current.isEmpty { terms.append(Term(text: "!", leftOut: false)) }
                leftOut = false
                end()
                index = text.index(after: index)
                continue
            }
            if character == "!", current.isEmpty, !leftOut {
                leftOut = true
                index = text.index(after: index)
                continue
            }
            if character == "\"", current.isEmpty, let close = closingQuote(in: text, after: index) {
                let phrase = String(text[text.index(after: index)..<close])
                if !phrase.isEmpty { terms.append(Term(text: phrase, leftOut: leftOut)) }
                leftOut = false
                index = text.index(after: close)
                continue
            }
            current.append(character)
            index = text.index(after: index)
            if leftOut {
                // The rest of the word, left out.
                while index < text.endIndex, !text[index].isWhitespace {
                    current.append(text[index])
                    index = text.index(after: index)
                }
                terms.append(Term(text: current, leftOut: true))
                current = ""
                leftOut = false
            }
        }
        if leftOut { terms.append(Term(text: "!", leftOut: false)) }
        end()
        return terms
    }

    /// The words a name must hold (`terms`, without those left out).
    public static func words(_ text: String) -> [String] { terms(text).filter { !$0.leftOut }.map(\.text) }

    /// The words a name must not hold (`!draft`).
    public static func leftOut(_ text: String) -> [String] { terms(text).filter(\.leftOut).map(\.text) }

    /// Where the quote that closes the one at `open` is, if any.
    static func closingQuote(in text: String, after open: String.Index) -> String.Index? {
        text[text.index(after: open)...].firstIndex(of: "\"")
    }

    /// Whether `name` holds every word, and none left out.
    public func matches(_ name: String, cache: FoldedNameCache? = nil) -> Bool {
        matchers.allSatisfy { $0.matches(name, cache: cache) } && !excluded.contains { $0.matches(name, cache: cache) }
    }

    /// Whether an ASCII name, as its bytes, holds every word; nil when a word or the name needs folding first.
    public func matches(asciiBytes bytes: UnsafeBufferPointer<UInt8>) -> Bool? {
        var unknown = false
        for matcher in matchers {
            switch matcher.matches(asciiBytes: bytes) {
            case false?: return false
            case nil: unknown = true
            case true?: break
            }
        }
        for matcher in excluded {
            switch matcher.matches(asciiBytes: bytes) {
            case true?: return false
            case nil: unknown = true
            case false?: break
            }
        }
        return unknown ? nil : true
    }

    /// Whether the item called `name` in `folders` (one folded for each of `allMatchers`, in their order) holds every
    /// word and none left out.
    public func matches(name: String, in folders: [FoldedFolder]) -> Bool {
        zip(matchers, folders).allSatisfy { $0.matches(name: name, in: $1) }
            && !zip(excluded, folders.dropFirst(matchers.count)).contains { $0.matches(name: name, in: $1) }
    }

    /// Each word's run in `name`, in order, merged where they meet or overlap.
    public func marks(in name: String) -> [HighlightRange] {
        let marks = matchers.flatMap { $0.marks(in: name).prefix(1) }.sorted { $0.start < $1.start }
        var merged: [HighlightRange] = []
        for mark in marks {
            if let last = merged.last, mark.start <= last.end {
                merged[merged.count - 1].end = max(last.end, mark.end)
            } else {
                merged.append(mark)
            }
        }
        return merged
    }

    /// Whether everything a search for `next` finds is also found by one for `base`: each of `base`'s words is in one
    /// of `next`'s, and each word `base` leaves out holds one `next` leaves out (what has "draft" has "dra"), a plain
    /// letter standing for its accented forms.
    public static func isNarrower(base: String, next: String) -> Bool {
        let baseTerms = terms(base)
        let nextTerms = terms(next)
        guard !baseTerms.isEmpty else { return false }
        let nextWords = nextTerms.filter { !$0.leftOut }.map(\.text)
        let nextLeftOut = nextTerms.filter(\.leftOut).compactMap { NameMatcher($0.text, mode: .contains) }
        return baseTerms.allSatisfy { term in
            if term.leftOut { return nextLeftOut.contains { $0.matches(term.text) } }
            guard let matcher = NameMatcher(term.text, mode: .contains) else { return true }
            return nextWords.contains { matcher.matches($0) }
        }
    }
}
