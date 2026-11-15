// The regular expression a Plain Text search hands fd, so that it finds what the filters would
import Foundation

/// A Plain Text search is matched as the filters match names (`NameMatcher` in Contains): case aside, a plain letter
/// finding its accented forms, an accented one only itself, however a name stores its accents. fd compares bytes, so
/// it is given a regular expression in its syntax (Rust's) that finds at least all of those names; what it finds is
/// then judged by the matcher, so the two always agree.
public enum PlainTextPattern {
    /// The pattern for `text`: case ignored; each plain character (a letter, a digit, a sign) as the class of its
    /// accented and full-width forms, followed by any marks a name keeps apart from it; each accented letter as
    /// itself. Either is found however a name spells it: composed, decomposed, partly composed or with its marks in
    /// another order. Where the letters typed are those of a ligature ("fi"), the ligature is found in their place too.
    ///
    /// Only the first `patternLimit` characters of a long text go into the pattern: fd refuses a regular expression
    /// that compiles to more than 10 MB, which some 500 characters come to, and a name that holds the whole text
    /// holds its start, so nothing the matcher would keep is missed.
    public static func regex(for text: String) -> String {
        var tokens: [Token] = []
        for character in text.prefix(patternLimit) {
            for letter in FoldedText(String(character)).letters {
                // A letter typed with a mark it has no composed form with is looked for as the plain letter is: fd
                // finds the letter under any marks, and the matcher keeps the names that have the same ones.
                if letter.exact == letter.base || letter.exact == 0x3C2 || letter.exact & 0x8000_0000 != 0 {
                    tokens.append(.plain(letter.base))
                } else if let scalar = Unicode.Scalar(letter.exact) {
                    tokens.append(.literal(either(escaped(String(scalar)), scalar)))
                }
            }
        }
        let ligatures = Ligatures(tokens)
        var pattern = "(?i)"
        var at = 0
        while at < tokens.count {
            // The letters one ligature can stand for are written together: up to where no ligature reaches across.
            var end = at + 1
            while end < tokens.count, ligatures.reachesAcross[end] { end += 1 }
            if end - at <= Ligatures.spelledOutLimit {
                pattern += spelledOut(tokens, ligatures, from: at, to: end)
            } else {
                pattern += (at..<end).map { loose(tokens, ligatures, at: $0) }.joined()
            }
            at = end
        }
        return pattern
    }

    /// The characters of a text the pattern is made of.
    static let patternLimit = 64

    /// One character typed, as the pattern takes it.
    private enum Token {
        /// A plain letter, digit or sign, by its folded value: found with or without an accent.
        case plain(UInt32)
        /// Anything else, already written as a pattern: found as itself.
        case literal(String)
    }

    /// Where a ligature in a name can stand for the letters typed: "ﬁ" for "fi", and for the "f" a text ends with or
    /// the "i" it starts with, as the matcher finds a run of letters that begins or ends inside one.
    private struct Ligatures {
        /// Past this many letters that ligatures chain together ("ffffffffff"), the ways to read them are no longer
        /// written out one by one.
        static let spelledOutLimit = 8

        /// For each token, the ligatures that can stand for that one letter alone.
        var single: [String]
        /// For each token, the ligatures that can stand for it and the letters after it: how many, and which.
        var runs: [[(length: Int, ligatures: String)]]
        /// For each token, whether a ligature starting at a token before it reaches past it.
        var reachesAcross: [Bool]

        init(_ tokens: [Token]) {
            let count = tokens.count
            single = Array(repeating: "", count: count)
            runs = Array(repeating: [], count: count)
            reachesAcross = Array(repeating: false, count: count)
            for start in 0..<count {
                var found: [Int: String] = [:]
                for (scalar, letters) in PlainTextPattern.ligatures {
                    // Only the first letters typed can begin inside a ligature, and only the last can end inside one.
                    for offset in 0..<letters.count where offset == 0 || start == 0 {
                        for length in 1...(letters.count - offset)
                        where start + length <= count && (offset + length == letters.count || start + length == count) {
                            let fits = (0..<length).allSatisfy {
                                if case .plain(let value) = tokens[start + $0] {
                                    value == letters[offset + $0]
                                } else {
                                    false
                                }
                            }
                            if fits, found[length]?.unicodeScalars.contains(scalar) != true {
                                found[length, default: ""].unicodeScalars.append(scalar)
                            }
                        }
                    }
                }
                single[start] = found[1] ?? ""
                for (length, ligatures) in found.sorted(by: { $0.key < $1.key }) where length > 1 {
                    runs[start].append((length, ligatures))
                    for inside in (start + 1)..<(start + length) { reachesAcross[inside] = true }
                }
            }
        }
    }

    /// The Latin ligatures and the letters each stands for, as the matcher folds them.
    private static let ligatures: [(Unicode.Scalar, [UInt32])] = FoldedText.ligatures.sorted { $0.key < $1.key }
        .compactMap { entry in Unicode.Scalar(entry.key).map { ($0, entry.value) } }

    /// What can stand for one token inside a class: the character, its accented and full-width forms, and the
    /// ligatures that can stand for it alone; nil for a token that is a pattern already.
    private static func classBody(_ tokens: [Token], _ ligatures: Ligatures, at index: Int) -> String? {
        guard case .plain(let base) = tokens[index] else { return nil }
        return escapedInClass(base) + (accentedForms[base] ?? "") + ligatures.single[index]
    }

    /// One token on its own: a plain character as its class and any marks after it.
    private static func element(_ tokens: [Token], _ ligatures: Ligatures, at index: Int) -> String {
        switch tokens[index] {
        case .literal(let pattern): return pattern
        case .plain(let base):
            let more = (accentedForms[base] ?? "") + ligatures.single[index]
            let one = more.isEmpty ? escapedInClass(base) : "[" + escapedInClass(base) + more + "]"
            return (Unicode.Scalar(base).map { either(one, $0) } ?? one) + marks
        }
    }

    /// `pattern`, which finds the composed character `scalar`, or one of the other ways a name can spell it.
    private static func either(_ pattern: String, _ scalar: Unicode.Scalar) -> String {
        let others = otherSpellings(of: scalar)
        return others.isEmpty ? pattern : "(?:" + ([pattern] + others).joined(separator: "|") + ")"
    }

    /// The other ways a name can spell `scalar`, a composed character, as patterns: decomposed, partly composed, or
    /// with its marks in another order, all of which the matcher composes back into it ("か" and its mark for "が", "ậ"
    /// as "ạ" and a circumflex). A Hangul syllable is also its jamo.
    private static func otherSpellings(of scalar: Unicode.Scalar) -> [String] {
        let decomposed = String(scalar).decomposedStringWithCanonicalMapping
        let parts = Array(decomposed.unicodeScalars)
        guard parts.count > 1 else { return [] }
        guard parts.dropFirst().allSatisfy(isMark) else { return [escaped(decomposed)] }
        let marks = parts.dropFirst().map(\.value)
        var ways: [String] = []
        // The letter alone, or composed with some of the marks; the rest after it, in any order.
        let leads = [(parts[0], [UInt32]())] + (composedForms[parts[0].value] ?? [])
        for (lead, own) in leads where lead != scalar {
            var rest = marks
            let held = own.allSatisfy { mark in
                guard let at = rest.firstIndex(of: mark) else { return false }
                rest.remove(at: at)
                return true
            }
            if held { ways.append(escaped(String(lead)) + anyOrder(rest)) }
        }
        return ways
    }

    /// `marks` after a letter, in any order, each also as a character that stands for it (U+0341 for U+0301): as many
    /// as there are, or one fewer where U+0344 stands for two.
    private static func anyOrder(_ marks: [UInt32]) -> String {
        guard !marks.isEmpty else { return "" }
        var members = Set(marks)
        for (standIn, stoodFor) in markStandIns where stoodFor.allSatisfy(members.contains) {
            members.insert(standIn)
        }
        let body = members.sorted().map(escapedInClass).joined()
        let one = members.count == 1 ? body : "[" + body + "]"
        let fewest = members.contains(0x344) ? marks.count - 1 : marks.count
        if fewest == marks.count {
            return marks.count == 1 ? one : one + "{\(marks.count)}"
        }
        return one + "{\(fewest),\(marks.count)}"
    }

    /// Marks written as one character that the matcher reads as others: the tone marks as the accents, the Greek
    /// dialytika tonos as a diaeresis and an acute.
    private static let markStandIns: [(UInt32, [UInt32])] = [
        (0x340, [0x300]), (0x341, [0x301]), (0x343, [0x313]), (0x344, [0x308, 0x301]),
    ]

    /// For each letter, the composed letters made of it and marks, with their marks: "ạ" with U+0323 for "a". Latin,
    /// Greek and Cyrillic, lowercase alone, as the pattern ignores case.
    private static let composedForms: [UInt32: [(Unicode.Scalar, [UInt32])]] = {
        var forms: [UInt32: [(Unicode.Scalar, [UInt32])]] = [:]
        for value in [0xC0...0x24F, 0x370...0x52F, 0x1E00...0x1FFF].joined() {
            guard let scalar = Unicode.Scalar(value), !scalar.properties.changesWhenCaseFolded else { continue }
            let parts = Array(String(scalar).decomposedStringWithCanonicalMapping.unicodeScalars)
            guard parts.count > 1, parts.dropFirst().allSatisfy(isMark) else { continue }
            forms[parts[0].value, default: []].append((scalar, parts.dropFirst().map(\.value)))
        }
        return forms
    }()

    private static func isMark(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark: true
        default: false
        }
    }

    /// Any marks a name keeps apart from the character before them.
    private static let marks = "\\p{M}*"

    /// The tokens from `start` up to `end`, every way a name can spell them: letter by letter, or with a ligature in
    /// place of the letters it stands for.
    private static func spelledOut(_ tokens: [Token], _ ligatures: Ligatures, from start: Int, to end: Int) -> String {
        guard start < end else { return "" }
        var ways = [element(tokens, ligatures, at: start) + spelledOut(tokens, ligatures, from: start + 1, to: end)]
        for run in ligatures.runs[start] {
            ways.append(
                "[" + run.ligatures + "]" + marks
                    + spelledOut(tokens, ligatures, from: start + run.length, to: end))
        }
        return ways.count == 1 ? ways[0] : "(?:" + ways.joined(separator: "|") + ")"
    }

    /// One token of a long chain of ligature letters: itself or a ligature that begins with it, and nothing at all
    /// where a ligature before it may have taken it. This finds more names than the matcher keeps, never fewer.
    private static func loose(_ tokens: [Token], _ ligatures: Ligatures, at index: Int) -> String {
        guard let body = classBody(tokens, ligatures, at: index), case .plain(let base) = tokens[index],
            let scalar = Unicode.Scalar(base)
        else {
            return element(tokens, ligatures, at: index)
        }
        let longer = ligatures.runs[index].map(\.ligatures).joined()
        let one = either("[" + body + longer + "]", scalar) + marks
        return ligatures.reachesAcross[index] ? "(?:" + one + ")?" : one
    }

    /// For each plain character, the composed letters (either case) that fold to it with an accent, and its full-width
    /// form: "é", "É", "ê" and the rest for "e", as `FoldedText` takes accents off Latin, Greek and Cyrillic letters
    /// alone. Also the characters a name may store that the matcher reads as another: a compatibility ideograph as
    /// its ideograph, the Kelvin sign as "k", a Hebrew or Indic letter stored as one character with its mark.
    private static let accentedForms: [UInt32: String] = {
        var forms: [UInt32: String] = [:]
        let ranges: [ClosedRange<UInt32>] = [
            0xC0...0x24F, 0x370...0x52F, 0x900...0xFFF, 0x1E00...0x1FFF, 0x2126...0x212B, 0xF900...0xFAFF,
            0xFB1D...0xFB4F, FoldedText.fullWidth, 0x2F800...0x2FA1F,
        ]
        for value in ranges.joined() {
            guard let scalar = Unicode.Scalar(value) else { continue }
            let letters = FoldedText(String(scalar)).letters
            guard letters.count == 1, let letter = letters.first, letter.exact != letter.base || value != letter.base
            else { continue }
            forms[letter.base, default: ""].unicodeScalars.append(scalar)
        }
        return forms
    }()

    /// The characters Rust's regular expressions take as syntax.
    private static let syntax = Set("\\.+*?()|[]{}^$#&-~".unicodeScalars)

    private static func escaped(_ text: String) -> String {
        var result = ""
        for scalar in text.unicodeScalars {
            if syntax.contains(scalar) { result += "\\" }
            result.unicodeScalars.append(scalar)
        }
        return result
    }

    private static func escapedInClass(_ value: UInt32) -> String {
        guard let scalar = Unicode.Scalar(value) else { return "" }
        return escaped(String(scalar))
    }
}
