// Fast form of compareEntriesByName (packages/core/src/fs/explorerService.ts) for a whole listing
import Foundation

/// The names of a listing prepared for sorting. Each name becomes a key whose bytes compare, with `memcmp`,
/// as `localeCompare(b, undefined, { numeric: true, sensitivity: "base" })` orders the names. With ICU
/// (what V8 compares with) the key is ICU's own sort key. Without it, a name of ASCII and the characters
/// in `CollationTable` becomes a key of its letters' primary weights, a run of digits as a marker, the
/// number of digits without leading zeros and the digits, and the characters the collation ignores left
/// out; any other name (Cyrillic, CJK, emoji…) is compared as text by `Collation`.
struct NameKeys {
    private(set) var bytes: [UInt8] = []
    private(set) var starts: [Int32] = []
    private(set) var hasKey: [Bool] = []
    private(set) var names: [String] = []
    private let icu: ICUCollator?

    var count: Int { names.count }

    /// How names are turned into keys: by the system's ICU (what V8's localeCompare uses), where it is
    /// there, or by `CollationTable`.
    enum Mode {
        case automatic
        case table
    }

    init(capacity: Int = 0, mode: Mode = .automatic) {
        icu = mode == .automatic ? ICUCollator.shared : nil
        bytes.reserveCapacity(capacity * 24)
        starts.reserveCapacity(capacity + 1)
        hasKey.reserveCapacity(capacity)
        names.reserveCapacity(capacity)
    }

    mutating func append(_ name: String) {
        names.append(name)
        starts.append(Int32(bytes.count))
        if let icu {
            icu.appendSortKey(of: name, to: &bytes)
            hasKey.append(true)
            return
        }
        var name = name
        let ascii = name.withUTF8 { Self.appendKey($0, to: &bytes) }
        hasKey.append(ascii)
    }

    /// The marker that starts a number in a key; no character has it.
    private static let numberMarker = Collation.weight(of: UInt8(ascii: "0"))

    private static func appendKey(_ name: UnsafeBufferPointer<UInt8>, to key: inout [UInt8]) -> Bool {
        let start = key.count
        var index = 0
        while index < name.count {
            let byte = name[index]
            if byte < 0x80 {
                index = appendASCII(byte, in: name, at: index, to: &key)
                continue
            }
            // A character that is not ASCII: some compare as an ASCII letter or two (é is e), some are
            // ignored (a combining accent); for any other the name is compared as text.
            guard let (scalar, length) = decode(name, at: index) else {
                key.removeSubrange(start...)
                return false
            }
            index += length
            if CollationTable.ignorable.contains(scalar) { continue }
            guard let replacement = CollationTable.replacements[scalar] else {
                key.removeSubrange(start...)
                return false
            }
            replacement.withUTF8Buffer { letters in
                for letter in letters {
                    key.append(Collation.weight(of: letter))
                }
            }
        }
        return true
    }

    /// Adds the key of the ASCII character (or run of digits) at `index`; returns where the next begins.
    private static func appendASCII(
        _ byte: UInt8, in name: UnsafeBufferPointer<UInt8>, at index: Int, to key: inout [UInt8]
    ) -> Int {
        let weight = Collation.weight(of: byte)
        if weight == 0 { return index + 1 }
        guard byte >= 48 && byte <= 57 else {
            key.append(weight)
            return index + 1
        }
        var end = index
        while end < name.count && name[end] >= 48 && name[end] <= 57 { end += 1 }
        var first = index
        while first < end && name[first] == 48 { first += 1 }
        key.append(numberMarker)
        key.append(UInt8(truncatingIfNeeded: end - first))
        while first < end {
            key.append(Collation.weight(of: name[first]))
            first += 1
        }
        return end
    }

    /// The scalar starting at `index` and the bytes it takes; nil when the bytes are not UTF-8.
    private static func decode(_ name: UnsafeBufferPointer<UInt8>, at index: Int) -> (UInt32, Int)? {
        let lead = name[index]
        let length = lead >= 0xF0 ? 4 : lead >= 0xE0 ? 3 : lead >= 0xC0 ? 2 : 0
        guard length > 0, index + length <= name.count else { return nil }
        var scalar = UInt32(lead) & (length == 2 ? 0x1F : length == 3 ? 0x0F : 0x07)
        for offset in 1..<length {
            let next = name[index + offset]
            guard next & 0xC0 == 0x80 else { return nil }
            scalar = scalar << 6 | UInt32(next & 0x3F)
        }
        return (scalar, length)
    }

    /// Compares names for sorting; the closure given to `body` takes the positions of two names and answers
    /// negative, zero or positive.
    func withComparator<R>(_ body: (_ compare: (Int, Int) -> Int) -> R) -> R {
        let total = Int32(bytes.count)
        return bytes.withUnsafeBufferPointer { bytes in
            starts.withUnsafeBufferPointer { starts in
                hasKey.withUnsafeBufferPointer { hasKey in
                    names.withUnsafeBufferPointer { names in
                        body { left, right in
                            if hasKey[left] && hasKey[right] {
                                let leftStart = Int(starts[left])
                                let rightStart = Int(starts[right])
                                let leftEnd = Int(left + 1 < starts.count ? starts[left + 1] : total)
                                let rightEnd = Int(right + 1 < starts.count ? starts[right + 1] : total)
                                let leftLength = leftEnd - leftStart
                                let rightLength = rightEnd - rightStart
                                let common = min(leftLength, rightLength)
                                if common > 0, let base = bytes.baseAddress {
                                    let result = memcmp(base + leftStart, base + rightStart, common)
                                    if result != 0 { return result < 0 ? -1 : 1 }
                                }
                                return leftLength == rightLength ? 0 : (leftLength < rightLength ? -1 : 1)
                            }
                            return Collation.compareNumericBase(names[left], names[right])
                        }
                    }
                }
            }
        }
    }

    /// The positions of the names in order, equal names in the order given.
    func sortedPositions() -> [Int] {
        withComparator { compare in
            var order = Array(0..<count)
            order.sort { left, right in
                let result = compare(left, right)
                return result != 0 ? result < 0 : left < right
            }
            return order
        }
    }
}
