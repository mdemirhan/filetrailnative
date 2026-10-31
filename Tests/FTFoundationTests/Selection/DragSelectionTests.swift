// Port of apps/desktop/src/renderer/lib/dragSelection.test.ts
import Testing

@testable import FTFoundation

struct DragSelectionTests {
    private let entries = (0..<10).map { "/demo/item-\($0)" }

    private func names(_ hits: [DragSelectionHit]) -> [String] {
        hits.map { $0.path.replacingOccurrences(of: "/demo/", with: "") }
    }

    // T-cde8b505 F-784
    @Test func makesABoxWhicheverWayThePointerMovesFromWhereItStarted() {
        #expect(
            DragSelection.box(from: (50, 80), to: (10, 20))
                == DragSelectionBox(left: 10, top: 20, right: 50, bottom: 80))
    }

    // T-ced97aea F-784 B-SEL-149
    @Test func addsWithShiftFlipsWithCmdAndOtherwiseReplaces() {
        #expect(DragSelection.mode(meta: false, shift: false) == .replace)
        #expect(DragSelection.mode(meta: false, shift: true) == .add)
        #expect(DragSelection.mode(meta: true, shift: false) == .toggle)
        #expect(DragSelection.mode(meta: true, shift: true) == .toggle)
    }

    // T-329989e4 F-784 B-SEL-149
    // B-SEL-153 B-VIEW-079
    @Test func combinesWhatTheBoxTouchesWithTheSelectionTheDragStartedWith() {
        #expect(DragSelection.combine(startPaths: ["a", "b"], hitPaths: ["b", "c"], mode: .replace) == ["b", "c"])
        #expect(DragSelection.combine(startPaths: ["a", "b"], hitPaths: ["b", "c"], mode: .add) == ["a", "b", "c"])
        #expect(DragSelection.combine(startPaths: ["a", "b"], hitPaths: ["b", "c"], mode: .toggle) == ["a", "c"])
    }

    // T-f691a93e F-784 B-SEL-154
    // B-VIEW-082
    @Test func selectsTheListViewsRowsTheBoxTouchesHoweverLittle() {
        func hit(_ top: Double, _ bottom: Double) -> [String] {
            names(
                DragSelection.detailsItems(
                    box: DragSelectionBox(left: 40, top: top, right: 60, bottom: bottom), entryPaths: entries,
                    rowHeight: 28))
        }
        #expect(hit(30, 60) == ["item-1", "item-2"])
        // Ends exactly where row 2 starts: row 2 is not touched.
        #expect(hit(30, 56) == ["item-1"])
        #expect(hit(-20, 1) == ["item-0"])
        // Below the last row.
        #expect(hit(290, 400) == [])
    }

    // T-fc34240d T-132cae07 F-784 B-SEL-155
    // B-VIEW-039 B-VIEW-082
    @Test func selectsTheFlowListsItemsColumnByColumn() {
        let layout = DesignTokens.flowList(density: .comfortable)
        let step = layout.itemWidth + layout.columnGap
        func hit(
            _ left: Double, _ right: Double, _ top: Double, _ bottom: Double,
            sizes: [String: DragSelectionSize] = [:]
        ) -> [String] {
            names(
                DragSelection.flowListItems(
                    box: DragSelectionBox(left: left, top: top, right: right, bottom: bottom), entryPaths: entries,
                    rowsPerColumn: 4, rowHeight: layout.rowHeight, itemWidth: layout.itemWidth,
                    columnGap: layout.columnGap, sizes: sizes))
        }
        // Rows 1 and 2 of the first two columns.
        #expect(hit(100, step + 5, 30, 60) == ["item-1", "item-2", "item-5", "item-6"])
        // In the gap between the columns: nothing.
        #expect(hit(layout.itemWidth, step, 0, 100) == [])
        // After a short name, measured on screen: only the item that has not been measured.
        #expect(hit(80, 200, 0, 40, sizes: ["/demo/item-0": DragSelectionSize(width: 70, height: 28)]) == ["item-1"])
        // The third column holds only items 8 and 9.
        #expect(hit(2 * step + 20, 2 * step + 30, 0, 200) == ["item-8", "item-9"])
    }

    // T-395f1dac T-a8349a96 F-784 B-SEL-156 B-SEL-157
    // B-VIEW-082
    @Test func selectsTheIconViewsItemsOnTheirIconsAndNamesOnly() {
        let layout = DesignTokens.iconGrid(density: .comfortable)
        let gridWidth = 4.0 * 150
        func hit(
            _ left: Double, _ right: Double, _ top: Double, _ bottom: Double,
            sizes: [String: DragSelectionSize] = [:]
        ) -> [String] {
            names(
                DragSelection.iconGridItems(
                    box: DragSelectionBox(left: left, top: top, right: right, bottom: bottom), entryPaths: entries,
                    columns: 4, gridWidth: gridWidth, layout: layout, sizes: sizes))
        }
        // In the first 150 pt column the tile spans 39 to 111 (5 to 77 down) and a name at its widest 24 to 126 (81 to
        // 114 down).
        #expect(hit(0, 20, 0, 300) == [])
        #expect(hit(0, 30, 0, 320) == ["item-0", "item-4", "item-8"])
        #expect(hit(0, 35, 0, 78) == [])
        #expect(hit(100, 200, 10, 20) == ["item-0", "item-1"])
        // A short name, measured on screen, leaves the space beside and below it empty.
        let shortName = ["/demo/item-0": DragSelectionSize(width: 40, height: 18)]
        #expect(hit(26, 38, 82, 98) == ["item-0"])
        #expect(hit(26, 38, 82, 98, sizes: shortName) == [])
        #expect(hit(60, 90, 100, 110, sizes: shortName) == [])
        // Above row 1's tiles, in the padding at the top of its items: nothing from row 1.
        let row1 = layout.rowHeight
        #expect(hit(40, 100, row1 - 1, row1 + layout.itemPaddingTop) == [])
        #expect(hit(40, 100, row1 - 1, row1 + layout.itemPaddingTop + 1) == ["item-4"])
        // Row 2 holds items 8 and 9 only.
        #expect(hit(0, gridWidth, 2 * layout.rowHeight + 5, 400) == ["item-8", "item-9"])
    }

    // T-a943e644 F-784 B-SEL-158
    @Test func scrollsFasterTheFurtherPastTheEdgeThePointerIs() {
        #expect(DragSelection.autoScrollStep(overshoot: 0) == 0)
        #expect(DragSelection.autoScrollStep(overshoot: 3) == 5)
        #expect(DragSelection.autoScrollStep(overshoot: -30) == -14)
        #expect(DragSelection.autoScrollStep(overshoot: 500) == 40)
    }

    // B-SEL-151: the lead at button up is the touched item nearest the pointer, else the last one selected.
    // B-VIEW-080
    @Test func theLeadIsTheTouchedItemNearestThePointer() {
        let hits = DragSelection.detailsItems(
            box: DragSelectionBox(left: 0, top: 30, right: 100, bottom: 120), entryPaths: entries, rowHeight: 28)
        #expect(
            DragSelection.nearestLead(hits: hits, pointer: (50, 118), shownPaths: hits.map(\.path)) == "/demo/item-4")
        #expect(
            DragSelection.nearestLead(hits: hits, pointer: (50, 31), shownPaths: hits.map(\.path)) == "/demo/item-1")
        #expect(
            DragSelection.nearestLead(hits: [], pointer: (0, 0), shownPaths: ["/demo/item-2", "/demo/item-3"])
                == "/demo/item-3")
    }
}
