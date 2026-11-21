// Checks the window views' rules and the names of saved views: what is read back, their tabs' tab views, the sizes
// kept, and names unique ignoring case and accents
import Foundation
import Testing

@testable import FTFoundation

struct WindowViewsTests {
    static let compare = TabView(id: "t1", name: "Compare", keeps: TabViewKeeps(panes: 2))
    static let newest = TabView(
        id: "t2", name: "Newest", keeps: TabViewKeeps(pane: PaneKeeps(view: FolderViewKeeps(foldersFirst: false))))

    @Test func everyPartIsReadBackAsWritten() throws {
        let view = WindowView(
            id: "w1", name: "Research", tabs: ["t1", nil, "t2"], frontTab: 2,
            size: WindowView.Size(width: 1440, height: 900), folderTreeOpen: true, propertiesOpen: false)
        #expect(WindowViews.sanitize(try JSONNode.of([view])) == [view])
    }

    @Test func whatMakesNoSenseIsMadeSenseOf() {
        // No tabs is one plain tab; past the tab limit is cut; a front tab past the end is the first.
        #expect(WindowView(id: "w", name: "W", tabs: []).tabs == [nil])
        let many = WindowView(id: "w", name: "W", tabs: Array(repeating: "t1", count: 30), frontTab: 29)
        #expect(many.tabs.count == AppPreferenceLimits.openTabsLimit)
        #expect(many.frontTab == 0)
        #expect(WindowView(id: "w", name: "W", tabs: [""]).tabs == [nil])
        // A size is never smaller than a window can be.
        #expect(
            WindowView(id: "w", name: "W", tabs: [nil], size: .init(width: 10, height: 10)).size
                == WindowView.minimumSize)
    }

    @Test func aDamagedListKeepsWhatMakesSense() throws {
        let json = """
            [
              {"id": "w1", "name": "Research", "tabs": ["t1", null, 7]},
              {"id": "w1", "name": "Same id", "tabs": []},
              {"id": "w2", "name": "RESEARCH", "tabs": []},
              {"id": "w3", "name": " ", "tabs": []},
              {"id": "w4", "tabs": []},
              {"id": "w5", "name": "Review", "frontTab": "first", "size": {"width": "wide"}, "folderTreeOpen": 1}
            ]
            """
        let views = WindowViews.sanitize(try JSONNode.parse(Data(json.utf8)))
        #expect(views.map(\.id) == ["w1", "w5"])
        #expect(views[0].tabs == ["t1", nil, nil])
        #expect(views[1].tabs == [nil])
        #expect(views[1].frontTab == 0 && views[1].size == nil && views[1].folderTreeOpen == nil)
    }

    @Test func aTabsTabViewIsFoundByIdAndOneRemovedIsAPlainTab() {
        let view = WindowView(id: "w", name: "W", tabs: ["t1", nil, "gone", "t2"])
        #expect(view.resolvedTabs(in: [Self.compare, Self.newest]) == [Self.compare, nil, nil, Self.newest])
    }

    @Test func removingATabViewNamesTheWindowViewsThatUseItAndLeavesThemPlainTabs() {
        let research = WindowView(id: "w1", name: "Research", tabs: ["t1", "t2"])
        let review = WindowView(id: "w2", name: "Review", tabs: ["t2"])
        #expect(WindowViews.using("t1", in: [research, review]).map(\.id) == ["w1"])
        let left = WindowViews.forgetting("t1", in: [research, review])
        #expect(left.map(\.tabs) == [[nil, "t2"], ["t2"]])
        // Renaming changes nothing in them: they name it by its id.
        #expect(WindowViews.using("t2", in: left).count == 2)
    }

    @Test(
        arguments: [
            (1440, 900, 1512, 945, 1440, 900),
            (3000, 2000, 1512, 945, 1512, 945),
            (200, 100, 1512, 945, 400, 300),
            (1440, 900, 300, 200, 400, 300),
        ])
    func aSizeIsHeldToTheScreen(
        width: Int, height: Int, roomWidth: Int, roomHeight: Int, heldWidth: Int, heldHeight: Int
    ) {
        let held = WindowView.held(
            .init(width: width, height: height), within: .init(width: roomWidth, height: roomHeight))
        #expect(held == WindowView.Size(width: heldWidth, height: heldHeight))
    }

    // MARK: Names

    @Test func namesAreUniqueIgnoringCaseAndHowAnAccentIsStored() {
        let views = [TabView(id: "t1", name: "Caf\u{E9}", keeps: TabViewKeeps(panes: 1))]
        #expect(SavedViewNames.index(named: "CAFE\u{301}", in: views) == 0)
        #expect(SavedViewNames.index(named: "  caf\u{E9} ", in: views) == 0)
        #expect(
            SavedViewNames.renameRefusal("cafe\u{301}", id: "t2", in: views, kind: "tab view")
                == "There\u{2019}s already a tab view called \u{201C}Caf\u{E9}\u{201D}.")
        // Its own name, in another case, is no refusal.
        #expect(SavedViewNames.renameRefusal("CAF\u{C9}", id: "t1", in: views, kind: "tab view") == nil)
    }

    @Test func aNameIsTrimmedComposedAndCut() {
        #expect(SavedViewNames.clean("  cafe\u{301} ") == "caf\u{E9}")
        #expect(SavedViewNames.clean(String(repeating: "a", count: 100)).utf16.count == SavedViewNames.nameLimit)
    }

    @Test func savingUnderANameReplacesItAndPastTheLimitAddsNothing() {
        let first = TabView(id: "t1", name: "Compare", keeps: TabViewKeeps(panes: 2))
        let again = TabView(id: "t1", name: "compare", keeps: TabViewKeeps(panes: 1))
        #expect(SavedViewNames.saving(again, in: [first]) == [again])
        let full = (0..<SavedViewNames.limit).map {
            TabView(id: "t\($0)", name: "V\($0)", keeps: TabViewKeeps(panes: 1))
        }
        #expect(SavedViewNames.saving(TabView(id: "x", name: "New", keeps: .init(panes: 1)), in: full) == full)
    }

    @Test func aCopyGetsTheFirstNameNoOtherHas() {
        let views = [
            TabView(id: "t1", name: "Compare", keeps: TabViewKeeps(panes: 2)),
            TabView(id: "t2", name: "Compare copy", keeps: TabViewKeeps(panes: 2)),
        ]
        #expect(SavedViewNames.copyName(of: "Compare", in: views) == "Compare copy 2")
        #expect(SavedViewNames.copyName(of: "Other", in: views) == "Other copy")
        // A name at the limit is cut before its suffix, so copies never share a name.
        let long = String(repeating: "x", count: SavedViewNames.nameLimit)
        let first = SavedViewNames.copyName(of: long, in: [TabView]())
        let longViews = [TabView(id: "t", name: first, keeps: .init(panes: 1))]
        let second = SavedViewNames.copyName(of: long, in: longViews)
        #expect(second.hasSuffix(" copy 2") && second.utf16.count == SavedViewNames.nameLimit)
    }
}
