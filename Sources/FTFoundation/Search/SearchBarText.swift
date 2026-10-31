// Port of the words and rules of apps/desktop/src/renderer/components/SearchBar.tsx (SearchResultsState, the bar's
// labels), buildSearchScopeOptions (App.tsx:2954-2975) and the timings of hooks/useExplorerSearchController.ts
import Foundation

/// How long things wait while searching.
public enum SearchTiming {
    /// Typing searches on its own once the trimmed text is this long (`LIVE_SEARCH_MIN_LENGTH`).
    public static let liveSearchMinLength = 2
    /// …and the keyboard has been still for this long (`LIVE_SEARCH_DELAY_MS`).
    public static let liveSearchDelay: TimeInterval = 0.4
    /// The search on screen is asked for news this often (`SEARCH_POLL_INTERVAL_MS`).
    public static let pollInterval: TimeInterval = 0.12
    /// A background tab's search, this often (`BACKGROUND_SEARCH_POLL_INTERVAL_MS`).
    public static let backgroundPollInterval: TimeInterval = 1
    /// Stop and its spinner come only for a search that runs on this long (`SEARCH_STOP_DELAY_MS`).
    public static let stopDelay: TimeInterval = 0.4

    /// `text.trim()`: what a query is searched as.
    public static func trimmed(_ text: String) -> String {
        JSString.trimmed(text)
    }
}

/// A place the results bar offers to search in.
public struct SearchScopeOption: Equatable, Sendable {
    public var path: String
    public var label: String

    public init(path: String, label: String) {
        self.path = path
        self.label = label
    }
}

/// The words of the results bar and its states.
public enum SearchBarText {
    public static let scopeLabel = "Search:"
    public static let scopeToolbarName = "Search scope"
    public static let filterPlaceholder = "Filter by name or folder"
    public static let filterAccessibilityName = "Filter results"
    public static let clearFilterTitle = "Clear Filter (Esc)"
    public static let clearFilterName = "Clear filter"
    public static let stop = "Stop"
    public static let stopTitle = "Stop Search"
    public static let stopName = "Stop search"
    public static let done = "Done"
    public static let doneTitle = "Close Search Results (Esc)"
    public static let doneName = "Close search results"
    public static let truncatedBanner = "Showing the first 20,000 matches."

    /// The toolbar's field.
    public static let fieldPlaceholder = "Search"
    public static let fieldName = "Find files in current folder"
    public static let clearSearchTitle = "Clear Search"
    public static let clearSearchName = "Clear file search"
    public static let optionsTitle = "Search Options"
    public static let optionsName = "Search options"

    /// `buildSearchScopeOptions`: the folder on screen, Home, the disk it is on when that is another disk, and
    /// Macintosh HD, without repeats (the first of two with the same path wins).
    public static func scopeOptions(currentPath: String, homePath: String) -> [SearchScopeOption] {
        let volume = TreePaths.volumeRootPath(currentPath)
        var candidates: [(String, String)] = [
            (currentPath, "\u{201C}\(TabText.folderDisplayName(currentPath))\u{201D}"), (homePath, "Home"),
        ]
        if volume != "/" { candidates.append((volume, TabText.folderDisplayName(volume))) }
        candidates.append(("/", "Macintosh HD"))
        var options: [SearchScopeOption] = []
        for (path, label) in candidates
        where !path.isEmpty && !options.contains(where: { JSString.equals($0.path, path) }) {
            options.append(SearchScopeOption(path: path, label: label))
        }
        return options
    }
}

/// What the results' views show while they have no rows (`SearchResultsState`): how the search is going, or why it
/// found nothing.
public enum SearchResultsState: Equatable, Sendable {
    /// A pattern that does not parse while it is being typed: not a failure yet.
    case incompletePattern
    case failed(message: String)
    case searching
    /// Results exist, and the filter hides them all.
    case filteredOut(query: String)
    case noMatches

    /// Nil once there are results to show. An error comes first, rows or not.
    public static func make(
        isRunning: Bool, shownCount: Int, totalCount: Int, error: String?, errorIsQuiet: Bool, filterQuery: String
    ) -> SearchResultsState? {
        if let error, !error.isEmpty {
            return errorIsQuiet ? .incompletePattern : .failed(message: error)
        }
        if shownCount > 0 { return nil }
        if isRunning { return .searching }
        if totalCount > 0 { return .filteredOut(query: filterQuery) }
        return .noMatches
    }

    public var title: String {
        switch self {
        case .incompletePattern: "Incomplete pattern"
        case .failed: "Search failed"
        case .searching: "Searching…"
        case .filteredOut(let query): "No results match \u{201C}\(query)\u{201D}"
        case .noMatches: "No matches"
        }
    }

    public var message: String? {
        switch self {
        case .incompletePattern: "Keep typing, or press Return to see what is wrong with it."
        case .failed(let message): message
        case .searching: nil
        case .filteredOut: "Nothing found has that in its name or folder. Press Esc to see all the results."
        case .noMatches: "Try other text, or another location above."
        }
    }
}
