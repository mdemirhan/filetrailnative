// What a name search matched, to mark it in the names
import Foundation

/// The text of a name search as the names are marked with it: a regular expression in the system's syntax
/// (`NSRegularExpression`), or the text itself, found as typed. It only says which letters are painted; which files a
/// search finds is the search's (`SearchNameMatch`).
public struct HighlightPattern: @unchecked Sendable {
    /// How long one name may take a regular expression to look through. The names are marked on the main thread, and a
    /// pattern such as `(a+)+$` can take seconds on a name that almost matches: past this, it gives up.
    public static let timePerName: DispatchTimeInterval = .milliseconds(5)

    private enum Matcher {
        case regex(NSRegularExpression, GaveUp)
        /// The text's UTF-16 units, folded when case doesn't matter.
        case text([UInt16], ignoreCase: Bool)
        /// Plain Text, each word matched as the filters match names.
        case names(NameTerms)
    }

    /// Set once a name took the pattern too long: it marks no more names, as the next would likely take as long.
    private final class GaveUp: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.withLock { value } }
        func set() { lock.withLock { value = true } }
    }

    private let matcher: Matcher

    /// A regular expression; nil for one the system doesn't take.
    public init?(regex source: String, ignoreCase: Bool) {
        guard let regex = try? NSRegularExpression(pattern: source, options: ignoreCase ? [.caseInsensitive] : [])
        else { return nil }
        matcher = .regex(regex, GaveUp())
    }

    /// The text itself; nil for an empty one. Without case, each character is compared by its simple case fold: "k"
    /// finds "K", but "ss" doesn't find "ß".
    public init?(text: String, ignoreCase: Bool) {
        guard !text.isEmpty else { return nil }
        matcher = .text(ignoreCase ? Self.folded(text) : Array(text.utf16), ignoreCase: ignoreCase)
    }

    /// Plain Text as a search matches it (`NameTerms`): each word's run of letters, as a filter in Contains marks it.
    public init(names terms: NameTerms) {
        self.matcher = .names(terms)
    }

    /// What to mark in `name`: each word's run for Plain Text, otherwise the first match (`firstMatch`).
    public func marks(in name: String) -> [HighlightRange] {
        if case .names(let terms) = matcher { return terms.marks(in: name) }
        guard let found = firstMatch(in: name), found.length > 0 else { return [] }
        return [HighlightRange(start: found.location, end: found.location + found.length)]
    }

    /// Where the first match in `name` is, in UTF-16 units; nil when there is none, or when a regular expression took
    /// longer than `timePerName` over this name or an earlier one.
    public func firstMatch(in name: String) -> NSRange? {
        switch matcher {
        case .regex(let regex, let gaveUp):
            guard !gaveUp.isSet else { return nil }
            var found: NSRange?
            // Counted in the time this thread works, so a busy Mac alone doesn't spend it.
            let budget = ThreadTimeBudget(Self.timePerName)
            // The block is called with each match, and now and then while a long one is looked for.
            regex.enumerateMatches(
                in: name, options: [.reportProgress], range: NSRange(location: 0, length: name.utf16.count)
            ) { result, _, stop in
                if let result {
                    found = result.range
                    stop.pointee = true
                } else if budget.isSpent {
                    gaveUp.set()
                    stop.pointee = true
                }
            }
            return found
        case .names(let terms):
            return terms.marks(in: name).first.map { NSRange(location: $0.start, length: $0.end - $0.start) }
        case .text(let text, let ignoreCase):
            let units = ignoreCase ? Self.folded(name) : Array(name.utf16)
            guard units.count >= text.count else { return nil }
            for start in 0...(units.count - text.count) where units[start..<(start + text.count)].elementsEqual(text) {
                return NSRange(location: start, length: text.count)
            }
            return nil
        }
    }

    /// `text`'s UTF-16 units with each character folded on its own, where the fold keeps its length: the units stay
    /// where they are in `text`, so a match is a range of the name itself.
    private static func folded(_ text: String) -> [UInt16] {
        var units: [UInt16] = []
        units.reserveCapacity(text.utf16.count)
        for scalar in text.unicodeScalars {
            let fold = String(scalar).folding(options: .caseInsensitive, locale: nil)
            units.append(contentsOf: fold.utf16.count == scalar.utf16.count ? Array(fold.utf16) : Array(scalar.utf16))
        }
        return units
    }
}
