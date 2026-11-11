// Sort keys for the names of a whole listing, compared faster than name by name
import Foundation

/// The names of a listing prepared for sorting. Each name becomes a key whose bytes compare, with `memcmp`,
/// as `localeCompare(b, undefined, { numeric: true, sensitivity: "base" })` orders the names: ICU's own sort key.
/// Where the system's ICU can't be used, names are compared as text by Foundation instead, numbers by value,
/// case and accents ignored: the same order but for the rare characters the two weigh differently, and slower.
struct NameKeys {
    private(set) var bytes: [UInt8] = []
    private(set) var starts: [Int32] = []
    private(set) var hasKey: [Bool] = []
    private(set) var names: [String] = []
    private let icu: ICUCollator?

    var count: Int { names.count }

    /// `icu`: the system's collator, nil to compare as text (tests).
    init(capacity: Int = 0, icu: ICUCollator? = ICUCollator.shared) {
        self.icu = icu
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
        } else {
            hasKey.append(false)
        }
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
