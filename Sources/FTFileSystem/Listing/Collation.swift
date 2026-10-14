// Port of the string comparisons of packages/core/src/fs/explorerService.ts:
//   compareEntriesByName: a.localeCompare(b, undefined, { numeric: true, sensitivity: "base" })
//   the Kind column: a.localeCompare(b)
import Foundation

/// A name prepared for many comparisons: plain ASCII names (nearly all of them) are compared on their bytes
/// with the root collation's order, which is what JavaScript's localeCompare uses; others go to Foundation.
struct CollationKey: Sendable {
    let text: String
    /// The UTF-8 bytes of an ASCII text; nil for any other.
    let ascii: [UInt8]?

    init(_ text: String) {
        self.text = text
        var bytes = Array(text.utf8)
        if bytes.allSatisfy({ $0 < 0x80 }) {
            ascii = bytes
        } else {
            bytes.removeAll()
            ascii = nil
        }
    }
}

enum Collation {
    /// `localeCompare(b, undefined, { numeric: true, sensitivity: "base" })`: digits compare as numbers,
    /// and case and accents don't count. Negative, zero or positive.
    static func compareNumericBase(_ left: CollationKey, _ right: CollationKey) -> Int {
        if let a = left.ascii, let b = right.ascii {
            return a.withUnsafeBufferPointer { a in
                b.withUnsafeBufferPointer { b in compareASCIINumeric(a, b) }
            }
        }
        return foldedCompare(left.text, right.text, numeric: true, strength: .base)
    }

    /// `localeCompare(b)`: case matters last (a lowercase letter comes before its capital).
    static func compareVariant(_ left: CollationKey, _ right: CollationKey) -> Int {
        if let a = left.ascii, let b = right.ascii {
            return a.withUnsafeBufferPointer { a in
                b.withUnsafeBufferPointer { b in compareASCIIVariant(a, b) }
            }
        }
        return foldedCompare(left.text, right.text, numeric: false, strength: .variant)
    }

    // MARK: ASCII

    /// The primary weight of each ASCII character in the root collation (ICU), 0 for those it ignores
    /// (control characters). Letters share a weight with their capitals. Recorded from the reference by
    /// tools/parity/golden/listing-collation.ts.
    private static let weights: [UInt8] = {
        var table = [UInt8](repeating: 0, count: 128)
        let order: [UInt8] = Array("\t\n\u{0B}\u{0C}\r _-,;:!?.'\"()[]{}@*/\\&#%`^+<=>|~$".utf8)
        for (index, byte) in order.enumerated() {
            table[Int(byte)] = UInt8(index + 1)
        }
        let digitsStart = UInt8(order.count + 1)
        for digit in 0..<10 {
            table[48 + digit] = digitsStart + UInt8(digit)
        }
        let lettersStart = digitsStart + 10
        for letter in 0..<26 {
            table[65 + letter] = lettersStart + UInt8(letter)
            table[97 + letter] = lettersStart + UInt8(letter)
        }
        return table
    }()

    private static func isDigit(_ byte: UInt8) -> Bool { byte >= 48 && byte <= 57 }

    private static func compareASCIINumeric(_ a: UnsafeBufferPointer<UInt8>, _ b: UnsafeBufferPointer<UInt8>) -> Int {
        var i = 0
        var j = 0
        while true {
            while i < a.count && weights[Int(a[i])] == 0 { i += 1 }
            while j < b.count && weights[Int(b[j])] == 0 { j += 1 }
            if i == a.count || j == b.count {
                return (i == a.count ? 0 : 1) - (j == b.count ? 0 : 1)
            }
            let x = a[i]
            let y = b[j]
            if isDigit(x) && isDigit(y) {
                // Numbers compare by value: without leading zeros, the longer is the greater.
                var startA = i
                while startA < a.count && a[startA] == 48 { startA += 1 }
                var startB = j
                while startB < b.count && b[startB] == 48 { startB += 1 }
                var endA = startA
                while endA < a.count && isDigit(a[endA]) { endA += 1 }
                var endB = startB
                while endB < b.count && isDigit(b[endB]) { endB += 1 }
                let lengthA = endA - startA
                let lengthB = endB - startB
                if lengthA != lengthB { return lengthA < lengthB ? -1 : 1 }
                var offset = 0
                while offset < lengthA {
                    let p = a[startA + offset]
                    let q = b[startB + offset]
                    if p != q { return p < q ? -1 : 1 }
                    offset += 1
                }
                i = endA
                j = endB
                continue
            }
            let p = weights[Int(x)]
            let q = weights[Int(y)]
            if p != q { return p < q ? -1 : 1 }
            i += 1
            j += 1
        }
    }

    private static func compareASCIIVariant(_ a: UnsafeBufferPointer<UInt8>, _ b: UnsafeBufferPointer<UInt8>) -> Int {
        var i = 0
        var j = 0
        var caseDifference = 0
        while true {
            while i < a.count && weights[Int(a[i])] == 0 { i += 1 }
            while j < b.count && weights[Int(b[j])] == 0 { j += 1 }
            if i == a.count || j == b.count {
                let ended = (i == a.count ? 0 : 1) - (j == b.count ? 0 : 1)
                return ended != 0 ? ended : caseDifference
            }
            let p = weights[Int(a[i])]
            let q = weights[Int(b[j])]
            if p != q { return p < q ? -1 : 1 }
            if caseDifference == 0 {
                let lowerA = a[i] >= 97
                let lowerB = b[j] >= 97
                let isLetter = (a[i] | 0x20) >= 97 && (a[i] | 0x20) <= 122
                if isLetter && lowerA != lowerB { caseDifference = lowerA ? -1 : 1 }
            }
            i += 1
            j += 1
        }
    }

    // MARK: Anything else

    private enum Strength { case base, variant }

    private static let locale = Locale(identifier: "en_US")

    private static func foldedCompare(_ a: String, _ b: String, numeric: Bool, strength: Strength) -> Int {
        var options: String.CompareOptions = []
        if numeric { options.insert(.numeric) }
        if strength == .base { options.formUnion([.caseInsensitive, .diacriticInsensitive]) }
        switch a.compare(b, options: options, range: nil, locale: locale) {
        case .orderedAscending: return -1
        case .orderedDescending: return 1
        case .orderedSame: return 0
        }
    }
}

/// A sort that keeps the order of items that compare equal, as JavaScript's does.
func stableSorted<T>(_ items: [T], by compare: (T, T) -> Int) -> [T] {
    var order = Array(items.indices)
    order.sort { left, right in
        let result = compare(items[left], items[right])
        return result != 0 ? result < 0 : left < right
    }
    return order.map { items[$0] }
}
