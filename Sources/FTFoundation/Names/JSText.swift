// Port of the JavaScript string behavior packages/contracts/src/itemName.ts and copyPasteNames.ts rely on
import Foundation

/// JavaScript's string rules where Swift's differ: `trim`, `trimEnd`, `toLowerCase`, UTF-16 length.
enum JSText {
    /// `WhiteSpace` and `LineTerminator` of ECMAScript, which `String.prototype.trim` removes.
    static func isTrimmed(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0xA0, 0x2028, 0x2029, 0xFEFF:
            return true
        default:
            return scalar.value > 0x7F && scalar.properties.generalCategory == .spaceSeparator
        }
    }

    static func trimmed(_ text: String) -> String {
        trimmingEnd(trimmingStart(text))
    }

    static func trimmingStart(_ text: String) -> String {
        var scalars = Substring(text).unicodeScalars
        while let first = scalars.first, isTrimmed(first) {
            scalars.removeFirst()
        }
        return String(scalars)
    }

    static func trimmingEnd(_ text: String) -> String {
        var scalars = Substring(text).unicodeScalars
        while let last = scalars.last, isTrimmed(last) {
            scalars.removeLast()
        }
        return String(scalars)
    }

    /// `toLowerCase()`: Unicode lowercasing with the final-sigma rule, which Swift's `lowercased()` leaves out.
    /// Foundation's version cuts a string at a NUL, so each part between NULs is lowercased on its own
    /// (a NUL is neither cased nor ignorable, so the sigma rule can't reach across it).
    static func lowercased(_ text: String) -> String {
        guard text.unicodeScalars.contains("\0") else { return text.lowercased(with: nil) }
        let parts = text.unicodeScalars.split(separator: "\0", omittingEmptySubsequences: false)
        return parts.map { String(String.UnicodeScalarView($0)).lowercased(with: nil) }.joined(separator: "\0")
    }

    static func utf8Length(_ text: String) -> Int {
        text.utf8.count
    }

    static func utf16Length(_ text: String) -> Int {
        text.utf16.count
    }

    /// Numbers as `String(number)` writes the whole ones: digits up to 1e21, then "1e+21".
    static func integerText(_ value: Double) -> String {
        if abs(value) < 9_007_199_254_740_992 {
            return String(Int64(value))
        }
        var shortest = "\(value)"
        var exponent = 0
        if let marker = shortest.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            exponent = Int(shortest[shortest.index(after: marker)...].replacingOccurrences(of: "+", with: "")) ?? 0
            shortest = String(shortest[..<marker])
        }
        var parts = shortest.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        if parts.count == 1 { parts.append("") }
        var digits = parts[0] + parts[1]
        let pointAt = parts[0].count + exponent
        let sign = digits.hasPrefix("-") ? "-" : ""
        if !sign.isEmpty {
            digits.removeFirst()
        }
        let intLength = pointAt - (sign.isEmpty ? 0 : 1)
        if intLength > 21 {
            let mantissa = digits.count > 1 ? "\(digits.prefix(1)).\(digits.dropFirst())" : digits
            return "\(sign)\(mantissa)e+\(intLength - 1)"
        }
        if digits.count < intLength {
            digits += String(repeating: "0", count: intLength - digits.count)
        }
        return sign + String(digits.prefix(intLength))
    }
}
