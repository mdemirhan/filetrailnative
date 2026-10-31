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
        let needle = Array(normalizedQuery.utf8)
        return entries.filter { matches($0.name, needle: needle, query: normalizedQuery, prefixOnly: false) }
    }

    /// Whether the lowercased `name` contains (or starts with) the lowercased `query`. A name of ASCII letters only,
    /// nearly every name, is compared byte by byte with no copy; any other goes through the full case mapping.
    private static func matches(_ name: String, needle: [UInt8], query: String, prefixOnly: Bool) -> Bool {
        var name = name
        let fast: Bool? = name.withUTF8 { bytes in
            for byte in bytes where byte >= 0x80 { return nil }
            return asciiFolded(bytes, needle, prefixOnly: prefixOnly)
        }
        if let fast { return fast }
        let lowered = JSString.lowercased(name)
        return prefixOnly ? JSString.hasPrefix(lowered, query) : JSString.includes(lowered, query)
    }

    private static func asciiFolded(_ bytes: UnsafeBufferPointer<UInt8>, _ needle: [UInt8], prefixOnly: Bool) -> Bool {
        let count = needle.count
        guard count <= bytes.count else { return false }
        let last = prefixOnly ? 0 : bytes.count - count
        var start = 0
        while start <= last {
            var offset = 0
            while offset < count {
                var byte = bytes[start + offset]
                if byte >= 65 && byte <= 90 { byte += 32 }
                if byte != needle[offset] { break }
                offset += 1
            }
            if offset == count { return true }
            start += 1
        }
        return false
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
        let needle = Array(normalizedQuery.utf8)
        return matches.first { Self.matches($0.name, needle: needle, query: normalizedQuery, prefixOnly: true) }
            ?? matches.first
    }

    /// "240 items", or "3 of 240 items" while a filter hides some of them.
    public static func formatItemCount(shown: Int, total: Int) -> String {
        let noun = total == 1 ? "item" : "items"
        return shown == total ? "\(total) \(noun)" : "\(shown) of \(total) \(noun)"
    }
}
