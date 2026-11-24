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
    /// Whether a plain-text search for `query` would find this item: each of its words as the filters match names
    /// (`NameTerms`, `NameMatcher` in Contains), which is how the search's own results are judged.
    public static func matchesTextQuery(_ item: some SearchRefinementItem, query: String, scope: SearchMatchScope)
        -> Bool
    {
        guard let terms = NameTerms(query) else { return true }
        return terms.matches(scope == .path ? item.path : item.name)
    }

    /// The results a plain-text search for `query` would find, in their order: judged by one matcher, the names (or
    /// paths) beyond ASCII folded through `cache`, so that a list judged again for longer text folds none of them again.
    public static func matching<T: SearchRefinementItem>(
        _ results: [T], query: String, scope: SearchMatchScope, cache: FoldedNameCache? = nil
    ) -> [T] {
        guard let terms = NameTerms(query) else { return results }
        return results.filter { terms.matches(scope == .path ? $0.path : $0.name, cache: cache) }
    }

    /// Whether everything a plain-text search for `next` finds is also found by one for `base`: each word of `base`
    /// is in a word of `next` (`NameTerms.isNarrower`).
    public static func isNarrower(base: String, next: String) -> Bool {
        NameTerms.isNarrower(base: base, next: next)
    }

    /// The results a search for `query` and one for `previousQuery` have in common: whichever of the
    /// two is the narrower decides. Used to keep, across a change of query, the results on screen that
    /// still belong there. Unrelated queries share nothing that is known.
    public static func keepMatching<T: SearchRefinementItem>(
        _ results: [T], previousQuery: String, query: String, scope: SearchMatchScope, cache: FoldedNameCache? = nil
    ) -> [T] {
        if isNarrower(base: previousQuery, next: query) {
            return matching(results, query: query, scope: scope, cache: cache)
        }
        // The new text is the shorter one: everything found so far still matches it.
        if isNarrower(base: query, next: previousQuery) {
            return results
        }
        return []
    }
}
