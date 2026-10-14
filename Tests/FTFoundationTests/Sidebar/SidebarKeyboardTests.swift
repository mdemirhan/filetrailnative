// The sidebar's keyboard as decisions: apps/desktop/src/renderer/hooks/useExplorerNavigationController.ts (B-TREE-106..136)
// and the cases of App.treeKeys.test.tsx that depend on it
import Testing

@testable import FTFoundation

struct SidebarKeyboardTests {
    static let home = "/Users/demo"

    private func node(
        _ path: String, expanded: Bool = false, loaded: Bool = false, children: [String] = [], alias: Bool = false
    )
        -> TreeNodeState
    {
        var node = TreeNodeState(path: path, name: String(path.split(separator: "/").last ?? "/"), expanded: expanded)
        node.loaded = loaded
        node.childPaths = children
        node.isSymlink = alias
        return node
    }

    private var nodes: TreeNodes {
        TreeNodes([
            node(
                "/Users/demo", expanded: true, loaded: true,
                children: ["/Users/demo/a", "/Users/demo/b", "/Users/demo/link"]),
            node("/Users/demo/a", expanded: true, loaded: true, children: ["/Users/demo/a/deep"]),
            node("/Users/demo/a/deep", loaded: true),
            node("/Users/demo/b"),
            node("/Users/demo/link", alias: true),
        ])
    }

    private let favorites = [
        FavoritePreference(path: "/Applications", icon: .applications),
        FavoritePreference(path: "/Users/demo/Desktop", icon: .desktop),
    ]

    private func context(
        separate: Bool, subview: SidebarSubview = .tree, selected: TreeItemID?, locationsOpen: Bool = true,
        nodes override: TreeNodes? = nil
    ) -> SidebarKeyContext {
        let nodes = override ?? self.nodes
        let locations = Favorites.locations(volumes: [], homePath: Self.home)
        let list =
            favorites.map {
                (id: TreeItemID.favorite($0.path), label: FavoriteLabel.label(for: $0.path, homePath: Self.home))
            }
            + (locationsOpen ? locations.map { (id: TreeItemID.location($0.path), label: $0.label) } : [])
        let presentation = Favorites.presentation(
            .init(
                favorites: favorites, favoritesExpanded: true, homePath: Self.home, rootPath: Self.home, nodes: nodes,
                includeFavorites: !separate, locations: locations, locationsExpanded: true))
        return SidebarKeyContext(
            separate: separate, subview: subview, selected: selected, favoriteList: list, presentation: presentation,
            nodes: nodes, rootPath: Self.home)
    }

    // T-9f474d2b T-b523bf72 F-740 B-TREE-107 B-TREE-108
    @Test func movesThroughTheRowsAndSkipsTheHeadings() {
        // Integrated: the first row is the first favorite, never the heading.
        let top = context(separate: false, selected: .favorite("/Applications"))
        #expect(SidebarKeyboard.decide(.up, top) == .select(.favorite("/Applications"), subview: nil))
        #expect(SidebarKeyboard.decide(.home, top) == .select(.favorite("/Applications"), subview: nil))
        #expect(SidebarKeyboard.decide(.down, top) == .select(.favorite("/Users/demo/Desktop"), subview: nil))
        // From the last favorite, down goes past the Locations heading to the first location.
        let last = context(separate: false, selected: .favorite("/Users/demo/Desktop"))
        #expect(SidebarKeyboard.decide(.down, last) == .select(.location("/Users/demo"), subview: nil))
        #expect(SidebarKeyboard.decide(.end, last) == .select(.filesystem("/Users/demo/link"), subview: nil))
        // Clamped at the last row.
        let end = context(separate: false, selected: .filesystem("/Users/demo/link"))
        #expect(SidebarKeyboard.decide(.down, end) == .select(.filesystem("/Users/demo/link"), subview: nil))
    }

    // T-1389208f B-TREE-109
    @Test func withNothingSelectedDownTakesTheSecondRowAndUpTheFirst() {
        let none = context(separate: false, selected: nil)
        #expect(SidebarKeyboard.decide(.down, none) == .select(.favorite("/Users/demo/Desktop"), subview: nil))
        #expect(SidebarKeyboard.decide(.up, none) == .select(.favorite("/Applications"), subview: nil))
        // Separate: Up from nothing in the tree goes to the last favorite or open location.
        let separate = context(separate: true, selected: nil)
        #expect(SidebarKeyboard.decide(.up, separate) == .select(.location("/Users/demo/.Trash"), subview: .favorites))
    }

    // T-fc0da8c2 T-eaf07a43 T-05d06d43 T-6625a938 F-740 B-TREE-111 B-TREE-113
    @Test func opensABranchWithRightGoesIntoItAndComesBackOutWithLeft() {
        let tree = context(separate: true, selected: .filesystem("/Users/demo/b"))
        // Never read: read and expand, the selection stays.
        #expect(SidebarKeyboard.decide(.right, tree) == .load(path: "/Users/demo/b"))
        // Expanded with children: into the first subfolder.
        let expanded = context(separate: true, selected: .filesystem("/Users/demo/a"))
        #expect(SidebarKeyboard.decide(.right, expanded) == .select(.filesystem("/Users/demo/a/deep"), subview: nil))
        // Left on an expanded branch closes it; otherwise it goes to the parent.
        #expect(SidebarKeyboard.decide(.left, expanded) == .toggle(path: "/Users/demo/a"))
        let deep = context(separate: true, selected: .filesystem("/Users/demo/a/deep"))
        #expect(SidebarKeyboard.decide(.left, deep) == .select(.filesystem("/Users/demo/a"), subview: nil))
        // The top of the tree has nothing above it; an alias never expands.
        let root = context(separate: true, selected: .filesystem("/Users/demo"))
        var closedNodes = nodes
        closedNodes["/Users/demo"]?.expanded = false
        let closedRoot = context(separate: true, selected: .filesystem("/Users/demo"), nodes: closedNodes)
        #expect(SidebarKeyboard.decide(.left, root) == .toggle(path: "/Users/demo"))
        #expect(SidebarKeyboard.decide(.left, closedRoot) == .none)
        let alias = context(separate: true, selected: .filesystem("/Users/demo/link"))
        #expect(SidebarKeyboard.decide(.right, alias) == .none)
        // A loaded folder without subfolders does nothing.
        let leaf = context(separate: true, selected: .filesystem("/Users/demo/a/deep"))
        #expect(SidebarKeyboard.decide(.right, leaf) == .none)
        // A collapsed folder with subfolders expands without a read.
        var collapsed = nodes
        collapsed["/Users/demo/a"]?.expanded = false
        let closed = context(separate: true, selected: .filesystem("/Users/demo/a"), nodes: collapsed)
        #expect(SidebarKeyboard.decide(.right, closed) == .toggle(path: "/Users/demo/a"))
    }

    // T-12edaacc B-TREE-112 B-TREE-114 B-TREE-125
    @Test func leftAndRightDoNothingOnAFavoriteOrALocation() {
        for selected in [TreeItemID.favorite("/Applications"), .location("/")] {
            let integrated = context(separate: false, selected: selected)
            #expect(SidebarKeyboard.decide(.left, integrated) == .none)
            #expect(SidebarKeyboard.decide(.right, integrated) == .none)
            let list = context(separate: true, subview: .favorites, selected: selected)
            #expect(SidebarKeyboard.decide(.left, list) == .none)
            #expect(SidebarKeyboard.decide(.right, list) == .none)
        }
    }

    // T-12edaacc T-0be11137 T-06c248dd B-TREE-122 B-TREE-123 B-TREE-124
    @Test func goesUpFromTheTopOfTheTreeIntoFavoritesAndDownAgain() {
        // Up from the top row of the tree: the last favorite or open location.
        let top = context(separate: true, selected: .filesystem("/Users/demo"))
        #expect(SidebarKeyboard.decide(.up, top) == .select(.location("/Users/demo/.Trash"), subview: .favorites))
        let closed = context(separate: true, selected: .filesystem("/Users/demo"), locationsOpen: false)
        #expect(SidebarKeyboard.decide(.up, closed) == .select(.favorite("/Users/demo/Desktop"), subview: .favorites))
        // Down from the last row of the list: the tree's top row.
        let last = context(separate: true, subview: .favorites, selected: .location("/Users/demo/.Trash"))
        #expect(SidebarKeyboard.decide(.down, last) == .select(.filesystem("/Users/demo"), subview: .tree))
        // Through the favorites and then the disks, one list; Home and End jump to its ends; Up stops at the first.
        let first = context(separate: true, subview: .favorites, selected: .favorite("/Applications"))
        #expect(SidebarKeyboard.decide(.up, first) == .none)
        #expect(SidebarKeyboard.decide(.down, first) == .select(.favorite("/Users/demo/Desktop"), subview: nil))
        let desktop = context(separate: true, subview: .favorites, selected: .favorite("/Users/demo/Desktop"))
        #expect(SidebarKeyboard.decide(.down, desktop) == .select(.location("/Users/demo"), subview: nil))
        #expect(SidebarKeyboard.decide(.home, desktop) == .select(.favorite("/Applications"), subview: nil))
        #expect(SidebarKeyboard.decide(.end, desktop) == .select(.location("/Users/demo/.Trash"), subview: nil))
    }

    // T-1389208f B-TREE-123
    @Test func goesUpIntoFavoritesFromAnEmptyTree() {
        let empty = context(separate: true, selected: nil, nodes: TreeNodes())
        #expect(SidebarKeyboard.decide(.up, empty) == .select(.location("/Users/demo/.Trash"), subview: .favorites))
        #expect(SidebarKeyboard.decide(.down, empty) == .none)
    }

    // T-7ff56dd9 T-1a68f61e T-5ccadc2f F-740 B-TREE-115 B-TREE-116
    @Test func returnOpensAFavoriteAgainReadsAnUnreadFolderAndTogglesTheOthers() {
        let favorite = context(separate: false, selected: .favorite("/Applications"))
        #expect(SidebarKeyboard.decideOpen(favorite) == .select(.favorite("/Applications"), subview: nil))
        #expect(
            SidebarKeyboard.decideOpen(context(separate: false, selected: .filesystem("/Users/demo/b")))
                == .load(path: "/Users/demo/b"))
        #expect(
            SidebarKeyboard.decideOpen(context(separate: false, selected: .filesystem("/Users/demo/a")))
                == .toggle(path: "/Users/demo/a"))
        // A link to a folder opens its folder, without expanding or reading it.
        #expect(
            SidebarKeyboard.decideOpen(context(separate: false, selected: .filesystem("/Users/demo/link")))
                == .select(.filesystem("/Users/demo/link"), subview: nil))
        // Headings do nothing; in the Favorites list only a favorite or a location opens.
        #expect(SidebarKeyboard.decideOpen(context(separate: false, selected: .favoritesRoot)) == .none)
        #expect(
            SidebarKeyboard.decideOpen(
                context(separate: true, subview: .favorites, selected: .filesystem("/Users/demo/a"))) == .none)
        #expect(SidebarKeyboard.decideOpen(context(separate: false, selected: nil)) == .none)
    }

    // T-5acdef9e T-0b507270 T-5ccadc2f B-TREE-117
    @Test func commandUpSelectsTheParentFolderButNotForAFavoriteALocationOrADiskRoot() {
        #expect(
            SidebarKeyboard.decideParent(context(separate: false, selected: .filesystem("/Users/demo/a")))
                == .select(.filesystem("/Users/demo"), subview: nil))
        #expect(
            SidebarKeyboard.decideParent(context(separate: false, selected: .filesystem("/Users/demo")))
                == .select(.filesystem("/Users"), subview: nil))
        #expect(SidebarKeyboard.decideParent(context(separate: false, selected: .favorite("/Applications"))) == .none)
        #expect(SidebarKeyboard.decideParent(context(separate: false, selected: .location("/"))) == .none)
        #expect(SidebarKeyboard.decideParent(context(separate: false, selected: .filesystem("/"))) == .none)
        #expect(
            SidebarKeyboard.decideParent(context(separate: false, selected: .filesystem("/Volumes/Backup"))) == .none)
        #expect(
            SidebarKeyboard.decideParent(
                context(separate: true, subview: .favorites, selected: .filesystem("/Users/demo/a"))) == .none)
    }

    // T-e976a231 T-faee0026 T-df5c84b6 B-TREE-130 B-TREE-131 B-TREE-132
    @Test func selectsTheFirstRowWhoseNameStartsWithWhatIsTyped() {
        let integrated = context(separate: false, selected: nil)
        #expect(SidebarKeyboard.typeaheadMatch("des", integrated) == .favorite("/Users/demo/Desktop"))
        #expect(SidebarKeyboard.typeaheadMatch("DESK", integrated) == .favorite("/Users/demo/Desktop"))
        #expect(SidebarKeyboard.typeaheadMatch("zzz", integrated) == nil)
        // A heading is a candidate by its label: it is found, and selecting it does nothing.
        #expect(SidebarKeyboard.typeaheadMatch("fav", integrated) == .favoritesRoot)
        #expect(SidebarKeyboard.typeaheadMatch("loc", integrated) == .locationsRoot)
        // Nothing typed: nothing.
        #expect(SidebarKeyboard.typeaheadMatch("  ", integrated) == nil)
        // The favorites list: favorites, then open locations, by label.
        let list = context(separate: true, subview: .favorites, selected: nil)
        #expect(SidebarKeyboard.typeaheadMatch("app", list) == .favorite("/Applications"))
        #expect(SidebarKeyboard.typeaheadMatch("mac", list) == .location("/"))
        #expect(SidebarKeyboard.typeaheadMatch("t", list) == .location("/Users/demo/.Trash"))
        // The tree: the visible rows of the filesystem.
        let tree = context(separate: true, selected: nil)
        #expect(SidebarKeyboard.typeaheadMatch("b", tree) == .filesystem("/Users/demo/b"))
        #expect(SidebarKeyboard.typeaheadMatch("deep", tree) == .filesystem("/Users/demo/a/deep"))
    }

    // T-13ea5c0d T-0782664c T-d651771b T-d5a14beb F-733 B-TREE-134 B-TREE-135
    @Test func pagesByTheRowsOnScreenAndStopsAtTheEnds() {
        // rows on screen = floor(height / row height); a page is one less, half a page half of them, at least 1.
        let regular = DesignTokens.explorer(density: .comfortable).treeRowHeight
        let compact = DesignTokens.explorer(density: .compact).treeRowHeight
        #expect(regular == 26)
        #expect(compact == 21)
        #expect(SidebarKeyboard.pageStepLines(viewportHeight: 520, rowHeight: regular, size: .full) == 19)
        #expect(SidebarKeyboard.pageStepLines(viewportHeight: 520, rowHeight: regular, size: .half) == 10)
        #expect(SidebarKeyboard.pageStepLines(viewportHeight: 520, rowHeight: compact, size: .full) == 23)
        #expect(SidebarKeyboard.pageStepLines(viewportHeight: 520, rowHeight: compact, size: .half) == 12)
        #expect(SidebarKeyboard.pageStepLines(viewportHeight: 10, rowHeight: regular, size: .full) == 1)
        #expect(SidebarKeyboard.pageStepLines(viewportHeight: 30, rowHeight: regular, size: .half) == 1)
        #expect(SidebarKeyboard.pageStepLines(viewportHeight: 0, rowHeight: regular, size: .full) == 1)

        // The page works on the rows the arrow keys reach (headings are skipped).
        let integrated = context(separate: false, selected: .favorite("/Applications"))
        #expect(SidebarKeyboard.pageTarget(forward: true, lines: 2, integrated) == .location("/Users/demo"))
        #expect(SidebarKeyboard.pageTarget(forward: false, lines: 2, integrated) == nil)
        let bottom = context(separate: false, selected: .filesystem("/Users/demo/link"))
        #expect(SidebarKeyboard.pageTarget(forward: true, lines: 5, bottom) == nil)
        #expect(SidebarKeyboard.pageTarget(forward: false, lines: 100, bottom) == .favorite("/Applications"))
        // With nothing selected a page down starts from the first row.
        let none = context(separate: false, selected: nil)
        #expect(SidebarKeyboard.pageTarget(forward: true, lines: 1, none) == .favorite("/Users/demo/Desktop"))
        // The favorites list pages through the favorites and the open locations.
        let list = context(separate: true, subview: .favorites, selected: .favorite("/Applications"))
        #expect(SidebarKeyboard.pageTarget(forward: true, lines: 3, list) == .location("/"))
    }
}
