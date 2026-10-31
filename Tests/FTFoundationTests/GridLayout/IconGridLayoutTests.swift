// Ports apps/desktop/src/renderer/lib/iconGridLayout.test.ts, and checks the grid math against the golden recorded from
// the reference (tools/parity/golden/icon-grid-layout.ts)
import FTTestSupport
import Foundation
import Testing

@testable import FTFoundation

struct IconGridLayoutTests {
    static let layout = DesignTokens.iconGrid(density: .comfortable)
    static let compact = DesignTokens.iconGrid(density: .compact)

    /// The stylesheet's numbers, as the golden recorded them from the reference's `styles.css`.
    static func css() throws -> [String: Double] {
        let cases: [GoldenCase<Input, Output>] = try Golden.load(suite: "icon-grid-layout")
        guard let found = cases.first(where: { $0.input.op == "css" }), case .constants(let values) = found.output
        else { return [:] }
        return values
    }

    // T-7bc9401f F-757 B-VIEW-017
    @Test func putsTheIconAsFarDownInItsItemAsTheStylesheetDoes() throws {
        let css = try Self.css()
        #expect(css["itemPaddingTop"] == Self.layout.itemPaddingTop)
        #expect(css["compactItemPaddingTop"] == Self.compact.itemPaddingTop)
    }

    // T-ff73f27d F-757 F-760 B-VIEW-025
    @Test func takesClicksOnTheTileAndTheNameWhereTheStylesheetDrawsThem() throws {
        let css = try Self.css()
        #expect(css["iconBox"] == Self.layout.iconBoxSize && css["compactIconBox"] == Self.compact.iconBoxSize)
        #expect(css["labelWidth"] == Self.layout.labelWidth && css["compactLabelWidth"] == Self.compact.labelWidth)
        #expect(css["labelGap"] == Self.layout.labelGap && css["compactLabelGap"] == Self.compact.labelGap)
    }

    // T-a8a78af5 F-757 B-VIEW-005 B-VIEW-017
    @Test func usesSmallerIconsAndTighterRowsInCompactMode() {
        #expect(DesignTokens.iconGrid(density: .comfortable) == Self.layout)
        #expect(DesignTokens.iconGrid(density: .compact) == Self.compact)
        #expect(Self.compact.iconSize < Self.layout.iconSize)
        #expect(Self.compact.rowHeight < Self.layout.rowHeight)
        #expect(Self.compact.cellMinWidth < Self.layout.cellMinWidth)
    }

    // T-71a44152 F-758 B-VIEW-018
    @Test func fitsAsManyColumnsAsThePaneHoldsAndMoreOfThemWhenCompact() {
        #expect(Self.layout.columns(containerWidth: 1000) == 9)
        #expect(Self.compact.columns(containerWidth: 1000) == 11)
        #expect(Self.layout.columns(containerWidth: 32 + 104 * 3) == 3)
        #expect(Self.layout.columns(containerWidth: 32 + 104 * 3 - 1) == 2)
    }

    // T-1798645c F-758 B-VIEW-018
    @Test func keepsOneColumnForAPaneThatIsTooNarrowOrNotMeasuredYet() {
        #expect(Self.layout.columns(containerWidth: 0) == 1)
        #expect(Self.layout.columns(containerWidth: 60) == 1)
    }

    // MARK: getIconGridRevealScrollTop

    static func reveal(_ scrollTop: Double, _ index: Int, viewport: Double = 400) -> Double {
        layout.revealScrollTop(
            currentScrollTop: scrollTop, viewportHeight: viewport, itemIndex: index, itemCount: 100, columns: 5)
    }

    // T-a1d93055 B-VIEW-028
    @Test func keepsTheScrollPositionWhenTheRowIsFullyVisible() {
        #expect(Self.reveal(100, 7) == 100)
    }

    // T-2c12de45 B-VIEW-028
    @Test func scrollsUpToARowAboveTheViewport() {
        // Item 7 is in the second row, which starts below the top padding and one row.
        #expect(Self.reveal(500, 7) == Self.layout.paddingTop + Self.layout.rowHeight)
    }

    // T-ac5c7f93 B-VIEW-028
    @Test func scrollsToTheVeryTopForTheFirstRow() {
        #expect(Self.reveal(500, 3) == 0)
    }

    // T-7baaab02 B-VIEW-028
    // B-NAV-165
    @Test func scrollsDownJustFarEnoughForARowBelowTheViewport() {
        // Item 30 is in the seventh row.
        let rowBottom = Self.layout.paddingTop + 7 * Self.layout.rowHeight
        #expect(Self.reveal(0, 30) == rowBottom - 400)
    }

    // T-4ce6d4ac B-VIEW-028
    @Test func bringsTheBottomPaddingInWithTheLastRow() {
        let rowBottom = Self.layout.paddingTop + 20 * Self.layout.rowHeight + Self.layout.paddingBottom
        #expect(Self.reveal(0, 99) == rowBottom - 400)
    }

    // T-a9405ac4 B-VIEW-028
    @Test func showsTheTopOfARowThatIsTallerThanTheViewport() {
        #expect(Self.reveal(0, 12, viewport: 80) == Self.layout.paddingTop + 2 * Self.layout.rowHeight)
    }

    // MARK: Where items sit (styles.css:7899-8111)

    // F-757 F-758 F-759 B-VIEW-019 B-VIEW-025: items are centred in columns that share the grid's width; the tile is
    // `itemPaddingTop` down, the name `iconBoxSize + labelGap` below that.
    @Test func itemsSitInTheMiddleOfTheirColumns() {
        let style = IconItemStyle.make(density: .comfortable)
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
        let small = IconItemStyle.make(density: .compact)
        #expect(Self.compact.tileFrame(style: small) == GridRect(x: 16, y: 3, width: 56, height: 56))
        #expect(Self.compact.labelFrame(textWidth: 200, lines: 2) == GridRect(x: 1, y: 62, width: 86, height: 32))
        #expect(Self.layout.contentHeight(itemCount: 19, columns: 9) == 10 + 3 * 116 + 10)
        #expect(style.renameHeight == 20 && small.renameHeight == 19)
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
        var compact: Bool?
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
        let compact = input.compact ?? false
        let layout = DesignTokens.iconGrid(density: compact ? .compact : .comfortable)
        let style = IconItemStyle.make(density: compact ? .compact : .comfortable)
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
            let regular = DesignTokens.iconGrid(density: .comfortable)
            let small = DesignTokens.iconGrid(density: .compact)
            return .constants([
                "itemPaddingTop": regular.itemPaddingTop, "compactItemPaddingTop": small.itemPaddingTop,
                "iconBox": regular.iconBoxSize, "compactIconBox": small.iconBoxSize, "labelWidth": regular.labelWidth,
                "compactLabelWidth": small.labelWidth, "labelGap": regular.labelGap, "compactLabelGap": small.labelGap,
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

    // T-71a44152 T-1798645c T-a1d93055 T-2c12de45 T-ac5c7f93 T-7baaab02 T-4ce6d4ac T-a9405ac4 F-757 F-758
    @Test func theGridMathMatchesTheReference() throws {
        let cases: [GoldenCase<Input, Output>] = try Golden.load(suite: "icon-grid-layout")
        #expect(cases.count >= 500)
        Golden.expectMatches(cases) { Self.run($0) }
    }
}
