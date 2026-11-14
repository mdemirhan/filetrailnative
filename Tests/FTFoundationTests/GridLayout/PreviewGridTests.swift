// The Previews view's grid: 9, 4, 2 or 1 previews fill the pane, each picture as large as its place allows
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

    @Test func thePlacesShareThePaneExactly() {
        for count in PreviewGrid.counts {
            let (columns, rows) = PreviewGrid.shape(count)
            let grid = PreviewGrid.layout(base: base, count: count, width: 1216, height: 800)
            #expect(grid.columns(containerWidth: 1216) == columns)
            #expect(grid.cellMinWidth == 1200 / Double(columns))
            // Nothing of the next row shows.
            #expect(grid.paddingTop == 0 && grid.paddingBottom == 0)
            #expect(Double(rows) * grid.rowHeight == 800)
        }
    }

    @Test func thePictureTakesItsPlaceLessTheMarginsAndTheName() {
        let grid = PreviewGrid.layout(base: base, count: 1, width: 1216, height: 800)
        let box = PreviewGrid.pictureBox(grid)
        #expect(box.width == 1200 - 12)
        #expect(box.height == 800 - 2 - 12 - grid.labelGap - (2 * grid.labelLineHeight + 2 * grid.labelPaddingVertical))
        // A wide photo fills the width, a tall one the height; neither is stretched.
        let wide = PreviewGrid.fitted((4000, 2000), in: box)
        #expect(wide.width == box.width && wide.height < box.height)
        let tall = PreviewGrid.fitted((1000, 3000), in: box)
        #expect(tall.height == box.height && tall.width < box.width)
        // Fewer previews are larger.
        let sides = PreviewGrid.counts.map {
            PreviewGrid.layout(base: base, count: $0, width: 1216, height: 800).iconSize
        }
        #expect(sides == sides.sorted())
    }

    @Test func aSwipeSettlesOnTheNextRowTheWayItWentOrBack() {
        // A sixth of a row along goes on to the next; less goes back.
        #expect(PreviewGrid.snappedScrollTop(from: 0, to: 80, rowHeight: 400, maxScrollTop: 4000) == 400)
        #expect(PreviewGrid.snappedScrollTop(from: 0, to: 50, rowHeight: 400, maxScrollTop: 4000) == 0)
        #expect(PreviewGrid.snappedScrollTop(from: 800, to: 700, rowHeight: 400, maxScrollTop: 4000) == 400)
        #expect(PreviewGrid.snappedScrollTop(from: 800, to: 760, rowHeight: 400, maxScrollTop: 4000) == 800)
        // A long swipe goes as far as it went, within the content.
        #expect(PreviewGrid.snappedScrollTop(from: 0, to: 1300, rowHeight: 400, maxScrollTop: 4000) == 1600)
        #expect(PreviewGrid.snappedScrollTop(from: 3600, to: 3990, rowHeight: 400, maxScrollTop: 3900) == 3900)
    }
}
