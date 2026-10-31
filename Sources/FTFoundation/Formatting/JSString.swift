// Port of the string semantics the original's formatting and ranking code gets from JavaScript.
import Foundation

/// JavaScript compares, searches and measures strings in UTF-16 code units, with no Unicode
/// equivalence; Swift's `String` does it by characters and takes NFC and NFD as equal. The original's
/// results (name ranges, which names contain a text) depend on the JavaScript way, so the ported code
/// goes through these helpers.
enum JSString {
    /// Whether JavaScript's `trim`, `\s` and `split(/\s+/)` count the code unit as white space.
    static func isWhitespace(_ unit: UInt16) -> Bool {
        switch unit {
        case 0x09...0x0D, 0x20, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF:
            return true
        default:
            return false
        }
    }

    static func string(_ units: some Collection<UInt16>) -> String {
        String(decoding: units, as: UTF16.self)
    }

    /// `text.trim()`.
    static func trimmed(_ text: String) -> String {
        trimmedUnits(Array(text.utf16), start: true, end: true)
    }

    /// `text.trimEnd()`.
    static func trimmedEnd(_ text: String) -> String {
        trimmedUnits(Array(text.utf16), start: false, end: true)
    }

    /// `text.trimStart()`.
    static func trimmedStart(_ text: String) -> String {
        trimmedUnits(Array(text.utf16), start: true, end: false)
    }

    private static func trimmedUnits(_ units: [UInt16], start: Bool, end: Bool) -> String {
        var lower = 0
        var upper = units.count
        if start {
            while lower < upper, isWhitespace(units[lower]) { lower += 1 }
        }
        if end {
            while upper > lower, isWhitespace(units[upper - 1]) { upper -= 1 }
        }
        return string(units[lower..<upper])
    }

    /// `text.split(/\s+/u).filter(Boolean)`: the runs of text between white space.
    static func words(_ text: String) -> [String] {
        var words: [String] = []
        var current: [UInt16] = []
        for unit in text.utf16 {
            if isWhitespace(unit) {
                if !current.isEmpty {
                    words.append(string(current))
                    current.removeAll()
                }
            } else {
                current.append(unit)
            }
        }
        if !current.isEmpty { words.append(string(current)) }
        return words
    }

    /// `text.split("/").filter((part) => part.length > 0)` for any separator unit: unlike Swift's
    /// `split`, a combining mark after the separator does not glue to it.
    static func components(_ text: String, separator: UInt16) -> [String] {
        text.utf16.split(separator: separator, omittingEmptySubsequences: true).map { string($0) }
    }

    /// `left === right`.
    static func equals(_ left: String, _ right: String) -> Bool {
        left.utf8.elementsEqual(right.utf8)
    }

    /// `haystack.indexOf(needle, from)` in UTF-16 units; nil for -1.
    static func index(of needle: [UInt16], in haystack: [UInt16], from start: Int = 0) -> Int? {
        let count = needle.count
        guard start >= 0, count <= haystack.count else { return nil }
        if count == 0 { return min(start, haystack.count) }
        guard start <= haystack.count - count else { return nil }
        var position = start
        while position <= haystack.count - count {
            if haystack[position] == needle[0], haystack[position..<position + count].elementsEqual(needle) {
                return position
            }
            position += 1
        }
        return nil
    }

    /// `haystack.includes(needle)`.
    static func includes(_ haystack: String, _ needle: String) -> Bool {
        index(of: Array(needle.utf16), in: Array(haystack.utf16)) != nil
    }

    /// `text.startsWith(prefix)`.
    static func hasPrefix(_ text: String, _ prefix: String) -> Bool {
        text.utf16.starts(with: prefix.utf16)
    }

    /// `text.endsWith(suffix)`.
    static func hasSuffix(_ text: String, _ suffix: String) -> Bool {
        let units = Array(text.utf16)
        let tail = Array(suffix.utf16)
        return tail.count <= units.count && units[(units.count - tail.count)...].elementsEqual(tail)
    }

    /// `text.lastIndexOf(unit)` in UTF-16 units; nil for -1.
    static func lastIndex(of unit: UInt16, in units: [UInt16]) -> Int? {
        units.lastIndex(of: unit)
    }

    /// `text.toLowerCase()` / `toLocaleLowerCase()` for a locale without special rules: full case
    /// mappings, and the Greek capital sigma lowered to the final form at the end of a word.
    static func lowercased(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        let scalars = Array(text.unicodeScalars)
        for (index, scalar) in scalars.enumerated() {
            if scalar == "\u{03A3}" {
                result.append(isFinalSigma(scalars, at: index) ? "\u{03C2}" : "\u{03C3}")
            } else {
                result.append(contentsOf: scalar.properties.lowercaseMapping.unicodeScalars)
            }
        }
        return String(result)
    }

    // Unicode's Final_Sigma: after a cased letter (case-ignorable marks skipped), and not before one.
    private static func isFinalSigma(_ scalars: [Unicode.Scalar], at index: Int) -> Bool {
        var before = index - 1
        while before >= 0, scalars[before].properties.isCaseIgnorable { before -= 1 }
        guard before >= 0, scalars[before].properties.isCased else { return false }
        var after = index + 1
        while after < scalars.count, scalars[after].properties.isCaseIgnorable { after += 1 }
        return after >= scalars.count || !scalars[after].properties.isCased
    }

    /// `value.toFixed(digits)` for a finite value of at least 1 (the exact decimal expansion is
    /// printed and rounded half up, where C's `printf` rounds a tie to even: 2.25 gives "2.3").
    static func toFixed(_ value: Double, _ digits: Int) -> String {
        let exact = String(format: "%.60f", value)
        let parts = exact.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let integerDigits = Array(parts[0].utf8)
        let fractionDigits = parts.count > 1 ? Array(parts[1].utf8) : []
        var kept = integerDigits + fractionDigits.prefix(digits)
        if fractionDigits.count > digits, fractionDigits[digits] >= UInt8(ascii: "5") {
            var position = kept.count - 1
            while position >= 0 {
                if kept[position] == UInt8(ascii: "9") {
                    kept[position] = UInt8(ascii: "0")
                    position -= 1
                } else {
                    kept[position] += 1
                    break
                }
            }
            if position < 0 { kept.insert(UInt8(ascii: "1"), at: 0) }
        }
        let integerCount = kept.count - digits
        let integerPart = String(decoding: kept[..<integerCount], as: UTF8.self)
        return digits == 0 ? integerPart : "\(integerPart).\(String(decoding: kept[integerCount...], as: UTF8.self))"
    }

    /// `JSON.stringify` of a string.
    static func jsonQuoted(_ text: String) -> String {
        var out = "\""
        let units = Array(text.utf16)
        var index = 0
        while index < units.count {
            let unit = units[index]
            index += 1
            switch unit {
            case 0x22: out += "\\\""
            case 0x5C: out += "\\\\"
            case 0x08: out += "\\b"
            case 0x0C: out += "\\f"
            case 0x0A: out += "\\n"
            case 0x0D: out += "\\r"
            case 0x09: out += "\\t"
            case 0..<0x20: out += String(format: "\\u%04x", unit)
            case 0xD800...0xDBFF where index < units.count && (0xDC00...0xDFFF).contains(units[index]):
                out += String(decoding: [unit, units[index]], as: UTF16.self)
                index += 1
            case 0xD800...0xDFFF: out += String(format: "\\u%04x", unit)
            default: out += String(decoding: [unit], as: UTF16.self)
            }
        }
        return out + "\""
    }
}

/// A string used as a key the way JavaScript's `Map` and `Set` use one: by its exact code units, so
/// the NFC and NFD spellings of a name are two keys.
struct ExactKey: Hashable, Sendable {
    let bytes: [UInt8]

    init(_ text: String) {
        bytes = Array(text.utf8)
    }
}

extension Date {
    /// Milliseconds since the epoch, whole, as `Date.now()` and `getTime()` count them.
    public var epochMilliseconds: Double {
        (timeIntervalSince1970 * 1000).rounded()
    }

    public init(epochMilliseconds: Double) {
        self.init(timeIntervalSince1970: epochMilliseconds / 1000)
    }
}
