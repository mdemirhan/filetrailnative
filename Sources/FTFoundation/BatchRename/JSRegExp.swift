// Port of the JavaScript RegExp behavior (flags "gu" or "giu") that apps/desktop/src/shared/batchRename.ts relies on
import Foundation

/// A syntax or semantic error in a pattern, worded like the engine's own ("Nothing to repeat").
struct JSRegExpError: Error, Equatable, CustomStringConvertible {
    let message: String
    var description: String { message }
}

/// One match of a global search: `groups[0]` is the whole match, `nil` a group that took no part.
struct JSMatch: Equatable {
    /// UTF-16 offset of the match in the searched text.
    let index: Int
    let groups: [String?]
    /// `match.groups`: nil when the pattern names no group.
    let namedGroups: [String: String?]?

    var text: String { groups[0] ?? "" }
}

/// A JavaScript regular expression in unicode mode, run by `NSRegularExpression` (ICU) after the pattern is rewritten
/// so that ICU matches what JavaScript matches. Where the two differ the rewrite says so:
///
/// - `$` is the end of the text only (ICU also matches before a final line break): written `\z`.
/// - `.` leaves out `\n \r U+2028 U+2029` only (ICU also leaves out U+0085, U+000B, U+000C).
/// - `\d \w \s \b` are ASCII digits and word characters and JavaScript's white space (ICU's are Unicode ones).
/// - Under the `i` flag every literal is a one-character set `[\x{..}]`: ICU folds a run of literals (and a lone "ß")
///   as a string with *full* case folding, so "ss" would find "ß"; a set closes over *simple* case folding, which is
///   what JavaScript's unicode mode does.
/// - Capture groups are numbered; their names are kept here and `\k<name>` is rewritten as a number.
/// - Syntax JavaScript's unicode mode refuses and ICU accepts is refused here: unknown escapes (`\Q`, `\A`, `\h`, `\-`
///   outside a class), a lone `{`, `}` or `]`, `*+` possessive and `(?i)` style groups, a quantified lookahead.
/// - Known gaps, left as ICU has them (none is reachable from a name typed in the sheet in practice): a back reference
///   to a group that took no part fails the match (JavaScript matches the empty string); look-behinds must be of
///   bounded length; `\P{Lu}` under `i` leaves the capitals out (JavaScript's does not); what a group captures in a
///   loop that matched the empty string (`(a*)*`, `(|a)+`) can differ; a ligature such as "ﬁ" inside a class also
///   finds "fi".
struct JSRegExp {
    let regex: NSRegularExpression
    /// The name of each capture group, in order (nil for an unnamed one).
    let groupNames: [String?]

    /// `new RegExp(source, "gu")` or `"giu"`.
    init(source: String, ignoreCase: Bool) throws {
        var translator = try JSRegExpTranslator(source: source, ignoreCase: ignoreCase)
        let pattern = try translator.translate()
        try self.init(icuPattern: pattern, groupNames: translator.groupNames, ignoreCase: ignoreCase)
    }

    /// The pattern `escapeRegExp(text)` writes: `text` itself, as typed.
    init(literal text: String, ignoreCase: Bool) throws {
        let pattern = text.unicodeScalars.map { JSRegExpTranslator.literal($0, ignoreCase: ignoreCase) }.joined()
        try self.init(icuPattern: pattern, groupNames: [], ignoreCase: ignoreCase)
    }

    private init(icuPattern: String, groupNames: [String?], ignoreCase: Bool) throws {
        guard !icuPattern.isEmpty else {
            // ICU refuses an empty pattern; JavaScript's matches the empty string everywhere.
            self.regex = try NSRegularExpression(pattern: "(?:)", options: [])
            self.groupNames = groupNames
            return
        }
        do {
            regex = try NSRegularExpression(pattern: icuPattern, options: ignoreCase ? [.caseInsensitive] : [])
        } catch {
            throw JSRegExpError(message: "Invalid pattern")
        }
        self.groupNames = groupNames
    }

    /// `[...text.matchAll(regex)]`.
    func matches(in text: String) -> [JSMatch] {
        let string = text as NSString
        let found = regex.matches(in: text, options: [], range: NSRange(location: 0, length: string.length))
        let hasNames = groupNames.contains { $0 != nil }
        return found.map { result in
            let groups: [String?] = (0..<result.numberOfRanges).map { index in
                let range = result.range(at: index)
                return range.location == NSNotFound ? nil : string.substring(with: range)
            }
            var named: [String: String?]?
            if hasNames {
                var byName: [String: String?] = [:]
                for (offset, name) in groupNames.enumerated() {
                    if let name, offset + 1 < groups.count { byName[name] = groups[offset + 1] }
                }
                named = byName
            }
            return JSMatch(index: result.range.location, groups: groups, namedGroups: named)
        }
    }
}

/// Rewrites a JavaScript pattern (unicode mode) as an ICU one; see `JSRegExp`.
struct JSRegExpTranslator {
    private let scalars: [Unicode.Scalar]
    private let ignoreCase: Bool
    private var position = 0
    private var output = ""
    private var openGroups: [GroupKind] = []
    private var previous = Previous.nothing
    private(set) var groupNames: [String?] = []
    private var captureCount: Int { groupNames.count }

    private enum GroupKind { case capturing, plain, lookahead, lookbehind }

    /// What the last thing written allows after it.
    private enum Previous {
        /// Start of the pattern, after `(` or `|`: a quantifier has nothing to repeat.
        case nothing
        case atom
        /// `^ $ \b` and look-arounds: JavaScript's unicode mode refuses a quantifier here.
        case assertion
        case quantified
    }

    private enum ClassAtom {
        case scalar(Unicode.Scalar)
        case set(String)

        var fragment: String {
            switch self {
            case .scalar(let scalar): JSRegExpTranslator.hex(scalar)
            case .set(let text): text
            }
        }
    }

    // ICU fragments for JavaScript's classes.
    private static let digits = "0-9"
    private static let wordCharacters = "A-Za-z0-9_"
    private static let whiteSpace =
        "\\x{9}-\\x{D}\\x{20}\\x{A0}\\x{1680}\\x{2000}-\\x{200A}\\x{2028}\\x{2029}\\x{202F}\\x{205F}\\x{3000}\\x{FEFF}"
    private static let wordBoundary =
        "(?:(?<=[A-Za-z0-9_])(?![A-Za-z0-9_])|(?<![A-Za-z0-9_])(?=[A-Za-z0-9_]))"
    private static let notWordBoundary =
        "(?:(?<=[A-Za-z0-9_])(?=[A-Za-z0-9_])|(?<![A-Za-z0-9_])(?![A-Za-z0-9_]))"

    static func hex(_ scalar: Unicode.Scalar) -> String {
        "\\x{\(String(scalar.value, radix: 16, uppercase: true))}"
    }

    /// Characters whose full case folding is several characters and has no simple folding (ligatures such as "ﬁ",
    /// "ŉ", "İ"): even in a set, ICU lets them match the folded text ("fi"), which JavaScript's unicode mode does not.
    private static let foldsToSeveral: Set<UInt32> = [
        0x130, 0x149, 0x1F0, 0x587, 0x1E96, 0x1E97, 0x1E98, 0x1E99, 0x1E9A, 0x1F50, 0x1F52, 0x1F54, 0x1F56, 0x1FB2,
        0x1FB4, 0x1FB6, 0x1FB7, 0x1FC2, 0x1FC4, 0x1FC6, 0x1FC7, 0x1FD2, 0x1FD6, 0x1FD7, 0x1FE2, 0x1FE4, 0x1FE6,
        0x1FE7, 0x1FF2, 0x1FF4, 0x1FF6, 0x1FF7, 0xFB00, 0xFB01, 0xFB02, 0xFB03, 0xFB04, 0xFB13, 0xFB14, 0xFB15,
        0xFB16, 0xFB17,
    ]

    static func literal(_ scalar: Unicode.Scalar, ignoreCase: Bool) -> String {
        guard ignoreCase else { return hex(scalar) }
        // Those characters have no other case form, so they are matched as they are.
        return foldsToSeveral.contains(scalar.value) ? "(?-i:\(hex(scalar)))" : "[\(hex(scalar))]"
    }

    init(source: String, ignoreCase: Bool) throws {
        scalars = Array(source.unicodeScalars)
        self.ignoreCase = ignoreCase
        groupNames = try Self.scanGroups(scalars)
    }

    private static func fail(_ message: String) -> JSRegExpError {
        JSRegExpError(message: message)
    }

    // MARK: Groups, found first: `\1` and `\k<name>` need to know what exists.

    private static func scanGroups(_ s: [Unicode.Scalar]) throws -> [String?] {
        var names: [String?] = []
        var seen = Set<String>()
        var index = 0
        while index < s.count {
            let scalar = s[index]
            if scalar == "\\" {
                index += 2
                continue
            }
            if scalar == "[" {
                index += 1
                while index < s.count, s[index] != "]" {
                    index += s[index] == "\\" ? 2 : 1
                }
                index += 1
                continue
            }
            if scalar == "(" {
                if index + 1 < s.count, s[index + 1] == "?" {
                    if index + 3 < s.count, s[index + 2] == "<", s[index + 3] != "=", s[index + 3] != "!" {
                        var end = index + 3
                        while end < s.count, s[end] != ">" { end += 1 }
                        guard end < s.count else { throw fail("Invalid capture group name") }
                        let name = String(String.UnicodeScalarView(s[(index + 3)..<end]))
                        guard isGroupName(Array(s[(index + 3)..<end])) else { throw fail("Invalid capture group name") }
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

    private static func isGroupName(_ name: [Unicode.Scalar]) -> Bool {
        guard let first = name.first else { return false }
        guard first == "$" || first == "_" || first.properties.isIDStart else { return false }
        return name.dropFirst().allSatisfy {
            $0 == "$" || $0 == "_" || $0 == "\u{200C}" || $0 == "\u{200D}" || $0.properties.isIDContinue
        }
    }

    // MARK: Translation

    mutating func translate() throws -> String {
        while position < scalars.count {
            let scalar = scalars[position]
            switch scalar {
            case "\\":
                try escape()
            case "[":
                try characterClass()
            case "(":
                try openGroup()
            case ")":
                guard let kind = openGroups.popLast() else { throw Self.fail("Unmatched ')'") }
                output += ")"
                previous = kind == .lookahead || kind == .lookbehind ? .assertion : .atom
                position += 1
            case "|":
                output += "|"
                previous = .nothing
                position += 1
            case "^":
                output += "^"
                previous = .assertion
                position += 1
            case "$":
                output += "\\z"
                previous = .assertion
                position += 1
            case ".":
                atom("[^\\x{A}\\x{D}\\x{2028}\\x{2029}]")
            case "*", "+", "?":
                try quantifier(String(Character(scalar)))
            case "{":
                guard let bounds = braceQuantifier() else { throw Self.fail("Incomplete quantifier") }
                try quantifier(bounds)
            case "}", "]":
                throw Self.fail("Lone quantifier brackets")
            default:
                literal(scalar)
            }
        }
        guard openGroups.isEmpty else { throw Self.fail("Unterminated group") }
        return output
    }

    private mutating func atom(_ text: String) {
        output += text
        previous = .atom
        position += 1
    }

    private mutating func literal(_ scalar: Unicode.Scalar) {
        output += Self.literal(scalar, ignoreCase: ignoreCase)
        previous = .atom
        position += 1
    }

    /// `text` is the quantifier as written for ICU; a `?` after it makes it lazy.
    private mutating func quantifier(_ text: String) throws {
        guard previous == .atom else { throw Self.fail("Nothing to repeat") }
        output += text
        if text.hasPrefix("{") {
            // position is already past the braces
        } else {
            position += 1
        }
        if position < scalars.count, scalars[position] == "?" {
            output += "?"
            position += 1
        }
        previous = .quantified
    }

    /// `{n}`, `{n,}` or `{n,m}` at the position, consumed; nil when it is not one.
    private mutating func braceQuantifier() -> String? {
        var index = position + 1
        func number() -> (text: String, value: Double)? {
            let start = index
            while index < scalars.count, ("0"..."9").contains(scalars[index]) { index += 1 }
            guard index > start else { return nil }
            let text = String(String.UnicodeScalarView(scalars[start..<index]))
            return (text, Double(text) ?? .infinity)
        }
        guard let low = number() else { return nil }
        var result = "{\(low.text)"
        if index < scalars.count, scalars[index] == "," {
            index += 1
            result += ","
            if let high = number() {
                guard low.value <= high.value else { return nil }
                result += high.text
            }
        }
        guard index < scalars.count, scalars[index] == "}" else { return nil }
        position = index + 1
        return result + "}"
    }

    private mutating func openGroup() throws {
        position += 1
        guard position < scalars.count, scalars[position] == "?" else {
            output += "("
            openGroups.append(.capturing)
            previous = .nothing
            return
        }
        position += 1
        func at(_ offset: Int) -> Unicode.Scalar? {
            position + offset < scalars.count ? scalars[position + offset] : nil
        }
        switch (at(0), at(1)) {
        case (":", _):
            output += "(?:"
            openGroups.append(.plain)
            position += 1
        case ("=", _):
            output += "(?="
            openGroups.append(.lookahead)
            position += 1
        case ("!", _):
            output += "(?!"
            openGroups.append(.lookahead)
            position += 1
        case ("<", "="):
            output += "(?<="
            openGroups.append(.lookbehind)
            position += 2
        case ("<", "!"):
            output += "(?<!"
            openGroups.append(.lookbehind)
            position += 2
        case ("<", _):
            // A named group: its name was checked with the scan; it is a plain numbered group here.
            while position < scalars.count, scalars[position] != ">" { position += 1 }
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
        guard position + 1 < scalars.count else { throw Self.fail("\\ at end of pattern") }
        let next = scalars[position + 1]
        switch next {
        case "d": position += 1; atom("[\(Self.digits)]")
        case "D": position += 1; atom("[^\(Self.digits)]")
        case "w": position += 1; atom("[\(Self.wordCharacters)]")
        case "W": position += 1; atom("[^\(Self.wordCharacters)]")
        case "s": position += 1; atom("[\(Self.whiteSpace)]")
        case "S": position += 1; atom("[^\(Self.whiteSpace)]")
        case "b":
            output += Self.wordBoundary
            previous = .assertion
            position += 2
        case "B":
            output += Self.notWordBoundary
            previous = .assertion
            position += 2
        case "0"..."9":
            try numberedEscape()
        case "k":
            try namedReference()
        case "p", "P":
            position += 1
            let property = try propertyEscape()
            output += property
            previous = .atom
        default:
            let scalar = try characterEscape(inClass: false)
            output += Self.literal(scalar, ignoreCase: ignoreCase)
            previous = .atom
        }
    }

    /// `\0`, or a back reference `\1`…
    private mutating func numberedEscape() throws {
        var end = position + 1
        while end < scalars.count, ("0"..."9").contains(scalars[end]) { end += 1 }
        let digits = String(String.UnicodeScalarView(scalars[(position + 1)..<end]))
        if digits == "0" {
            output += Self.literal("\0", ignoreCase: ignoreCase)
        } else {
            guard !digits.hasPrefix("0"), let number = Int(digits), number <= captureCount else {
                throw Self.fail("Invalid escape")
            }
            output += "(?:\\\(number))"
        }
        previous = .atom
        position = end
    }

    private mutating func namedReference() throws {
        guard groupNames.contains(where: { $0 != nil }) else { throw Self.fail("Invalid named reference") }
        guard position + 2 < scalars.count, scalars[position + 2] == "<" else {
            throw Self.fail("Invalid named reference")
        }
        var end = position + 3
        while end < scalars.count, scalars[end] != ">" { end += 1 }
        guard end < scalars.count else { throw Self.fail("Invalid named reference") }
        let name = String(String.UnicodeScalarView(scalars[(position + 3)..<end]))
        guard let index = groupNames.firstIndex(where: { $0 == name }) else {
            throw Self.fail("Invalid named capture referenced")
        }
        output += "(?:\\\(index + 1))"
        previous = .atom
        position = end + 1
    }

    /// `\p{…}` or `\P{…}`, with the position on the `p`; consumed.
    private mutating func propertyEscape() throws -> String {
        let negated = scalars[position] == "P"
        guard position + 1 < scalars.count, scalars[position + 1] == "{" else {
            throw Self.fail("Invalid property name")
        }
        var end = position + 2
        while end < scalars.count, scalars[end] != "}" { end += 1 }
        guard end < scalars.count, end > position + 2 else { throw Self.fail("Invalid property name") }
        let body = scalars[(position + 2)..<end]
        let allowed: (Unicode.Scalar) -> Bool = {
            $0 == "_" || $0 == "=" || ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0)
        }
        guard body.allSatisfy(allowed) else { throw Self.fail("Invalid property name") }
        position = end + 1
        return "\\\(negated ? "P" : "p"){\(String(String.UnicodeScalarView(body)))}"
    }

    /// The character an escape names (`\n`, `\x41`, `\u{1F600}`, `\/`, `\-` in a class…), the position on the
    /// backslash; consumed.
    private mutating func characterEscape(inClass: Bool) throws -> Unicode.Scalar {
        let code = scalars[position + 1]
        position += 2
        switch code {
        case "t": return "\t"
        case "n": return "\n"
        case "v": return "\u{0B}"
        case "f": return "\u{0C}"
        case "r": return "\r"
        case "c":
            guard position < scalars.count, let letter = Optional(scalars[position]),
                ("a"..."z").contains(letter) || ("A"..."Z").contains(letter)
            else { throw Self.fail("Invalid unicode escape") }
            position += 1
            return Unicode.Scalar(letter.value % 32) ?? "\0"
        case "x":
            guard let value = hexDigits(count: 2), let scalar = Unicode.Scalar(value) else {
                throw Self.fail("Invalid escape")
            }
            return scalar
        case "u":
            return try unicodeEscape()
        case "^", "$", "\\", ".", "*", "+", "?", "(", ")", "[", "]", "{", "}", "|", "/":
            return code
        case "-" where inClass:
            return "-"
        default:
            throw Self.fail("Invalid escape")
        }
    }

    private mutating func hexDigits(count: Int) -> UInt32? {
        guard position + count <= scalars.count else { return nil }
        var value: UInt32 = 0
        for offset in 0..<count {
            guard let digit = Character(scalars[position + offset]).hexDigitValue else { return nil }
            value = value * 16 + UInt32(digit)
        }
        position += count
        return value
    }

    /// After `\u`: `{H…}`, or four digits, a pair of surrogates `\uD83D\uDE00` being one character.
    private mutating func unicodeEscape() throws -> Unicode.Scalar {
        if position < scalars.count, scalars[position] == "{" {
            var end = position + 1
            while end < scalars.count, scalars[end] != "}" { end += 1 }
            guard end < scalars.count, end > position + 1 else { throw Self.fail("Invalid Unicode escape") }
            var value: UInt32 = 0
            for scalar in scalars[(position + 1)..<end] {
                guard let digit = Character(scalar).hexDigitValue, value <= 0x10FFFF else {
                    throw Self.fail("Invalid Unicode escape")
                }
                value = value * 16 + UInt32(digit)
            }
            guard let scalar = Unicode.Scalar(value) else { throw Self.fail("Invalid Unicode escape") }
            position = end + 1
            return scalar
        }
        guard let first = hexDigits(count: 4) else { throw Self.fail("Invalid Unicode escape") }
        if (0xD800...0xDBFF).contains(first), position + 1 < scalars.count, scalars[position] == "\\",
            scalars[position + 1] == "u"
        {
            let saved = position
            position += 2
            if let second = hexDigits(count: 4), (0xDC00...0xDFFF).contains(second),
                let pair = Unicode.Scalar(0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00))
            {
                return pair
            }
            position = saved
        }
        // A lone surrogate can't be in a Swift string, so nothing could match it.
        guard let scalar = Unicode.Scalar(first) else { throw Self.fail("Invalid Unicode escape") }
        return scalar
    }

    // MARK: Character classes

    private mutating func characterClass() throws {
        position += 1
        var negated = false
        if position < scalars.count, scalars[position] == "^" {
            negated = true
            position += 1
        }
        var body = ""
        var closed = false
        while position < scalars.count {
            if scalars[position] == "]" {
                closed = true
                position += 1
                break
            }
            let low = try classAtom()
            if position + 1 < scalars.count, scalars[position] == "-", scalars[position + 1] != "]" {
                position += 1
                let high = try classAtom()
                guard case .scalar(let from) = low, case .scalar(let to) = high else {
                    throw Self.fail("Invalid character class")
                }
                guard from.value <= to.value else { throw Self.fail("Range out of order in character class") }
                body += "\(Self.hex(from))-\(Self.hex(to))"
            } else {
                body += low.fragment
            }
        }
        guard closed else { throw Self.fail("Unterminated character class") }
        if body.isEmpty {
            // [] matches nothing and [^] anything, which ICU can't write as an empty set.
            output += negated ? "[\\x{0}-\\x{10FFFF}]" : "[^\\x{0}-\\x{10FFFF}]"
        } else {
            output += "[\(negated ? "^" : "")\(body)]"
        }
        previous = .atom
    }

    private mutating func classAtom() throws -> ClassAtom {
        let scalar = scalars[position]
        guard scalar == "\\" else {
            position += 1
            return .scalar(scalar)
        }
        guard position + 1 < scalars.count else { throw Self.fail("\\ at end of pattern") }
        switch scalars[position + 1] {
        case "d": position += 2; return .set(Self.digits)
        case "D": position += 2; return .set("[^\(Self.digits)]")
        case "w": position += 2; return .set(Self.wordCharacters)
        case "W": position += 2; return .set("[^\(Self.wordCharacters)]")
        case "s": position += 2; return .set(Self.whiteSpace)
        case "S": position += 2; return .set("[^\(Self.whiteSpace)]")
        case "b": position += 2; return .scalar("\u{08}")
        case "0":
            position += 2
            if position < scalars.count, ("0"..."9").contains(scalars[position]) {
                throw Self.fail("Invalid class escape")
            }
            return .scalar("\0")
        case "1"..."9", "B", "k":
            throw Self.fail("Invalid class escape")
        case "p", "P":
            position += 1
            return .set(try propertyEscape())
        default:
            return .scalar(try characterEscape(inClass: true))
        }
    }
}
