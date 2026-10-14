// Port of the sidebar keyboard of apps/desktop/src/renderer/hooks/useExplorerNavigationController.ts (handleTreeKeyboardAction, openTreeNode,
// navigateTreeSelectionToParent, handleTypeaheadInput, the tree branch of the page move) and getPageStepLineCount/getPagedLineMove of lib/explorerNavigation.ts
import Foundation

/// The sidebar has two lists when Favorites are in their own section: the favorites (with the open Locations below
/// them) and the folder tree. In the integrated layout everything is in the tree.
public enum SidebarSubview: String, Sendable, Hashable {
    case favorites, tree
}

/// What the keyboard decisions look at.
public struct SidebarKeyContext: Sendable {
    /// `favoritesPlacement === "separate"`.
    public var separate: Bool
    public var subview: SidebarSubview
    public var selected: TreeItemID?
    /// `getFavoriteItemIds`: the favorites, then the Locations when they are open, with the labels they carry.
    public var favoriteList: [(id: TreeItemID, label: String)]
    /// The tree's rows (`getTreePresentationState`): the filesystem alone in the separate layout.
    public var presentation: TreePresentation
    public var nodes: TreeNodes
    public var rootPath: String

    public init(
        separate: Bool, subview: SidebarSubview, selected: TreeItemID?,
        favoriteList: [(id: TreeItemID, label: String)], presentation: TreePresentation, nodes: TreeNodes,
        rootPath: String
    ) {
        self.separate = separate
        self.subview = subview
        self.selected = selected
        self.favoriteList = favoriteList
        self.presentation = presentation
        self.nodes = nodes
        self.rootPath = rootPath
    }

    /// The separate Favorites list has the keyboard.
    public var favoritesListActive: Bool { separate && subview == .favorites }
}

/// What a key does in the sidebar.
public enum SidebarKeyAction: Equatable, Sendable {
    /// Nothing: the key is not taken.
    case none
    /// Selects the row and opens its folder (history push), first switching to `subview` when given.
    case select(TreeItemID, subview: SidebarSubview?)
    /// Reads the folder's children and expands it.
    case load(path: String)
    /// Opens or closes the folder's branch.
    case toggle(path: String)
}

public enum SidebarKeyboard {
    public static let typeaheadResetMilliseconds = 1000

    /// `handleTreeKeyboardAction`.
    public static func decide(_ key: TreeView.Key, _ context: SidebarKeyContext) -> SidebarKeyAction {
        if context.favoritesListActive {
            return decideInFavorites(key, context)
        }
        // The arrow keys go past the Favorites and Locations headings, as in Finder's sidebar.
        let visible = context.presentation.visibleItemIDs.filter { !$0.isHeading }
        if visible.isEmpty {
            if context.separate, context.subview == .tree, key == .up, let last = context.favoriteList.last {
                return .select(last.id, subview: .favorites)
            }
            return .none
        }
        let currentIndex = context.selected.flatMap { selected in visible.firstIndex(of: selected) }
        guard let safeCurrent = currentIndex != nil ? context.selected : visible.first,
            context.presentation.items[safeCurrent] != nil
        else { return .none }

        switch key {
        case .home:
            return .select(visible[0], subview: nil)
        case .end:
            return .select(visible[visible.count - 1], subview: nil)
        case .up, .down:
            let base = currentIndex ?? 0
            if context.separate, context.subview == .tree, key == .up, base == 0,
                let last = context.favoriteList.last
            {
                return .select(last.id, subview: .favorites)
            }
            let next = key == .up ? max(0, base - 1) : min(visible.count - 1, base + 1)
            return .select(visible[next], subview: nil)
        case .right:
            if safeCurrent.favoritePath != nil || safeCurrent.locationPath != nil { return .none }
            guard let path = safeCurrent.filesystemPath, let node = context.nodes[path], !node.isSymlink else {
                return .none
            }
            if !node.loaded { return .load(path: path) }
            if !node.expanded, !node.childPaths.isEmpty { return .toggle(path: path) }
            if node.expanded, let first = node.childPaths.first { return .select(.filesystem(first), subview: nil) }
            return .none
        case .left:
            // A favorite or a location has nothing above it to go to.
            if safeCurrent.favoritePath != nil || safeCurrent.locationPath != nil { return .none }
            guard let path = safeCurrent.filesystemPath, let node = context.nodes[path] else { return .none }
            if node.expanded, !node.childPaths.isEmpty { return .toggle(path: path) }
            // The top of the tree, or of a disk: there is nothing above it to go to.
            if JSString.equals(path, context.rootPath) || isVolumeRoot(path) { return .none }
            guard let parent = TreePaths.parent(of: path), !JSString.equals(parent, path) else { return .none }
            return .select(.filesystem(parent), subview: nil)
        }
    }

    private static func decideInFavorites(_ key: TreeView.Key, _ context: SidebarKeyContext) -> SidebarKeyAction {
        let ids = context.favoriteList.map(\.id)
        if ids.isEmpty { return .none }
        let currentIndex = context.selected.flatMap { selected in ids.firstIndex(of: selected) }
        let safe = currentIndex ?? 0
        switch key {
        case .home: return .select(ids[0], subview: nil)
        case .end: return .select(ids[ids.count - 1], subview: nil)
        case .left, .right: return .none
        case .up:
            return safe - 1 >= 0 ? .select(ids[safe - 1], subview: nil) : .none
        case .down:
            if safe + 1 < ids.count { return .select(ids[safe + 1], subview: nil) }
            // Down from the last row goes into the tree, to its top.
            guard let first = context.presentation.visibleItemIDs.first else { return .none }
            return .select(first, subview: .tree)
        }
    }

    /// `openTreeNode` (Return, and Cmd+Down): what opening the selected row does.
    public static func decideOpen(_ context: SidebarKeyContext) -> SidebarKeyAction {
        guard let current = context.selected else { return .none }
        if context.favoritesListActive {
            return current.shortcutPath != nil ? .select(current, subview: nil) : .none
        }
        if current.isHeading { return .none }
        if current.shortcutPath != nil { return .select(current, subview: nil) }
        guard let path = current.filesystemPath, let node = context.nodes[path] else { return .none }
        // A link to a folder opens its folder without expanding or reading it.
        if node.isSymlink { return .select(current, subview: nil) }
        if !node.loaded { return .load(path: path) }
        return .toggle(path: path)
    }

    /// `navigateTreeSelectionToParent` (Cmd+Up): the parent folder's row of the selected folder.
    public static func decideParent(_ context: SidebarKeyContext) -> SidebarKeyAction {
        if context.favoritesListActive { return .none }
        guard let current = context.selected, current.favoritePath == nil, current.locationPath == nil,
            let path = current.filesystemPath, !isVolumeRoot(path),
            let parent = TreePaths.parent(of: path), !JSString.equals(parent, path)
        else { return .none }
        return .select(.filesystem(parent), subview: nil)
    }

    /// `isVolumeRootPath`.
    static func isVolumeRoot(_ path: String) -> Bool {
        JSString.equals(TreePaths.volumeRootPath(path), path)
    }

    // MARK: Type to select

    /// `handleTypeaheadInput`: the first row whose label starts with what was typed, case aside. In the separate
    /// layout's Favorites list the candidates are the favorites and the open Locations; otherwise the visible tree
    /// rows, headings included (a prefix whose first match is a heading selects nothing). Nil when none matches.
    public static func typeaheadMatch(_ query: String, _ context: SidebarKeyContext) -> TreeItemID? {
        let normalized = JSString.lowercased(JSString.trimmed(query))
        if normalized.isEmpty { return nil }
        if context.favoritesListActive {
            return context.favoriteList.first { JSString.hasPrefix(JSString.lowercased($0.label), normalized) }?.id
        }
        return context.presentation.visibleItemIDs.first { id in
            JSString.hasPrefix(JSString.lowercased(context.presentation.items[id]?.label ?? ""), normalized)
        }
    }

    // MARK: Paging

    public enum PageSize: Sendable { case half, full }

    /// `getPageStepLineCount`: a full page is one row less than fit on screen, so the last one stays in view; half a
    /// page is half of those that fit.
    public static func pageStepLines(viewportHeight: Double, rowHeight: Double, size: PageSize) -> Int {
        let visible = max(1, Int((max(0, viewportHeight) / max(1, rowHeight)).rounded(.down)))
        return max(1, size == .full ? visible - 1 : visible / 2)
    }

    /// The row a page move lands on (`getPagedLineMove` over the rows the arrow keys reach), or nil when it would not
    /// move (the key is then not taken).
    public static func pageTarget(
        forward: Bool, lines: Int, _ context: SidebarKeyContext
    ) -> TreeItemID? {
        let ids =
            context.favoritesListActive
            ? context.favoriteList.map(\.id) : context.presentation.visibleItemIDs.filter { !$0.isHeading }
        if ids.isEmpty { return nil }
        let currentIndex = context.selected.flatMap { selected in ids.firstIndex(of: selected) } ?? -1
        let from = max(0, currentIndex)
        let step = max(1, lines)
        let index = min(max(0, forward ? from + step : from - step), ids.count - 1)
        let target = ids[index]
        return target == context.selected ? nil : target
    }
}
