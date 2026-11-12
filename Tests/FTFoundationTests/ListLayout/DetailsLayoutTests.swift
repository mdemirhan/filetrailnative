import FTTestSupport
import Foundation
import Testing

@testable import FTFoundation

struct DetailsLayoutTests {
    static let layout = DesignTokens.details(density: .standard)
    static let finder = DesignTokens.details(density: .finder)
    static let defaults = DetailsColumns.widths(DetailColumnWidths.defaults)

    // MARK: Layout cases

    @Test func rowHeightsFollowTheDensity() {
        #expect(Self.layout.rowHeight == 28)
        #expect(Self.finder.rowHeight == 24)
        #expect(Self.layout.rowInset == 10)
        #expect(Self.layout.columnGap == 12)
    }

    @Test func nameIsFirstAndOptionalColumnsFollowTheirOrder() {
        var visibility = DetailColumnVisibility(
            modified: false, size: true, kind: true, created: false, permissions: true)
        #expect(
            DetailsColumns.visible(visibility: visibility, order: AppPreferenceLimits.defaultDetailColumnOrder)
                == [.name, .size, .kind, .permissions])
        visibility = DetailColumnVisibility(modified: true, size: true, kind: true, created: true, permissions: true)
        #expect(
            DetailsColumns.visible(visibility: visibility, order: [.kind, .permissions, .modified, .created, .size])
                == [.name, .kind, .permissions, .modified, .created, .size])
    }

    @Test func gapsAndRowPaddingAddToTheTableWidth() {
        var widths = Self.defaults
        widths[.name] = 220
        #expect(DetailsColumns.tableWidth(widths: widths, columns: [.name], layout: Self.layout) == 220 + 24)
        #expect(
            DetailsColumns.tableWidth(widths: Self.defaults, columns: [.name, .modified, .size], layout: Self.layout)
                == 320 + 152 + 108 + 12 * 2 + 24)
    }

    static func fitWidth(_ column: DetailColumn, header: Double, values: [Double], extra: Double = 0) -> Double {
        DetailsColumns.fitWidth(
            for: column, headerWidth: header, valueWidths: values, valueExtraWidth: extra, layout: layout
        ) { DetailsColumns.clamp($0, column: column, search: false) }
    }

    @Test func aColumnFitsTheWiderOfItsTitleAndItsWidestValue() {
        #expect(Self.fitWidth(.kind, header: 28, values: [60.2, 84.5]) == 87)
        #expect(Self.fitWidth(.size, header: 69.4, values: [24]) == 72)
        #expect(Self.fitWidth(.name, header: 40, values: [300], extra: 24) == 326)
    }

    @Test func permissionsFitsItsCodesNotItsTitle() {
        #expect(Self.fitWidth(.permissions, header: 69.4, values: [36.5]) == 39)
        #expect(Self.fitWidth(.permissions, header: 69.4, values: [24]) == 36)
    }

    @Test func aFittedWidthStaysWithinTheColumnsLimits() {
        #expect(Self.fitWidth(.size, header: 26, values: []) == 60)
        #expect(Self.fitWidth(.name, header: 40, values: [5000], extra: 24) == 1000)
    }

    // MARK: The sort rules of the header

    @Test func headerClicksSortOnlyBySortableColumns() {
        #expect(DetailsSorting.sortKey(for: .name, search: false) == "name")
        #expect(DetailsSorting.sortKey(for: .created, search: false) == nil)
        #expect(DetailsSorting.sortKey(for: .permissions, search: false) == nil)
        #expect(DetailsSorting.sortKey(for: .folder, search: false) == nil)
        #expect(DetailsSorting.sortKey(for: .folder, search: true) == "path")
        #expect(DetailsSorting.sortKey(for: .size, search: true) == nil)
        // The same key flips; a new Date Modified or Size starts descending, Name and Kind ascending.
        #expect(DetailsSorting.next(current: .name, direction: .asc, requested: .name) == (.name, .desc))
        #expect(DetailsSorting.next(current: .name, direction: .desc, requested: .name) == (.name, .asc))
        #expect(DetailsSorting.next(current: .name, direction: .asc, requested: .modified) == (.modified, .desc))
        #expect(DetailsSorting.next(current: .name, direction: .asc, requested: .size) == (.size, .desc))
        #expect(DetailsSorting.next(current: .size, direction: .desc, requested: .kind) == (.kind, .asc))
        #expect(DetailsSorting.next(current: .size, direction: .desc, requested: .name) == (.name, .asc))
    }

    // MARK: Size bars

    @Test func barsAreAShareOfTheLargestSize() {
        #expect(SizeBars.fraction(bytes: 50, maxBytes: 100) == 0.5)
        #expect(SizeBars.fraction(bytes: 500, maxBytes: 100) == 1)
        #expect(SizeBars.fraction(bytes: nil, maxBytes: 100) == nil)
        #expect(SizeBars.fraction(bytes: 5, maxBytes: 0) == nil)
        #expect(SizeBars.maxBytes([nil, 0, nil]) == nil)
        #expect(SizeBars.maxBytes([10, nil, 40, 5]) == 40)
        // Zero draws no bar, a sliver draws the least width, the biggest reaches past the cell.
        #expect(SizeBars.span(fraction: 0, cellWidth: 108, layout: Self.layout) == nil)
        #expect(SizeBars.span(fraction: nil, cellWidth: 108, layout: Self.layout) == nil)
        let sliver = SizeBars.span(fraction: 0.001, cellWidth: 108, layout: Self.layout)
        #expect(sliver?.width == 2)
        #expect(sliver?.x == 110)
        let full = SizeBars.span(fraction: 1, cellWidth: 108, layout: Self.layout)
        #expect(full?.width == 108)
        #expect(full?.x == 4)
    }

    // MARK: States

    @Test func theEmptyStateTexts() {
        #expect(ContentStateText.empty(path: "/Users/demo", hiddenItemCount: 0) == "Empty folder")
        #expect(ContentStateText.empty(path: "/Users/demo", hiddenItemCount: 1) == "Empty folder · 1 hidden item")
        #expect(ContentStateText.empty(path: "/Users/demo", hiddenItemCount: 3) == "Empty folder · 3 hidden items")
        #expect(ContentStateText.empty(path: "  ", hiddenItemCount: 3) == "Select a folder to see what’s in it.")
        #expect(ContentStateText.noMatches(query: "ab") == "No items match “ab”")
    }

    // MARK: Against the golden

    struct Input: Codable, Sendable {
        var op: String
        var visibility: [String: Bool]?
        var order: [String]?
        var columns: [String]?
        var widths: [String: Double]?
        var key: String?
        var headerWidth: Double?
        var valueWidths: [Double]?
        var valueExtraWidth: Double?
    }

    enum Output: Codable, Equatable, Sendable {
        case columns([String])
        case number(Double)
        case constants([String: Double])

        init(from decoder: any Decoder) throws {
            let single = try decoder.singleValueContainer()
            if let value = try? single.decode([String].self) {
                self = .columns(value)
            } else if let value = try? single.decode(Double.self) {
                self = .number(value)
            } else {
                self = .constants(try single.decode([String: Double].self))
            }
        }

        func encode(to encoder: any Encoder) throws {
            var single = encoder.singleValueContainer()
            switch self {
            case .columns(let value): try single.encode(value)
            case .number(let value): try single.encode(value)
            case .constants(let value): try single.encode(value)
            }
        }
    }

    static func columns(_ names: [String]?) -> [DetailColumn] { (names ?? []).compactMap(DetailColumn.init(rawValue:)) }

    static func widths(_ named: [String: Double]?) -> [DetailColumn: Double] {
        Dictionary(
            uniqueKeysWithValues: (named ?? [:]).compactMap { name, value in
                DetailColumn(rawValue: name).map { ($0, value) }
            })
    }

    static func run(_ input: Input) -> Output {
        switch input.op {
        case "visible":
            let visibility = DetailColumnVisibility(
                modified: input.visibility?["modified"] ?? false, size: input.visibility?["size"] ?? false,
                kind: input.visibility?["kind"] ?? false, created: input.visibility?["created"] ?? false,
                permissions: input.visibility?["permissions"] ?? false)
            let order = (input.order ?? []).compactMap(OptionalDetailColumnKey.init(rawValue:))
            return .columns(DetailsColumns.visible(visibility: visibility, order: order).map(\.rawValue))
        case "tableWidth":
            return .number(
                DetailsColumns.tableWidth(
                    widths: widths(input.widths), columns: columns(input.columns), layout: layout))
        case "fitWidth":
            guard let column = DetailColumn(rawValue: input.key ?? "") else { return .number(-1) }
            return .number(
                fitWidth(
                    column, header: input.headerWidth ?? 0, values: input.valueWidths ?? [],
                    extra: input.valueExtraWidth ?? 0))
        default:
            let l = layout
            return .constants([
                "regularRowHeight": DesignTokens.details(density: .standard).rowHeight,
                // Finder's sizes have the golden's compact rows.
                "compactRowHeight": DesignTokens.details(density: .finder).rowHeight, "columnGap": l.columnGap,
                "rowPadding": l.rowPadding, "rowInset": l.rowInset,
            ])
        }
    }

    @Test func theColumnMathMatchesTheGoldenFile() throws {
        let cases: [GoldenCase<Input, Output>] = try Golden.load(suite: "details-layout")
        #expect(cases.count >= 190)
        Golden.expectMatches(cases) { Self.run($0) }
    }
}
