import Foundation
import Testing

@testable import FTFoundation

/// Zoom and density replace the zoomed and Compact screenshots (PLAN.md section 5.4): for every
/// zoom and density, each metric is the original's CSS pixel value times zoom / 100. The base
/// values below are typed out from the original's layout modules and `ui.md`, apart from the code under test.
@Suite struct MetricsTests {
    static let zooms = [75, 90, 100, 110, 125, 150]
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
    static func mismatches(_ value: Any, base: Table, zoom: Int, label: String) -> [String] {
        var seen = Set<String>()
        var problems: [String] = []
        for child in Mirror(reflecting: value).children {
            guard let name = child.label, let actual = child.value as? Double else { continue }
            seen.insert(name)
            guard let original = base[name] else {
                problems.append("\(label).\(name) has no base value")
                continue
            }
            let expected = original * Double(zoom) / 100
            if abs(actual - expected) > 1e-9 {
                problems.append("\(label).\(name) at \(zoom)%: expected \(expected), got \(actual)")
            }
        }
        for name in base.keys where !seen.contains(name) { problems.append("\(label).\(name) missing in Swift") }
        return problems
    }

    @Test(arguments: zooms, Density.allCases)
    func everyMetricIsTheOriginalTimesZoom(zoom: Int, density: Density) {
        let metrics = Metrics(zoom: zoom, density: density)
        var problems: [String] = []
        problems += Self.mismatches(metrics.typeScale, base: Self.typeScale, zoom: zoom, label: "typeScale")
        problems += Self.mismatches(metrics.radii, base: Self.radii, zoom: zoom, label: "radii")
        problems += Self.mismatches(metrics.controlHeights, base: Self.controlHeights, zoom: zoom, label: "heights")
        problems += Self.mismatches(metrics.explorer, base: Self.explorer(density), zoom: zoom, label: "explorer")
        problems += Self.mismatches(metrics.iconGrid, base: Self.iconGrid(density), zoom: zoom, label: "iconGrid")
        problems += Self.mismatches(metrics.details, base: Self.details(density), zoom: zoom, label: "details")
        problems += Self.mismatches(metrics.flowList, base: Self.flowList(density), zoom: zoom, label: "flowList")
        problems += Self.mismatches(metrics.toolbar, base: Self.toolbar, zoom: zoom, label: "toolbar")
        problems += Self.mismatches(metrics.tabStrip, base: Self.tabStrip, zoom: zoom, label: "tabStrip")
        #expect(problems.isEmpty, "\(problems.count) problems: \(problems.prefix(8))")

        let factor = Double(zoom) / 100
        #expect(metrics.spacing.count == 11)
        for (scaled, original) in zip(metrics.spacing, [2, 4, 6, 8, 10, 12, 14, 16, 20, 24, 28]) {
            #expect(abs(scaled - Double(original) * factor) < 1e-9)
        }
        #expect(abs(metrics.scrollbarWidth - 8 * factor) < 1e-9)
        #expect(abs(metrics.paneHeaderHeight - 30 * factor) < 1e-9)
        #expect(abs(metrics.breadcrumbRowHeight - 33 * factor) < 1e-9)
        #expect(abs(metrics.focusRingWidth - 3 * factor) < 1e-9)
        #expect(abs(metrics.details.rowHeight - Self.details(density)["rowHeight", default: 0] * factor) < 1e-9)
        #expect(
            abs(metrics.flowList.columnStep - (Self.flowList(density)["itemWidth", default: 0] + 18) * factor) < 1e-9)
    }

    @Test(arguments: zooms)
    func columnWidthsScale(zoom: Int) {
        let metrics = Metrics(zoom: zoom, density: .comfortable)
        let factor = Double(zoom) / 100
        for column in DetailColumn.allCases {
            let widths = metrics.columnWidths(column)
            let base = Self.columns[column] ?? []
            #expect(abs(widths.defaultWidth - base[0] * factor) < 1e-9)
            #expect(abs(widths.min - base[1] * factor) < 1e-9)
            #expect(abs(widths.max - base[2] * factor) < 1e-9)
        }
        // Search results start Name at 300.
        #expect(abs(metrics.columnWidths(.name, search: true).defaultWidth - 300 * factor) < 1e-9)
    }

    @Test func atHundredPercentMetricsAreTheDesignTokens() {
        for density in Density.allCases {
            let metrics = Metrics(zoom: 100, density: density)
            #expect(metrics.iconGrid == DesignTokens.iconGrid(density: density))
            #expect(metrics.details == DesignTokens.details(density: density))
            #expect(metrics.flowList == DesignTokens.flowList(density: density))
            #expect(metrics.explorer == DesignTokens.explorer(density: density))
            #expect(metrics.toolbar == DesignTokens.toolbar)
            #expect(metrics.typeScale == DesignTokens.typeScale)
        }
    }

    @Test func zoomIsClampedToTheSupportedRange() {
        #expect(Metrics(zoom: 10, density: .comfortable).zoomPercent == 75)
        #expect(Metrics(zoom: 400, density: .compact).zoomPercent == 150)
        #expect(Metrics(zoom: 110, density: .compact).zoomPercent == 110)
    }

    @Test(arguments: zooms, Density.allCases)
    func iconGridColumnsMatchTheOriginalFloor(zoom: Int, density: Density) {
        // computeIconGridColumns(width, layout) = max(1, floor((width - 2 * paddingInline) / cellMinWidth)),
        // evaluated in CSS pixels; the zoomed layout sees the pane in zoomed points.
        let base = Self.iconGrid(density)
        let layout = Metrics(zoom: zoom, density: density).iconGrid
        let factor = Double(zoom) / 100
        for cssWidth in stride(from: 0.5, through: 1500.5, by: 7.0) {
            let expected = max(
                1, Int(((cssWidth - (base["paddingInline"] ?? 0) * 2) / (base["cellMinWidth"] ?? 1)).rounded(.down)))
            #expect(layout.columns(containerWidth: cssWidth * factor) == expected, "width \(cssWidth) at \(zoom)%")
        }
        #expect(layout.columns(containerWidth: 0) == 1)
    }
}
