// Port of apps/desktop/src/renderer/lib/explorerTabs.ts
import CoreGraphics
import FTFileSystem
import FTFoundation
import Foundation

/// Where a tab's search stands: the worker's statuses, or `idle` before it has run.
public enum TabSearchStatus: String, Sendable, Equatable {
    case idle, running, complete, cancelled, truncated, error

    init(_ status: SearchJobStatus) {
        self = TabSearchStatus(rawValue: status.rawValue) ?? .error
    }
}

/// A tab's search, as it was when the tab was left. The search itself keeps running; `jobID` and `cursor` are where
/// to pick its results up again.
public struct TabSearchSession: Equatable, Sendable {
    public var draftQuery = ""
    public var committedQuery = ""
    public var rootPath = ""
    public var resultsVisible = false
    public var results: [SearchResultItem] = []
    public var status: TabSearchStatus = .idle
    public var error: String?
    public var truncated = false
    public var elapsedMilliseconds: Double?
    public var jobID: String?
    public var cursor = 0
    /// An answer from the search was on its way when the tab was left, and was thrown away. If it was the last one,
    /// the search has let go of the results it carried.
    public var pollInFlight = false
    public var keptResultPaths: Set<String> = []
    public var interrupted = false

    public init() {}
}

/// What a search says when a background tab asks how it is doing (`search:getUpdate`).
public struct TabSearchUpdate: Equatable, Sendable {
    public var jobID: String
    public var status: SearchJobStatus
    public var items: [SearchResultItem]
    public var nextCursor: Int
    public var done: Bool
    public var truncated: Bool
    public var error: String?

    public init(
        jobID: String, status: SearchJobStatus, items: [SearchResultItem], nextCursor: Int, done: Bool,
        truncated: Bool, error: String?
    ) {
        self.jobID = jobID
        self.status = status
        self.items = items
        self.nextCursor = nextCursor
        self.done = done
        self.truncated = truncated
        self.error = error
    }

    public init(_ update: SearchUpdate) {
        self.init(
            jobID: update.jobId, status: update.status, items: update.items, nextCursor: update.nextCursor,
            done: update.done, truncated: update.truncated, error: update.error)
    }
}

/// A folder of the tab's tree as it was left; only whether it was still loading matters to the tabs.
public struct TabTreeNode: Equatable, Sendable {
    public var path: String
    public var expanded: Bool
    public var loading: Bool
    public var loaded: Bool
    public var childPaths: [String]

    public init(
        path: String, expanded: Bool = false, loading: Bool = false, loaded: Bool = false, childPaths: [String] = []
    ) {
        self.path = path
        self.expanded = expanded
        self.loading = loading
        self.loaded = loaded
        self.childPaths = childPaths
    }
}

/// What a tab had on screen: enough to show it again at once, before its folder is read again.
public struct TabViewState: Equatable, Sendable {
    public var treeNodes: [String: TabTreeNode] = [:]
    public var selectedPaths: [String] = []
    public var listFilterQuery = ""
    public var contentScroll = CGPoint.zero
    public var treeScrollTop: Double = 0
    public var sidebarSectionsScrollTop: Double = 0
    /// The listing is of another folder than the tab's: the folder is read afresh when the tab is shown.
    public var listingOutOfDate = false

    public init() {}
}

/// Everything a tab keeps of itself while another tab is on screen.
public struct TabSnapshot: Equatable, Sendable {
    public enum LeftPaneSubview: String, Sendable { case favorites, tree }
    public enum FocusedPane: String, Sendable { case tree, content }

    public var currentPath: String
    public var historyPaths: [String]
    public var historyIndex: Int
    public var viewMode: ExplorerViewMode
    /// The view of search results in this tab, apart from the folder's.
    public var searchViewMode: ExplorerViewMode
    public var sortBy: SortByPreference
    public var sortDirection: SortDirectionPreference
    public var treeRootPath: String
    /// `fs:<path>`, `favorite:<path>` or another tree item; nil with none selected.
    public var selectedTreeItemID: String?
    public var leftPaneSubview: LeftPaneSubview
    public var focusedPane: FocusedPane
    public var includeHidden: Bool
    public var foldersFirst: Bool
    public var favoritesExpanded: Bool
    public var locationsExpanded: Bool
    /// Nil for a tab that has not been shown yet: its folder and tree are read when it is first opened.
    public var view: TabViewState?
    public var search: TabSearchSession?

    public init(
        currentPath: String, historyPaths: [String], historyIndex: Int, viewMode: ExplorerViewMode = .icons,
        searchViewMode: ExplorerViewMode = .details, sortBy: SortByPreference = .name,
        sortDirection: SortDirectionPreference = .asc, treeRootPath: String, selectedTreeItemID: String? = nil,
        leftPaneSubview: LeftPaneSubview = .tree, focusedPane: FocusedPane = .content, includeHidden: Bool = false,
        foldersFirst: Bool = true, favoritesExpanded: Bool = true, locationsExpanded: Bool = true,
        view: TabViewState? = nil, search: TabSearchSession? = nil
    ) {
        self.currentPath = currentPath
        self.historyPaths = historyPaths
        self.historyIndex = historyIndex
        self.viewMode = viewMode
        self.searchViewMode = searchViewMode
        self.sortBy = sortBy
        self.sortDirection = sortDirection
        self.treeRootPath = treeRootPath
        self.selectedTreeItemID = selectedTreeItemID
        self.leftPaneSubview = leftPaneSubview
        self.focusedPane = focusedPane
        self.includeHidden = includeHidden
        self.foldersFirst = foldersFirst
        self.favoritesExpanded = favoritesExpanded
        self.locationsExpanded = locationsExpanded
        self.view = view
        self.search = search
    }
}

/// A tab's label with what telling it apart from the others needs (`disambiguateTabLabels`' items).
public struct TabLabel: Equatable, Sendable {
    public var label: String
    public var kind: TabDescription.Kind
    public var path: String

    public init(label: String, kind: TabDescription.Kind, path: String) {
        self.label = label
        self.kind = kind
        self.path = path
    }
}

/// A folder renamed or moved: where it was and where it is now.
public struct PathMove: Equatable, Sendable {
    public var from: String
    public var to: String

    public init(from: String, to: String) {
        self.from = from
        self.to = to
    }
}

public enum ExplorerTabs {
    /// How many closed tabs Reopen Closed Tab can bring back, most recent first (CLOSED_TABS_LIMIT).
    public static let closedTabsLimit = 10

    // MARK: Paths

    /// `parentDirectoryPath`: nil above `/`.
    public static func parentDirectoryPath(_ path: String) -> String? {
        if path == "/" { return nil }
        let parts = path.split(separator: "/")
        if parts.count <= 1 { return "/" }
        return "/" + parts.dropLast().joined(separator: "/")
    }

    /// `getVolumeRootPath`: `/Volumes/<name>` for a path on another disk, else `/`.
    public static func volumeRootPath(_ path: String) -> String {
        let prefix = "/Volumes/"
        guard path.hasPrefix(prefix) else { return "/" }
        let name = path.dropFirst(prefix.count).prefix { $0 != "/" }
        return name.isEmpty ? "/" : prefix + name
    }

    /// `getFolderDisplayName`: "Macintosh HD" for `/`.
    public static func folderDisplayName(_ path: String) -> String {
        TabText.folderDisplayName(path)
    }

    /// `getPathAndAncestors`: `path` and the folders above it, nearest first: where a tab goes when its folder is gone.
    public static func pathAndAncestors(_ path: String) -> [String] {
        var paths: [String] = []
        var current: String? = path
        while let candidate = current, !candidate.isEmpty {
            paths.append(candidate)
            current = parentDirectoryPath(candidate)
        }
        return paths
    }

    // MARK: Labels

    /// `describeTab`: its folder, or its search while results are showing.
    public static func describe(
        currentPath: String, searchVisible: Bool, searchQuery: String, searchRootPath: String, searchRunning: Bool
    ) -> TabDescription {
        TabText.describe(
            currentPath: currentPath, searchVisible: searchVisible, searchQuery: searchQuery,
            searchRootPath: searchRootPath, searchRunning: searchRunning)
    }

    /// `describeTabSnapshot`.
    public static func describe(_ snapshot: TabSnapshot) -> TabDescription {
        let search = snapshot.search
        return describe(
            currentPath: snapshot.currentPath, searchVisible: search?.resultsVisible ?? false,
            searchQuery: search?.committedQuery ?? "", searchRootPath: search?.rootPath ?? "",
            searchRunning: search?.status == .running)
    }

    /// `disambiguateTabLabels`: tabs on folders with the same name are told apart by the folder each one is in. Tabs
    /// on the same folder, and search tabs, keep their labels.
    public static func disambiguate(_ items: [TabLabel]) -> [TabLabel] {
        items.enumerated().map { index, item in
            guard item.kind == .folder else { return item }
            let clashes = items.enumerated().contains { otherIndex, other in
                otherIndex != index && other.kind == .folder && other.label == item.label && other.path != item.path
            }
            guard clashes, let parent = parentDirectoryPath(item.path) else { return item }
            var labelled = item
            labelled.label = "\(item.label) — \(folderDisplayName(parent))"
            return labelled
        }
    }

    // MARK: The row of tabs

    /// `resolveTabAfterClose`: the tab that takes over when `closed` closes: the one to its right, or to its left when
    /// it was last.
    public static func tabAfterClose<ID: Equatable>(_ tabs: [ID], closing closed: ID) -> ID? {
        guard let index = tabs.firstIndex(of: closed) else { return nil }
        if tabs.indices.contains(index + 1) { return tabs[index + 1] }
        return index > 0 ? tabs[index - 1] : nil
    }

    public enum Direction: Sendable { case next, previous }

    /// `resolveAdjacentTab`: the next or previous tab, wrapping around at the ends.
    public static func adjacentTab<ID: Equatable>(_ tabs: [ID], active: ID, _ direction: Direction) -> ID? {
        guard tabs.count >= 2, let index = tabs.firstIndex(of: active) else { return nil }
        let step = direction == .next ? 1 : -1
        return tabs[(index + step + tabs.count) % tabs.count]
    }

    /// `moveTabInList`: moves a tab to `toIndex` in the row; the other tabs keep their order.
    public static func moveTab<ID: Equatable>(_ tabs: [ID], _ tab: ID, to toIndex: Int) -> [ID] {
        var next = tabs
        guard let from = next.firstIndex(of: tab) else { return next }
        let moved = next.remove(at: from)
        next.insert(moved, at: max(0, min(toIndex, next.count)))
        return next
    }

    // MARK: Snapshots

    /// `settleTreeNodes`: a tree saved in the middle of loading a folder would wait for that answer for ever, since
    /// the answer went to the tab that was on screen then.
    public static func settleTreeNodes(_ nodes: [String: TabTreeNode]) -> [String: TabTreeNode] {
        nodes.mapValues { node in
            var settled = node
            settled.loading = false
            return settled
        }
    }

    /// `toReopenableSnapshot`: what is kept of a closed tab: its folder, its tree root, and how it showed the folder.
    /// Its history, selection and search go with it.
    public static func reopenable(_ snapshot: TabSnapshot) -> TabSnapshot {
        var kept = snapshot
        kept.historyPaths = snapshot.currentPath.isEmpty ? [] : [snapshot.currentPath]
        kept.historyIndex = snapshot.currentPath.isEmpty ? -1 : 0
        kept.view = nil
        kept.search = nil
        return kept
    }

    /// `applyBackgroundSearchUpdate`: a background tab's search once the worker has been asked how it is doing: what
    /// was found since is added, and a search that has finished is let go.
    public static func applyBackgroundSearchUpdate(_ session: TabSearchSession, _ update: TabSearchUpdate)
        -> TabSearchSession
    {
        var next = session
        // The answer thrown away when the tab was left turned out to be the last one: its results are gone, so the
        // search is marked to run again when the tab is shown.
        if session.pollInFlight, update.done, update.items.isEmpty {
            next.jobID = nil
            next.status = .cancelled
            next.interrupted = true
            next.pollInFlight = false
            return next
        }
        let newItems =
            session.keptResultPaths.isEmpty
            ? update.items : update.items.filter { !session.keptResultPaths.contains($0.path) }
        next.pollInFlight = false
        next.results += newItems
        next.cursor = update.nextCursor
        next.status = TabSearchStatus(update.status)
        next.error = update.error
        next.truncated = update.truncated
        if update.done {
            next.jobID = nil
            next.elapsedMilliseconds = nil
        }
        return next
    }

    /// `leaveUnmountedDisks`: a background tab on a disk that was unmounted goes Home, as the tab on screen does.
    public static func leaveUnmountedDisks(_ snapshot: TabSnapshot, unmounted: Set<String>, homePath: String)
        -> TabSnapshot
    {
        func isGone(_ path: String) -> Bool { !path.isEmpty && unmounted.contains(volumeRootPath(path)) }
        guard isGone(snapshot.currentPath) || isGone(snapshot.treeRootPath) else { return snapshot }
        var left = snapshot
        left.historyPaths = snapshot.historyPaths.filter { !isGone($0) } + [homePath]
        left.currentPath = homePath
        left.historyIndex = left.historyPaths.count - 1
        left.treeRootPath = homePath
        left.selectedTreeItemID = "fs:\(homePath)"
        left.leftPaneSubview = .tree
        left.view = nil
        return left
    }

    /// `followMovedPath`: where `path` is after `moves`. The deepest move that holds it decides.
    public static func followMovedPath(_ path: String, _ moves: [PathMove]) -> String {
        // Compared as JavaScript compares strings: unit by unit, not by canonical equivalence.
        func startsWith(_ text: String, _ prefix: String) -> Bool { text.utf16.starts(with: prefix.utf16) }
        var deepest: PathMove?
        for move in moves
        where (path.utf16.elementsEqual(move.from.utf16) || startsWith(path, move.from + "/"))
            && (deepest == nil || move.from.utf16.count > deepest?.from.utf16.count ?? 0)
        {
            deepest = move
        }
        guard let deepest else { return path }
        if path.utf16.elementsEqual(deepest.from.utf16) { return deepest.to }
        let rest = path.utf16.index(path.utf16.startIndex, offsetBy: deepest.from.utf16.count)
        return deepest.to + path[rest...]
    }

    /// `followMovedItems`: a background tab on a folder that was renamed or moved follows it, as a Finder window does.
    /// Its listing is read again, at the new place, when it is shown.
    public static func followMovedItems(_ snapshot: TabSnapshot, _ moves: [PathMove]) -> TabSnapshot {
        let currentPath = followMovedPath(snapshot.currentPath, moves)
        let historyPaths = snapshot.historyPaths.map { followMovedPath($0, moves) }
        let treeRootPath = followMovedPath(snapshot.treeRootPath, moves)
        var selected = snapshot.selectedTreeItemID
        if let item = selected, item.hasPrefix("fs:") {
            selected = "fs:" + followMovedPath(String(item.dropFirst(3)), moves)
        }
        let moved =
            currentPath != snapshot.currentPath || treeRootPath != snapshot.treeRootPath
            || historyPaths != snapshot.historyPaths
        if !moved, selected == snapshot.selectedTreeItemID { return snapshot }
        var followed = snapshot
        followed.currentPath = currentPath
        followed.historyPaths = historyPaths
        followed.treeRootPath = treeRootPath
        followed.selectedTreeItemID = selected
        if currentPath != snapshot.currentPath { followed.view = nil }
        return followed
    }
}
