import Foundation

public protocol SearchRefinementItem {
    var name: String { get }
    var path: String { get }
}

public enum SearchMatchScope: String, Codable, Sendable {
    case name
    case path
}

/// While plain text is typed into the search field, most keystrokes only make the text longer.
/// Everything the longer text can match was already matched by the shorter one, so the search that is
/// running (or has finished) is kept and its results are narrowed here, instead of walking the disk
/// again for every pause in typing.
public enum SearchRefinement {
    /// Whether a plain-text search for `query` would find this item: as the filters match names (`NameMatcher` in
    /// Contains), which is how the search's own results are judged.
    public static func matchesTextQuery(_ item: some SearchRefinementItem, query: String, scope: SearchMatchScope)
        -> Bool
    {
        guard let matcher = NameMatcher(query, mode: .contains) else { return true }
        return matcher.matches(scope == .path ? item.path : item.name)
    }

    /// Whether everything a plain-text search for `next` finds is also found by one for `base`: `next` holds `base`
    /// as a run of letters, a plain letter of `base` standing for its accented forms in `next`.
    public static func isNarrower(base: String, next: String) -> Bool {
        if base.isEmpty || next.utf16.count < base.utf16.count {
            return false
        }
        return NameMatcher(base, mode: .contains)?.matches(next) ?? false
    }

    /// The results a search for `query` and one for `previousQuery` have in common: whichever of the
    /// two is the narrower decides. Used to keep, across a change of query, the results on screen that
    /// still belong there. Unrelated queries share nothing that is known.
    public static func keepMatching<T: SearchRefinementItem>(
        _ results: [T], previousQuery: String, query: String, scope: SearchMatchScope
    ) -> [T] {
        if isNarrower(base: previousQuery, next: query) {
            return results.filter { matchesTextQuery($0, query: query, scope: scope) }
        }
        // The new text is the shorter one: everything found so far still matches it.
        if isNarrower(base: query, next: previousQuery) {
            return results
        }
        return []
    }
}
