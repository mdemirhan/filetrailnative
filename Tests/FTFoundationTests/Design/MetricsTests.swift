import Foundation
import Testing

@testable import FTFoundation

/// For each density, every metric is typed out here apart from the code under test: File Trail's are its own pixel
/// values (no zoom), and Finder's are the defaults of Finder's View Options and AppKit's source list sizes.
@Suite struct MetricsTests {
    typealias Table = [String: Double]

    // MARK: Base values, in points

    static let typeScale: Table = [
        "mini": 10, "small": 11, "callout": 12, "body": 13, "name": 14, "title3": 15, "title2": 17, "title1": 20,
        "mono": 12,
    ]
    static let radii: Table = ["xs": 4, "control": 6, "menu": 10, "dialog": 14, "capsule": 999]
    static let controlHeights: Table = ["small": 22, "regular": 24, "large": 28, "toolbar": 32]

    static let explorer: Table = [
        "treeMinWidth": 220, "treeMaxWidth": 520, "inspectorMinWidth": 260, "inspectorMaxWidth": 480,
        "resizerWidth": 8, "paneResizeStep": 12, "paneResizeStepLarge": 24, "minContentWidth": 420,
        "defaultTreeWidth": 280, "defaultInspectorWidth": 320,
    ]

    static func iconGrid(_ density: Density) -> Table {
        [
            "iconSize": 64, "iconBoxSize": 72, "cellMinWidth": 104, "rowHeight": 116, "itemPaddingTop": 5,
            "labelGap": 4, "labelWidth": 102, "paddingTop": 10, "paddingBottom": 10, "paddingInline": 16,
            "labelFontSize": density == .finder ? 12 : 13, "labelLineHeight": density == .finder ? 15 : 16,
            "labelPaddingVertical": 1, "labelPaddingHorizontal": 4, "labelRadius": 4, "clipboardBadgeSize": 18,
            "clipboardBadgeOffset": -4,
        ]
    }

    static func details(_ density: Density) -> Table {
        [
            "rowHeight": density == .finder ? 24 : 28, "columnGap": 12, "rowPadding": 24, "rowInset": 10,
            "rowRadius": 6, "nameFloorWidth": 160, "nameMinWidth": 96, "cellFontSize": density == .finder ? 13 : 14,
            "headerHeight": 28, "headerFontSize": 11, "sortChevronWidth": 9, "sortChevronHeight": 6,
            "separatorWidth": 1, "separatorHeight": 14, "separatorHitWidth": 12, "columnKeyboardStep": 12,
            "iconSize": density == .finder ? 16 : 18, "nameIconGap": 8, "rowPaddingInline": 12, "headerButtonGap": 6,
            "sortChevronTrailingMargin": 6,
            "headerBorderWidth": 1, "separatorHitOverhang": 6, "scrollbarAllowance": 8, "sizeBarInsetVertical": 3,
            "sizeBarOverhang": 4, "sizeBarMinWidth": 2, "sizeBarAlpha": 0.2, "sizeBarSelectedAlpha": 0.28,
            "fitSlack": 2,
        ]
    }

    static func flowList(_ density: Density) -> Table {
        [
            "rowHeight": density == .finder ? 24 : 28, "rowGap": 0, "itemWidth": density == .finder ? 252 : 292,
            "columnGap": 18, "paddingTop": 8, "paddingBottom": 4, "paddingInline": 10,
            "fontSize": density == .finder ? 13 : 14, "iconSize": density == .finder ? 16 : 18, "iconGap": 8,
        ]
    }

    static let toolbar: Table = [
        "titleMinWidth": 96, "searchWidth": 200, "searchMinWidth": 110, "controlHeight": 32, "buttonWidth": 32,
        "minHeight": 52,
        "paddingLeading": 8, "paddingTrailing": 12, "titlePaddingLeading": 8, "titlePaddingTrailing": 4,
        "titleFontSize": 15, "iconSize": 17, "segmentedTrackPadding": 4, "segmentWidth": 32,
        "segmentHeight": 24,
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

    @Test(arguments: Density.allCases)
    func everyMetricHasItsSetValue(density: Density) {
        let metrics = Metrics(density: density)
        var problems: [String] = []
        problems += Self.mismatches(metrics.typeScale, base: Self.typeScale, label: "typeScale")
        problems += Self.mismatches(metrics.radii, base: Self.radii, label: "radii")
        problems += Self.mismatches(metrics.controlHeights, base: Self.controlHeights, label: "heights")
        problems += Self.mismatches(metrics.explorer, base: Self.explorer, label: "explorer")
        problems += Self.mismatches(metrics.iconGrid, base: Self.iconGrid(density), label: "iconGrid")
        problems += Self.mismatches(metrics.details, base: Self.details(density), label: "details")
        problems += Self.mismatches(metrics.flowList, base: Self.flowList(density), label: "flowList")
        problems += Self.mismatches(metrics.toolbar, base: Self.toolbar, label: "toolbar")
        #expect(problems.isEmpty, "\(problems.count) problems: \(problems.prefix(8))")

        #expect(metrics.density == density)
        #expect(metrics.scrollbarWidth == 8)
        #expect(metrics.paneHeaderHeight == 30)
        #expect(metrics.breadcrumbRowHeight == 33)
        #expect(metrics.focusRingWidth == 3)
        #expect(metrics.details.rowHeight == Self.details(density)["rowHeight"])
        #expect(metrics.flowList.columnStep == (Self.flowList(density)["itemWidth"] ?? 0) + 18)
    }

    @Test func columnWidthsHaveTheirSetValues() {
        let metrics = Metrics(density: .standard)
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

    @Test(arguments: Density.allCases)
    func iconGridColumnsAreTheWidthOverTheCellRoundedDown(density: Density) {
        // Columns = max(1, floor((width - 2 * paddingInline) / cellMinWidth)).
        let base = Self.iconGrid(density)
        let layout = Metrics(density: density).iconGrid
        for width in stride(from: 0.5, through: 1500.5, by: 7.0) {
            let expected = max(
                1, Int(((width - (base["paddingInline"] ?? 0) * 2) / (base["cellMinWidth"] ?? 1)).rounded(.down)))
            #expect(layout.columns(containerWidth: width) == expected, "width \(width)")
        }
        #expect(layout.columns(containerWidth: 0) == 1)
    }

    /// Row, indent, chevron, icon, symbol, label gap, label font, list padding top and bottom, section header.
    static func sidebar(_ density: SidebarDensity) -> [Double] {
        switch density {
        case .standard: [26, 14, 14, 16, 16, 6, 14, 6, 16, 24]
        case .small: [24, 12, 12, 14, 11, 4, 11, 4, 12, 20]
        case .medium: [32, 14, 14, 16, 13, 6, 13, 6, 16, 24]
        case .large: [40, 16, 16, 20, 15, 8, 15, 6, 16, 28]
        }
    }

    // The sidebar's lengths are tokens of the density too: its rows, indents, icons, labels and section headers.
    @Test(arguments: SidebarDensity.allCases)
    func sidebarMetricsAreTokensOfTheDensity(density: SidebarDensity) {
        let sidebar = DesignTokens.sidebar(density: density)
        #expect(
            [
                sidebar.rowHeight, sidebar.indent, sidebar.chevronBox, sidebar.iconSize, sidebar.symbolPointSize,
                sidebar.labelGap, sidebar.labelFontSize, sidebar.treeListPaddingTop, sidebar.treeListPaddingBottom,
                sidebar.sectionHeaderHeight,
            ] == Self.sidebar(density))
        #expect(sidebar.titlebarHeight == DesignTokens.toolbar.minHeight)
        #expect(sidebar.rowRadius == DesignTokens.radii.control)
        #expect(sidebar.foldersTitlePadding == SidebarInsets(top: 14, right: 12, bottom: 0, left: 20))
    }

    // With Finder's sizes the tree takes the system's sidebar size; File Trail's keep its own.
    @Test func theTreeFollowsTheSystemSidebarSizeOnlyWithFindersSizes() {
        for system in [SidebarDensity.small, .medium, .large] {
            #expect(Density.finder.sidebarDensity(system: system) == system)
            #expect(Density.standard.sidebarDensity(system: system) == .standard)
        }
        #expect(Metrics(density: .standard).sidebar == DesignTokens.sidebar(density: .standard))
        #expect(Metrics(density: .finder).sidebar == DesignTokens.sidebar(density: .medium))
    }
}
