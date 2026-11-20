import CoreGraphics
import FTFileSystem
import FTFoundation
import FTOperations
import Foundation

/// What a tab had on screen: enough to show it again at once, before its folder is read again.
public struct TabViewState: Equatable, Sendable {
    public var treeNodes = TreeNodes()
    /// The read error on screen (`directoryError`): a new tab on the folder shows the same.
    public var directoryError: FolderReadError?
    public var contentSelection = ContentSelection.empty
    public var listFilterQuery = ""
    /// The typed filter's own mode, which a tab started from this one keeps; nil for none typed.
    public var listFilterMode: NameMatchMode?
    /// The pane's pinned filter, kept while the app runs (Duplicate Tab); never saved.
    public var pinnedListFilter: PinnedListFilter?
    public var contentScroll = CGPoint.zero
    public var treeScrollTop: Double = 0
    public var sidebarSectionsScrollTop: Double = 0
    /// How the folders in its history were left, for Back and Forward.
    public var folderViewMemories: FolderViewMemories = [:]

    public init() {}

    /// The view as a closed tab or pane comes back with it while it showed search results: the search isn't brought
    /// back, so the results' selection, filter and scroll go with it. The pinned filter and the places Back and
    /// Forward go back to stay.
    public func leavingSearchResults() -> TabViewState {
        var left = self
        left.contentSelection = .empty
        left.listFilterQuery = ""
        left.listFilterMode = nil
        left.contentScroll = .zero
        return left
    }
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
    /// The tab's second pane while it shows two, with its history; the fields above are its first pane's.
    public var secondPane: PaneSnapshot?
    /// The pane the tab has active: 1 for the second.
    public var activePane = 0
    /// The left pane's share of the room while it shows two.
    public var paneSplit: Double?
    /// The sizes its first pane shows its views at; the second pane's are with it.
    public var viewSizes: PaneViewSizes?
    /// How typing filters its first pane's folders; the second pane's is with it.
    public var filterMode: NameMatchMode?

    public init(
        currentPath: String, historyPaths: [String], historyIndex: Int, viewMode: ExplorerViewMode = .icons,
        searchViewMode: ExplorerViewMode = .details, sortBy: SortByPreference = .name,
        sortDirection: SortDirectionPreference = .asc, treeRootPath: String, selectedTreeItemID: String? = nil,
        leftPaneSubview: LeftPaneSubview = .tree, focusedPane: FocusedPane = .content, includeHidden: Bool = false,
        foldersFirst: Bool = true, favoritesExpanded: Bool = true, locationsExpanded: Bool = true,
        view: TabViewState? = nil
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
    }
}

/// A tab's second pane as a snapshot keeps it: how it shows its folder, its history, and what it had on screen.
public struct PaneSnapshot: Equatable, Sendable {
    public var pane: OpenPanePreference
    public var historyPaths: [String]
    public var historyIndex: Int
    /// Its selection, filters, scroll and the places Back and Forward go back to; nil for a pane whose folder is yet to
    /// be read. The tree's parts are the tab's, in the snapshot's own `view`, but for its scrolls, which a pane that
    /// is active puts back as it shows its first folder.
    public var view: TabViewState?

    public init(pane: OpenPanePreference, historyPaths: [String], historyIndex: Int, view: TabViewState? = nil) {
        self.pane = pane
        self.historyPaths = historyPaths
        self.historyIndex = historyIndex
        self.view = view
    }
}

/// A tab's label with what telling it apart from the others needs (the items of `ExplorerTabs.disambiguate`).
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

/// A file operation's result, as far as the windows' tabs look at it (`WriteOperationResult`).
public struct WriteOperationOutcome: Equatable, Sendable {
    public var action: WriteOperationAction
    /// For a paste, whether what it pasted was copied or cut.
    public var mode: CopyPasteMode?
    public var items: [WriteEffectItem]

    public init(action: WriteOperationAction, mode: CopyPasteMode?, items: [WriteEffectItem]) {
        self.action = action
        self.mode = mode
        self.items = items
    }

    /// Whether it gave items new paths: a rename or move, a paste that moved what was cut, or one that moved some
    /// items and copied others.
    public var movedItems: Bool {
        WriteEffects.movedItems(action, cut: mode == .cut, items: items)
    }
}

/// A file operation's progress, as every window hears it.
public struct WriteOperationProgress: Equatable, Sendable {
    public var status: WriteOperationStatus
    public var result: WriteOperationOutcome?

    public init(status: WriteOperationStatus, result: WriteOperationOutcome?) {
        self.status = status
        self.result = result
    }
}

public enum ExplorerTabs {
    /// How many closed tabs Reopen Closed Tab can bring back, most recent first.
    public static let closedTabsLimit = 10

    // MARK: Paths

    /// `parentDirectoryPath`: nil above `/`.
    public static func parentDirectoryPath(_ path: String) -> String? {
        if path == "/" { return nil }
        let parts = path.split(separator: "/")
        if parts.count <= 1 { return "/" }
        return "/" + parts.dropLast().joined(separator: "/")
    }

    /// `/Volumes/<name>` for a path on another disk, else `/`.
    public static func volumeRootPath(_ path: String) -> String {
        let prefix = "/Volumes/"
        guard path.hasPrefix(prefix) else { return "/" }
        let name = path.dropFirst(prefix.count).prefix { $0 != "/" }
        return name.isEmpty ? "/" : prefix + name
    }

    /// The startup disk's name for `/`, "Trash" for a Trash folder.
    public static func folderDisplayName(
        _ path: String, homePath: String, startupDiskName: String = VolumePaths.defaultStartupDiskName
    ) -> String {
        TabText.folderDisplayName(path, homePath: homePath, startupDiskName: startupDiskName)
    }

    /// `path` and the folders above it, nearest first: where a tab goes when its folder is gone.
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

    /// Its folder, or its search while results are showing.
    public static func describe(
        currentPath: String, searchVisible: Bool, searchQuery: String, searchRootPath: String, searchRunning: Bool,
        homePath: String, startupDiskName: String = VolumePaths.defaultStartupDiskName
    ) -> TabDescription {
        TabText.describe(
            currentPath: currentPath, searchVisible: searchVisible, searchQuery: searchQuery,
            searchRootPath: searchRootPath, searchRunning: searchRunning, homePath: homePath,
            startupDiskName: startupDiskName)
    }

    /// Tabs on folders with the same name are told apart by the folder each one is in. Tabs
    /// on the same folder, and search tabs, keep their labels.
    public static func disambiguate(
        _ items: [TabLabel], homePath: String, startupDiskName: String = VolumePaths.defaultStartupDiskName
    ) -> [TabLabel] {
        items.enumerated().map { index, item in
            guard item.kind == .folder else { return item }
            let clashes = items.enumerated().contains { otherIndex, other in
                otherIndex != index && other.kind == .folder && other.label == item.label && other.path != item.path
            }
            guard clashes, let parent = parentDirectoryPath(item.path) else { return item }
            var labelled = item
            let parentName = folderDisplayName(parent, homePath: homePath, startupDiskName: startupDiskName)
            labelled.label = "\(item.label) — \(parentName)"
            return labelled
        }
    }

    // MARK: The row of tabs

    /// The tab that takes over when `closed` closes: the one to its right, or to its left when
    /// it was last.
    public static func tabAfterClose<ID: Equatable>(_ tabs: [ID], closing closed: ID) -> ID? {
        guard let index = tabs.firstIndex(of: closed) else { return nil }
        if tabs.indices.contains(index + 1) { return tabs[index + 1] }
        return index > 0 ? tabs[index - 1] : nil
    }

    public enum Direction: Sendable { case next, previous }

    /// The next or previous tab, wrapping around at the ends.
    public static func adjacentTab<ID: Equatable>(_ tabs: [ID], active: ID, _ direction: Direction) -> ID? {
        guard tabs.count >= 2, let index = tabs.firstIndex(of: active) else { return nil }
        let step = direction == .next ? 1 : -1
        return tabs[(index + step + tabs.count) % tabs.count]
    }

    // MARK: Snapshots

    /// `settleTreeNodes`: a tree saved in the middle of loading a folder would wait for that answer for ever, since
    /// the answer went to the tab that was on screen then.
    public static func settleTreeNodes(_ nodes: TreeNodes) -> TreeNodes {
        TreeNodes(
            nodes.all.map { node in
                var settled = node
                settled.loading = false
                return settled
            })
    }

    /// The tab a new one starts as: the same folder and tree, a history of its own, nothing selected or
    /// typed, the list at the top, no memories and no search. It has one pane, on the active pane's folder and shown
    /// as that pane shows it.
    public static func newTab(from snapshot: TabSnapshot) -> TabSnapshot {
        var new = snapshot
        if snapshot.activePane == 1, let second = snapshot.secondPane?.pane {
            new.currentPath = second.path ?? ""
            new.viewMode = second.viewMode
            new.searchViewMode = second.searchViewMode
            new.sortBy = second.sortBy
            new.sortDirection = second.sortDirection
            new.includeHidden = second.includeHidden
            new.foldersFirst = second.foldersFirst
            new.viewSizes = second.viewSizes
            // What the first pane had on screen isn't this folder's.
            new.view?.directoryError = nil
        }
        // Its pane is a new one: it starts with the filter mode chosen last.
        new.filterMode = nil
        new.secondPane = nil
        new.activePane = 0
        new.paneSplit = nil
        new.historyPaths = new.currentPath.isEmpty ? [] : [new.currentPath]
        new.historyIndex = new.currentPath.isEmpty ? -1 : 0
        new.view?.contentSelection = .empty
        new.view?.listFilterQuery = ""
        new.view?.listFilterMode = nil
        new.view?.pinnedListFilter = nil
        new.view?.contentScroll = .zero
        new.view?.folderViewMemories = [:]
        return new
    }

    /// What is kept of a closed tab: all of it, its panes' history, selection, filters and scroll among them, but for
    /// the error that was on screen, as its folders are read again. Its search isn't in the snapshot (`closedSnapshot`).
    public static func reopenable(_ snapshot: TabSnapshot) -> TabSnapshot {
        var kept = snapshot
        kept.view?.directoryError = nil
        kept.secondPane?.view?.directoryError = nil
        return kept
    }

    /// `leaveUnmountedDisks`: a background tab on a disk that was unmounted goes Home, as the tab on screen does.
    /// Each of its panes on the disk does; one on another disk stays where it is. The tree goes Home with the active
    /// pane, or when its own root was on the disk. `volumeRoot` says which disk a path is on.
    public static func leaveUnmountedDisks(
        _ snapshot: TabSnapshot, unmounted: Set<String>, homePath: String,
        volumeRoot: (String) -> String = volumeRootPath
    ) -> TabSnapshot {
        func isGone(_ path: String) -> Bool { !path.isEmpty && unmounted.contains(volumeRoot(path)) }
        let second = snapshot.secondPane
        let rootGone = isGone(snapshot.treeRootPath)
        let firstGone = isGone(snapshot.currentPath)
        let secondGone = second?.pane.path.map(isGone) ?? false
        guard firstGone || secondGone || rootGone else { return snapshot }
        var left = snapshot
        if firstGone {
            left.historyPaths = snapshot.historyPaths.filter { !isGone($0) } + [homePath]
            left.currentPath = homePath
            left.historyIndex = left.historyPaths.count - 1
            left.view = nil
        }
        if secondGone, let second {
            let history = second.historyPaths.filter { !isGone($0) } + [homePath]
            left.secondPane?.pane.path = homePath
            left.secondPane?.historyPaths = history
            left.secondPane?.historyIndex = history.count - 1
            left.secondPane?.view = nil
        }
        let secondIsActive = snapshot.activePane == 1 && second != nil
        if rootGone || (secondIsActive ? secondGone : firstGone) {
            let active = secondIsActive ? left.secondPane?.pane.path ?? "" : left.currentPath
            left.treeRootPath = homePath
            left.selectedTreeItemID = active.isEmpty ? nil : "fs:\(active)"
            left.leftPaneSubview = .tree
        }
        return left
    }

    /// `followMovedPath`: where `path` is after `moves`. The deepest move that holds it decides.
    public static func followMovedPath(_ path: String, _ moves: [PathMove]) -> String {
        // Compared by UTF-16 unit, not by canonical equivalence.
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

    /// `collectFollowedMoves`: where the operation took each item that really moved (`WriteEffects.followedMoves`).
    public static func collectFollowedMoves(_ action: WriteOperationAction, items: [some WrittenItem]) -> [PathMove] {
        WriteEffects.followedMoves(action, items: items).map { PathMove(from: $0.from, to: $0.to) }
    }

    /// The moves a window's tabs follow on hearing `event`: none until the operation has ended, and only from one that
    /// moved items.
    public static func followedMoves(_ event: WriteOperationProgress) -> [PathMove] {
        guard event.status.isTerminal, let result = event.result, result.movedItems else { return [] }
        return collectFollowedMoves(result.action, items: result.items)
    }

    /// `followMovedItems`: a background tab on a folder that was renamed or moved follows it, as a Finder window does,
    /// in each of its panes. Its listing is read again, at the new place, when it is shown.
    public static func followMovedItems(_ snapshot: TabSnapshot, _ moves: [PathMove]) -> TabSnapshot {
        let currentPath = followMovedPath(snapshot.currentPath, moves)
        let historyPaths = snapshot.historyPaths.map { followMovedPath($0, moves) }
        let treeRootPath = followMovedPath(snapshot.treeRootPath, moves)
        var selected = snapshot.selectedTreeItemID
        if let item = selected, item.hasPrefix("fs:") {
            selected = "fs:" + followMovedPath(String(item.dropFirst(3)), moves)
        }
        var secondPane = snapshot.secondPane
        if let second = snapshot.secondPane {
            secondPane?.pane.path = second.pane.path.map { followMovedPath($0, moves) }
            secondPane?.historyPaths = second.historyPaths.map { followMovedPath($0, moves) }
            if secondPane?.pane.path != second.pane.path { secondPane?.view = nil }
        }
        let moved =
            currentPath != snapshot.currentPath || treeRootPath != snapshot.treeRootPath
            || historyPaths != snapshot.historyPaths || secondPane != snapshot.secondPane
        if !moved, selected == snapshot.selectedTreeItemID { return snapshot }
        var followed = snapshot
        followed.currentPath = currentPath
        followed.historyPaths = historyPaths
        followed.treeRootPath = treeRootPath
        followed.selectedTreeItemID = selected
        followed.secondPane = secondPane
        if currentPath != snapshot.currentPath { followed.view = nil }
        return followed
    }
}
