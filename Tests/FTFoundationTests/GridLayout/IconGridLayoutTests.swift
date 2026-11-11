import FTTestSupport
import Foundation
import Testing

@testable import FTFoundation

struct IconGridLayoutTests {
    static let layout = DesignTokens.iconGrid(density: .standard)
    static let finder = DesignTokens.iconGrid(density: .finder)

    /// The icon grid's fixed lengths, as the icon-grid-layout golden holds them.
    static func css() throws -> [String: Double] {
        let cases: [GoldenCase<Input, Output>] = try Golden.load(suite: "icon-grid-layout")
        guard let found = cases.first(where: { $0.input.op == "css" }), case .constants(let values) = found.output
        else { return [:] }
        return values
    }

    @Test func putsTheIconAsFarDownInItsItemAsTheStylesheetDoes() throws {
        let css = try Self.css()
        #expect(css["itemPaddingTop"] == Self.layout.itemPaddingTop)
    }

    @Test func takesClicksOnTheTileAndTheNameWhereTheStylesheetDrawsThem() throws {
        let css = try Self.css()
        #expect(css["iconBox"] == Self.layout.iconBoxSize)
        #expect(css["labelWidth"] == Self.layout.labelWidth)
        #expect(css["labelGap"] == Self.layout.labelGap)
    }

    // Finder's Icons view keeps 64 point icons in its default View Options, with 12 point names.
    @Test func findersSizesKeepTheGridAndTakeFindersSmallerNames() {
        var finder = Self.finder
        #expect(finder.labelFontSize == 12 && finder.labelLineHeight == 15)
        finder.labelFontSize = Self.layout.labelFontSize
        finder.labelLineHeight = Self.layout.labelLineHeight
        #expect(finder == Self.layout)
    }

    @Test func fitsAsManyColumnsAsThePaneHolds() {
        #expect(Self.layout.columns(containerWidth: 1000) == 9)
        #expect(Self.finder.columns(containerWidth: 1000) == 9)
        #expect(Self.layout.columns(containerWidth: 32 + 104 * 3) == 3)
        #expect(Self.layout.columns(containerWidth: 32 + 104 * 3 - 1) == 2)
    }

    @Test func keepsOneColumnForAPaneThatIsTooNarrowOrNotMeasuredYet() {
        #expect(Self.layout.columns(containerWidth: 0) == 1)
        #expect(Self.layout.columns(containerWidth: 60) == 1)
    }

    // MARK: Scrolling an item into view

    static func reveal(_ scrollTop: Double, _ index: Int, viewport: Double = 400) -> Double {
        layout.revealScrollTop(
            currentScrollTop: scrollTop, viewportHeight: viewport, itemIndex: index, itemCount: 100, columns: 5)
    }

    @Test func keepsTheScrollPositionWhenTheRowIsFullyVisible() {
        #expect(Self.reveal(100, 7) == 100)
    }

    @Test func scrollsUpToARowAboveTheViewport() {
        // Item 7 is in the second row, which starts below the top padding and one row.
        #expect(Self.reveal(500, 7) == Self.layout.paddingTop + Self.layout.rowHeight)
    }

    @Test func scrollsToTheVeryTopForTheFirstRow() {
        #expect(Self.reveal(500, 3) == 0)
    }

    @Test func scrollsDownJustFarEnoughForARowBelowTheViewport() {
        // Item 30 is in the seventh row.
        let rowBottom = Self.layout.paddingTop + 7 * Self.layout.rowHeight
        #expect(Self.reveal(0, 30) == rowBottom - 400)
    }

    @Test func bringsTheBottomPaddingInWithTheLastRow() {
        let rowBottom = Self.layout.paddingTop + 20 * Self.layout.rowHeight + Self.layout.paddingBottom
        #expect(Self.reveal(0, 99) == rowBottom - 400)
    }

    @Test func showsTheTopOfARowThatIsTallerThanTheViewport() {
        #expect(Self.reveal(0, 12, viewport: 80) == Self.layout.paddingTop + 2 * Self.layout.rowHeight)
    }

    // MARK: Where items sit

    // Items are centred in columns that share the grid's width; the tile is
    // `itemPaddingTop` down, the name `iconBoxSize + labelGap` below that.
    @Test func itemsSitInTheMiddleOfTheirColumns() {
        let style = IconItemStyle.make(density: .standard)
        let width = 1000.0
        let columns = Self.layout.columns(containerWidth: width)
        let columnWidth = (width - 32) / Double(columns)
        let first = Self.layout.itemFrame(index: 0, columns: columns, containerWidth: width, style: style)
        #expect(abs(first.x - (16 + (columnWidth - 104) / 2)) < 1e-9)
        #expect(first.y == 10 && first.width == 104 && first.height == 114)
        let second = Self.layout.itemFrame(index: columns + 1, columns: columns, containerWidth: width, style: style)
        #expect(second.y == 10 + 116)
        #expect(abs(second.x - (first.x + columnWidth)) < 1e-9)
        #expect(Self.layout.tileFrame(style: style) == GridRect(x: 16, y: 5, width: 72, height: 72))
        #expect(Self.layout.iconInset == 4)
        #expect(Self.layout.labelFrame(textWidth: 40, lines: 1) == GridRect(x: 28, y: 81, width: 48, height: 18))
        #expect(Self.layout.labelFrame(textWidth: 200, lines: 3) == GridRect(x: 1, y: 81, width: 102, height: 34))
        let finder = IconItemStyle.make(density: .finder)
        #expect(Self.finder.tileFrame(style: finder) == GridRect(x: 16, y: 5, width: 72, height: 72))
        #expect(Self.finder.labelFrame(textWidth: 200, lines: 2) == GridRect(x: 1, y: 81, width: 102, height: 32))
        #expect(Self.layout.contentHeight(itemCount: 19, columns: 9) == 10 + 3 * 116 + 10)
        #expect(style.renameHeight == 20 && finder.renameHeight == 19)
    }

    @Test func theRowsInABandAreTheOnesItMeets() {
        #expect(Self.layout.items(top: 0, bottom: 126, itemCount: 100, columns: 5) == 0..<5)
        #expect(Self.layout.items(top: 0, bottom: 127, itemCount: 100, columns: 5) == 0..<10)
        #expect(Self.layout.items(top: 2000, bottom: 9000, itemCount: 100, columns: 5) == 85..<100)
        #expect(Self.layout.items(top: 0, bottom: 100, itemCount: 0, columns: 5).isEmpty)
    }

    // MARK: The golden

    struct Input: Codable, Sendable {
        var op: String
        var width: Double?
        var currentScrollTop: Double?
        var viewportHeight: Double?
        var itemIndex: Int?
        var itemCount: Int?
        var columns: Int?
    }

    enum Output: Codable, Equatable, Sendable {
        case number(Double)
        case constants([String: Double])
        case places([[Double]])

        init(from decoder: any Decoder) throws {
            let single = try decoder.singleValueContainer()
            if let value = try? single.decode(Double.self) {
                self = .number(value)
            } else if let value = try? single.decode([[Double]].self) {
                self = .places(value)
            } else {
                self = .constants(try single.decode([String: Double].self))
            }
        }

        func encode(to encoder: any Encoder) throws {
            var single = encoder.singleValueContainer()
            switch self {
            case .number(let value): try single.encode(value)
            case .constants(let value): try single.encode(value)
            case .places(let value): try single.encode(value)
            }
        }
    }

    static func run(_ input: Input) -> Output {
        let layout = DesignTokens.iconGrid(density: .standard)
        let style = IconItemStyle.make(density: .standard)
        switch input.op {
        case "columns":
            return .number(Double(layout.columns(containerWidth: input.width ?? 0)))
        case "reveal":
            return .number(
                layout.revealScrollTop(
                    currentScrollTop: input.currentScrollTop ?? 0, viewportHeight: input.viewportHeight ?? 0,
                    itemIndex: input.itemIndex ?? 0, itemCount: input.itemCount ?? 0, columns: input.columns ?? 1))
        case "places":
            // Every item's column, row and left edge in a grid of this width.
            let width = input.width ?? 0
            let columns = layout.columns(containerWidth: width)
            return .places(
                (0..<(input.itemCount ?? 0)).map { index in
                    let frame = layout.itemFrame(index: index, columns: columns, containerWidth: width, style: style)
                    return [
                        Double(index % columns), Double(index / columns), (frame.x * 1000).rounded() / 1000, frame.y,
                    ]
                })
        case "css":
            return .constants([
                "itemPaddingTop": layout.itemPaddingTop, "iconBox": layout.iconBoxSize, "labelWidth": layout.labelWidth,
                "labelGap": layout.labelGap,
            ])
        default:
            return .constants([
                "iconSize": layout.iconSize, "cellMinWidth": layout.cellMinWidth, "rowHeight": layout.rowHeight,
                "itemPaddingTop": layout.itemPaddingTop, "iconBoxSize": layout.iconBoxSize,
                "labelGap": layout.labelGap, "labelWidth": layout.labelWidth, "paddingTop": layout.paddingTop,
                "paddingBottom": layout.paddingBottom, "paddingInline": layout.paddingInline,
            ])
        }
    }

    @Test func theGridMathMatchesTheGoldenFile() throws {
        let cases: [GoldenCase<Input, Output>] = try Golden.load(suite: "icon-grid-layout")
        #expect(cases.count >= 300)
        Golden.expectMatches(cases) { Self.run($0) }
    }
}
