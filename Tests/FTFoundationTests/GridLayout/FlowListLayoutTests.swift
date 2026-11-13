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

    // Items fill a column before the next, inside 8 of padding at the top, 10 at the sides and 4 at the bottom; an
    // item hugs its icon and name.
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
        var rowsPerColumn: Int?
        var currentScrollLeft: Double?
        var viewportWidth: Double?
        var itemIndex: Int?
        var maxScrollLeft: Double?
    }

    enum Output: Codable, Equatable, Sendable {
        case number(Double)
        case rows([[Double]])
        case constants([String: Double])

        init(from decoder: any Decoder) throws {
            let single = try decoder.singleValueContainer()
            if let value = try? single.decode(Double.self) {
                self = .number(value)
            } else if let value = try? single.decode([[Double]].self) {
                self = .rows(value)
            } else {
                self = .constants(try single.decode([String: Double].self))
            }
        }

        func encode(to encoder: any Encoder) throws {
            var single = encoder.singleValueContainer()
            switch self {
            case .number(let value): try single.encode(value)
            case .rows(let value): try single.encode(value)
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
        case "reveal":
            return .number(
                layout.revealScrollLeft(
                    currentScrollLeft: input.currentScrollLeft ?? 0, viewportWidth: input.viewportWidth ?? 0,
                    itemIndex: input.itemIndex ?? 0, rowsPerColumn: input.rowsPerColumn ?? 0,
                    maxScrollLeft: input.maxScrollLeft))
        default:
            return .constants([
                "rowHeight": layout.rowHeight, "rowGap": layout.rowGap, "itemWidth": layout.itemWidth,
                "columnGap": layout.columnGap, "paddingTop": layout.paddingTop, "paddingBottom": layout.paddingBottom,
                "paddingInline": layout.paddingInline, "columnStep": layout.columnStep,
            ])
        }
    }

    @Test func theCompactListMathMatchesTheGoldenFile() throws {
        let cases: [GoldenCase<Input, Output>] = try Golden.load(suite: "flow-list-layout")
        #expect(cases.count >= 500)
        Golden.expectMatches(cases) { Self.run($0) }
    }
}

struct RowsPerColumnTests {
    static func layout(rowHeight: Double, rowGap: Double, paddingTop: Double, paddingBottom: Double)
        -> FlowListLayout
    {
        var layout = DesignTokens.flowList(density: .standard)
        layout.rowHeight = rowHeight
        layout.rowGap = rowGap
        layout.paddingTop = paddingTop
        layout.paddingBottom = paddingBottom
        return layout
    }

    static let normal = layout(rowHeight: 44, rowGap: 4, paddingTop: 10, paddingBottom: 4)
    static let compact = layout(rowHeight: 36, rowGap: 2, paddingTop: 8, paddingBottom: 4)

    static func rows(_ height: Double, _ layout: FlowListLayout = normal) -> Int {
        layout.rowsPerColumn(containerHeight: height)
    }

    // Rows fit inside the padding, a row gap between each: 500 - 10 - 4 + 4 = 490, floor(490 / 44) = 11. A height the
    // scroll bar has already taken from, an exact fit and one point short of it, and a container smaller than a row
    // (or of no height) that still has one.
    @Test func fitsTheRowsOfAColumnInTheHeight() {
        let normal: [(height: Double, rows: Int)] = [
            (500, 11), (492, 10), (494, 11), (493, 10), (486, 10), (0, 1), (-10, 1), (50, 1), (20, 1), (230, 5),
            (229, 4), (450, 10), (449, 9), (670, 15), (669, 14),
        ]
        for fit in normal { #expect(Self.rows(fit.height) == fit.rows, "\(fit.height)") }
        let compact: [(height: Double, rows: Int)] = [(500, 13), (492, 13), (472, 12)]
        for fit in compact { #expect(Self.rows(fit.height, Self.compact) == fit.rows, "compact \(fit.height)") }
    }
}

/// Resizing the Compact List's columns in place.
struct FlowListResizeTests {
    static let standard = DesignTokens.flowList(density: .standard)

    // The column at the left of the view is the one whose step holds the scroll offset.
    @Test func findsTheColumnAtTheLeftOfTheView() {
        let layout = Self.standard
        #expect(layout.column(atScrollLeft: 0) == 0)
        #expect(layout.column(atScrollLeft: 10 + 309) == 0)
        #expect(layout.column(atScrollLeft: 10 + 310) == 1)
        #expect(layout.column(atScrollLeft: 10 + 3 * 310 + 5) == 3)
        #expect(layout.column(atScrollLeft: -40) == 0)
    }

    // That column's left edge stays put: the columns before it grew by as much each, so the list scrolls by that.
    @Test func keepsTheColumnsLeftEdgeInPlace() {
        var wider = Self.standard
        wider.itemWidth = 352
        #expect(wider.anchoredScrollLeft(column: 0, startWidth: 292, startScrollLeft: 40) == 40)
        #expect(wider.anchoredScrollLeft(column: 3, startWidth: 292, startScrollLeft: 40) == 40 + 3 * 60)
        let before = Self.standard.paddingInline + 3 * Self.standard.columnStep - 40
        let after = wider.paddingInline + 3 * wider.columnStep - (40 + 3 * 60)
        #expect(before == after)
    }
}

/// The icon grid at another icon size.
struct IconGridSizeTests {
    static let base = DesignTokens.iconGrid(density: .standard)

    // At 64 the grid is as it was; larger icons widen the tile, the column, the label and the row with them.
    @Test func theGridGrowsWithTheIcon() {
        #expect(Self.base.sized(iconSize: 64) == Self.base)
        let large = Self.base.sized(iconSize: 128)
        #expect(large.iconSize == 128 && large.iconBoxSize == 136)
        #expect(large.cellMinWidth == 168 && large.labelWidth == 166)
        #expect(large.rowHeight == 180)
        #expect(large.iconInset == 4)
    }

    // Smaller icons keep the column wide enough for two lines of name.
    @Test func smallIconsKeepRoomForTheirNames() {
        let small = Self.base.sized(iconSize: 32)
        #expect(small.iconBoxSize == 40)
        #expect(small.cellMinWidth == 104 && small.labelWidth == 102)
        #expect(small.rowHeight == 84)
        #expect(small.columns(containerWidth: 1000) == Self.base.columns(containerWidth: 1000))
    }
}
