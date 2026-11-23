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
            (200, 100, 1512, 945, 760, 480),
            (1440, 900, 300, 200, 760, 480),
        ])
    func aSizeIsHeldToTheScreen(
        width: Int, height: Int, roomWidth: Int, roomHeight: Int, heldWidth: Int, heldHeight: Int
    ) {
        let held = WindowView.held(
            .init(width: width, height: height), within: .init(width: roomWidth, height: roomHeight))
        #expect(held == WindowView.Size(width: heldWidth, height: heldHeight))
    }

    // A size typed in Window View Options is held between the smallest an explorer window can be and the screen's
    // room, as it is typed and when it starts.
    @Test func aSizeTypedIsHeldBetweenTheSmallestWindowAndTheScreen() {
        #expect(WindowView.minimumSize == WindowView.Size(width: 760, height: 480))
        var draft = WindowViewDraft(
            tabs: [nil], front: 0, size: .init(width: 2000, height: 1400), folderTreeOpen: true, propertiesOpen: false,
            largestSize: .init(width: 1512, height: 945))
        #expect(draft.customSize == WindowView.Size(width: 1512, height: 945))
        draft.customSize.width = 100
        draft.customSize.height = 99_999
        #expect(draft.customSize == WindowView.Size(width: 760, height: 945))
        draft.customSize = .init(width: 1000, height: 700)
        #expect(draft.customSize == WindowView.Size(width: 1000, height: 700))
        draft.keepsSize = true
        draft.sizeChoice = .custom
        #expect(draft.windowView(id: "w").size == WindowView.Size(width: 1000, height: 700))
        // With no screen known, only the smallest holds.
        var free = WindowViewDraft(
            tabs: [nil], front: 0, size: .init(width: 900, height: 600), folderTreeOpen: true, propertiesOpen: false)
        free.customSize.width = 5000
        #expect(free.customSize.width == 5000)
        // A screen smaller than the smallest window still gives the smallest.
        let tiny = WindowViewDraft(
            tabs: [nil], front: 0, size: .init(width: 900, height: 600), folderTreeOpen: true, propertiesOpen: false,
            largestSize: .init(width: 600, height: 400))
        #expect(tiny.customSize == WindowView.minimumSize)
    }

    // Maximized or full screen is kept in place of a size, read back as written, and said in the list.
    @Test func maximizedAndFullScreenAreKeptInPlaceOfASize() throws {
        let full = WindowView(
            id: "w", name: "W", tabs: [nil], size: .init(width: 1000, height: 700), sizing: .fullScreen)
        #expect(full.size == nil && full.sizing == .fullScreen)
        let data = try JSONEncoder().encode(full)
        #expect(try JSONDecoder().decode(WindowView.self, from: data) == full)
        let unknown = Data(#"{"id": "w", "name": "W", "tabs": [null], "sizing": "huge"}"#.utf8)
        #expect(try JSONDecoder().decode(WindowView.self, from: unknown).sizing == nil)
        #expect(SavedViewText.parts(full, tabViews: []).contains("Full screen"))

        var draft = WindowViewDraft(
            editing: full, sizeNow: .init(width: 900, height: 600), folderTreeOpen: true,
            propertiesOpen: false)
        #expect(draft.keepsSize && draft.sizeChoice == .fullScreen)
        draft.sizeChoice = .maximized
        #expect(draft.windowView(id: "w").sizing == .maximized && draft.windowView(id: "w").size == nil)
        draft.sizeChoice = .custom
        #expect(draft.windowView(id: "w").sizing == nil && draft.windowView(id: "w").size == draft.customSize)
        draft.keepsSize = false
        #expect(draft.windowView(id: "w").sizing == nil && draft.windowView(id: "w").size == nil)
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

    @Test func theLimitsNoticesSayWhatIsKeptAndHowToGoOn() {
        #expect(SavedViewNames.limitTitle(kind: "tab views") == "Too Many Tab Views")
        #expect(SavedViewNames.limitTitle(kind: "window views") == "Too Many Window Views")
        #expect(
            SavedViewNames.saveLimitMessage(kind: "window views", name: "Work", count: 20)
                == "File Trail keeps up to 20 window views, and you have 20. To save \u{201C}Work\u{201D}, remove one "
                + "you no longer use, or save over one by choosing its name from the list.")
        #expect(
            SavedViewNames.duplicateLimitMessage(kind: "tab views", count: 20, copies: 1)
                == "File Trail keeps up to 20 tab views, and you have 20. Remove one you no longer use to make room "
                + "for the copy.")
        #expect(
            SavedViewNames.duplicateLimitMessage(kind: "tab views", count: 20, copies: 3)
                == "File Trail keeps up to 20 tab views, and you have 20. Remove some you no longer use to make room "
                + "for the copies.")
        #expect(
            SavedViewNames.duplicateLimitMessage(kind: "tab views", count: 18, copies: 3)
                == "File Trail keeps up to 20 tab views. You have 18, so 2 more copies fit, and 3 are selected. "
                + "Remove some you no longer use, or select fewer.")
        #expect(
            SavedViewNames.duplicateLimitMessage(kind: "tab views", count: 19, copies: 2)
                == "File Trail keeps up to 20 tab views. You have 19, so 1 more copy fits, and 2 are selected. "
                + "Remove some you no longer use, or select fewer.")
    }

    @Test func severalAreCopiedEachAfterItsOwnAndNoneWhenTheyDontFit() {
        let views = ["A", "B", "A copy"].map { TabView(id: $0, name: $0, keeps: TabViewKeeps(panes: 1)) }
        var next = 0
        let result = SavedViewNames.duplicating(["A copy", "A"], in: views) {
            next += 1
            return "new\(next)"
        }
        #expect(result.views.map(\.name) == ["A", "A copy 2", "B", "A copy", "A copy copy"])
        #expect(result.copies == ["new1", "new2"])
        let full = (0..<(SavedViewNames.limit - 1)).map {
            TabView(id: "t\($0)", name: "V\($0)", keeps: TabViewKeeps(panes: 1))
        }
        #expect(SavedViewNames.duplicating(["t0", "t1"], in: full) { "x" }.views == full)
        #expect(SavedViewNames.duplicating(["t0"], in: full) { "x" }.views.count == SavedViewNames.limit)
    }

    @Test func rowsMovedTogetherKeepTheirOrder() {
        let list = ["a", "b", "c", "d", "e"]
        #expect(SavedViewNames.moving(list, rows: [1, 3], to: 0) == (["b", "d", "a", "c", "e"], 0))
        #expect(SavedViewNames.moving(list, rows: [0, 2], to: 5) == (["b", "d", "e", "a", "c"], 3))
        #expect(SavedViewNames.moving(list, rows: [0, 4], to: 2) == (["b", "a", "e", "c", "d"], 1))
        #expect(SavedViewNames.moving(list, rows: [1], to: 2).views == list)
        #expect(SavedViewNames.moving(list, rows: [9], to: 0).views == list)
    }
}
