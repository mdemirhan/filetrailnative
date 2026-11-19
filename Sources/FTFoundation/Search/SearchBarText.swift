import Foundation

/// How long things wait while searching.
public enum SearchTiming {
    /// Typing searches on its own once the trimmed text is this long.
    public static let liveSearchMinLength = 2
    /// …and the keyboard has been still for this long.
    public static let liveSearchDelay: TimeInterval = 0.4
    /// The search on screen is asked for news this often.
    public static let pollInterval: TimeInterval = 0.12
    /// A background tab's search, this often.
    public static let backgroundPollInterval: TimeInterval = 1
    /// Stop and its spinner come only for a search that runs on this long.
    public static let stopDelay: TimeInterval = 0.4

    /// What a query is searched as: the text without white space at either end.
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
    public static let scopeToolbarName = "Search scope"
    public static let filterPlaceholder = "Name or folder"
    public static let filterAccessibilityName = "Filter results"
    public static let clearFilterTitle = "Clear Filter (Esc)"
    public static let clearFilterName = "Clear filter"
    public static let stop = "Stop"
    public static let stopTitle = "Stop Search"
    public static let stopName = "Stop search"
    public static let done = "Done"
    public static let doneTitle = "Close Search Results (Esc)"
    public static let doneName = "Close search results"
    public static let truncatedBanner =
        "Showing the first \(ContextMenuRules.groupedCount(SearchLimits.resultLimit)) matches."
    /// A write put items inside the folder searched, which the results don't list.
    public static let mayBeMissingBanner = "Items added since this search may not be listed."
    public static let searchAgain = "Search Again"
    public static let searchAgainName = "Search again"

    /// What the banner over the results says: that they were cut short, that they may be missing what was added, or
    /// both; nil when there is nothing to say.
    public static func banner(truncated: Bool, mayBeMissingItems: Bool) -> String? {
        let lines = [truncated ? truncatedBanner : nil, mayBeMissingItems ? mayBeMissingBanner : nil].compactMap { $0 }
        return lines.isEmpty ? nil : lines.joined(separator: " ")
    }

    /// The toolbar's field.
    public static let fieldPlaceholder = "Search"
    public static let fieldName = "Find files in current folder"
    public static let clearSearchTitle = "Clear Search"
    public static let clearSearchName = "Clear file search"
    public static let optionsTitle = "Search Options"
    public static let optionsName = "Search options"
    /// The results bar's button that opens the same menu as the field's magnifier.
    public static let optionsButton = "Options"

    /// The options of a search that differ from what a new install searches with, by the options menu's names, in
    /// its order; empty while every one is at its default.
    public static func changedOptions(
        matchScope: SearchMatchScopePreference, patternMode: SearchPatternModePreference, recursive: Bool,
        skipGitFolders: Bool, skipGitIgnored: Bool
    ) -> [String] {
        let defaults = AppPreferences.defaults()
        var changed: [String] = []
        if matchScope != defaults.searchMatchScope { changed.append(matchScope == .path ? "Full Path" : "Name") }
        if patternMode != defaults.searchPatternMode { changed.append(patternMode.label) }
        if recursive != defaults.searchRecursive { changed.append("Search Subfolders \(recursive ? "On" : "Off")") }
        if skipGitFolders != defaults.searchSkipGitFolders {
            changed.append("Skip .git Folders \(skipGitFolders ? "On" : "Off")")
        }
        if skipGitIgnored != defaults.searchSkipGitIgnored {
            changed.append("Skip Files Ignored by Git \(skipGitIgnored ? "On" : "Off")")
        }
        return changed
    }

    /// The tooltip of the magnifier and the bar's Options button: what has been changed from the defaults, if anything.
    public static func optionsTitle(changed: [String]) -> String {
        changed.isEmpty ? optionsTitle : "\(optionsTitle): \(changed.joined(separator: ", "))"
    }

    /// The folder on screen, Home, the disk it is on when that is another disk, and
    /// the startup disk, without repeats (the first of two with the same path wins).
    public static func scopeOptions(
        currentPath: String, homePath: String, startupDiskName: String = VolumePaths.defaultStartupDiskName
    ) -> [SearchScopeOption] {
        let volume = VolumePaths.volumeRootPath(currentPath)
        let shown = TabText.folderDisplayName(currentPath, homePath: homePath, startupDiskName: startupDiskName)
        var candidates: [(String, String)] = [(currentPath, shown), (homePath, "Home")]
        if volume != "/" { candidates.append((volume, TabText.folderDisplayName(volume, homePath: homePath))) }
        candidates.append(("/", startupDiskName))
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
