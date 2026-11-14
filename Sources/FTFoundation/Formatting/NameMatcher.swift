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
                // A ligature is its letters, each spanning the one character the name stores.
                if let spelled = Self.ligatures[scalar.value] {
                    for value in spelled {
                        letters.append(FoldedLetter(exact: value, base: value))
                        spans.append(span)
                        wordStarts.append(!opened && Self.startsWord(previous: previous, current: first))
                        opened = true
                    }
                    continue
                }
                let folded = Self.caseFolded(Self.narrowed(scalar))
                letters.append(FoldedLetter(exact: folded.value, base: Self.base(of: folded)))
                spans.append(span)
                wordStarts.append(!opened && Self.startsWord(previous: previous, current: first))
                opened = true
            }
            previous = first
            offset += stored
        }
    }

    /// The Latin ligatures some fonts and documents put in names ("\u{FB01}" in "\u{FB01}le"), as the letters they
    /// stand for.
    static let ligatures: [UInt32: [UInt32]] = [
        0xFB00: [0x66, 0x66], 0xFB01: [0x66, 0x69], 0xFB02: [0x66, 0x6C], 0xFB03: [0x66, 0x66, 0x69],
        0xFB04: [0x66, 0x66, 0x6C], 0xFB05: [0x73, 0x74], 0xFB06: [0x73, 0x74],
    ]

    /// The full-width forms of the ASCII characters, which East Asian keyboards type: U+FF21 is "A", U+FF11 is "1".
    static let fullWidth: ClosedRange<UInt32> = 0xFF01...0xFF5E

    /// A full-width letter, digit or sign as the ASCII one it is, lowercased; any other scalar as it is.
    private static func narrowed(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        guard fullWidth.contains(scalar.value) else { return scalar }
        let ascii = scalar.value - 0xFEE0
        return Unicode.Scalar((0x41...0x5A).contains(ascii) ? ascii + 0x20 : ascii) ?? scalar
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

    static func startsWord(previous: UInt32, current: UInt32) -> Bool {
        !isLetterOrDigit(previous) || (isLowercase(previous) && isUppercase(current))
    }

    private static let bases = OSAllocatedUnfairLock(initialState: [UInt32: UInt32]())
    private static let folds = OSAllocatedUnfairLock(initialState: [UInt32: Unicode.Scalar]())

    /// A lowercase letter as Unicode folds case, where that gives one letter: "ſ" is "s", "µ" is "μ", "ς" is "σ", as
    /// fd's own case rule takes them. "ß" stays itself, as its fold is two letters.
    static func caseFolded(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        if scalar.isASCII { return scalar }
        if let known = folds.withLock({ $0[scalar.value] }) { return known }
        let parts = Array(String(scalar).folding(options: .caseInsensitive, locale: nil).unicodeScalars)
        let found = parts.count == 1 ? parts[0] : scalar
        folds.withLock { $0[scalar.value] = found }
        return found
    }

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

/// A name's letters and which of them start words: what matching and weighing a name need, without where each
/// letter is in the name as stored.
struct FoldedName: Sendable {
    var letters: [FoldedLetter]
    var wordStarts: [Bool]

    init(_ text: FoldedText) {
        letters = text.letters
        wordStarts = text.wordStarts
    }
}

/// Names beyond ASCII folded into letters once, for a list filtered keystroke after keystroke: the first keystroke
/// folds them and the next ones only compare. An ASCII name is compared byte by byte and isn't kept. A name kept takes
/// a few hundred bytes, so the cache is let go of with the list it was for, and holds no more names than `limit`.
public final class FoldedNameCache {
    private var folded: [String: FoldedName] = [:]
    /// Past this many names the cache starts over. A pane sets it from the size of the list it filters, so that every
    /// name of a large folder stays folded while it is typed over, and no more than that list's names are kept.
    public var limit: Int
    /// The limit of a cache made for a list of unknown size: some megabytes of names.
    public static let standardLimit = 20_000

    public init(limit: Int = FoldedNameCache.standardLimit) {
        self.limit = limit
    }

    /// The names folded and kept.
    public var count: Int { folded.count }

    /// Lets go of every name kept, and of the room they took.
    public func removeAll() {
        folded = [:]
    }

    func name(_ name: String) -> FoldedName {
        if let known = folded[name] { return known }
        if folded.count >= limit { folded.removeAll(keepingCapacity: true) }
        let made = FoldedName(FoldedText(name))
        folded[name] = made
        return made
    }

    func letters(of name: String) -> [FoldedLetter] {
        self.name(name).letters
    }
}

/// Room to weigh one name after another without asking for memory for each: an ASCII name's letters, and the table
/// the best fit is worked out in.
final class FitScratch {
    private(set) var letters: UnsafeMutablePointer<FoldedLetter>
    private(set) var wordStarts: UnsafeMutablePointer<Bool>
    private var nameRoom = 256
    /// The best score for each letter typed at each letter of the name, and where the letter before it was.
    private(set) var best: UnsafeMutablePointer<Int>
    private(set) var from: UnsafeMutablePointer<Int>
    private var cellRoom = 2048
    /// For each letter typed, the first and the last place in the name it can take.
    private(set) var first: UnsafeMutablePointer<Int>
    private(set) var last: UnsafeMutablePointer<Int>
    private var typedRoom = 32

    init() {
        letters = .allocate(capacity: nameRoom)
        wordStarts = .allocate(capacity: nameRoom)
        best = .allocate(capacity: cellRoom)
        from = .allocate(capacity: cellRoom)
        first = .allocate(capacity: typedRoom)
        last = .allocate(capacity: typedRoom)
    }

    deinit {
        letters.deallocate()
        wordStarts.deallocate()
        best.deallocate()
        from.deallocate()
        first.deallocate()
        last.deallocate()
    }

    /// Makes room for a name of `count` letters.
    func reserveName(_ count: Int) {
        guard count > nameRoom else { return }
        nameRoom = max(count, nameRoom * 2)
        letters.deallocate()
        wordStarts.deallocate()
        letters = .allocate(capacity: nameRoom)
        wordStarts = .allocate(capacity: nameRoom)
    }

    /// Makes room for the table of `typed` letters over a name of `count`.
    func reserveTable(typed: Int, count: Int) {
        if typed > typedRoom {
            typedRoom = max(typed, typedRoom * 2)
            first.deallocate()
            last.deallocate()
            first = .allocate(capacity: typedRoom)
            last = .allocate(capacity: typedRoom)
        }
        guard typed * count > cellRoom else { return }
        cellRoom = max(typed * count, cellRoom * 2)
        best.deallocate()
        from.deallocate()
        best = .allocate(capacity: cellRoom)
        from = .allocate(capacity: cellRoom)
    }
}

/// How a name stands to the text typed, for choosing the one a filter selects.
enum NameStanding: Equatable {
    /// It starts with the text.
    case prefix
    /// It holds the text as a run of letters.
    case contained
    /// It has the letters in order, fitting this well.
    case fit(Int)
    /// None of these, or a fit that wasn't asked for.
    case other
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
    /// The text's bytes when it folds to ASCII: compared with an ASCII name byte by byte, case aside.
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
        // Folded, not as typed: "ſ" is an "s" and compares byte by byte with an ASCII name.
        let isASCII = folded.letters.allSatisfy { $0.exact < 0x80 }
        ascii = isASCII ? folded.letters.map { UInt8($0.exact) } : nil
    }

    private func same(_ index: Int, _ letter: FoldedLetter) -> Bool {
        plain[index] ? letters[index].base == letter.base : letters[index].exact == letter.exact
    }

    // MARK: Matching

    /// Whether `name` matches; a name beyond ASCII is folded through `cache` when one is given.
    public func matches(_ name: String, cache: FoldedNameCache? = nil) -> Bool {
        if let fast = asciiMatches(name) { return fast }
        return matches(cache?.letters(of: name) ?? FoldedText(name).letters)
    }

    /// Whether the folded name matches: the form a list keeps once for each name.
    func matches(_ name: [FoldedLetter]) -> Bool {
        mode == .contains ? firstRun(in: name) != nil : isSubsequence(of: name)
    }

    /// Whether `name` starts with the text.
    public func isPrefix(of name: String, cache: FoldedNameCache? = nil) -> Bool {
        if let bytes = ascii, let result = withASCII(name, { Self.asciiRun(bytes, in: $0, prefixOnly: true) }) {
            return result
        }
        return isPrefix(of: cache?.letters(of: name) ?? FoldedText(name).letters)
    }

    private func isPrefix(of folded: [FoldedLetter]) -> Bool {
        folded.count >= letters.count && letters.indices.allSatisfy { same($0, folded[$0]) }
    }

    /// Whether `name` holds the text as a run of letters, whatever the mode.
    public func isContained(in name: String, cache: FoldedNameCache? = nil) -> Bool {
        if let bytes = ascii, let result = withASCII(name, { Self.asciiRun(bytes, in: $0, prefixOnly: false) }) {
            return result
        }
        return firstRun(in: cache?.letters(of: name) ?? FoldedText(name).letters) != nil
    }

    /// How `name` stands to the text: one look at the name tells a prefix, a run and, when `fit` asks for it, how
    /// well the letters in order fit. A name beyond ASCII is folded through `cache`; an ASCII one is read into
    /// `scratch`, so weighing many names asks for no memory.
    func standing(of name: String, cache: FoldedNameCache?, scratch: FitScratch, fit: Bool) -> NameStanding {
        var name = name
        let plainName: NameStanding? = name.withUTF8 { bytes in
            guard let stored = bytes.baseAddress else { return .other }
            scratch.reserveName(bytes.count)
            let letters = scratch.letters
            let wordStarts = scratch.wordStarts
            // A letter starts a word after what is no letter or digit, and a capital does after a lowercase letter
            // (`FoldedText.startsWord`, for bytes).
            var afterLower = false
            var afterLetterOrDigit = false
            for index in 0..<bytes.count {
                let byte = stored[index]
                if byte >= 0x80 { return nil }
                let upper = byte >= 0x41 && byte <= 0x5A
                let lower = byte >= 0x61 && byte <= 0x7A
                let folded = UInt32(upper ? byte + 0x20 : byte)
                letters[index] = FoldedLetter(exact: folded, base: folded)
                wordStarts[index] = !afterLetterOrDigit || (afterLower && upper)
                afterLower = lower
                afterLetterOrDigit = upper || lower || (byte >= 0x30 && byte <= 0x39)
            }
            // Text with a letter beyond ASCII is in no ASCII name.
            guard ascii != nil else { return .other }
            if let run = firstRun(UnsafePointer(letters), count: bytes.count) { return run == 0 ? .prefix : .contained }
            guard fit else { return .other }
            let found = bestFit(
                UnsafePointer(letters), UnsafePointer(wordStarts), count: bytes.count, scratch: scratch,
                positions: false)
            return found.map { .fit($0.score) } ?? .other
        }
        if let plainName { return plainName }
        let folded = cache?.name(name) ?? FoldedName(FoldedText(name))
        let count = folded.letters.count
        return folded.letters.withUnsafeBufferPointer { stored in
            folded.wordStarts.withUnsafeBufferPointer { starts in
                guard let stored = stored.baseAddress, let starts = starts.baseAddress else { return .other }
                if let run = firstRun(stored, count: count) { return run == 0 ? .prefix : .contained }
                guard fit else { return .other }
                let found = bestFit(stored, starts, count: count, scratch: scratch, positions: false)
                return found.map { .fit($0.score) } ?? .other
            }
        }
    }

    /// Where the text first runs in the `count` letters at `name`; nil when it doesn't.
    private func firstRun(_ name: UnsafePointer<FoldedLetter>, count: Int) -> Int? {
        let typedCount = letters.count
        guard typedCount <= count else { return nil }
        return letters.withUnsafeBufferPointer { typed in
            plain.withUnsafeBufferPointer { plain in
                guard let typed = typed.baseAddress, let plain = plain.baseAddress else { return nil }
                var start = 0
                while start + typedCount <= count {
                    var index = 0
                    while index < typedCount {
                        let letter = name[start + index]
                        let same =
                            plain[index] ? typed[index].base == letter.base : typed[index].exact == letter.exact
                        if !same { break }
                        index += 1
                    }
                    if index == typedCount { return start }
                    start += 1
                }
                return nil
            }
        }
    }

    /// The match for an ASCII name, byte by byte; nil when the name isn't ASCII or the text isn't.
    private func asciiMatches(_ name: String) -> Bool? {
        guard let bytes = ascii else {
            // Text with a letter that folds beyond ASCII never matches an ASCII name: a plain one is its own base, and
            // an accented one is compared as itself.
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
    /// marked where it first is; a fuzzy match marks the letters of its best fit (`score`). A letter the name stores as
    /// one character with others (a ligature, a letter and its accent) marks the whole character.
    public func marks(in name: String) -> [HighlightRange] {
        let folded = FoldedText(name)
        let positions: [Int]
        if let run = firstRun(in: folded.letters) {
            positions = Array(run)
        } else if mode == .fuzzy, let fit = bestFit(FoldedName(folded), scratch: FitScratch(), positions: true) {
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
        bestFit(FoldedName(FoldedText(name)), scratch: FitScratch(), positions: false)?.score
    }

    private static let matchScore = 16
    private static let wordStartBonus = 8
    private static let nextToBonus = 8
    private static let gapOpening = 3
    private static let gapExtension = 1
    private static let lateStartLimit = 8

    private func bestFit(_ name: FoldedName, scratch: FitScratch, positions: Bool) -> (score: Int, positions: [Int])? {
        name.letters.withUnsafeBufferPointer { letters in
            name.wordStarts.withUnsafeBufferPointer { starts in
                guard let letters = letters.baseAddress, let starts = starts.baseAddress else { return nil }
                return bestFit(letters, starts, count: name.letters.count, scratch: scratch, positions: positions)
            }
        }
    }

    /// The best fit of the letters typed, in order, over the `count` letters at `name`: its score, and with
    /// `positions` where each letter landed. The table is `scratch`'s, and only the stretch of the name each letter
    /// can take is worked out: from where it first can be, the ones before it placed as early as they go, to where it
    /// last can be, the ones after it placed as late as they go.
    private func bestFit(
        _ name: UnsafePointer<FoldedLetter>, _ wordStarts: UnsafePointer<Bool>, count n: Int, scratch: FitScratch,
        positions wantsPositions: Bool
    ) -> (score: Int, positions: [Int])? {
        let m = letters.count
        guard m <= n else { return nil }
        scratch.reserveTable(typed: m, count: n)
        let best = scratch.best
        let from = scratch.from
        let first = scratch.first
        let last = scratch.last
        return letters.withUnsafeBufferPointer { typed -> (score: Int, positions: [Int])? in
            plain.withUnsafeBufferPointer { plain -> (score: Int, positions: [Int])? in
                guard let typed = typed.baseAddress, let plain = plain.baseAddress else { return nil }
                func same(_ index: Int, _ letter: FoldedLetter) -> Bool {
                    plain[index] ? typed[index].base == letter.base : typed[index].exact == letter.exact
                }
                var j = 0
                for i in 0..<m {
                    while j < n, !same(i, name[j]) { j += 1 }
                    if j == n { return nil }
                    first[i] = j
                    j += 1
                }
                j = n - 1
                for i in stride(from: m - 1, through: 0, by: -1) {
                    while !same(i, name[j]) { j -= 1 }
                    last[i] = j
                    j -= 1
                }
                let none = Int.min / 4
                for j in first[0]...last[0] {
                    let landing = Self.matchScore + (wordStarts[j] ? Self.wordStartBonus : 0)
                    best[j] = same(0, name[j]) ? landing - min(j, Self.lateStartLimit) : none
                    from[j] = -1
                }
                for i in 1..<max(m, 1) {
                    let row = best + i * n
                    let origins = from + i * n
                    let before = row - n
                    let beforeFirst = first[i - 1]
                    let beforeLast = last[i - 1]
                    let rowFirst = first[i]
                    var gapBest = none
                    var gapFrom = -1
                    for j in (beforeFirst + 1)...last[i] {
                        if j >= beforeFirst + 2 {
                            // A gap of at least one letter between the letter before at k and this one at j.
                            let k = j - 2
                            let opened = (k <= beforeLast ? before[k] : none) - Self.gapOpening
                            if gapBest != none { gapBest -= Self.gapExtension }
                            if opened > gapBest {
                                gapBest = opened
                                gapFrom = k
                            }
                        }
                        guard j >= rowFirst else { continue }
                        guard same(i, name[j]) else {
                            row[j] = none
                            continue
                        }
                        // One next to the letter before counts for being next to it; one after a gap counts for more
                        // where it lands on a letter that starts a word.
                        var value = none
                        var origin = -1
                        if j - 1 <= beforeLast, before[j - 1] > none {
                            value = before[j - 1] + Self.matchScore + Self.nextToBonus
                            origin = j - 1
                        }
                        let landing = Self.matchScore + (wordStarts[j] ? Self.wordStartBonus : 0)
                        if gapBest > none, gapBest + landing > value {
                            value = gapBest + landing
                            origin = gapFrom
                        }
                        row[j] = value
                        origins[j] = origin
                    }
                }
                let final = best + (m - 1) * n
                var end = -1
                for j in first[m - 1]...last[m - 1] where final[j] > none && (end < 0 || final[j] > final[end]) {
                    end = j
                }
                guard end >= 0 else { return nil }
                guard wantsPositions else { return (final[end], []) }
                var positions = [Int](repeating: 0, count: m)
                j = end
                for i in stride(from: m - 1, through: 0, by: -1) {
                    positions[i] = j
                    j = from[i * n + j]
                }
                return (final[end], positions)
            }
        }
    }
}
