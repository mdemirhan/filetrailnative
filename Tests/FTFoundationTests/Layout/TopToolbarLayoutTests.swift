// Ports apps/desktop/src/renderer/lib/topToolbarLayout.test.ts
import Testing

@testable import FTFoundation

struct TopToolbarLayoutTests {
    let layout = DesignTokens.toolbar

    func keys(_ slots: [TopToolbarSlot]) -> [String] { slots.map(\.key) }

    func slots(_ ids: [ToolbarItemID]) -> [TopToolbarSlot] { TopToolbarLayout.slots(ids) }

    /// Widths for a row whose buttons are all 32 wide.
    func widths(_ slots: [TopToolbarSlot], _ width: Double = 32) -> [String: Double] {
        Dictionary(slots.map { ($0.key, width) }, uniquingKeysWith: { first, _ in first })
    }

    /// The narrowest a row of 32-wide items, the title and the search field can be.
    func minRowWidth(_ row: [TopToolbarSlot]) -> Double {
        let fixedCount = row.filter { $0.id != .title && $0.id != .search }.count
        let capsuleEnds = TopToolbarLayout.capsules(row).values.reduce(0) {
            $0 + ($1.start ? 1 : 0) + ($1.end ? 1 : 0)
        }
        return Double(fixedCount) * 32 + layout.titleMinWidth + layout.searchMinWidth + 2 * layout.edgedItemInset
            + Double(capsuleEnds) * (layout.capsulePadding + layout.edgedItemInset)
            + Double(row.count - 1) * layout.itemGap
    }

    var overflowRoom: Double {
        layout.itemGap + layout.overflowButtonWidth + 2 * (layout.capsulePadding + layout.edgedItemInset)
    }

    // T-fc2f1ec9 (the stylesheet's sizes are checked against the reference in ToolbarLayoutGoldenTests)
    @Test func hasTheSizesTheStylesheetLaysTheToolbarOutFrom() {
        #expect(layout.itemGap == 2)
        #expect(layout.edgedItemInset == 5)
        #expect(layout.capsulePadding == 3)
        #expect(layout.titleMinWidth == 96)
        #expect(layout.overflowButtonWidth == 32)
        #expect(layout.searchWidth == 200)
        #expect(layout.searchMinWidth == 110)
    }

    // T-d4d1b659 B-VIEW-109
    @Test func keysEachItemByItsIdAndRepeatedSeparatorsByTheirCount() {
        #expect(
            keys(slots([.back, .topSeparator, .title, .topSeparator, .search]))
                == ["back", "topSeparator", "title", "topSeparator:1", "search"])
    }

    let selection: [ToolbarItemID] = [.back, .forward, .title, .view, .sort, .viewOptions, .search, .copyPath]

    // T-776a8dab B-VIEW-115
    @Test func keepsTheRemovableItemsFromTheStartAndEveryRequiredItem() {
        let row = slots(selection)
        #expect(keys(TopToolbarLayout.select(row, optionalCount: 5)) == keys(row))
        #expect(
            keys(TopToolbarLayout.select(row, optionalCount: 3)) == [
                "back", "forward", "title", "view", "viewOptions", "search",
            ])
        #expect(keys(TopToolbarLayout.select(row, optionalCount: 0)) == ["title", "viewOptions", "search"])
    }

    // T-5bde4d3e B-VIEW-113
    @Test func dropsSeparatorsLeftWithNothingToDivide() {
        let row = slots([
            .topSeparator, .back, .topSeparator, .topSeparator, .title, .view, .topSeparator, .sort, .search,
            .topSeparator,
        ])
        #expect(
            keys(TopToolbarLayout.select(row, optionalCount: 7)) == [
                "back", "topSeparator:1", "title", "view", "topSeparator:3", "sort", "search",
            ])
        #expect(keys(TopToolbarLayout.select(row, optionalCount: 2)) == ["back", "title", "search"])
    }

    var fitRow: [TopToolbarSlot] { slots([.back, .forward, .title, .view, .sort, .clipboard, .viewOptions, .search]) }

    // T-fd0b32ba B-VIEW-114
    @Test func keepsEveryItemWhileTheTitleAndSearchFieldCanStillGiveRoom() {
        let row = fitRow
        let measured = widths(row)
        #expect(TopToolbarLayout.visibleOptionalCount(slots: row, widths: measured, availableWidth: 1200) == 4)
        #expect(
            TopToolbarLayout.visibleOptionalCount(
                slots: row, widths: measured,
                availableWidth: minRowWidth(TopToolbarLayout.select(row, optionalCount: 4))) == 4)
    }

    // T-0ff98e2e B-VIEW-114 B-VIEW-115
    @Test func hidesTheRemovableItemsNearestTheEndFirstAndNeverARequiredOne() {
        let row = fitRow
        let measured = widths(row)
        func fit(_ width: Double) -> Int {
            TopToolbarLayout.visibleOptionalCount(slots: row, widths: measured, availableWidth: width)
        }
        func needs(_ count: Int) -> Double {
            minRowWidth(TopToolbarLayout.select(row, optionalCount: count)) + (count < 4 ? overflowRoom : 0)
        }
        #expect(fit(needs(4) - 1) < 4)
        var width = needs(0)
        while width <= needs(4) {
            let count = fit(width)
            #expect(needs(count) <= width, "\(width)")
            if count < 4 { #expect(needs(count + 1) > width, "\(width)") }
            width += 3
        }
        #expect(fit(40) == 0)
    }

    // T-30d2ceed
    @Test func countsAWiderClipboardButtonAgainstTheButtons() {
        let row = fitRow
        var measured = widths(row)
        measured["clipboard"] = 60
        #expect(
            TopToolbarLayout.visibleOptionalCount(
                slots: row, widths: measured,
                availableWidth: minRowWidth(TopToolbarLayout.select(row, optionalCount: 4))) < 4)
    }

    // T-de64243f
    @Test func doesNotCountASeparatorThatWouldBeDropped() {
        let row = slots([.back, .title, .search, .topSeparator, .sort])
        var measured = widths(row)
        measured["topSeparator"] = 11
        #expect(
            TopToolbarLayout.visibleOptionalCount(
                slots: row, widths: measured,
                availableWidth: minRowWidth(TopToolbarLayout.select(row, optionalCount: 2)) + overflowRoom) == 2)
        #expect(keys(TopToolbarLayout.select(row, optionalCount: 2)) == ["back", "title", "search"])
    }

    // T-f7127f9d B-VIEW-115
    @Test func keepsTheWholeToolbarUntilItHasBeenLaidOut() {
        let row = fitRow
        #expect(TopToolbarLayout.visibleOptionalCount(slots: row, widths: [:], availableWidth: 300) == 4)
        #expect(TopToolbarLayout.visibleOptionalCount(slots: row, widths: widths(row), availableWidth: 0) == 4)
    }

    // T-804fd7a7 B-VIEW-112
    @Test func putsButtonsSideBySideOnOneCapsuleAndLeavesTheTitleSearchAndViewSwitchOff() {
        let row = slots([.back, .forward, .title, .clipboard, .view, .sort, .search, .viewOptions, .infoPanel])
        #expect(
            TopToolbarLayout.capsules(row) == [
                "back": .init(start: true, end: false), "forward": .init(start: false, end: true),
                "clipboard": .init(start: true, end: true), "sort": .init(start: true, end: true),
                "viewOptions": .init(start: true, end: false), "infoPanel": .init(start: false, end: true),
            ])
    }

    // T-519f9c74 B-VIEW-112
    @Test func joinsTheButtonsOnEitherSideOfAnItemThatIsNotShown() {
        let row = slots([.sort, .clipboard, .viewOptions])
        #expect(
            TopToolbarLayout.capsules(row) { $0.id != .clipboard } == [
                "sort": .init(start: true, end: false), "viewOptions": .init(start: false, end: true),
            ])
    }

    // T-8e161dd6 B-VIEW-135
    @Test func landsADraggedItemAfterEveryItemWhoseMiddleIsLeftOfThePointer() {
        let centers: [Double] = [20, 60, 300, 520]
        #expect(TopToolbarLayout.dropIndex(centers: centers, pointerX: 5) == 0)
        #expect(TopToolbarLayout.dropIndex(centers: centers, pointerX: 61) == 2)
        #expect(TopToolbarLayout.dropIndex(centers: centers, pointerX: 900) == 4)
        #expect(TopToolbarLayout.dropIndex(centers: [], pointerX: 100) == 0)
    }

    // F-708 F-709 F-710: the default toolbar, laid out as the original's flexbox lays it out (1200 pt window,
    // 280 pt tree): every item where the Electron capture has it.
    @Test func laysTheDefaultRowOutWhereTheOriginalDrawsIt() {
        let row = TopToolbarLayout.slots(ToolbarItems.defaultTopItems).filter { $0.id != .clipboard }
        let widths: [String: Double] = [
            "folderTree": 32, "topSeparator": 0, "back": 32, "forward": 32, "view": 122, "sort": 32,
            "viewOptions": 32, "infoPanel": 32,
        ]
        let placed = TopToolbarRow.place(
            row, widths: widths, capsules: TopToolbarLayout.capsules(row), overflow: false, rowWidth: 892,
            titleMinWidth: 96)
        // The row starts 8 pt into the toolbar, which starts at 288.
        func x(_ key: String) -> Double? { placed.places[key].map { 296 + $0.x } }
        #expect(x("folderTree") == 304)
        #expect(x("back") == 356)
        #expect(x("title") == 432)
        #expect(placed.places["title"]?.width == 286)
        #expect(x("view") == 720)
        #expect(x("search") == 894)
        #expect(placed.places["search"]?.width == 210)
        #expect(x("viewOptions") == 1114)
        #expect(x("infoPanel") == 1148)
        #expect(placed.contentWidth == 892)
    }

    // F-716: the title gives up its room before the search field does, and the search field stops at its minimum.
    @Test func shrinksTheTitleFirstThenTheSearchField() {
        let row = TopToolbarLayout.slots([.title, .search])
        func place(_ width: Double) -> TopToolbarRow {
            TopToolbarRow.place(
                row, widths: [:], capsules: [:], overflow: false, rowWidth: width, titleMinWidth: 96)
        }
        #expect(place(400).places["title"]?.width == 188)
        #expect(place(308).places["title"]?.width == 96)
        #expect(place(308).places["search"]?.width == 210)
        #expect(place(250).places["search"]?.width == 152)
        #expect(place(100).places["search"]?.width == 120)
    }
}
