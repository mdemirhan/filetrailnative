// Port of apps/desktop/src/shared/toolbarItems.test.ts
import Testing

@testable import FTFoundation

struct ToolbarItemsTests {
    static func list(_ names: [String]) -> JSONNode { .array(names.map(JSONNode.string)) }

    static func sanitized(_ names: [String]) -> [String] {
        ToolbarItems.sanitizeTopItems(list(names)).map(\.rawValue)
    }

    static let defaults = ToolbarItems.defaultTopItems

    // T-d37fe3fb F-017 F-067
    @Test func keepsATopToolbarsOrderTheFixedItemsWhereverTheyWerePut() {
        let customized = [
            "search", "back", "viewOptions", "topSeparator", "sort", "title", "topSeparator", "clipboard", "view",
        ]
        #expect(Self.sanitized(customized) == customized)
        #expect(ToolbarItems.sanitizeTopItems(Self.list(Self.defaults.map(\.rawValue))) == Self.defaults)
    }

    // T-9d244d69 F-017
    @Test func dropsItemsThatAreUnknownOrRepeated() {
        #expect(
            Self.sanitized([
                "back", "title", "title", "back", "leftSeparator", "nonsense", "search", "openSelection", "clipboard",
                "viewOptions", "search",
            ]) == ["back", "title", "search", "openSelection", "clipboard", "viewOptions"])
    }

    // T-1f3bf2e9 F-067
    @Test func putsAFixedItemThatAListIsMissingAtTheEnd() {
        #expect(Self.sanitized(["search", "back", "title"]) == ["search", "back", "title", "clipboard", "viewOptions"])
        #expect(
            Self.sanitized(["back", "view"]) == ["back", "view", "title", "clipboard", "search", "viewOptions"])
        #expect(ToolbarItems.sanitizeTopItems(.null).map(\.rawValue) == ["title", "clipboard", "search", "viewOptions"])
    }

    // T-ebfaa9c3 F-017 F-067
    @Test func preservesRepeatableSeparatorItemsWhileStillDedupingNormalItems() {
        #expect(
            Self.sanitized([
                "topSeparator", "back", "topSeparator", "back", "title", "clipboard", "search", "viewOptions",
            ]) == ["topSeparator", "back", "topSeparator", "title", "clipboard", "search", "viewOptions"])
    }

    // T-b87edb39 F-067
    @Test func addsAClickedItemAtTheFarRight() {
        #expect(ToolbarItems.addTopItem(Self.defaults, .copyPath) == Self.defaults + [.copyPath])
    }

    // T-97bc9a9e F-067
    @Test func insertsMovesAndRemovesItemsByTheirPlaceInTheOrder() {
        let items = Self.defaults
        #expect(
            ToolbarItems.insertTopItem(items, .refresh, at: 3)
                == Array(items[..<3]) + [.refresh] + Array(items[3...]))
        // Out of range lands at the nearer end.
        #expect(ToolbarItems.insertTopItem(items, .refresh, at: -3).first == .refresh)
        #expect(ToolbarItems.insertTopItem(items, .refresh, at: 99).last == .refresh)
        // Back moved after Sort: the index counts the items without Back.
        #expect(
            ToolbarItems.moveTopItem(items, from: 2, to: 7) == [
                .folderTree, .topSeparator, .forward, .title, .clipboard, .view, .sort, .back, .search, .viewOptions,
                .infoPanel,
            ])
        let sortIndex = items.firstIndex(of: .sort) ?? 0
        #expect(!ToolbarItems.removeTopItem(items, at: sortIndex).contains(.sort))
        // The four that always stay are not taken off.
        let searchIndex = items.firstIndex(of: .search) ?? 0
        #expect(ToolbarItems.removeTopItem(items, at: searchIndex) == items)
    }

    // T-6856c3fc F-067
    @Test func offersEveryItemThatCanBeTakenOffSoEachCanBePutBack() {
        let palette = ToolbarItems.paletteItems(excluding: [])
        let alwaysThere: Set<ToolbarItemID> = [.title, .clipboard, .search, .viewOptions]
        for id in ToolbarItems.ids where !alwaysThere.contains(id) {
            #expect(palette.contains(id), "\(id)")
        }
    }

    // T-2b6a35fc F-067
    @Test func offersEveryItemTheToolbarDoesNotHoldAndTheSpaceAlways() {
        let palette = ToolbarItems.paletteItems(excluding: Self.defaults)
        #expect(palette.first == .topSeparator)
        #expect(palette.contains(.refresh))
        for id in Self.defaults where id != .topSeparator {
            #expect(!palette.contains(id), "\(id)")
        }
        #expect(ToolbarItems.paletteItems(excluding: Self.defaults + [.topSeparator]).contains(.topSeparator))
    }

    // T-23d43fd9
    @Test func offersTheAppsOwnButtonsAndTheNewFileActions() {
        let names = [
            "title", "newTab", "quickLook", "showInFinder", "theme", "settings", "help", "clipboard", "viewOptions",
            "search",
        ]
        #expect(Self.sanitized(names) == names)
    }

    // T-01a55030 F-066
    @Test func givesEveryButtonACommandToRunApartFromTheOnesTheToolbarDrawsItself() {
        let drawnByTheToolbar: Set<ToolbarItemID> = [
            .back, .forward, .up, .view, .sort, .title, .clipboard, .viewOptions, .search, .foldersFirst, .hidden,
            .infoPanel, .infoRow, .theme, .topSeparator,
        ]
        let withoutCommand = ToolbarItems.ids.filter { ToolbarItems.definition($0).commandType == nil }
        #expect(withoutCommand.filter { !drawnByTheToolbar.contains($0) } == [])
    }

    // F-066
    @Test func theCatalogHoldsThe37Items() {
        #expect(ToolbarItems.ids.count == 37)
        #expect(Set(ToolbarItems.ids).count == 37)
        #expect(ToolbarItems.definitions.filter(\.allowDuplicates).map(\.id) == [.topSeparator])
        #expect(ToolbarItems.definitions.filter(\.topRequired).map(\.id) == [.title, .clipboard, .viewOptions, .search])
        #expect(ToolbarItems.definition(.editSelection).tooltipLabel == "Edit in Text Editor")
        #expect(ToolbarItems.definition(.help).tooltipLabel == "File Trail Help")
        #expect(ToolbarItems.definition(.trashSelection).shortcutCommand == .trashSelection)
        #expect(ToolbarItems.definition(.copySelection).shortcutCommand == .copy)
    }
}
