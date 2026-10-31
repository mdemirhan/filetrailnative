// Port of the JavaScript RegExp behavior without the unicode flag (flags "" or "i", ECMA-262 Annex B) that
// buildSearchHighlightPattern of apps/desktop/src/renderer/lib/searchResults.ts relies on
import Foundation

/// A JavaScript regular expression in its default mode (`new RegExp(source, "")` or `"i"`), run by
/// `NSRegularExpression` (ICU) after the pattern is rewritten so that ICU matches what JavaScript matches.
///
/// - JavaScript matches UTF-16 code units here, ICU code points: both the pattern and the text are matched with each
///   surrogate unit standing for a code point of its own (U+10D800…U+10DFFF), so `.` is one unit, as in JavaScript,
///   and the offsets found are counted back in the text's units.
/// - Annex B syntax: an escape of a character that names nothing is the character (`\-`, `\p`, `\k`, `\8`); a lone
///   `{`, `}` or `]` and a brace that is not a quantifier are literal; `\1` past the groups is an octal escape; `\c`
///   not before a letter is a backslash; a class escape at the end of a range is a member (`[\w-z]`); a lookahead
///   may be repeated; `\u{…}` is `u` repeated.
/// - Under `i` two characters match when their uppercase forms are the same single unit (and a non-ASCII one never
///   matches an ASCII one): "ſ" does not find "s", the Kelvin sign not "k", as JavaScript's `Canonicalize` has it.
/// - `$` is the end of the text only, `.` leaves out `\n \r U+2028 U+2029` only, and `\d \w \s \b` are JavaScript's.
/// - Known gaps, left as ICU has them: a back reference to a group that took no part fails the match (JavaScript
///   matches the empty string), and under `i` it compares with ICU's case folding; look-behinds must be of bounded
///   length; what a group captures in a loop that matched the empty string can differ.
public struct JSLegacyRegExp: @unchecked Sendable {
    let regex: NSRegularExpression

    /// `new RegExp(source, "")` or `"i"`.
    public init(source: String, ignoreCase: Bool) throws {
        var translator = try JSLegacyRegExpTranslator(source: source, ignoreCase: ignoreCase)
        let pattern = try translator.translate()
        try self.init(icuPattern: pattern, ignoreCase: ignoreCase && translator.hasBackReference)
    }

    /// The pattern `escapeRegExp(text)` writes: `text` itself, as typed.
    public init(literal text: String, ignoreCase: Bool) throws {
        let pattern = text.utf16.map { JSLegacyRegExpTranslator.literal($0, ignoreCase: ignoreCase) }.joined()
        try self.init(icuPattern: pattern, ignoreCase: false)
    }

    private init(icuPattern: String, ignoreCase: Bool) throws {
        do {
            regex = try NSRegularExpression(
                pattern: icuPattern.isEmpty ? "(?:)" : icuPattern, options: ignoreCase ? [.caseInsensitive] : [])
        } catch {
            throw JSRegExpError(message: "Invalid pattern")
        }
    }

    /// `regex.exec(text)` from the start: where the first match is, in UTF-16 units of `text`. Nil when nothing
    /// matches.
    public func firstMatch(in text: String) -> JSFirstMatch? {
        let units = Array(text.utf16)
        guard units.contains(where: JSLegacyRegExpTranslator.isSurrogate) else {
            let found = regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: units.count))
            return found.map { JSFirstMatch(range: $0.range) }
        }
        // Each unit a code point of its own; `unitAt` counts the matched text's offsets back in the text's units.
        var scalars = String.UnicodeScalarView()
        var unitAt: [Int] = []
        unitAt.reserveCapacity(units.count * 2 + 1)
        for (index, unit) in units.enumerated() {
            let value = JSLegacyRegExpTranslator.mapped(unit)
            scalars.append(Unicode.Scalar(value) ?? "\0")
            unitAt.append(index)
            if value > 0xFFFF { unitAt.append(index) }
        }
        unitAt.append(units.count)
        let mappedText = String(scalars)
        guard
            let found = regex.firstMatch(
                in: mappedText, options: [], range: NSRange(location: 0, length: unitAt.count - 1))
        else { return nil }
        let start = unitAt[found.range.location]
        let end = unitAt[found.range.location + found.range.length]
        return JSFirstMatch(range: NSRange(location: start, length: end - start))
    }
}

/// A set of UTF-16 code units.
struct JSUnitSet {
    private var words = [UInt64](repeating: 0, count: 1024)

    mutating func insert(_ unit: UInt16) {
        words[Int(unit >> 6)] |= 1 << UInt64(unit & 63)
    }

    mutating func insert(_ range: ClosedRange<UInt16>) {
        for unit in range { insert(unit) }
    }

    func contains(_ unit: UInt16) -> Bool {
        words[Int(unit >> 6)] & (1 << UInt64(unit & 63)) != 0
    }

    mutating func formUnion(_ other: JSUnitSet) {
        for index in words.indices { words[index] |= other.words[index] }
    }

    func inverted() -> JSUnitSet {
        var result = self
        for index in result.words.indices { result.words[index] = ~result.words[index] }
        return result
    }

    var isEmpty: Bool { words.allSatisfy { $0 == 0 } }

    /// Every unit whose canonical form (`Canonicalize`) is that of a member: what the set matches under `i`.
    func caseClosed() -> JSUnitSet {
        var result = self
        for members in JSLegacyCase.groups.values where members.contains(where: contains) {
            for unit in members { result.insert(unit) }
        }
        return result
    }

    /// The first member at or after `unit`, if any.
    private func next(from unit: Int) -> Int? {
        var index = unit >> 6
        guard index < words.count else { return nil }
        var bits = words[index] & (~0 << UInt64(unit & 63))
        while bits == 0 {
            index += 1
            guard index < words.count else { return nil }
            bits = words[index]
        }
        return index << 6 + bits.trailingZeroBitCount
    }

    /// The members as an ICU set, each unit written as the code point it is matched as.
    var icuClass: String {
        var body = ""
        var start = next(from: 0)
        while let unit = start {
            var end = unit
            // A run stops at the edges of the surrogates, where the code points it is written as jump.
            while end < 0xFFFF, contains(UInt16(end + 1)), end + 1 != 0xD800, end + 1 != 0xE000 { end += 1 }
            let low = JSLegacyRegExpTranslator.hex(UInt16(unit))
            body += end == unit ? low : "\(low)-\(JSLegacyRegExpTranslator.hex(UInt16(end)))"
            start = end < 0xFFFF ? next(from: end + 1) : nil
        }
        return body.isEmpty ? "[^\\x{0}-\\x{10FFFF}]" : "[\(body)]"
    }
}

/// `Canonicalize` without the unicode flag: a unit's uppercase form when that is one unit and does not take a
/// non-ASCII unit to an ASCII one; the unit itself otherwise.
enum JSLegacyCase {
    static let canonical: [UInt16] = {
        var table = [UInt16](repeating: 0, count: 0x10000)
        for unit in 0...0xFFFF {
            guard let scalar = Unicode.Scalar(UInt32(unit)) else {
                table[unit] = UInt16(unit)
                continue
            }
            let upper = Array(scalar.properties.uppercaseMapping.utf16)
            table[unit] = upper.count == 1 && !(unit >= 128 && upper[0] < 128) ? upper[0] : UInt16(unit)
        }
        return table
    }()

    /// The units that share a canonical form with another, by that form.
    static let groups: [UInt16: [UInt16]] = {
        var groups: [UInt16: [UInt16]] = [:]
        for unit in 0...0xFFFF where canonical[unit] != UInt16(unit) {
            groups[canonical[unit], default: []].append(UInt16(unit))
        }
        for form in groups.keys where canonical[Int(form)] == form { groups[form, default: []].append(form) }
        return groups.filter { $0.value.count > 1 }
    }()
}

/// Rewrites a JavaScript pattern (default mode) as an ICU one; see `JSLegacyRegExp`.
struct JSLegacyRegExpTranslator {
    private let units: [UInt16]
    private let ignoreCase: Bool
    private var position = 0
    private var output = ""
    private var openGroups: [GroupKind] = []
    private var previous = Previous.nothing
    private let captureCount: Int
    private let groupNames: [String?]
    private var hasNamedGroups: Bool { groupNames.contains { $0 != nil } }
    private(set) var hasBackReference = false

    private enum GroupKind { case capturing, plain, lookahead, lookbehind }

    /// What the last thing written allows after it.
    private enum Previous {
        /// Start of the pattern, after `(` or `|`: a quantifier has nothing to repeat.
        case nothing
        /// A character, a set, a group or a lookahead.
        case atom
        /// `^ $ \b \B` and look-behinds.
        case assertion
        case quantified
    }

    private enum ClassAtom {
        case unit(UInt16)
        case set(JSUnitSet)
    }

    static func isSurrogate(_ unit: UInt16) -> Bool { (0xD800...0xDFFF).contains(unit) }

    /// The code point a unit is matched as.
    static func mapped(_ unit: UInt16) -> UInt32 { isSurrogate(unit) ? 0x10_0000 + UInt32(unit) : UInt32(unit) }

    static func hex(_ unit: UInt16) -> String { "\\x{\(String(mapped(unit), radix: 16, uppercase: true))}" }

    static func literal(_ unit: UInt16, ignoreCase: Bool) -> String {
        guard ignoreCase, let members = JSLegacyCase.groups[JSLegacyCase.canonical[Int(unit)]] else {
            return hex(unit)
        }
        return "[\(members.sorted().map(hex).joined())]"
    }

    private static func code(_ character: Unicode.Scalar) -> UInt16 { UInt16(character.value) }

    private static let digits: JSUnitSet = {
        var set = JSUnitSet()
        set.insert(code("0")...code("9"))
        return set
    }()
    private static let wordCharacters: JSUnitSet = {
        var set = digits
        set.insert(code("A")...code("Z"))
        set.insert(code("a")...code("z"))
        set.insert(code("_"))
        return set
    }()
    private static let whiteSpace: JSUnitSet = {
        var set = JSUnitSet()
        set.insert(0x9...0xD)
        for unit: UInt16 in [0x20, 0xA0, 0x1680, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF] { set.insert(unit) }
        set.insert(0x2000...0x200A)
        return set
    }()
    private static let wordBoundary =
        "(?:(?<=[A-Za-z0-9_])(?![A-Za-z0-9_])|(?<![A-Za-z0-9_])(?=[A-Za-z0-9_]))"
    private static let notWordBoundary =
        "(?:(?<=[A-Za-z0-9_])(?=[A-Za-z0-9_])|(?<![A-Za-z0-9_])(?![A-Za-z0-9_]))"
    private static let anyButLineBreaks = "[^\\x{A}\\x{D}\\x{2028}\\x{2029}]"

    init(source: String, ignoreCase: Bool) throws {
        units = Array(source.utf16)
        self.ignoreCase = ignoreCase
        let groups = try Self.scanGroups(units)
        groupNames = groups
        captureCount = groups.count
    }

    private static func fail(_ message: String) -> JSRegExpError {
        JSRegExpError(message: message)
    }

    private func unit(at index: Int) -> UInt16? { index < units.count ? units[index] : nil }

    private func isDigit(_ unit: UInt16?) -> Bool { unit.map { (0x30...0x39).contains($0) } ?? false }

    private func isOctal(_ unit: UInt16?) -> Bool { unit.map { (0x30...0x37).contains($0) } ?? false }

    private func isLetter(_ unit: UInt16?) -> Bool {
        unit.map { (0x41...0x5A).contains($0) || (0x61...0x7A).contains($0) } ?? false
    }

    // MARK: Groups, found first: `\1` and `\k<name>` need to know what exists.

    private static func scanGroups(_ s: [UInt16]) throws -> [String?] {
        var names: [String?] = []
        var seen = Set<String>()
        var index = 0
        while index < s.count {
            let unit = s[index]
            if unit == code("\\") {
                index += 2
                continue
            }
            if unit == code("[") {
                index += 1
                while index < s.count, s[index] != code("]") {
                    index += s[index] == code("\\") ? 2 : 1
                }
                index += 1
                continue
            }
            if unit == code("(") {
                if index + 1 < s.count, s[index + 1] == code("?") {
                    if index + 3 < s.count, s[index + 2] == code("<"), s[index + 3] != code("="),
                        s[index + 3] != code("!")
                    {
                        var end = index + 3
                        while end < s.count, s[end] != code(">") { end += 1 }
                        guard end < s.count else { throw fail("Invalid capture group name") }
                        let name = String(decoding: s[(index + 3)..<end], as: UTF16.self)
                        guard isGroupName(name) else { throw fail("Invalid capture group name") }
                        guard seen.insert(name).inserted else { throw fail("Duplicate capture group name") }
                        names.append(name)
                    }
                } else {
                    names.append(nil)
                }
            }
            index += 1
        }
        return names
    }

    private static func isGroupName(_ name: String) -> Bool {
        let scalars = Array(name.unicodeScalars)
        guard let first = scalars.first else { return false }
        guard first == "$" || first == "_" || first.properties.isIDStart else { return false }
        return scalars.dropFirst().allSatisfy {
            $0 == "$" || $0 == "_" || $0 == "\u{200C}" || $0 == "\u{200D}" || $0.properties.isIDContinue
        }
    }

    // MARK: Translation

    mutating func translate() throws -> String {
        while position < units.count {
            switch units[position] {
            case Self.code("\\"):
                try escape()
            case Self.code("["):
                try characterClass()
            case Self.code("("):
                try openGroup()
            case Self.code(")"):
                guard let kind = openGroups.popLast() else { throw Self.fail("Unmatched ')'") }
                // A lookahead is written inside a group of its own, which ICU lets a quantifier follow.
                output += kind == .lookahead ? "))" : ")"
                previous = kind == .lookbehind ? .assertion : .atom
                position += 1
            case Self.code("|"):
                output += "|"
                previous = .nothing
                position += 1
            case Self.code("^"):
                assertion("^")
            case Self.code("$"):
                assertion("\\z")
            case Self.code("."):
                atom(Self.anyButLineBreaks)
            case Self.code("*"), Self.code("+"), Self.code("?"):
                let text = String(decoding: [units[position]], as: UTF16.self)
                position += 1
                try quantifier(text)
            case Self.code("{"):
                if let bounds = try braceQuantifier() {
                    try quantifier(bounds)
                } else {
                    literal(units[position])
                }
            default:
                literal(units[position])
            }
        }
        guard openGroups.isEmpty else { throw Self.fail("Unterminated group") }
        return output
    }

    private mutating func atom(_ text: String, length: Int = 1) {
        output += text
        previous = .atom
        position += length
    }

    private mutating func assertion(_ text: String, length: Int = 1) {
        output += text
        previous = .assertion
        position += length
    }

    private mutating func literal(_ unit: UInt16, length: Int = 1) {
        atom(Self.literal(unit, ignoreCase: ignoreCase), length: length)
    }

    private mutating func set(_ set: JSUnitSet, length: Int) {
        atom((ignoreCase ? set.caseClosed() : set).icuClass, length: length)
    }

    /// `text` is the quantifier as written for ICU, the position already past it; a `?` after it makes it lazy.
    private mutating func quantifier(_ text: String) throws {
        guard previous == .atom else { throw Self.fail("Nothing to repeat") }
        output += text
        if unit(at: position) == Self.code("?") {
            output += "?"
            position += 1
        }
        previous = .quantified
    }

    /// `{n}`, `{n,}` or `{n,m}` at the position, consumed; nil (and nothing consumed) when it is not one, which makes
    /// the brace a character of its own.
    private mutating func braceQuantifier() throws -> String? {
        var index = position + 1
        func number() -> (text: String, value: Double)? {
            let start = index
            while isDigit(unit(at: index)) { index += 1 }
            guard index > start else { return nil }
            let text = String(decoding: units[start..<index], as: UTF16.self)
            return (text, Double(text) ?? .infinity)
        }
        guard let low = number() else { return nil }
        var result = "{\(low.text)"
        var high: Double?
        if unit(at: index) == Self.code(",") {
            index += 1
            result += ","
            if let bound = number() {
                high = bound.value
                result += bound.text
            }
        }
        guard unit(at: index) == Self.code("}") else { return nil }
        // A quantifier with nothing before it is an error, not a literal brace.
        guard previous == .atom else { throw Self.fail("Nothing to repeat") }
        if let high, low.value > high { throw Self.fail("numbers out of order in {} quantifier") }
        position = index + 1
        return result + "}"
    }

    private mutating func openGroup() throws {
        position += 1
        guard unit(at: position) == Self.code("?") else {
            output += "("
            openGroups.append(.capturing)
            previous = .nothing
            return
        }
        position += 1
        switch (unit(at: position), unit(at: position + 1)) {
        case (Self.code(":"), _):
            output += "(?:"
            openGroups.append(.plain)
            position += 1
        case (Self.code("="), _):
            output += "(?:(?="
            openGroups.append(.lookahead)
            position += 1
        case (Self.code("!"), _):
            output += "(?:(?!"
            openGroups.append(.lookahead)
            position += 1
        case (Self.code("<"), Self.code("=")):
            output += "(?<="
            openGroups.append(.lookbehind)
            position += 2
        case (Self.code("<"), Self.code("!")):
            output += "(?<!"
            openGroups.append(.lookbehind)
            position += 2
        case (Self.code("<"), _):
            // A named group: its name was checked with the scan; it is a plain numbered group here.
            while position < units.count, units[position] != Self.code(">") { position += 1 }
            position += 1
            output += "("
            openGroups.append(.capturing)
        default:
            throw Self.fail("Invalid group")
        }
        previous = .nothing
    }

    // MARK: Escapes

    private mutating func escape() throws {
        guard let next = unit(at: position + 1) else { throw Self.fail("\\ at end of pattern") }
        switch next {
        case Self.code("d"): set(Self.digits, length: 2)
        case Self.code("D"): set(Self.digits.inverted(), length: 2)
        case Self.code("w"): set(Self.wordCharacters, length: 2)
        case Self.code("W"): set(Self.wordCharacters.inverted(), length: 2)
        case Self.code("s"): set(Self.whiteSpace, length: 2)
        case Self.code("S"): set(Self.whiteSpace.inverted(), length: 2)
        case Self.code("b"): assertion(Self.wordBoundary, length: 2)
        case Self.code("B"): assertion(Self.notWordBoundary, length: 2)
        case Self.code("1")...Self.code("9"):
            try decimalEscape()
        case Self.code("k") where hasNamedGroups:
            try namedReference()
        case Self.code("c") where !isLetter(unit(at: position + 2)):
            // `\` before a `c` that starts no control escape is a backslash; the `c` comes next.
            literal(Self.code("\\"))
        default:
            position += 1
            let character = characterEscape()
            output += Self.literal(character, ignoreCase: ignoreCase)
            previous = .atom
        }
    }

    /// `\1`…: a back reference when there are that many groups; past them an octal escape, or the digit itself.
    private mutating func decimalEscape() throws {
        var end = position + 1
        while isDigit(unit(at: end)) { end += 1 }
        let digits = String(decoding: units[(position + 1)..<end], as: UTF16.self)
        if let number = Int(digits), number <= captureCount {
            output += "(?:\\\(number))"
            hasBackReference = true
            previous = .atom
            position = end
            return
        }
        position += 1
        let character = characterEscape()
        output += Self.literal(character, ignoreCase: ignoreCase)
        previous = .atom
    }

    private mutating func namedReference() throws {
        guard unit(at: position + 2) == Self.code("<") else { throw Self.fail("Invalid named reference") }
        var end = position + 3
        while end < units.count, units[end] != Self.code(">") { end += 1 }
        guard end < units.count else { throw Self.fail("Invalid named reference") }
        let name = String(decoding: units[(position + 3)..<end], as: UTF16.self)
        guard let index = groupNames.firstIndex(where: { $0 == name }) else {
            throw Self.fail("Invalid named capture referenced")
        }
        output += "(?:\\\(index + 1))"
        hasBackReference = true
        previous = .atom
        position = end + 1
    }

    /// The unit a character escape names, the position on the unit after the backslash; consumed. Without the unicode
    /// flag every escape names something: what names nothing else is the character itself.
    private mutating func characterEscape() -> UInt16 {
        let code = units[position]
        position += 1
        switch code {
        case Self.code("t"): return 0x9
        case Self.code("n"): return 0xA
        case Self.code("v"): return 0xB
        case Self.code("f"): return 0xC
        case Self.code("r"): return 0xD
        case Self.code("c"):
            // Checked by the caller: a letter follows (or, in a class, a digit or `_` too).
            let letter = units[position]
            position += 1
            return letter % 32
        case Self.code("x"):
            return hexDigits(count: 2) ?? code
        case Self.code("u"):
            return hexDigits(count: 4) ?? code
        case Self.code("0")...Self.code("7"):
            return octalEscape(first: code)
        default:
            return code
        }
    }

    /// `LegacyOctalEscapeSequence`, its first digit read: up to three digits, at most \377.
    private mutating func octalEscape(first: UInt16) -> UInt16 {
        var value = first - Self.code("0")
        let most = first <= Self.code("3") ? 2 : 1
        for _ in 0..<most {
            guard let next = unit(at: position), isOctal(next) else { break }
            value = value * 8 + (next - Self.code("0"))
            position += 1
        }
        return value
    }

    private mutating func hexDigits(count: Int) -> UInt16? {
        guard position + count <= units.count else { return nil }
        var value: UInt16 = 0
        for offset in 0..<count {
            guard let digit = Character(Unicode.Scalar(units[position + offset]) ?? "\0").hexDigitValue else {
                return nil
            }
            value = value * 16 + UInt16(digit)
        }
        position += count
        return value
    }

    // MARK: Character classes

    private mutating func characterClass() throws {
        position += 1
        var negated = false
        if unit(at: position) == Self.code("^") {
            negated = true
            position += 1
        }
        var members = JSUnitSet()
        var closed = false
        while position < units.count {
            if units[position] == Self.code("]") {
                closed = true
                position += 1
                break
            }
            let low = try classAtom()
            if unit(at: position) == Self.code("-"), let after = unit(at: position + 1), after != Self.code("]") {
                position += 1
                let high = try classAtom()
                switch (low, high) {
                case (.unit(let from), .unit(let to)):
                    guard from <= to else { throw Self.fail("Range out of order in character class") }
                    members.insert(from...to)
                default:
                    // A class escape at either end makes no range: both ends and the "-" are members.
                    for end in [low, high] { add(end, to: &members) }
                    members.insert(Self.code("-"))
                }
            } else {
                add(low, to: &members)
            }
        }
        guard closed else { throw Self.fail("Unterminated character class") }
        if ignoreCase { members = members.caseClosed() }
        output += (negated ? members.inverted() : members).icuClass
        previous = .atom
    }

    private func add(_ atom: ClassAtom, to members: inout JSUnitSet) {
        switch atom {
        case .unit(let unit): members.insert(unit)
        case .set(let set): members.formUnion(set)
        }
    }

    private mutating func classAtom() throws -> ClassAtom {
        let first = units[position]
        guard first == Self.code("\\") else {
            position += 1
            return .unit(first)
        }
        guard let next = unit(at: position + 1) else { throw Self.fail("\\ at end of pattern") }
        switch next {
        case Self.code("d"):
            position += 2
            return .set(Self.digits)
        case Self.code("D"):
            position += 2
            return .set(Self.digits.inverted())
        case Self.code("w"):
            position += 2
            return .set(Self.wordCharacters)
        case Self.code("W"):
            position += 2
            return .set(Self.wordCharacters.inverted())
        case Self.code("s"):
            position += 2
            return .set(Self.whiteSpace)
        case Self.code("S"):
            position += 2
            return .set(Self.whiteSpace.inverted())
        case Self.code("b"):
            position += 2
            return .unit(0x8)
        case Self.code("k") where hasNamedGroups:
            throw Self.fail("Invalid escape")
        case Self.code("c"):
            // In a class a digit or `_` also makes a control escape; anything else leaves a backslash.
            if let control = unit(at: position + 2),
                isLetter(control) || isDigit(control) || control == Self.code("_")
            {
                position += 3
                return .unit(control % 32)
            }
            position += 1
            return .unit(Self.code("\\"))
        default:
            position += 1
            return .unit(characterEscape())
        }
    }
}
