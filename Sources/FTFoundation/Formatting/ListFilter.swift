import Foundation

public protocol ListFilterEntry {
    var name: String { get }
}

public protocol ListFilterSearchResult: ListFilterEntry {
    var relativeParentPath: String { get }
}

/// Typing in the file list (or the search results) narrows it to the names that match the text (`NameMatcher`).
/// The filter stays until it is cleared; there is no timer.
public enum ListFilter {
    /// How long after the last typed character Space still counts as part of the text. After that it
    /// is Quick Look again, so a filtered item can be previewed.
    public static let spaceWindow: TimeInterval = 1

    /// The names that match `query` in `mode`, in the list's order.
    public static func filterByName<T: ListFilterEntry>(_ entries: [T], query: String, mode: NameMatchMode) -> [T] {
        guard let matcher = NameMatcher(query, mode: mode) else { return entries }
        return entries.filter { matcher.matches($0.name) }
    }

    /// Search results are spread over many folders, so their filter also looks at the folder a
    /// result is in: "src" keeps the results under a folder named src as well as names with it. The name is matched
    /// in `mode`; the folder always as Contains, as letters scattered over a path would match nearly every one.
    public static func filterSearchResults<T: ListFilterSearchResult>(
        _ results: [T], query: String, mode: NameMatchMode
    ) -> [T] {
        guard let name = NameMatcher(query, mode: mode), let folder = NameMatcher(query, mode: .contains) else {
            return results
        }
        return results.filter { name.matches($0.name) || folder.matches($0.relativeParentPath) }
    }

    /// The item a filter selects: the first name that starts with the text, as type-to-select would
    /// pick, then the first that contains it, then the name the letters in order fit best (the first of equals);
    /// otherwise the first match.
    public static func selection<T: ListFilterEntry>(in matches: [T], query: String, mode: NameMatchMode) -> T? {
        guard let matcher = NameMatcher(query, mode: mode) else { return nil }
        if let prefix = matches.first(where: { matcher.isPrefix(of: $0.name) }) { return prefix }
        if let contained = matches.first(where: { matcher.isContained(in: $0.name) }) { return contained }
        if mode == .fuzzy {
            var best: (entry: T, score: Int)?
            for entry in matches {
                guard let score = matcher.score(entry.name), score > best?.score ?? Int.min else { continue }
                best = (entry, score)
            }
            if let best { return best.entry }
        }
        return matches.first
    }

    /// "240 items", or "3 of 240 items" while a filter hides some of them.
    public static func formatItemCount(shown: Int, total: Int) -> String {
        let noun = total == 1 ? "item" : "items"
        return shown == total ? "\(total) \(noun)" : "\(shown) of \(total) \(noun)"
    }
}
