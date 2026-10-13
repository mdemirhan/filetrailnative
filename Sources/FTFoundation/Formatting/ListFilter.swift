// Port of apps/desktop/src/renderer/lib/listFilter.ts
import Foundation

public protocol ListFilterEntry {
    var name: String { get }
}

public protocol ListFilterSearchResult: ListFilterEntry {
    var relativeParentPath: String { get }
}

/// Typing in the file list (or the search results) narrows it to the names that contain the text.
/// The filter stays until it is cleared; there is no timer.
public enum ListFilter {
    /// How long after the last typed character Space still counts as part of the text. After that it
    /// is Quick Look again, so a filtered item can be previewed.
    public static let spaceWindow: TimeInterval = 1

    /// Case-insensitive "name contains"; the order of the list is kept.
    public static func filterByName<T: ListFilterEntry>(_ entries: [T], query: String) -> [T] {
        let normalizedQuery = JSString.lowercased(query)
        if normalizedQuery.isEmpty {
            return entries
        }
        return entries.filter { JSString.includes(JSString.lowercased($0.name), normalizedQuery) }
    }

    /// Search results are spread over many folders, so their filter also looks at the folder a
    /// result is in: "src" keeps the results under a folder named src as well as names with it.
    public static func filterSearchResults<T: ListFilterSearchResult>(_ results: [T], query: String) -> [T] {
        let normalizedQuery = JSString.lowercased(query)
        if normalizedQuery.isEmpty {
            return results
        }
        return results.filter {
            JSString.includes(JSString.lowercased($0.name), normalizedQuery)
                || JSString.includes(JSString.lowercased($0.relativeParentPath), normalizedQuery)
        }
    }

    /// The item a filter selects: the first name that starts with the text, as type-to-select would
    /// pick, otherwise the first match.
    public static func selection<T: ListFilterEntry>(in matches: [T], query: String) -> T? {
        let normalizedQuery = JSString.lowercased(query)
        if normalizedQuery.isEmpty {
            return nil
        }
        return matches.first { JSString.hasPrefix(JSString.lowercased($0.name), normalizedQuery) } ?? matches.first
    }

    /// "240 items", or "3 of 240 items" while a filter hides some of them.
    public static func formatItemCount(shown: Int, total: Int) -> String {
        let noun = total == 1 ? "item" : "items"
        return shown == total ? "\(total) \(noun)" : "\(shown) of \(total) \(noun)"
    }
}
