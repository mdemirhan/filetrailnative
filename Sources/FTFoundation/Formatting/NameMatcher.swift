// Names compared with what is typed: whether a name matches, which of its letters to mark, and how well it fits
import Foundation
import os

/// How typed text finds a name: as a run of letters in it (Contains), or as letters in order with anything between
/// them (Fuzzy). Anything Contains finds, Fuzzy finds too.
public enum NameMatchMode: String, Codable, CaseIterable, Sendable, Hashable {
    case fuzzy, contains

    /// The mode's name, as Settings and the filter's chip say it.
    public var label: String {
        switch self {
        case .fuzzy: "Fuzzy"
        case .contains: "Contains"
        }
    }

    /// The other mode, which a click on the chip switches to.
    public var toggled: NameMatchMode { self == .fuzzy ? .contains : .fuzzy }
}

/// One letter of text as names are compared with what is typed: lowercased and composed.
struct FoldedLetter: Equatable, Sendable {
    /// The letter itself, an accented one as one value. A letter carrying a mark it has no composed form with has the
    /// top bit set, so that no letter typed on its own is the same.
    var exact: UInt32
    /// The letter without its accent: what a plain letter typed is compared with. Only Latin, Greek and Cyrillic
    /// letters lose their accents; a letter that is not an accent on another (ø, ł, ı) is its own.
    var base: UInt32
}

/// Text folded into letters, each with the units it spans in the text as stored and whether it starts a word.
struct FoldedText: Sendable {
    var letters: [FoldedLetter] = []
    /// For each letter, the stored text's UTF-16 units of the character it came from.
    var spans: [Range<Int>] = []
    /// For each letter, whether it starts a word: the first, one after a character that is no letter or digit, or a
    /// capital after a lowercase letter ("Trail" in "FileTrail").
    var wordStarts: [Bool] = []

    init(_ text: String) {
        if text.utf8.allSatisfy({ $0 < 0x80 }) {
            var previous: UInt8 = 0x20
            var index = 0
            for byte in text.utf8 {
                let lower = byte >= 0x41 && byte <= 0x5A ? byte + 0x20 : byte
                letters.append(FoldedLetter(exact: UInt32(lower), base: UInt32(lower)))
                spans.append(index..<(index + 1))
                wordStarts.append(Self.startsWord(previous: UInt32(previous), current: UInt32(byte)))
                previous = byte
                index += 1
            }
            return
        }
        // Folded whole, as a letter's case can depend on its neighbours (a final sigma); each character of the folded
        // text is the fold of the stored one at the same place. Should the count differ, each is folded on its own.
        let whole = NameFolding.folded(text)
        let pieces = whole.count == text.count ? whole.map { String($0) } : text.map { NameFolding.folded(String($0)) }
        var offset = 0
        var previous: UInt32 = 0x20
        for (character, piece) in zip(text, pieces) {
            let stored = String(character).utf16.count
            let span = offset..<(offset + stored)
            let first = character.unicodeScalars.first.map(\.value) ?? 0
            var opened = false
            for scalar in piece.unicodeScalars {
                if opened, Self.isMark(scalar) {
                    letters[letters.count - 1].exact |= 0x8000_0000
                    continue
                }
                letters.append(FoldedLetter(exact: scalar.value, base: Self.base(of: scalar)))
                spans.append(span)
                wordStarts.append(!opened && Self.startsWord(previous: previous, current: first))
                opened = true
            }
            previous = first
            offset += stored
        }
    }

    private static func isMark(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark: true
        default: false
        }
    }

    private static func isLetterOrDigit(_ value: UInt32) -> Bool {
        if value < 0x80 {
            return (0x30...0x39).contains(value) || (0x41...0x5A).contains(value) || (0x61...0x7A).contains(value)
        }
        guard let scalar = Unicode.Scalar(value) else { return false }
        return scalar.properties.isAlphabetic || scalar.properties.numericType != nil
    }

    private static func isUppercase(_ value: UInt32) -> Bool {
        if value < 0x80 { return (0x41...0x5A).contains(value) }
        return Unicode.Scalar(value)?.properties.isUppercase ?? false
    }

    private static func isLowercase(_ value: UInt32) -> Bool {
        if value < 0x80 { return (0x61...0x7A).contains(value) }
        return Unicode.Scalar(value)?.properties.isLowercase ?? false
    }

    private static func startsWord(previous: UInt32, current: UInt32) -> Bool {
        !isLetterOrDigit(previous) || (isLowercase(previous) && isUppercase(current))
    }

    private static let bases = OSAllocatedUnfairLock(initialState: [UInt32: UInt32]())

    /// `scalar` without its accent, for a letter of the scripts whose accents a plain letter may stand for.
    static func base(of scalar: Unicode.Scalar) -> UInt32 {
        let value = scalar.value
        if value < 0xC0 { return value }
        // The final sigma is a sigma.
        if value == 0x3C2 { return 0x3C3 }
        if let known = bases.withLock({ $0[value] }) { return known }
        var found = value
        let parts = Array(String(scalar).decomposedStringWithCanonicalMapping.unicodeScalars)
        if parts.count > 1, let first = parts.first, first.value < 0x530 || (0x1E00..<0x2000).contains(first.value),
            parts.dropFirst().allSatisfy(isMark)
        {
            found = first.value == 0x3C2 ? 0x3C3 : first.value
        }
        let base = found
        bases.withLock { $0[value] = base }
        return base
    }
}

/// Typed text, ready to find names: Contains or Fuzzy, an accented letter found only as itself and a plain one with
/// or without an accent ("e" finds "é"; "é" doesn't find "e"), case aside, however the name stores its accents.
public struct NameMatcher: Sendable {
    public let mode: NameMatchMode
    /// The text as typed.
    public let text: String
    private let letters: [FoldedLetter]
    /// For each letter typed, whether it is plain: compared with the name's letters without their accents.
    private let plain: [Bool]
    /// The text's bytes when it is ASCII: compared with an ASCII name byte by byte, case aside.
    private let ascii: [UInt8]?

    /// Nil for text that folds to nothing.
    public init?(_ text: String, mode: NameMatchMode) {
        let folded = FoldedText(text)
        guard !folded.letters.isEmpty else { return nil }
        self.mode = mode
        self.text = text
        letters = folded.letters
        // The final sigma is a plain sigma.
        plain = folded.letters.map { $0.exact == $0.base || $0.exact == 0x3C2 }
        let isASCII = text.utf8.allSatisfy { $0 < 0x80 }
        ascii = isASCII ? folded.letters.map { UInt8($0.exact) } : nil
    }

    private func same(_ index: Int, _ letter: FoldedLetter) -> Bool {
        plain[index] ? letters[index].base == letter.base : letters[index].exact == letter.exact
    }

    // MARK: Matching

    /// Whether `name` matches.
    public func matches(_ name: String) -> Bool {
        if let fast = asciiMatches(name) { return fast }
        return matches(FoldedText(name).letters)
    }

    /// Whether the folded name matches: the form a list keeps once for each name.
    func matches(_ name: [FoldedLetter]) -> Bool {
        mode == .contains ? firstRun(in: name) != nil : isSubsequence(of: name)
    }

    /// Whether `name` starts with the text.
    public func isPrefix(of name: String) -> Bool {
        if let bytes = ascii, let result = withASCII(name, { Self.asciiRun(bytes, in: $0, prefixOnly: true) }) {
            return result
        }
        let folded = FoldedText(name).letters
        return folded.count >= letters.count && letters.indices.allSatisfy { same($0, folded[$0]) }
    }

    /// Whether `name` holds the text as a run of letters, whatever the mode.
    public func isContained(in name: String) -> Bool {
        if let bytes = ascii, let result = withASCII(name, { Self.asciiRun(bytes, in: $0, prefixOnly: false) }) {
            return result
        }
        return firstRun(in: FoldedText(name).letters) != nil
    }

    /// The match for an ASCII name, byte by byte; nil when the name isn't ASCII or the text isn't.
    private func asciiMatches(_ name: String) -> Bool? {
        guard let bytes = ascii else {
            // Text with a letter beyond ASCII never matches an ASCII name: neither the letter nor its base is ASCII.
            return withASCII(name) { _ in false }
        }
        return withASCII(name) { name in
            mode == .contains ? Self.asciiRun(bytes, in: name, prefixOnly: false) : Self.asciiInOrder(bytes, in: name)
        }
    }

    /// `body` with `name`'s bytes when they are all ASCII; nil otherwise.
    private func withASCII(_ name: String, _ body: (UnsafeBufferPointer<UInt8>) -> Bool) -> Bool? {
        var name = name
        return name.withUTF8 { bytes in
            for byte in bytes where byte >= 0x80 { return nil }
            return body(bytes)
        }
    }

    private static func asciiRun(_ needle: [UInt8], in bytes: UnsafeBufferPointer<UInt8>, prefixOnly: Bool) -> Bool {
        let count = needle.count
        guard count <= bytes.count else { return false }
        let last = prefixOnly ? 0 : bytes.count - count
        var start = 0
        while start <= last {
            var offset = 0
            while offset < count {
                var byte = bytes[start + offset]
                if byte >= 65 && byte <= 90 { byte += 32 }
                if byte != needle[offset] { break }
                offset += 1
            }
            if offset == count { return true }
            start += 1
        }
        return false
    }

    private static func asciiInOrder(_ needle: [UInt8], in bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        var index = 0
        for var byte in bytes {
            if byte >= 65 && byte <= 90 { byte += 32 }
            if byte == needle[index] {
                index += 1
                if index == needle.count { return true }
            }
        }
        return false
    }

    /// Where the text first runs in `name` from letter `from` on, as a range of its letters.
    func firstRun(in name: [FoldedLetter], from: Int = 0) -> Range<Int>? {
        let count = letters.count
        guard from >= 0, from + count <= name.count else { return nil }
        for start in from...(name.count - count) where (0..<count).allSatisfy({ same($0, name[start + $0]) }) {
            return start..<(start + count)
        }
        return nil
    }

    /// The first place of each letter typed in `name`, in order, each after the one before; nil when one is missing.
    func positionsInOrder(in name: [FoldedLetter]) -> [Int]? {
        var positions: [Int] = []
        for (position, letter) in name.enumerated() where same(positions.count, letter) {
            positions.append(position)
            if positions.count == letters.count { return positions }
        }
        return nil
    }

    private func isSubsequence(of name: [FoldedLetter]) -> Bool {
        var index = 0
        for letter in name where same(index, letter) {
            index += 1
            if index == letters.count { return true }
        }
        return false
    }

    // MARK: Marks and fit

    /// The letters of `name` to mark, in its UTF-16 units as stored; empty when it doesn't match. A run of the text is
    /// marked where it first is; a fuzzy match marks the letters of its best fit (`score`).
    public func marks(in name: String) -> [HighlightRange] {
        let folded = FoldedText(name)
        let positions: [Int]
        if let run = firstRun(in: folded.letters) {
            positions = Array(run)
        } else if mode == .fuzzy, let fit = bestFit(folded) {
            positions = fit.positions
        } else {
            return []
        }
        var ranges: [HighlightRange] = []
        for position in positions {
            let span = folded.spans[position]
            if let last = ranges.last, last.end >= span.lowerBound {
                ranges[ranges.count - 1].end = max(last.end, span.upperBound)
            } else {
                ranges.append(HighlightRange(start: span.lowerBound, end: span.upperBound))
            }
        }
        return ranges
    }

    /// How well the letters in order fit `name`, higher being better; nil when they aren't all in it. Letters next to
    /// each other and letters that start words count for more, and a gap or a late start for less.
    public func score(_ name: String) -> Int? {
        bestFit(FoldedText(name))?.score
    }

    private static let matchScore = 16
    private static let wordStartBonus = 8
    private static let nextToBonus = 8
    private static let gapOpening = 3
    private static let gapExtension = 1
    private static let lateStartLimit = 8

    private func bestFit(_ name: FoldedText) -> (score: Int, positions: [Int])? {
        let n = name.letters.count
        let m = letters.count
        guard m <= n, isSubsequence(of: name.letters) else { return nil }
        let none = Int.min / 4
        // best[i][j]: the best score with letter i typed matched at letter j of the name; from[i][j] where letter i-1 was.
        var best = [[Int]](repeating: [Int](repeating: none, count: n), count: m)
        var from = [[Int]](repeating: [Int](repeating: -1, count: n), count: m)
        for i in 0..<m {
            var gapBest = none
            var gapFrom = -1
            for j in 0..<n {
                if i > 0, j >= 2 {
                    // A gap of at least one letter between i-1 at k and i at j.
                    let opened = best[i - 1][j - 2] - Self.gapOpening
                    if gapBest != none { gapBest -= Self.gapExtension }
                    if opened > gapBest {
                        gapBest = opened
                        gapFrom = j - 2
                    }
                }
                guard same(i, name.letters[j]) else { continue }
                // A letter that starts a word counts for more where the match lands on it, first or after a gap; one
                // next to the letter before counts for being next to it.
                let landing = Self.matchScore + (name.wordStarts[j] ? Self.wordStartBonus : 0)
                if i == 0 {
                    best[i][j] = landing - min(j, Self.lateStartLimit)
                    continue
                }
                var value = none
                var origin = -1
                if j >= 1, best[i - 1][j - 1] > none {
                    value = best[i - 1][j - 1] + Self.matchScore + Self.nextToBonus
                    origin = j - 1
                }
                if gapBest > none, gapBest + landing > value {
                    value = gapBest + landing
                    origin = gapFrom
                }
                best[i][j] = value
                from[i][j] = origin
            }
        }
        var end = -1
        for j in 0..<n where best[m - 1][j] > none && (end < 0 || best[m - 1][j] > best[m - 1][end]) { end = j }
        guard end >= 0 else { return nil }
        var positions = [Int](repeating: 0, count: m)
        var j = end
        for i in stride(from: m - 1, through: 0, by: -1) {
            positions[i] = j
            j = from[i][j]
        }
        return (best[m - 1][end], positions)
    }
}
