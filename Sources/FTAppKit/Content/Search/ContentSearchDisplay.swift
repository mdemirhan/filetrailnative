// Port of what App.tsx hands ContentPane in search mode (entries, listColumns with getFolderLabel, nameHighlight,
// contentStateOverride, statusSummary, viewKey): search results shown by the folder's own views
import FTFileSystem
import FTFoundation
import Foundation

/// What the content pane shows while search results are on screen, in place of the folder.
struct ContentSearchDisplay {
    /// Where the search runs from; the Folder column is relative to it.
    var rootPath: String
    /// `search:<root>:<query>`: a new query or root is a new list, which starts at the top and drops the filter.
    var viewKey: String
    /// What the search found, narrowed to the committed text and in the chosen order.
    var results: [SearchResultItem]
    var sortBy: SearchResultsSortByPreference
    var sortDirection: SortDirectionPreference
    /// What the search matched in names, to mark.
    var highlight: JSLegacyRegExp?
    var isRunning: Bool
    var error: String?
    var errorIsQuiet: Bool
}

/// What the views of the folder draw differently for search results: the Folder column, the marks in names, and the
/// order of the List's header.
@MainActor
final class ContentSearchContext {
    let rootPath: String
    let highlight: JSLegacyRegExp?
    let sortBy: SearchResultsSortByPreference
    let sortDirection: SortDirectionPreference
    /// A header asked for the results to be ordered by this column.
    let requestSort: (SearchResultsSortByPreference) -> Void
    /// The order was set from outside (a scenario's sort step).
    let setSort: (SearchResultsSortByPreference, SortDirectionPreference) -> Void
    private var folderLabels: [String: String] = [:]
    private var matches: [String: HighlightRange?] = [:]

    init(
        display: ContentSearchDisplay, requestSort: @escaping (SearchResultsSortByPreference) -> Void,
        setSort: @escaping (SearchResultsSortByPreference, SortDirectionPreference) -> Void
    ) {
        self.setSort = setSort
        rootPath = display.rootPath
        highlight = display.highlight
        sortBy = display.sortBy
        sortDirection = display.sortDirection
        self.requestSort = requestSort
    }

    /// `formatSearchResultFolder`: "src › renderer", or the root's name for a result right in it.
    func folderLabel(_ path: String) -> String {
        if let known = folderLabels[path] { return known }
        let made = SearchResults.folderText(path: path, rootPath: rootPath)
        folderLabels[path] = made
        return made
    }

    /// The match in a whole name (`findNameMatch`), remembered per name.
    func match(in name: String) -> HighlightRange? {
        guard highlight != nil else { return nil }
        if let known = matches[name] { return known }
        let found = NameHighlight.match(highlight, in: name)
        matches[name] = found
        return found
    }

    /// The sort key the header's columns compare against (`listColumns.sortBy`).
    var headerSortKey: String { sortBy.rawValue }
}
