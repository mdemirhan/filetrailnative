// The regular expression a Plain Text search hands fd, so that it finds what the filters would
import Foundation

/// A Plain Text search is matched as the filters match names (`NameMatcher` in Contains): case aside, a plain letter
/// finding its accented forms, an accented one only itself, however a name stores its accents. fd compares bytes, so
/// it is given a regular expression in its syntax (Rust's) that finds at least all of those names; what it finds is
/// then judged by the matcher, so the two always agree.
public enum PlainTextPattern {
    /// The pattern for `text`: case ignored; each plain letter as the class of its accented forms, each followed by any
    /// marks a name keeps apart from its letter; each accented letter as itself, composed or decomposed; every other
    /// character as itself.
    public static func regex(for text: String) -> String {
        var pattern = "(?i)"
        for character in text {
            let letters = FoldedText(String(character)).letters
            if letters.count == 1, let letter = letters.first, letter.exact == letter.base || letter.exact == 0x3C2,
                let forms = accentedForms[letter.base]
            {
                pattern += "[" + escapedInClass(letter.base) + forms + "]\\p{M}*"
                continue
            }
            let composed = String(character).precomposedStringWithCanonicalMapping
            let decomposed = String(character).decomposedStringWithCanonicalMapping
            // Compared scalar by scalar: Swift's `==` takes the two spellings as equal.
            let same = composed.unicodeScalars.elementsEqual(decomposed.unicodeScalars)
            pattern += same ? escaped(composed) : "(?:\(escaped(composed))|\(escaped(decomposed)))"
        }
        return pattern
    }

    /// For each plain letter, the composed letters (either case) that fold to it with an accent: "é", "É", "ê" and the
    /// rest for "e". Latin, Greek and Cyrillic, as `FoldedText` takes accents off those alone.
    private static let accentedForms: [UInt32: String] = {
        var forms: [UInt32: String] = [:]
        let ranges: [ClosedRange<UInt32>] = [0xC0...0x24F, 0x370...0x52F, 0x1E00...0x1FFF]
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
