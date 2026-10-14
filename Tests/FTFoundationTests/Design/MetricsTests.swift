import Foundation
import Testing

@testable import FTFoundation

/// Density replaces the Compact screenshots (PLAN.md section 5.4): for each density, every metric is the original's CSS
/// pixel value (no zoom, D-005). The base values below are typed out from the original's layout modules and `ui.md`,
/// apart from the code under test.
@Suite struct MetricsTests {
    typealias Table = [String: Double]

    // MARK: Base values (CSS px at 100%)

    static let typeScale: Table = [
        "mini": 10, "small": 11, "callout": 12, "body": 13, "name": 14, "title3": 15, "title2": 17, "title1": 20,
        "mono": 12,
    ]
    static let radii: Table = ["xs": 4, "control": 6, "menu": 10, "dialog": 14, "capsule": 999]
    static let controlHeights: Table = ["small": 22, "regular": 24, "large": 28, "toolbar": 32]

    static func explorer(_ density: Density) -> Table {
        [
            "treeMinWidth": 220, "treeMaxWidth": 520, "inspectorMinWidth": 260, "inspectorMaxWidth": 480,
            "resizerWidth": 8, "paneResizeStep": 12, "paneResizeStepLarge": 24, "minContentWidth": 420,
            "defaultTreeWidth": 280, "defaultInspectorWidth": 320, "toolbarInsetWithoutTree": 76,
            "treeRowHeight": density == .compact ? 21 : 26,
        ]
    }

    static func iconGrid(_ density: Density) -> Table {
        switch density {
        case .comfortable:
            [
                "iconSize": 64, "iconBoxSize": 72, "cellMinWidth": 104, "rowHeight": 116, "itemPaddingTop": 5,
                "labelGap": 4, "labelWidth": 102, "paddingTop": 10, "paddingBottom": 10, "paddingInline": 16,
                "labelFontSize": 13, "labelLineHeight": 16, "labelPaddingVertical": 1, "labelPaddingHorizontal": 4,
                "labelRadius": 4, "clipboardBadgeSize": 18, "clipboardBadgeOffset": -4,
            ]
        case .compact:
            [
                "iconSize": 48, "iconBoxSize": 56, "cellMinWidth": 88, "rowHeight": 94, "itemPaddingTop": 3,
                "labelGap": 3, "labelWidth": 86, "paddingTop": 8, "paddingBottom": 8, "paddingInline": 16,
                "labelFontSize": 12, "labelLineHeight": 15, "labelPaddingVertical": 1, "labelPaddingHorizontal": 2,
                "labelRadius": 4, "clipboardBadgeSize": 18, "clipboardBadgeOffset": -4,
            ]
        }
    }

    static func details(_ density: Density) -> Table {
        [
            "rowHeight": density == .compact ? 24 : 28, "columnGap": 12, "rowPadding": 24, "rowInset": 10,
            "rowRadius": 6, "nameFloorWidth": 160, "nameMinWidth": 96, "cellFontSize": density == .compact ? 13 : 14,
            "headerHeight": 28, "headerFontSize": 11, "sortChevronWidth": 9, "sortChevronHeight": 6,
            "separatorWidth": 1, "separatorHeight": 14, "separatorHitWidth": 12, "columnKeyboardStep": 12,
        ]
    }

    static func flowList(_ density: Density) -> Table {
        [
            "rowHeight": density == .compact ? 24 : 28, "rowGap": 0, "itemWidth": density == .compact ? 252 : 292,
            "columnGap": 18, "paddingTop": 8, "paddingBottom": 4, "paddingInline": 10,
            "fontSize": density == .compact ? 13 : 14, "iconSize": 18, "iconGap": 8,
        ]
    }

    static let toolbar: Table = [
        "itemGap": 2, "edgedItemInset": 5, "capsulePadding": 3, "titleMinWidth": 96, "overflowButtonWidth": 32,
        "searchWidth": 200, "searchMinWidth": 110, "controlHeight": 32, "buttonWidth": 32, "minHeight": 52,
        "paddingLeading": 8, "paddingTrailing": 12, "titlePaddingLeading": 8, "titlePaddingTrailing": 4,
        "titleFontSize": 15, "iconSize": 17, "iconStrokeWidth": 1.7, "segmentedTrackPadding": 4, "segmentWidth": 32,
        "segmentHeight": 24,
    ]

    static let tabStrip: Table = [
        "height": 29, "tabWidth": 180, "tabMinWidth": 96, "tabPaddingLeading": 12, "tabPaddingTrailing": 28,
        "fontSize": 13, "activeLineHeight": 2, "closeButtonSize": 16, "closeButtonTrailing": 7, "newTabButtonWidth": 34,
        "leadingOverlap": 4, "dragThreshold": 6,
    ]

    /// default, min, max
    static let columns: [DetailColumn: [Double]] = [
        .name: [320, 140, 720], .modified: [152, 80, 280], .size: [108, 60, 240], .kind: [148, 60, 320],
        .created: [152, 80, 280], .permissions: [108, 36, 260], .folder: [240, 80, 720],
    ]

    // MARK: Checking

    /// Every stored Double of `value` must be in `base`, and every `base` entry must exist.
    static func mismatches(_ value: Any, base: Table, label: String) -> [String] {
        var seen = Set<String>()
        var problems: [String] = []
        for child in Mirror(reflecting: value).children {
            guard let name = child.label, let actual = child.value as? Double else { continue }
            seen.insert(name)
            guard let expected = base[name] else {
                problems.append("\(label).\(name) has no base value")
                continue
            }
            if abs(actual - expected) > 1e-9 {
                problems.append("\(label).\(name): expected \(expected), got \(actual)")
            }
        }
        for name in base.keys where !seen.contains(name) { problems.append("\(label).\(name) missing in Swift") }
        return problems
    }

    // N/A B-DLG-240 B-DLG-241 B-DLG-242 B-DLG-243 D-005: zoom is not ported
    // N/A F-588 F-651 F-931 D-005: zoom is not ported (nor is the zoom part of any other row: the About window is not
    // scaled and no zoom change resizes anything). Every other metric is checked here, Compact included.
    @Test(arguments: Density.allCases)
    func everyMetricIsTheOriginalValue(density: Density) {
        let metrics = Metrics(density: density)
        var problems: [String] = []
        problems += Self.mismatches(metrics.typeScale, base: Self.typeScale, label: "typeScale")
        problems += Self.mismatches(metrics.radii, base: Self.radii, label: "radii")
        problems += Self.mismatches(metrics.controlHeights, base: Self.controlHeights, label: "heights")
        problems += Self.mismatches(metrics.explorer, base: Self.explorer(density), label: "explorer")
        problems += Self.mismatches(metrics.iconGrid, base: Self.iconGrid(density), label: "iconGrid")
        problems += Self.mismatches(metrics.details, base: Self.details(density), label: "details")
        problems += Self.mismatches(metrics.flowList, base: Self.flowList(density), label: "flowList")
        problems += Self.mismatches(metrics.toolbar, base: Self.toolbar, label: "toolbar")
        problems += Self.mismatches(metrics.tabStrip, base: Self.tabStrip, label: "tabStrip")
        #expect(problems.isEmpty, "\(problems.count) problems: \(problems.prefix(8))")

        #expect(metrics.density == density)
        #expect(metrics.spacing == [2, 4, 6, 8, 10, 12, 14, 16, 20, 24, 28])
        #expect(metrics.scrollbarWidth == 8)
        #expect(metrics.paneHeaderHeight == 30)
        #expect(metrics.breadcrumbRowHeight == 33)
        #expect(metrics.focusRingWidth == 3)
        #expect(metrics.details.rowHeight == Self.details(density)["rowHeight"])
        #expect(metrics.flowList.columnStep == (Self.flowList(density)["itemWidth"] ?? 0) + 18)
    }

    @Test func columnWidthsAreTheOriginalValues() {
        let metrics = Metrics(density: .comfortable)
        for column in DetailColumn.allCases {
            let widths = metrics.columnWidths(column)
            let base = Self.columns[column] ?? []
            #expect(widths.defaultWidth == base[0])
            #expect(widths.min == base[1])
            #expect(widths.max == base[2])
        }
        // Search results start Name at 300.
        #expect(metrics.columnWidths(.name, search: true).defaultWidth == 300)
    }

    @Test func metricsAreTheDesignTokens() {
        for density in Density.allCases {
            let metrics = Metrics(density: density)
            #expect(metrics.iconGrid == DesignTokens.iconGrid(density: density))
            #expect(metrics.details == DesignTokens.details(density: density))
            #expect(metrics.flowList == DesignTokens.flowList(density: density))
            #expect(metrics.explorer == DesignTokens.explorer(density: density))
            #expect(metrics.toolbar == DesignTokens.toolbar)
            #expect(metrics.typeScale == DesignTokens.typeScale)
        }
    }

    @Test(arguments: Density.allCases)
    func iconGridColumnsMatchTheOriginalFloor(density: Density) {
        // computeIconGridColumns(width, layout) = max(1, floor((width - 2 * paddingInline) / cellMinWidth)).
        let base = Self.iconGrid(density)
        let layout = Metrics(density: density).iconGrid
        for width in stride(from: 0.5, through: 1500.5, by: 7.0) {
            let expected = max(
                1, Int(((width - (base["paddingInline"] ?? 0) * 2) / (base["cellMinWidth"] ?? 1)).rounded(.down)))
            #expect(layout.columns(containerWidth: width) == expected, "width \(width)")
        }
        #expect(layout.columns(containerWidth: 0) == 1)
    }
}
