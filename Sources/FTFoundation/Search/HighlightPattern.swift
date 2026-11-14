// What a name search matched, to mark it in the names
import Foundation

/// The text of a name search as the names are marked with it: a regular expression in the system's syntax
/// (`NSRegularExpression`), or the text itself, found as typed. It only says which letters are painted; which files a
/// search finds is fd's.
public struct HighlightPattern: @unchecked Sendable {
    /// How long one name may take a regular expression to look through. The names are marked on the main thread, and a
    /// pattern such as `(a+)+$` can take seconds on a name that almost matches: past this, it gives up.
    public static let timePerName: DispatchTimeInterval = .milliseconds(5)

    private enum Matcher {
        case regex(NSRegularExpression, GaveUp)
        /// The text's UTF-16 units, folded when case doesn't matter.
        case text([UInt16], ignoreCase: Bool)
        /// Plain Text, matched as the filters match names.
        case names(NameMatcher)
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

    /// The text itself; nil for an empty one. Without case, each character is compared by its simple case fold, as
    /// fd's search compares: "k" finds "K", but "ss" doesn't find "ß".
    public init?(text: String, ignoreCase: Bool) {
        guard !text.isEmpty else { return nil }
        matcher = .text(ignoreCase ? Self.folded(text) : Array(text.utf16), ignoreCase: ignoreCase)
    }

    /// Plain Text as a search matches it (`PlainTextPattern`): the run of letters a filter in Contains would mark.
    public init(names matcher: NameMatcher) {
        self.matcher = .names(matcher)
    }

    /// Where the first match in `name` is, in UTF-16 units; nil when there is none, or when a regular expression took
    /// longer than `timePerName` over this name or an earlier one.
    public func firstMatch(in name: String) -> NSRange? {
        switch matcher {
        case .regex(let regex, let gaveUp):
            guard !gaveUp.isSet else { return nil }
            var found: NSRange?
            let deadline = DispatchTime.now() + Self.timePerName
            // The block is called with each match, and now and then while a long one is looked for.
            regex.enumerateMatches(
                in: name, options: [.reportProgress], range: NSRange(location: 0, length: name.utf16.count)
            ) { result, _, stop in
                if let result {
                    found = result.range
                    stop.pointee = true
                } else if DispatchTime.now() > deadline {
                    gaveUp.set()
                    stop.pointee = true
                }
            }
            return found
        case .names(let matcher):
            return matcher.marks(in: name).first.map { NSRange(location: $0.start, length: $0.end - $0.start) }
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
