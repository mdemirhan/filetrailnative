import FTTestSupport
import Foundation
import Testing

@testable import FTFoundation

struct FlowListLayoutTests {
    static let layout = DesignTokens.flowList(density: .standard)
    /// Finder's sizes have compact rows: 24 points, columns 252 wide.
    static let finder = DesignTokens.flowList(density: .finder)

    @Test func usesTheDetailsViewRowPitchSoBothViewsHaveTheSameDensity() {
        #expect(Self.layout.rowHeight == DesignTokens.details(density: .standard).rowHeight)
        #expect(Self.finder.rowHeight == DesignTokens.details(density: .finder).rowHeight)
    }

    @Test func returnsTheCorrectColumnStepForEitherDensity() {
        #expect(Self.layout.columnStep == Self.layout.itemWidth + Self.layout.columnGap)
        #expect(Self.finder.columnStep == Self.finder.itemWidth + Self.finder.columnGap)
    }

    static func reveal(
        _ scrollLeft: Double, _ index: Int, finder: Bool = false, maxScrollLeft: Double = 3000
    ) -> Double {
        (finder ? Self.finder : Self.layout).revealScrollLeft(
            currentScrollLeft: scrollLeft, viewportWidth: 980, itemIndex: index, rowsPerColumn: 12,
            maxScrollLeft: maxScrollLeft)
    }

    @Test func keepsTheCurrentScrollWhenTheSelectedItemIsAlreadyFullyVisible() {
        #expect(Self.reveal(310, 24) == 310)
    }

    @Test func scrollsLeftToRevealAColumnThatMovedOutOfViewToTheLeft() {
        #expect(Self.reveal(620, 10) == 0)
    }

    @Test func scrollsRightJustEnoughToRevealAColumnThatMovedOutOfViewToTheRight() {
        #expect(Self.reveal(0, 36) == 262)
    }

    @Test func usesTheCompactColumnWidthWhenRevealingCompactListItems() {
        #expect(Self.reveal(0, 36, finder: true) == 102)
    }

    @Test func clampsTheRevealScrollOffsetToTheAvailableBounds() {
        #expect(Self.reveal(0, 120, maxScrollLeft: 1400) == 1400)
    }

    // Column-major places inside `padding: 8 10 4`; an item hugs its icon and name.
    @Test func itemsFillAColumnThenTheNext() {
        let style = FlowItemStyle.make()
        #expect(Self.layout.cellFrame(index: 0, rowsPerColumn: 10) == GridRect(x: 10, y: 8, width: 292, height: 28))
        #expect(Self.layout.cellFrame(index: 13, rowsPerColumn: 10) == GridRect(x: 320, y: 92, width: 292, height: 28))
        #expect(Self.layout.contentWidth(itemCount: 21, rowsPerColumn: 10) == 20 + 3 * 292 + 2 * 18)
        #expect(style.chromeWidth(layout: Self.layout) == 2 * 12 + 18 + 8)
        #expect(Self.layout.itemWidth(nameWidth: 40, style: style) == 90)
        #expect(Self.layout.itemWidth(nameWidth: 400, style: style) == 292)
        #expect(Self.finder.itemWidth(nameWidth: 400, style: style) == 252)
        #expect(Self.layout.items(left: 0, right: 330, itemCount: 100, rowsPerColumn: 10) == 0..<20)
        #expect(Self.layout.pageViewport(viewportWidth: 1000) == 998)
    }

    // MARK: The golden

    struct Input: Codable, Sendable {
        var op: String
        var compact: Bool?
        var height: Double?
        var itemCount: Int?
        var count: Int?
        var rowsPerColumn: Int?
        var columns: Int?
        var currentScrollLeft: Double?
        var viewportWidth: Double?
        var itemIndex: Int?
        var maxScrollLeft: Double?
        var itemSize: Double?
        var viewportSize: Double?
        var scrollOffset: Double?
        var overscan: Int?
    }

    enum Output: Codable, Equatable, Sendable {
        case number(Double)
        case rows([[Double]])
        case range(VirtualRange)
        case constants([String: Double])

        init(from decoder: any Decoder) throws {
            let single = try decoder.singleValueContainer()
            if let value = try? single.decode(Double.self) {
                self = .number(value)
            } else if let value = try? single.decode([[Double]].self) {
                self = .rows(value)
            } else if let value = try? single.decode(VirtualRange.self) {
                self = .range(value)
            } else {
                self = .constants(try single.decode([String: Double].self))
            }
        }

        func encode(to encoder: any Encoder) throws {
            var single = encoder.singleValueContainer()
            switch self {
            case .number(let value): try single.encode(value)
            case .rows(let value): try single.encode(value)
            case .range(let value): try single.encode(value)
            case .constants(let value): try single.encode(value)
            }
        }
    }

    static func run(_ input: Input) -> Output {
        let layout = DesignTokens.flowList(density: input.compact == true ? .finder : .standard)
        switch input.op {
        case "rows":
            return .number(Double(layout.rowsPerColumn(containerHeight: input.height ?? 0)))
        case "places":
            let rows = layout.rowsPerColumn(containerHeight: input.height ?? 0)
            return .rows(
                (0..<(input.itemCount ?? 0)).map { index in
                    let place = layout.place(index: index, rowsPerColumn: rows)
                    let frame = layout.cellFrame(index: index, rowsPerColumn: rows)
                    return [Double(place.column), Double(place.row), frame.x, frame.y]
                })
        case "columnMajor":
            let items = (0..<(input.count ?? 0)).map { Double($0 + 1) }
            return .rows(Virtualization.columnMajorRows(items, rowsPerColumn: input.rowsPerColumn ?? 0))
        case "chunk":
            let items = (0..<(input.count ?? 0)).map { Double($0 + 1) }
            return .rows(Virtualization.chunkIntoRows(items, columns: input.columns ?? 0))
        case "reveal":
            return .number(
                layout.revealScrollLeft(
                    currentScrollLeft: input.currentScrollLeft ?? 0, viewportWidth: input.viewportWidth ?? 0,
                    itemIndex: input.itemIndex ?? 0, rowsPerColumn: input.rowsPerColumn ?? 0,
                    maxScrollLeft: input.maxScrollLeft))
        case "range":
            return .range(
                Virtualization.range(
                    itemCount: input.itemCount ?? 0, itemSize: input.itemSize ?? 0,
                    viewportSize: input.viewportSize ?? 0, scrollOffset: input.scrollOffset ?? 0,
                    overscan: input.overscan ?? 0))
        default:
            return .constants([
                "rowHeight": layout.rowHeight, "rowGap": layout.rowGap, "itemWidth": layout.itemWidth,
                "columnGap": layout.columnGap, "paddingTop": layout.paddingTop, "paddingBottom": layout.paddingBottom,
                "paddingInline": layout.paddingInline, "columnStep": layout.columnStep,
            ])
        }
    }

    @Test func theCompactListMathMatchesTheReference() throws {
        let cases: [GoldenCase<Input, Output>] = try Golden.load(suite: "flow-list-layout")
        #expect(cases.count >= 500)
        Golden.expectMatches(cases) { Self.run($0) }
    }
}

struct VirtualizationTests {
    static let normal = FlowRowsLayout(rowHeight: 44, rowGap: 4, paddingTop: 10, paddingBottom: 4)
    static let compact = FlowRowsLayout(rowHeight: 36, rowGap: 2, paddingTop: 8, paddingBottom: 4)

    static func rows(_ height: Double, _ layout: FlowRowsLayout = normal) -> Int {
        Virtualization.rowsPerColumn(containerHeight: height, layout: layout)
    }

    @Test func computesRowsForAStandardViewport() {
        // 500 - 10 - 4 + 4 = 490; floor(490 / 44) = 11.
        #expect(Self.rows(500) == 11)
    }

    @Test func computesRowsWhenScrollbarHasAlreadyReducedClientHeight() {
        #expect(Self.rows(492) == 10)
    }

    @Test func returns1ForZeroOrNegativeContainerHeight() {
        #expect(Self.rows(0) == 1)
        #expect(Self.rows(-10) == 1)
    }

    @Test func handlesExactFitWithNoRemainder() {
        #expect(Self.rows(494) == 11)
    }

    @Test func dropsARowWhen1pxShortOfExactFit() {
        #expect(Self.rows(493) == 10)
    }

    @Test func handlesTheScrollbarBoundaryCorrectly() {
        #expect(Self.rows(494) == 11)
        #expect(Self.rows(486) == 10)
    }

    @Test func worksWithCompactLayout() {
        #expect(Self.rows(500, Self.compact) == 13)
    }

    @Test func worksWithCompactLayoutReducedByScrollbar() {
        #expect(Self.rows(492, Self.compact) == 13)
        #expect(Self.rows(472, Self.compact) == 12)
    }

    @Test func handlesVerySmallContainerGracefully() {
        #expect(Self.rows(50) == 1)
    }

    @Test func handlesContainerSmallerThanASingleRow() {
        #expect(Self.rows(20) == 1)
    }

    @Test func handlesARangeOfHeightsMatchingExpectedRowCounts() {
        #expect(Self.rows(230) == 5)
        #expect(Self.rows(229) == 4)
        #expect(Self.rows(450) == 10)
        #expect(Self.rows(449) == 9)
        #expect(Self.rows(670) == 15)
        #expect(Self.rows(669) == 14)
    }

    @Test func computesAStableVirtualRangeWithOverscan() {
        #expect(
            Virtualization.range(itemCount: 100, itemSize: 40, viewportSize: 200, scrollOffset: 160, overscan: 2)
                == VirtualRange(startIndex: 2, endIndex: 11))
    }

    @Test func returnsAnEmptyRangeWhenThereAreNoItems() {
        #expect(
            Virtualization.range(itemCount: 0, itemSize: 40, viewportSize: 200, scrollOffset: 0, overscan: 2)
                == VirtualRange(startIndex: 0, endIndex: 0))
    }

    @Test func clampsStaleScrollOffsetsSoANewShorterListStillRendersImmediately() {
        #expect(
            Virtualization.range(itemCount: 3, itemSize: 40, viewportSize: 200, scrollOffset: 4000, overscan: 2)
                == VirtualRange(startIndex: 0, endIndex: 3))
    }

    @Test func chunksItemsIntoEvenRowGroups() {
        #expect(Virtualization.chunkIntoRows([1, 2, 3, 4, 5], columns: 2) == [[1, 2], [3, 4], [5]])
    }

    @Test func buildsColumnMajorRowsForVerticalFirstLayouts() {
        #expect(
            Virtualization.columnMajorRows([1, 2, 3, 4, 5, 6, 7], rowsPerColumn: 3) == [[1, 4, 7], [2, 5], [3, 6]])
    }
}
