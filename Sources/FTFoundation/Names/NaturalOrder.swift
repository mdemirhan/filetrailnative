import Foundation

/// The one order names are put in, everywhere: the alphabet of the user's language, as Finder sorts (å, ä and ö
/// after z in Swedish, dotless ı before i in Turkish), with numbers by value (file2 before file10).
///
/// Where the system's collator can't be used, names are compared as text by Foundation in the same locale: the same
/// order but for the rare characters the two weigh differently, and slower.
public struct NameOrder: Sendable {
    /// The order of the user's language, read once at launch.
    public static let current = NameOrder(localeIdentifier: Locale.current.identifier)

    private let names: ICUCollator?
    private let words: ICUCollator?
    private let locale: Locale

    /// `localeIdentifier`: "sv_SE" and the like, "" for ICU's root order. `systemCollator`: false to compare as text
    /// by Foundation (tests).
    public init(localeIdentifier: String, systemCollator: Bool = true) {
        locale = Locale(identifier: localeIdentifier)
        names =
            systemCollator ? ICUCollator(localeIdentifier: localeIdentifier, strength: .primary, numeric: true) : nil
        words =
            systemCollator ? ICUCollator(localeIdentifier: localeIdentifier, strength: .tertiary, numeric: false) : nil
    }

    /// Names in order, numbers by value, case and accents set aside: negative, zero or positive.
    public func compare(_ left: String, _ right: String) -> Int {
        if let names { return names.compare(left, right) }
        return Self.order(
            left.compare(
                right, options: [.numeric, .caseInsensitive, .diacriticInsensitive], range: nil, locale: locale))
    }

    /// Words in the same alphabet, for what is not a name (a kind, an extension): digits one by one, and texts that
    /// differ only in case or accents are not equal, a lowercase letter coming before its capital.
    public func compareWords(_ left: String, _ right: String) -> Int {
        if let words { return words.compare(left, right) }
        return Self.order(left.compare(right, options: [], range: nil, locale: locale))
    }

    /// Adds a key of `text` to `key` whose bytes, compared with `memcmp` (shorter first when one is the start of the
    /// other), order texts as `compare` does. False, and nothing added, where only `compare` can order them.
    public func appendSortKey(of text: String, to key: inout [UInt8]) -> Bool {
        guard let names else { return false }
        names.appendSortKey(of: text, to: &key)
        return true
    }

    private static func order(_ result: ComparisonResult) -> Int {
        switch result {
        case .orderedAscending: -1
        case .orderedSame: 0
        case .orderedDescending: 1
        }
    }
}

/// Names in natural order (`NameOrder.current`): numbers by value (file2 before file10), case and accents aside.
public func naturalCompare(_ first: String, _ second: String) -> ComparisonResult {
    let compared = NameOrder.current.compare(first, second)
    return compared < 0 ? .orderedAscending : compared > 0 ? .orderedDescending : .orderedSame
}
