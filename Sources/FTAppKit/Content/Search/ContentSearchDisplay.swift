// Search results shown by the folder's own views
import FTFileSystem
import FTFoundation
import Foundation

/// What the content pane shows while search results are on screen, in place of the folder.
struct ContentSearchDisplay {
    /// Where the search runs from; the Folder column is relative to it.
    var rootPath: String
    /// `search:<root>:<query>`: a new query or root is a new list, which starts at the top and drops the filter.
    var viewKey: String
    /// Which run of the search these results are of: the same search run again (⌘R, an option changed) is another.
    var run = 0
    /// What the search found, narrowed to the committed text and in the chosen order.
    var results: [SearchResultItem]
    var sortBy: SearchResultsSortByPreference
    var sortDirection: SortDirectionPreference
    /// What the search matched in names, to mark.
    var highlight: HighlightPattern?
    var isRunning: Bool
    var error: String?
    var errorIsQuiet: Bool
    /// The search met folders it couldn't read: the status bar says so beside the count.
    var unreadableFolders = false
    /// What a result right in `/` shows in its Folder column.
    var startupDiskName = VolumePaths.defaultStartupDiskName
}

/// What the views of the folder draw differently for search results: the Folder column, the marks in names, and the
/// order of the List's header.
@MainActor
final class ContentSearchContext {
    let rootPath: String
    let highlight: HighlightPattern?
    let sortBy: SearchResultsSortByPreference
    let sortDirection: SortDirectionPreference
    /// A header asked for the results to be ordered by this column.
    let requestSort: (SearchResultsSortByPreference) -> Void
    /// The order was set from outside (a scenario's sort step).
    let setSort: (SearchResultsSortByPreference, SortDirectionPreference) -> Void
    private let startupDiskName: String
    private var folderLabels: [DiskPath: String] = [:]
    private var matches: [StoredName: HighlightRange?] = [:]

    init(
        display: ContentSearchDisplay, requestSort: @escaping (SearchResultsSortByPreference) -> Void,
        setSort: @escaping (SearchResultsSortByPreference, SortDirectionPreference) -> Void
    ) {
        self.setSort = setSort
        rootPath = display.rootPath
        startupDiskName = display.startupDiskName
        highlight = display.highlight
        sortBy = display.sortBy
        sortDirection = display.sortDirection
        self.requestSort = requestSort
    }

    /// "src › views", or the root's name for a result right in it. `path` is the result's, as its row spells it.
    func folderLabel(_ path: DiskPath) -> String {
        if let known = folderLabels[path] { return known }
        let made = SearchResults.folderText(path: path.string, rootPath: rootPath, startupDiskName: startupDiskName)
        folderLabels[path] = made
        return made
    }

    /// The match in a whole name, remembered per name as stored.
    func match(in name: String) -> HighlightRange? {
        guard highlight != nil else { return nil }
        let key = StoredName(name)
        if let known = matches[key] { return known }
        let found = NameHighlight.match(highlight, in: name)
        matches[key] = found
        return found
    }

    /// The sort key the header's columns compare against.
    var headerSortKey: String { sortBy.rawValue }
}
