import Foundation

/// Names in natural order, as English sorts them: numbers by value (file2 before file10), case and accents aside.
public func naturalCompare(_ first: String, _ second: String) -> ComparisonResult {
    first.compare(
        second, options: [.numeric, .caseInsensitive, .diacriticInsensitive], range: nil,
        locale: Locale(identifier: "en_US"))
}
