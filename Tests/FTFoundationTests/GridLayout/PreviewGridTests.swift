// The Previews view's grid: 9, 4, 2 or 1 previews fill the pane, as large as that many fit
import Testing

@testable import FTFoundation

struct PreviewGridTests {
    private let base = DesignTokens.iconGrid(density: .standard)

    @Test func theCountsGoFromNineToOneInTheirShapes() {
        #expect(PreviewGrid.counts == [9, 4, 2, 1])
        #expect(PreviewGrid.shape(9) == (3, 3))
        #expect(PreviewGrid.shape(4) == (2, 2))
        #expect(PreviewGrid.shape(2) == (2, 1))
        #expect(PreviewGrid.shape(1) == (1, 1))
        #expect(PreviewGrid.valid(3) == 4)
        #expect(PreviewGrid.index(of: 9) == 0 && PreviewGrid.index(of: 1) == 3)
        #expect(PreviewGrid.label(4) == "4 at a time" && PreviewGrid.label(1) == "1 at a time")
    }

    @Test func thePreviewsFillThePaneWithExactlyTheirColumnsAndRows() {
        for count in PreviewGrid.counts {
            let (columns, rows) = PreviewGrid.shape(count)
            let grid = PreviewGrid.layout(base: base, count: count, width: 1200, height: 800)
            #expect(grid.columns(containerWidth: 1200) == columns)
            // The rows share the pane's height exactly: nothing of the next row shows.
            #expect(grid.paddingTop == 0 && grid.paddingBottom == 0)
            #expect(Double(rows) * grid.rowHeight == 800)
            // The preview and its name sit in the middle of the row.
            #expect(grid.itemPaddingTop + grid.iconBoxSize <= grid.rowHeight)
        }
        // Fewer previews are larger.
        let sides = PreviewGrid.counts.map {
            PreviewGrid.layout(base: base, count: $0, width: 1200, height: 800).iconSize
        }
        #expect(sides == sides.sorted())
    }

    @Test func aPaneHalfAsWideShowsAsManySmaller() {
        let full = PreviewGrid.layout(base: base, count: 4, width: 1600, height: 2000)
        let half = PreviewGrid.layout(base: base, count: 4, width: 800, height: 2000)
        #expect(half.columns(containerWidth: 800) == 2)
        #expect(half.iconSize < full.iconSize)
        // A tiny pane still shows previews 32 points across.
        #expect(PreviewGrid.layout(base: base, count: 9, width: 120, height: 90).iconSize == 32)
    }

    @Test func aScrollSettlesOnTheNearestRow() {
        #expect(PreviewGrid.snappedScrollTop(390, rowHeight: 400, maxScrollTop: 4000) == 400)
        #expect(PreviewGrid.snappedScrollTop(190, rowHeight: 400, maxScrollTop: 4000) == 0)
        #expect(PreviewGrid.snappedScrollTop(3990, rowHeight: 400, maxScrollTop: 3900) == 3900)
    }
}
