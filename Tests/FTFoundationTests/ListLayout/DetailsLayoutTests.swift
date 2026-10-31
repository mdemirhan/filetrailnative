// Ports apps/desktop/src/renderer/lib/detailsLayout.test.ts, and checks the column math against the golden recorded from
// the reference (tools/parity/golden/details-layout.ts).
import FTTestSupport
import Foundation
import Testing

@testable import FTFoundation

struct DetailsLayoutTests {
    static let layout = DesignTokens.details(density: .comfortable)
    static let compact = DesignTokens.details(density: .compact)
    static let defaults = DetailsColumns.widths(DetailColumnWidths.defaults)

    // MARK: The original's cases

    // T-6f96314a
    @Test func rowHeightsFollowTheDensity() {
        #expect(Self.layout.rowHeight == 28)
        #expect(Self.compact.rowHeight == 24)
        #expect(Self.layout.rowInset == 10)
        #expect(Self.layout.columnGap == 12)
    }

    // T-da426402 F-764
    // B-VIEW-041
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

    // T-7fb627c4
    // B-VIEW-043
    @Test func gapsAndRowPaddingAddToTheTableWidth() {
        var widths = Self.defaults
        widths[.name] = 220
        #expect(DetailsColumns.tableWidth(widths: widths, columns: [.name], layout: Self.layout) == 220 + 24)
        #expect(
            DetailsColumns.tableWidth(widths: Self.defaults, columns: [.name, .modified, .size], layout: Self.layout)
                == 320 + 152 + 108 + 12 * 2 + 24)
    }

    static let columns: [DetailColumn] = [.name, .modified, .size, .kind]
    // The four columns, three gaps and the row padding.
    static let fullWidth = 728.0 + 36 + 24

    static func fit(_ available: Double, columns: [DetailColumn] = columns) -> DetailsColumnSet {
        DetailsColumns.fit(columns: columns, widths: defaults, availableWidth: available, layout: layout)
    }

    // T-bc6fc27c F-765
    // B-VIEW-044
    @Test func fittingChangesNothingWhenItFitsOrThePaneIsNotMeasured() {
        let same = DetailsColumnSet(columns: Self.columns, widths: Self.defaults)
        #expect(Self.fit(Self.fullWidth) == same)
        #expect(Self.fit(0) == same)
    }

    // T-933dad89
    // B-VIEW-045
    @Test func nameNarrowsBeforeAnyColumnDrops() {
        var narrowed = Self.defaults
        narrowed[.name] = 220
        #expect(Self.fit(Self.fullWidth - 100) == DetailsColumnSet(columns: Self.columns, widths: narrowed))
        narrowed[.name] = 160
        #expect(Self.fit(Self.fullWidth - 160) == DetailsColumnSet(columns: Self.columns, widths: narrowed))
    }

    // T-0bada08f
    // B-VIEW-045
    @Test func columnsDropFromTheRightOneAtATime() {
        let withoutKind = Self.fit(Self.fullWidth - 161)
        #expect(withoutKind.columns == [.name, .modified, .size])
        #expect(withoutKind.width(.name) == 319)
        #expect(Self.fit(468).columns == [.name, .modified, .size])
        #expect(Self.fit(467).columns == [.name, .modified])
        var alone = Self.defaults
        alone[.name] = 240
        #expect(Self.fit(264) == DetailsColumnSet(columns: [.name], widths: alone))
    }

    // T-1ef35513
    @Test func neverMoreThanThePaneHoldsAndNameStaysReadable() {
        var available = 120.0
        while available <= Self.fullWidth {
            let fitted = Self.fit(available)
            #expect(fitted.columns[0] == .name)
            #expect(fitted.width(.name) >= Self.layout.nameMinWidth)
            if fitted.width(.name) > Self.layout.nameMinWidth {
                #expect(
                    DetailsColumns.tableWidth(widths: fitted.widths, columns: fitted.columns, layout: Self.layout)
                        <= available)
            }
            available += 7
        }
    }

    // T-6ae4f9d2
    // B-VIEW-045
    @Test func fittingLeavesTheOtherSavedWidthsAlone() {
        let fitted = Self.fit(400)
        #expect(fitted.width(.modified) == 152)
        #expect(fitted.width(.size) == 108)
        #expect(fitted.width(.kind) == 148)
    }

    static func fitWidth(_ column: DetailColumn, header: Double, values: [Double], extra: Double = 0) -> Double {
        DetailsColumns.fitWidth(
            for: column, headerWidth: header, valueWidths: values, valueExtraWidth: extra, layout: layout
        ) { DetailsColumns.clamp($0, column: column, search: false) }
    }

    // T-0bd9a65d
    // T-077e781e
    @Test func aColumnFitsTheWiderOfItsTitleAndItsWidestValue() {
        #expect(Self.fitWidth(.kind, header: 28, values: [60.2, 84.5]) == 87)
        #expect(Self.fitWidth(.size, header: 69.4, values: [24]) == 72)
        #expect(Self.fitWidth(.name, header: 40, values: [300], extra: 24) == 326)
    }

    // T-c90c4243
    // T-077e781e
    @Test func permissionsFitsItsCodesNotItsTitle() {
        #expect(Self.fitWidth(.permissions, header: 69.4, values: [36.5]) == 39)
        #expect(Self.fitWidth(.permissions, header: 69.4, values: [24]) == 36)
    }

    // T-80505d69 B-VIEW-042
    // T-077e781e
    @Test func aFittedWidthStaysWithinTheColumnsLimits() {
        #expect(Self.fitWidth(.size, header: 26, values: []) == 60)
        #expect(Self.fitWidth(.name, header: 40, values: [5000], extra: 24) == 720)
    }

    // MARK: The sort rules of the header

    // B-VIEW-048 B-VIEW-049 B-NAV-127
    // B-VIEW-047 T-4023bc38 T-b0215a2e T-bae92ca4 T-f43eb8e0
    @Test func headerClicksSortLikeTheOriginal() {
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

    // T-87c303a0 B-VIEW-057 B-INFO-176 B-INFO-178
    // B-VIEW-058
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

    // T-71a43ef8 T-115ec808 T-af56cfdc B-VIEW-063 B-NAV-116 B-SEL-178 B-SEL-180
    @Test func theEmptyStateTexts() {
        #expect(ContentStateText.empty(path: "/Users/demo", hiddenItemCount: 0) == "Empty folder")
        #expect(ContentStateText.empty(path: "/Users/demo", hiddenItemCount: 1) == "Empty folder · 1 hidden item")
        #expect(ContentStateText.empty(path: "/Users/demo", hiddenItemCount: 3) == "Empty folder · 3 hidden items")
        #expect(ContentStateText.empty(path: "  ", hiddenItemCount: 3) == "Select a folder to see what’s in it.")
        #expect(ContentStateText.noMatches(query: "ab") == "No items match “ab”")
    }

    // MARK: Against the reference

    struct Input: Codable, Sendable {
        var op: String
        var visibility: [String: Bool]?
        var order: [String]?
        var columns: [String]?
        var widths: [String: Double]?
        var availableWidth: Double?
        var key: String?
        var headerWidth: Double?
        var valueWidths: [Double]?
        var valueExtraWidth: Double?
    }

    struct Fitted: Codable, Equatable, Sendable {
        var columns: [String]
        var widths: [String: Double]
    }

    enum Output: Codable, Equatable, Sendable {
        case columns([String])
        case number(Double)
        case fitted(Fitted)
        case constants([String: Double])

        init(from decoder: any Decoder) throws {
            let single = try decoder.singleValueContainer()
            if let value = try? single.decode(Fitted.self) {
                self = .fitted(value)
            } else if let value = try? single.decode([String].self) {
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
            case .fitted(let value): try single.encode(value)
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
        case "fit":
            let fitted = DetailsColumns.fit(
                columns: columns(input.columns), widths: widths(input.widths),
                availableWidth: input.availableWidth ?? 0, layout: layout)
            // The reference keeps every width it was given, Folder's included.
            let given = input.widths ?? [:]
            var out: [String: Double] = [:]
            for name in given.keys {
                out[name] = DetailColumn(rawValue: name).flatMap { fitted.widths[$0] } ?? given[name]
            }
            return .fitted(Fitted(columns: fitted.columns.map(\.rawValue), widths: out))
        case "fitWidth":
            guard let column = DetailColumn(rawValue: input.key ?? "") else { return .number(-1) }
            return .number(
                fitWidth(
                    column, header: input.headerWidth ?? 0, values: input.valueWidths ?? [],
                    extra: input.valueExtraWidth ?? 0))
        default:
            let l = layout
            return .constants([
                "regularRowHeight": DesignTokens.details(density: .comfortable).rowHeight,
                "compactRowHeight": DesignTokens.details(density: .compact).rowHeight, "columnGap": l.columnGap,
                "rowPadding": l.rowPadding, "rowInset": l.rowInset, "nameFloorWidth": l.nameFloorWidth,
                "nameMinWidth": l.nameMinWidth,
            ])
        }
    }

    // T-bc6fc27c T-933dad89 T-0bada08f T-1ef35513 T-6ae4f9d2 T-0bd9a65d T-c90c4243 T-80505d69 F-765 F-766
    // B-VIEW-041 B-VIEW-044 B-VIEW-045
    @Test func theColumnMathMatchesTheReference() throws {
        let cases: [GoldenCase<Input, Output>] = try Golden.load(suite: "details-layout")
        #expect(cases.count >= 500)
        Golden.expectMatches(cases) { Self.run($0) }
    }
}
