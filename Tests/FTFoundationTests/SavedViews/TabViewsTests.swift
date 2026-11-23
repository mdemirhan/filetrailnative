// Checks the tab views' rules: what is read back of them, what makes sense of their parts, and applying one to a tab
import Foundation
import Testing

@testable import FTFoundation

struct TabViewsTests {
    static func pane(_ folder: String?, view: ExplorerViewMode = .icons) -> PaneState {
        var settings = PaneViewResolutionGoldenTests.carried
        settings.view = view
        return PaneState(folder: folder, settings: settings)
    }

    static func tab(_ folders: [String], active: Int = 0, closed: String? = nil) -> TabState {
        TabState(panes: folders.map { pane($0) }, active: active, closedPane: closed.map { pane($0, view: .previews) })
    }

    static func apply(_ keeps: TabViewKeeps, _ tab: TabState, width: Double = 1009) -> TabViewApplied {
        TabViews.applying(keeps, to: tab, columnWidth: width)
    }

    // MARK: Reading and writing

    @Test func everyPartIsReadBackAsWritten() throws {
        let keeps = TabViewKeeps(
            panes: 2, divider: .share(0.62), includeHidden: true,
            left: PaneKeeps(folder: "/u/a", view: FolderViewKeeps(view: .details), folderViews: .tabViewFirst),
            right: PaneKeeps(
                view: FolderViewKeeps(sort: FolderViewSort(by: .modified, direction: .desc)),
                folderViews: .notUsed))
        let view = TabView(id: "tab-1", name: "Compare", keeps: keeps)
        let node = try JSONNode.of([view])
        #expect(TabViews.sanitize(node) == [view])
        for divider: TabViewKeeps.Divider in [.even, .share(0.3), .leftWidth(420)] {
            var other = keeps
            other.divider = divider
            #expect(try JSONNode.of(other).decode(TabViewKeeps.self) == other)
        }
    }

    @Test func folderFirstAndNothingKeptAreNotWritten() throws {
        let keeps = TabViewKeeps(pane: PaneKeeps(view: FolderViewKeeps(view: .details), folderViews: .folderFirst))
        let pane = try #require(try JSONNode.of(keeps).object?["pane"]?.object)
        #expect(pane["folderViews"] == nil)
        #expect(pane["folder"] == nil)
    }

    @Test func partsThatMakeNoSenseTogetherAreDropped() {
        let side = PaneKeeps(view: FolderViewKeeps(view: .details))
        // A divider, a left and a right only with two panes; a pane only without.
        let one = TabViewKeeps(panes: 1, divider: .even, left: side, right: side, pane: side)
        #expect(one.divider == nil && one.left == nil && one.right == nil && one.pane == side)
        let two = TabViewKeeps(panes: 2, divider: .even, left: side, pane: side)
        #expect(two.divider == .even && two.left == side && two.pane == nil)
        // A count of panes other than one or two is not kept, and what goes with two goes with it.
        let three = TabViewKeeps(panes: 3, divider: .even, left: side, pane: side)
        #expect(three.panes == nil && three.divider == nil && three.left == nil && three.pane == side)
        // A pane that keeps nothing is not kept.
        #expect(TabViewKeeps(pane: PaneKeeps()).pane == nil)
        #expect(TabViewKeeps(pane: PaneKeeps()).isEmpty)
    }

    // Any pane can open the viewer and keep the rest for the list behind it: one pane, either of two, or both.
    @Test func anyPaneOpensTheViewer() throws {
        let both = TabViewKeeps(
            panes: 2, left: PaneKeeps(opensViewer: true, viewerEditing: true),
            right: PaneKeeps(view: FolderViewKeeps(view: .details), opensViewer: true))
        #expect(both.left == PaneKeeps(opensViewer: true, viewerEditing: true))
        #expect(both.right == PaneKeeps(view: FolderViewKeeps(view: .details), opensViewer: true))
        let right = TabViewKeeps(
            panes: 2, right: PaneKeeps(folder: "/a", view: FolderViewKeeps(view: .icons), opensViewer: true))
        #expect(right.right?.opensViewer == true && right.right?.folder == "/a")
        #expect(TabViewKeeps(panes: 1, pane: PaneKeeps(opensViewer: true)).pane == PaneKeeps(opensViewer: true))
        #expect(TabViewKeeps(pane: PaneKeeps(opensViewer: true)).pane == PaneKeeps(opensViewer: true))
        #expect(TabViewKeeps(pane: PaneKeeps(viewerFollows: false)).pane == PaneKeeps(viewerFollows: false))
        // Read back as written.
        let data = try JSONEncoder().encode(both)
        #expect(try JSONDecoder().decode(TabViewKeeps.self, from: data) == both)
    }

    // A tab view saved when the viewer was a choice of View, which kept nothing else, reads as opening the viewer with
    // its Follow and Read or Edit; one that kept the sizes together keeps every view's.
    @Test func tabViewsSavedBeforeReadAsTheyWorked() throws {
        let viewer = Data(
            #"{"panes": 2, "right": {"viewer": {"follows": false, "editing": true}, "folder": "/a"}}"#.utf8)
        let read = try JSONDecoder().decode(TabViewKeeps.self, from: viewer)
        #expect(read.right == PaneKeeps(folder: "/a", opensViewer: true, viewerFollows: false, viewerEditing: true))
        let partial = Data(#"{"panes": 2, "right": {"viewer": {}}}"#.utf8)
        #expect(
            try JSONDecoder().decode(TabViewKeeps.self, from: partial).right
                == PaneKeeps(opensViewer: true, viewerFollows: true, viewerEditing: false))
        let sizes = Data(
            #"{"pane": {"view": {"view": "icons", "size": {"iconSizes": {"standard": 96, "finder": 80}}}}}"#.utf8)
        let pane = try #require(try JSONDecoder().decode(TabViewKeeps.self, from: sizes).pane)
        #expect(pane.view == FolderViewKeeps(view: .icons))
        #expect(pane.sizes?.kept == [.icons, .compactList, .previews])
        #expect(pane.sizes?.iconSizes == DensitySizes(standard: 96, finder: 80))
        #expect(pane.sizes?.compactListWidths == .compactListDefaults)
    }

    // Applied, a viewer starts as the pane's own Follow and Read or Edit, with what the tab view keeps of them over
    // those, which are the pane's from then on; the list behind it takes the rest. Following, with a list in the
    // other pane, it shows beside that list; otherwise it shows its own list's file in place. A pane given a view of a
    // folder and no viewer closes its viewer.
    @Test func aViewerOpensBesideTheOtherListOrInPlace() {
        var tab = Self.tab(["/a", "/b"])
        tab.panes[1].viewerDefaults = PaneViewer(follows: true, editing: false)
        let applied = Self.apply(
            TabViewKeeps(
                panes: 2,
                right: PaneKeeps(
                    folder: "/c", view: FolderViewKeeps(view: .details), opensViewer: true, viewerEditing: true)),
            tab)
        #expect(applied.viewers == [1: PaneViewer(follows: true, editing: true)])
        #expect(applied.viewersInPlace.isEmpty)
        #expect(applied.tab.panes[1].viewer == PaneViewer(follows: true, editing: true))
        #expect(applied.tab.panes[1].viewerDefaults == PaneViewer(follows: true, editing: true))
        #expect(applied.tab.panes[1].settings.view == .details)
        #expect(applied.tab.panes[1].folder == "/c")
        #expect(applied.panesMoved == [1])
        #expect(applied.viewersClosed.isEmpty)

        // Follow off: its own list's file, in place.
        let pinned = Self.apply(TabViewKeeps(panes: 2, right: PaneKeeps(opensViewer: true, viewerFollows: false)), tab)
        #expect(pinned.viewersInPlace == [1] && pinned.tab.panes[1].viewerInPlace && pinned.tab.panes[1].viewer == nil)
        // Both panes: neither has a list to follow, so both show in place.
        let both = Self.apply(
            TabViewKeeps(panes: 2, left: PaneKeeps(opensViewer: true), right: PaneKeeps(opensViewer: true)), tab)
        #expect(both.viewersInPlace == [0, 1])
        // One pane: in place.
        let one = Self.apply(TabViewKeeps(panes: 1, pane: PaneKeeps(opensViewer: true)), Self.tab(["/a"]))
        #expect(one.viewers.keys.sorted() == [0] && one.viewersInPlace == [0])

        tab.panes[1].viewer = PaneViewer()
        let list = Self.apply(TabViewKeeps(panes: 2, right: PaneKeeps(view: FolderViewKeeps(view: .details))), tab)
        #expect(list.viewersClosed == [1])
        #expect(list.tab.panes[1].viewer == nil)
        // A tab view that keeps no view for the pane leaves its viewer.
        let sorted = Self.apply(
            TabViewKeeps(panes: 2, right: PaneKeeps(view: FolderViewKeeps(foldersFirst: false))), tab)
        #expect(sorted.viewersClosed.isEmpty)
        // The left pane opening one, following: the right shows a viewer, not a list, so the left's shows in place,
        // and the right's stays.
        let left = Self.apply(TabViewKeeps(panes: 2, left: PaneKeeps(opensViewer: true)), tab)
        #expect(left.viewersInPlace == [0] && left.viewersClosed.isEmpty)
    }

    // Each view's size is applied on its own; under Tab View First, the override holds only the sizes kept.
    @Test func eachViewsSizeIsAppliedOnItsOwn() {
        let tab = Self.tab(["/a"])
        let keeps = TabViewKeeps(
            pane: PaneKeeps(
                sizes: ViewSizesKeeps(iconSizes: DensitySizes(standard: 112, finder: 96)), folderViews: .tabViewFirst))
        let applied = Self.apply(keeps, tab)
        let before = tab.panes[0].settings.size
        #expect(applied.tab.panes[0].settings.size?.iconSizes == DensitySizes(standard: 112, finder: 96))
        #expect(applied.tab.panes[0].settings.size?.compactListWidths == before?.compactListWidths)
        #expect(applied.tab.panes[0].settings.size?.previewCounts == before?.previewCounts)
        let override = applied.overrides[0]
        #expect(override?.kept == [.size] && override?.sizes == [.icons])
        #expect(override?.covers(.size) == true && override?.covers(ViewSizeKind.icons) == true)
        #expect(override?.covers(ViewSizeKind.previews) == false)
        // Changed by hand, one view's size lets go of that one alone; the last one lets go of the override.
        #expect(override?.without(ViewSizeKind.previews) == override)
        #expect(override?.without(ViewSizeKind.icons) == nil)
    }

    @Test func aDividerIsKeptWithinWhatADragAllows() {
        func divider(_ value: TabViewKeeps.Divider) -> TabViewKeeps.Divider? {
            TabViewKeeps(panes: 2, divider: value).divider
        }
        #expect(divider(.share(0.05)) == .share(PaneSplit.minimum))
        #expect(divider(.share(1.4)) == .share(PaneSplit.maximum))
        #expect(divider(.share(.nan)) == nil)
        #expect(divider(.leftWidth(0)) == nil)
        #expect(divider(.leftWidth(-3)) == nil)
        #expect(divider(.leftWidth(419.6)) == .leftWidth(420))
    }

    @Test func aDamagedListKeepsWhatMakesSense() throws {
        let json = """
            [
              {"id": "a", "name": "Compare", "keeps": {"panes": 2, "divider": {"share": 0.5}}},
              {"id": "", "name": "No id", "keeps": {"panes": 1}},
              {"name": "Missing id", "keeps": {"panes": 1}},
              {"id": "a", "name": "Same id", "keeps": {"panes": 1}},
              {"id": "b", "name": "COMPARE", "keeps": {"panes": 1}},
              {"id": "c", "name": "   ", "keeps": {"panes": 1}},
              {"id": "d", "name": "Keeps nothing", "keeps": {}},
              {"id": "e", "name": "Unreadable", "keeps": "two panes"},
              {"id": "f", "name": "  Newest  ", "keeps": {"pane": {"view": {"view": "nope", "foldersFirst": false}}}},
              "not a view"
            ]
            """
        let views = TabViews.sanitize(try JSONNode.parse(Data(json.utf8)))
        #expect(views.map(\.id) == ["a", "f"])
        #expect(views[1].name == "Newest")
        // A setting that can't be read is not kept; the one beside it is.
        #expect(views[1].keeps.pane?.view == FolderViewKeeps(foldersFirst: false))
        #expect(TabViews.sanitize(nil).isEmpty)
        #expect(TabViews.sanitize(.object([:])).isEmpty)
    }

    @Test func atMostTheLimitAreRead() throws {
        let many = (0..<(SavedViewNames.limit + 5)).map { index in
            TabView(id: "t\(index)", name: "View \(index)", keeps: TabViewKeeps(panes: 1))
        }
        #expect(TabViews.sanitize(try JSONNode.of(many)).count == SavedViewNames.limit)
    }

    // MARK: Applying: panes

    /// Each row: the tab's panes and active pane, the pane closed before, the panes kept; then the folders after, the
    /// active pane after, what the second pane did, and the closed pane after.
    @Test(
        arguments: [
            (["/a"], 0, nil, nil, ["/a"], 0, nil, nil),
            (["/a"], 0, nil, 1, ["/a"], 0, nil, nil),
            (["/a"], 0, nil, 2, ["/a", "/a"], 0, TabViewApplied.SecondPane.opened(reopened: false), nil),
            (["/a"], 0, "/c", 2, ["/a", "/c"], 0, .opened(reopened: true), nil),
            (["/a", "/b"], 0, nil, nil, ["/a", "/b"], 0, nil, nil),
            (["/a", "/b"], 1, nil, nil, ["/a", "/b"], 1, nil, nil),
            (["/a", "/b"], 0, nil, 2, ["/a", "/b"], 0, nil, nil),
            (["/a", "/b"], 0, nil, 1, ["/a"], 0, .closed(1), "/b"),
            (["/a", "/b"], 1, nil, 1, ["/b"], 0, .closed(0), "/a"),
            (["/a", "/b"], 1, "/c", 1, ["/b"], 0, .closed(0), "/a"),
        ] as [([String], Int, String?, Int?, [String], Int, TabViewApplied.SecondPane?, String?)])
    func panesOpenAndCloseAsTwoPanesDoes(
        folders: [String], active: Int, closed: String?, panes: Int?, after: [String], activeAfter: Int,
        second: TabViewApplied.SecondPane?, closedAfter: String?
    ) {
        let applied = Self.apply(TabViewKeeps(panes: panes), Self.tab(folders, active: active, closed: closed))
        #expect(applied.tab.panes.map(\.folder) == after)
        #expect(applied.tab.active == activeAfter)
        #expect(applied.secondPane == second)
        if let closedAfter {
            #expect(applied.tab.closedPane?.folder == closedAfter)
        } else if second != nil {
            #expect(applied.tab.closedPane == nil)
        }
    }

    @Test func aReopenedPaneComesBackAsItWasClosed() {
        let applied = Self.apply(TabViewKeeps(panes: 2), Self.tab(["/a"], closed: "/c"))
        // Closed in Previews, it comes back in Previews: the tab view keeps nothing of the right pane.
        #expect(applied.tab.panes[1].settings.view == .previews)
        #expect(applied.panesGiven.isEmpty)
    }

    // Forgetting the second pane is kept only with one pane, read back as written, and leaves the tab no pane closed
    // to bring back, whether it closes one or the tab had one closed already.
    @Test func onePaneCanForgetTheSecond() throws {
        #expect(TabViewKeeps(panes: 2, forgetsSecondPane: true).forgetsSecondPane == nil)
        #expect(TabViewKeeps(forgetsSecondPane: true).forgetsSecondPane == nil)
        #expect(TabViewKeeps(panes: 1).forgetsSecondPane == nil)
        let forgets = TabViewKeeps(panes: 1, forgetsSecondPane: true)
        #expect(forgets.forgetsSecondPane == true)
        #expect(try JSONDecoder().decode(TabViewKeeps.self, from: JSONEncoder().encode(forgets)) == forgets)
        var shared = Self.tab(["/a", "/b"])
        shared.split = 0.2
        #expect(Self.apply(forgets, shared).tab.closedPane == nil)
        #expect(Self.apply(forgets, shared).tab.split == PaneSplit.even)
        #expect(Self.apply(TabViewKeeps(panes: 1), shared).tab.split == 0.2)
        #expect(Self.apply(TabViewKeeps(panes: 1), Self.tab(["/a", "/b"])).tab.closedPane?.folder == "/b")
        #expect(Self.apply(forgets, Self.tab(["/a"], closed: "/c")).tab.closedPane == nil)
        #expect(SavedViewText.parts(forgets).prefix(2) == ["One pane", "Second pane forgotten"])
    }

    // One pane keeps the active pane, but never a viewer on its own: with the viewer active, the viewer closes and the
    // list stays.
    @Test func onePaneKeepsTheListWhenTheViewerIsActive() {
        var tab = Self.tab(["/a", "/b"], active: 1)
        tab.panes[1].viewer = PaneViewer()
        let applied = Self.apply(TabViewKeeps(panes: 1), tab)
        #expect(applied.secondPane == .closed(1))
        #expect(applied.tab.panes.map(\.folder) == ["/a"] && applied.tab.panes[0].viewer == nil)
        #expect(applied.tab.closedPane?.viewer == PaneViewer())
        // A list active beside a viewer stays as ever: the viewer closes.
        tab.active = 0
        #expect(Self.apply(TabViewKeeps(panes: 1), tab).secondPane == .closed(1))
        // Two lists: the one not active closes.
        #expect(Self.apply(TabViewKeeps(panes: 1), Self.tab(["/a", "/b"], active: 1)).secondPane == .closed(0))
    }

    @Test func aCopiedPaneIsTheActivePanesSettings() {
        var tab = Self.tab(["/a"])
        tab.panes[0].settings.sort = FolderViewSort(by: .size, direction: .desc)
        let applied = Self.apply(TabViewKeeps(panes: 2), tab)
        #expect(applied.tab.panes[1] == tab.panes[0])
    }

    // MARK: Applying: the divider

    /// The left pane's share for each divider in a column of a given width: within 20%–80%, and a width measured
    /// against the room left beside the divider (the column less 9 pt).
    @Test(
        arguments: [
            (TabViewKeeps.Divider.even, 1009.0, 0.5),
            (.share(0.62), 1009, 0.62),
            (.share(0.2), 1009, 0.2),
            (.leftWidth(420), 1009, 0.42),
            (.leftWidth(420), 609, 0.7),
            (.leftWidth(2000), 1009, 0.8),
            (.leftWidth(100), 1009, 0.2),
            (.leftWidth(420), 5, 0.5),
        ] as [(TabViewKeeps.Divider, Double, Double)])
    func theDividerSharesTheRoom(divider: TabViewKeeps.Divider, width: Double, share: Double) {
        let applied = Self.apply(TabViewKeeps(panes: 2, divider: divider), Self.tab(["/a", "/b"]), width: width)
        #expect(abs(applied.tab.split - share) < 0.0001)
    }

    @Test func aDividerIsLeftAloneWithOnePane() {
        var tab = Self.tab(["/a", "/b"])
        tab.split = 0.3
        // Panes not kept: the tab keeps both, and its share.
        #expect(Self.apply(TabViewKeeps(divider: .even), tab).tab.split == 0.3)
        // One pane kept: the second closes, and the divider has nothing to share.
        let closed = Self.apply(TabViewKeeps(panes: 1, divider: .even), tab)
        #expect(closed.tab.panes.count == 1)
    }

    // MARK: Applying: each pane's settings

    @Test func aSettingKeptIsTheTabViewsAndOneNotKeptIsThePanes() {
        let keeps = TabViewKeeps(
            panes: 2,
            left: PaneKeeps(view: FolderViewKeeps(view: .details, groupBy: .kind, groupReversed: true)),
            right: PaneKeeps(view: FolderViewKeeps(foldersFirst: false)))
        let before = Self.tab(["/a", "/b"])
        let applied = Self.apply(keeps, before)
        let left = applied.tab.panes[0].settings
        #expect(left.view == .details)
        #expect(left.groupBy == .kind && left.groupReversed == true)
        #expect(left.sort == before.panes[0].settings.sort)
        #expect(left.foldersFirst == true)
        let right = applied.tab.panes[1].settings
        #expect(right.view == .icons)
        #expect(right.foldersFirst == false)
        #expect(applied.panesGiven == [0, 1])
    }

    @Test func withPanesNotKeptOnlyTheActivePaneChanges() {
        let keeps = TabViewKeeps(pane: PaneKeeps(folder: "/x", view: FolderViewKeeps(view: .previews)))
        let applied = Self.apply(keeps, Self.tab(["/a", "/b"], active: 1))
        #expect(applied.tab.panes.map(\.folder) == ["/a", "/x"])
        #expect(applied.tab.panes.map(\.settings.view) == [.icons, .previews])
        #expect(applied.panesGiven == [1])
        #expect(applied.panesMoved == [1])
        #expect(applied.tab.active == 1)
    }

    @Test func withOnePaneKeptTheRemainingPaneTakesIt() {
        let keeps = TabViewKeeps(panes: 1, pane: PaneKeeps(view: FolderViewKeeps(view: .details)))
        // The right pane is active: the left closes, and the right, now the only one, takes the settings.
        let applied = Self.apply(keeps, Self.tab(["/a", "/b"], active: 1))
        #expect(applied.tab.panes.map(\.folder) == ["/b"])
        #expect(applied.tab.panes[0].settings.view == .details)
        #expect(applied.panesGiven == [0])
    }

    @Test func hiddenFilesAreTheTabsAndChangeOnlyWhenKept() {
        var tab = Self.tab(["/a"])
        tab.includeHidden = true
        #expect(Self.apply(TabViewKeeps(panes: 1), tab).tab.includeHidden)
        #expect(!Self.apply(TabViewKeeps(includeHidden: false), tab).tab.includeHidden)
    }

    // MARK: Applying: folders

    @Test func onlyAFolderThatDiffersMovesThePane() {
        let keeps = TabViewKeeps(
            panes: 2, left: PaneKeeps(folder: "/a"), right: PaneKeeps(folder: "/x"))
        let applied = Self.apply(keeps, Self.tab(["/a", "/b"]))
        #expect(applied.panesMoved == [1])
        #expect(applied.tab.panes.map(\.folder) == ["/a", "/x"])
    }

    @Test func aFolderIsOneByItsPathsBytes() {
        let keeps = TabViewKeeps(pane: PaneKeeps(folder: "/u/cafe\u{301}"))
        // Two spellings of one name are two folders on a disk that keeps them apart.
        #expect(Self.apply(keeps, Self.tab(["/u/caf\u{E9}"])).panesMoved == [0])
        #expect(Self.apply(keeps, Self.tab(["/u/cafe\u{301}"])).panesMoved.isEmpty)
    }

    @Test func aPaneWithNoFolderTakesTheTabViews() {
        let keeps = TabViewKeeps(pane: PaneKeeps(folder: "/x"))
        let applied = Self.apply(keeps, TabState(panes: [Self.pane(nil)]))
        #expect(applied.tab.panes[0].folder == "/x")
        #expect(applied.panesMoved == [0])
    }

    // MARK: Applying: overrides

    @Test func anOverrideIsLeftOnlyForAChoiceOtherThanTheFoldersViewFirst() {
        let keeps = TabViewKeeps(
            panes: 2,
            left: PaneKeeps(
                folder: "/x", view: FolderViewKeeps(view: .details, sort: FolderViewSort(by: .size, direction: .asc)),
                folderViews: .tabViewFirst),
            right: PaneKeeps(view: FolderViewKeeps(view: .previews)))
        let applied = Self.apply(keeps, Self.tab(["/a", "/b"]))
        #expect(applied.overrides.count == 1)
        // It holds in the folder the pane is on once applied: the tab view's folder, not the one before.
        #expect(applied.overrides[0] == TabViewOverride(folder: "/x", choice: .tabViewFirst, kept: [.view, .sort]))
    }

    @Test func notUsedHoldsInTheFolderThePaneStaysOn() {
        let keeps = TabViewKeeps(pane: PaneKeeps(folderViews: .notUsed))
        let applied = Self.apply(keeps, Self.tab(["/a"]))
        #expect(applied.overrides[0] == TabViewOverride(folder: "/a", choice: .notUsed, kept: []))
        #expect(applied.panesGiven == [0])
        #expect(applied.panesMoved.isEmpty)
    }

    @Test func aPaneWithNoFolderGetsNoOverride() {
        let keeps = TabViewKeeps(pane: PaneKeeps(folderViews: .notUsed))
        #expect(Self.apply(keeps, TabState(panes: [Self.pane(nil)])).overrides.isEmpty)
    }

    // MARK: Gone folders

    @Test func aGoneFolderIsTheNearestOneAboveAndCounted() {
        let keeps = TabViewKeeps(
            panes: 2, left: PaneKeeps(folder: "/u/gone/deep"), right: PaneKeeps(folder: "/u/here"))
        let result = TabViews.replacingGoneFolders(
            keeps, gone: [DiskPath("/u/gone/deep")], nearest: { _ in "/u" })
        #expect(result.replaced == 1)
        #expect(result.keeps.left?.folder == "/u")
        #expect(result.keeps.right?.folder == "/u/here")
        #expect(TabViews.replacingGoneFolders(keeps, gone: [], nearest: { _ in "/" }).replaced == 0)
        #expect(keeps.folders == ["/u/gone/deep", "/u/here"])
    }
}
