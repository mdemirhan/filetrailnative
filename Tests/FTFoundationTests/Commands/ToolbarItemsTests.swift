import Testing

@testable import FTFoundation

struct ToolbarItemsTests {
    static func list(_ names: [String]) -> JSONNode { .array(names.map(JSONNode.string)) }

    static func sanitized(_ names: [String]) -> [String] {
        ToolbarItems.sanitizeTopItems(list(names)).map(\.rawValue)
    }

    static let defaults = ToolbarItems.defaultTopItems

    @Test func keepsATopToolbarsOrderTheFixedItemsWhereverTheyWerePut() {
        let customized = [
            "search", "back", "viewOptions", "topSeparator", "sort", "title", "topSeparator", "clipboard", "view",
        ]
        #expect(Self.sanitized(customized) == customized)
        #expect(ToolbarItems.sanitizeTopItems(Self.list(Self.defaults.map(\.rawValue))) == Self.defaults)
    }

    @Test func dropsItemsThatAreUnknownOrRepeated() {
        #expect(
            Self.sanitized([
                "back", "title", "title", "back", "leftSeparator", "nonsense", "search", "openSelection", "clipboard",
                "viewOptions", "search",
            ]) == ["back", "title", "search", "openSelection", "clipboard", "viewOptions"])
    }

    @Test func putsAFixedItemThatAListIsMissingAtTheEnd() {
        #expect(Self.sanitized(["search", "back", "title"]) == ["search", "back", "title", "viewOptions"])
        #expect(Self.sanitized(["back", "view"]) == ["back", "view", "title", "search", "viewOptions"])
        #expect(ToolbarItems.sanitizeTopItems(.null).map(\.rawValue) == ["title", "search", "viewOptions"])
    }

    // The clipboard and Undo History buttons can be taken off, and stay off; a new toolbar has the clipboard's only,
    // and the Undo History button is one to add.
    @Test func letsTheClipboardAndUndoHistoryButtonsBeTakenOff() {
        #expect(
            Self.sanitized(["back", "title", "search", "viewOptions"]) == ["back", "title", "search", "viewOptions"])
        #expect(
            Self.sanitized(["title", "undoHistory", "search", "viewOptions"]) == [
                "title", "undoHistory", "search", "viewOptions",
            ])
        #expect(Self.defaults.contains(.clipboard))
        #expect(!Self.defaults.contains(.undoHistory))
        let palette = ToolbarItems.paletteItems(excluding: [.title, .search, .viewOptions])
        for id in [ToolbarItemID.clipboard, .undoHistory, .undo, .redo] {
            #expect(palette.contains(id), "\(id)")
        }
    }

    // While the toolbar is short of room, these stay as long as the items that can't be taken off.
    @Test func keepsTheClipboardAndUndoHistoryButtonsWhileRoomIsShort() {
        let high = ToolbarItems.definitions.filter(\.highPriority).map(\.id)
        #expect(high == [.title, .clipboard, .undoHistory, .viewOptions, .search])
    }

    @Test func preservesRepeatableSeparatorItemsWhileStillDedupingNormalItems() {
        #expect(
            Self.sanitized([
                "topSeparator", "back", "topSeparator", "back", "title", "clipboard", "search", "viewOptions",
            ]) == ["topSeparator", "back", "topSeparator", "title", "clipboard", "search", "viewOptions"])
    }

    // A space with nothing to divide isn't drawn: at either end, or right after another.
    @Test func dropsSeparatorsLeftWithNothingToDivide() {
        #expect(
            ToolbarItems.withoutIdleSeparators([
                .topSeparator, .back, .topSeparator, .topSeparator, .title, .view, .topSeparator, .sort, .search,
                .topSeparator,
            ]) == [.back, .topSeparator, .title, .view, .topSeparator, .sort, .search])
        #expect(ToolbarItems.withoutIdleSeparators([.topSeparator]) == [])
    }

    @Test func offersEveryItemThatCanBeTakenOffSoEachCanBePutBack() {
        let palette = ToolbarItems.paletteItems(excluding: [])
        let alwaysThere: Set<ToolbarItemID> = [.title, .search, .viewOptions]
        for id in ToolbarItems.ids where !alwaysThere.contains(id) {
            #expect(palette.contains(id), "\(id)")
        }
    }

    @Test func offersEveryItemTheToolbarDoesNotHoldAndTheSpaceAlways() {
        let palette = ToolbarItems.paletteItems(excluding: Self.defaults)
        #expect(palette.first == .topSeparator)
        #expect(palette.contains(.refresh))
        for id in Self.defaults where id != .topSeparator {
            #expect(!palette.contains(id), "\(id)")
        }
        #expect(ToolbarItems.paletteItems(excluding: Self.defaults + [.topSeparator]).contains(.topSeparator))
    }

    @Test func offersTheAppsOwnButtonsAndTheNewFileActions() {
        let names = [
            "title", "newTab", "quickLook", "showInFinder", "theme", "settings", "help", "clipboard", "viewOptions",
            "search",
        ]
        #expect(Self.sanitized(names) == names)
    }

    @Test func givesEveryButtonACommandToRunApartFromTheOnesTheToolbarDrawsItself() {
        let drawnByTheToolbar: Set<ToolbarItemID> = [
            .back, .forward, .up, .view, .sort, .title, .clipboard, .undoHistory, .viewOptions, .search, .foldersFirst,
            .hidden,
            .infoPanel, .infoRow, .theme, .topSeparator,
        ]
        let withoutCommand = ToolbarItems.ids.filter { ToolbarItems.definition($0).commandType == nil }
        #expect(withoutCommand.filter { !drawnByTheToolbar.contains($0) } == [])
    }

    @Test func theCatalogNamesEachItemOnce() {
        #expect(Set(ToolbarItems.ids).count == ToolbarItems.ids.count)
        #expect(ToolbarItems.definitions.filter(\.allowDuplicates).map(\.id) == [.topSeparator])
        #expect(ToolbarItems.definitions.filter(\.topRequired).map(\.id) == [.title, .viewOptions, .search])
        #expect(ToolbarItems.definition(.undo).shortcutCommand == .undo)
        #expect(ToolbarItems.definition(.redo).commandType == .redo)
        #expect(ToolbarItems.definition(.editSelection).tooltipLabel == "Edit in Text Editor")
        #expect(ToolbarItems.definition(.help).tooltipLabel == "File Trail Help")
        #expect(ToolbarItems.definition(.trashSelection).shortcutCommand == .trashSelection)
        #expect(ToolbarItems.definition(.copySelection).shortcutCommand == .copy)
    }
}
