// The regular expression a Plain Text search hands fd, so that it finds what the filters would
import Foundation

/// A Plain Text search is matched as the filters match names (`NameMatcher` in Contains): case aside, a plain letter
/// finding its accented forms, an accented one only itself, however a name stores its accents. fd compares bytes, so
/// it is given a regular expression in its syntax (Rust's) that finds at least all of those names; what it finds is
/// then judged by the matcher, so the two always agree.
public enum PlainTextPattern {
    /// The pattern for `text`: case ignored; each plain character (a letter, a digit, a sign) as the class of its
    /// accented and full-width forms, followed by any marks a name keeps apart from it; each accented letter as
    /// itself, composed or decomposed. Where the letters typed are those of a ligature ("fi"), the ligature is found
    /// in their place too.
    public static func regex(for text: String) -> String {
        var tokens: [Token] = []
        for character in text {
            let letters = FoldedText(String(character)).letters
            // A letter typed with a mark it has no composed form with finds that letter under any such mark, so it is
            // looked for as the plain letter is, and the matcher tells the names apart.
            let loose = letters.allSatisfy { $0.exact == $0.base || $0.exact == 0x3C2 || $0.exact & 0x8000_0000 != 0 }
            if !letters.isEmpty, loose {
                tokens.append(contentsOf: letters.map { .plain($0.base) })
                continue
            }
            let composed = String(character).precomposedStringWithCanonicalMapping
            let decomposed = String(character).decomposedStringWithCanonicalMapping
            // Compared scalar by scalar: Swift's `==` takes the two spellings as equal.
            let same = composed.unicodeScalars.elementsEqual(decomposed.unicodeScalars)
            tokens.append(.literal(same ? escaped(composed) : "(?:\(escaped(composed))|\(escaped(decomposed)))"))
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
            return (more.isEmpty ? escapedInClass(base) : "[" + escapedInClass(base) + more + "]") + marks
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
        guard let body = classBody(tokens, ligatures, at: index) else {
            return element(tokens, ligatures, at: index)
        }
        let longer = ligatures.runs[index].map(\.ligatures).joined()
        let one = "[" + body + longer + "]" + marks
        return ligatures.reachesAcross[index] ? "(?:" + one + ")?" : one
    }

    /// For each plain character, the composed letters (either case) that fold to it with an accent, and its full-width
    /// form: "é", "É", "ê" and the rest for "e". Latin, Greek and Cyrillic, as `FoldedText` takes accents off those
    /// alone.
    private static let accentedForms: [UInt32: String] = {
        var forms: [UInt32: String] = [:]
        let ranges: [ClosedRange<UInt32>] = [0xC0...0x24F, 0x370...0x52F, 0x1E00...0x1FFF, FoldedText.fullWidth]
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
