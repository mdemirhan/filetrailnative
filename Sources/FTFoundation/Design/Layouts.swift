import Foundation

/// How big the file views are: File Trail's own sizes, or Finder's (the defaults of its View Options).
public enum Density: String, CaseIterable, Codable, Sendable {
    case standard
    case finder

    public var isFinder: Bool { self == .finder }

    /// The folder tree's density: with Finder's sizes, the system's sidebar size (`system`).
    public func sidebarDensity(system: SidebarDensity) -> SidebarDensity { isFinder ? system : .standard }
}

/// How big the folder tree is. With Finder's sizes it follows the sidebar size of System Settings › Appearance, as
/// Finder's sidebar does; AppKit's source lists are 24, 32 and 40 points a row there, with 11, 13 and 15 point text.
public enum SidebarDensity: String, CaseIterable, Sendable {
    case standard
    case small
    case medium
    case large
}

/// Shell constraints and the preferences' default pane widths.
public struct ExplorerLayout: Equatable, Sendable {
    public var treeMinWidth: Double
    public var treeMaxWidth: Double
    public var inspectorMinWidth: Double
    public var inspectorMaxWidth: Double
    public var resizerWidth: Double
    public var paneResizeStep: Double
    public var paneResizeStepLarge: Double
    public var minContentWidth: Double
    public var defaultTreeWidth: Double
    public var defaultInspectorWidth: Double

    static func make() -> ExplorerLayout {
        ExplorerLayout(
            treeMinWidth: 220, treeMaxWidth: 520, inspectorMinWidth: 260, inspectorMaxWidth: 480,
            resizerWidth: 8, paneResizeStep: 12, paneResizeStepLarge: 24, minContentWidth: 420,
            defaultTreeWidth: 280, defaultInspectorWidth: 320)
    }
}

/// Icon view metrics. Finder's sizes keep the icons and the grid and take Finder's 12 point labels.
public struct IconGridLayout: Equatable, Sendable {
    public var iconSize: Double
    public var iconBoxSize: Double
    public var cellMinWidth: Double
    public var rowHeight: Double
    public var itemPaddingTop: Double
    public var labelGap: Double
    public var labelWidth: Double
    public var paddingTop: Double
    public var paddingBottom: Double
    public var paddingInline: Double
    public var labelFontSize: Double
    public var labelLineHeight: Double
    public var labelPaddingVertical: Double
    public var labelPaddingHorizontal: Double
    public var labelRadius: Double
    public var clipboardBadgeSize: Double
    public var clipboardBadgeOffset: Double

    static func make(density: Density) -> IconGridLayout {
        IconGridLayout(
            iconSize: 64, iconBoxSize: 72, cellMinWidth: 104, rowHeight: 116, itemPaddingTop: 5,
            labelGap: 4, labelWidth: 102, paddingTop: 10, paddingBottom: 10, paddingInline: 16,
            labelFontSize: density.isFinder ? 12 : 13, labelLineHeight: density.isFinder ? 15 : 16,
            labelPaddingVertical: 1, labelPaddingHorizontal: 4, labelRadius: 4, clipboardBadgeSize: 18,
            clipboardBadgeOffset: -4)
    }

    /// How many columns fit across the pane; `containerWidth` is in
    /// points.
    public func columns(containerWidth: Double) -> Int {
        Int(max(1, ((containerWidth - paddingInline * 2) / cellMinWidth).rounded(.down)))
    }
}

/// List view (`details`) metrics: the rows and the header.
public struct DetailsLayout: Equatable, Sendable {
    public var rowHeight: Double
    public var columnGap: Double
    /// Left plus right padding of a row and of the header.
    public var rowPadding: Double
    public var rowInset: Double
    public var rowRadius: Double
    public var nameFloorWidth: Double
    public var nameMinWidth: Double
    public var cellFontSize: Double
    public var headerHeight: Double
    public var headerFontSize: Double
    public var sortChevronWidth: Double
    public var sortChevronHeight: Double
    public var separatorWidth: Double
    public var separatorHeight: Double
    public var separatorHitWidth: Double
    public var columnKeyboardStep: Double
    /// The file icon in a Name cell and its gap to the name.
    public var iconSize: Double
    public var nameIconGap: Double
    /// Left and right padding of one row (half of `rowPadding`).
    public var rowPaddingInline: Double
    /// The gap between a header title and its sort chevron, and the chevron's margin before the column's end.
    public var headerButtonGap: Double
    public var sortChevronTrailingMargin: Double
    /// The line under the header.
    public var headerBorderWidth: Double
    /// How far a separator's hit area reaches beyond the header cell, above and to the right.
    public var separatorHitOverhang: Double
    /// Room kept free for the vertical scroller when the columns are fitted.
    public var scrollbarAllowance: Double
    /// Size bars: inset from the cell's top and bottom, reach past its right edge, the least width and the share of
    /// the colour (accent; the selection text on a selected row).
    public var sizeBarInsetVertical: Double
    public var sizeBarOverhang: Double
    public var sizeBarMinWidth: Double
    public var sizeBarAlpha: Double
    public var sizeBarSelectedAlpha: Double
    /// Pixels of slack added to a fitted column.
    public var fitSlack: Double

    static func make(density: Density) -> DetailsLayout {
        DetailsLayout(
            rowHeight: density.isFinder ? 24 : 28, columnGap: 12, rowPadding: 24, rowInset: 10,
            rowRadius: 6, nameFloorWidth: 160, nameMinWidth: 96, cellFontSize: density.isFinder ? 13 : 14,
            headerHeight: 28, headerFontSize: 11, sortChevronWidth: 9, sortChevronHeight: 6,
            separatorWidth: 1, separatorHeight: 14, separatorHitWidth: 12, columnKeyboardStep: 12,
            iconSize: density.isFinder ? 16 : 18,
            nameIconGap: 8, rowPaddingInline: 12, headerButtonGap: 6, sortChevronTrailingMargin: 6,
            headerBorderWidth: 1, separatorHitOverhang: 6, scrollbarAllowance: 8, sizeBarInsetVertical: 3,
            sizeBarOverhang: 4, sizeBarMinWidth: 2, sizeBarAlpha: 0.2, sizeBarSelectedAlpha: 0.28, fitSlack: 2)
    }
}

public enum DetailColumn: String, CaseIterable, Sendable {
    case name
    case modified
    case size
    case kind
    case created
    case permissions
    /// Search results only.
    case folder
}

/// A List column's default, least and greatest width.
public struct ColumnWidths: Equatable, Sendable {
    public var defaultWidth: Double
    public var min: Double
    public var max: Double

    static func make(_ column: DetailColumn, search: Bool) -> ColumnWidths {
        func spec(_ defaultWidth: Double, _ min: Double, _ max: Double) -> ColumnWidths {
            ColumnWidths(defaultWidth: defaultWidth, min: min, max: max)
        }
        switch column {
        case .name: return search ? spec(300, 140, 720) : spec(320, 140, 720)
        case .modified: return spec(152, 80, 280)
        case .size: return spec(108, 60, 240)
        case .kind: return spec(148, 60, 320)
        case .created: return spec(152, 80, 280)
        case .permissions: return spec(108, 36, 260)
        case .folder: return spec(240, 80, 720)
        }
    }
}

/// Compact List (`list`) metrics, and Finder's List view sizes (13 point text, 16 point icons).
public struct FlowListLayout: Equatable, Sendable {
    public var rowHeight: Double
    public var rowGap: Double
    public var itemWidth: Double
    public var columnGap: Double
    public var paddingTop: Double
    public var paddingBottom: Double
    public var paddingInline: Double
    public var fontSize: Double
    public var iconSize: Double
    public var iconGap: Double

    /// One horizontal page step: exactly one rendered column.
    public var columnStep: Double { itemWidth + columnGap }

    static func make(density: Density) -> FlowListLayout {
        FlowListLayout(
            rowHeight: density.isFinder ? 24 : 28, rowGap: 0, itemWidth: density.isFinder ? 252 : 292,
            columnGap: 18, paddingTop: 8, paddingBottom: 4, paddingInline: 10,
            fontSize: density.isFinder ? 13 : 14, iconSize: density.isFinder ? 16 : 18, iconGap: 8)
    }
}

/// Top toolbar metrics.
public struct ToolbarLayout: Equatable, Sendable {
    public var titleMinWidth: Double
    public var searchWidth: Double
    public var searchMinWidth: Double
    public var controlHeight: Double
    public var buttonWidth: Double
    public var minHeight: Double
    public var paddingLeading: Double
    public var paddingTrailing: Double
    public var titlePaddingLeading: Double
    public var titlePaddingTrailing: Double
    public var titleFontSize: Double
    public var iconSize: Double
    public var iconStrokeWidth: Double
    public var segmentedTrackPadding: Double
    public var segmentWidth: Double
    public var segmentHeight: Double

    static func make() -> ToolbarLayout {
        ToolbarLayout(
            titleMinWidth: 96, searchWidth: 200, searchMinWidth: 110, controlHeight: 32,
            buttonWidth: 32, minHeight: 52, paddingLeading: 8, paddingTrailing: 12,
            titlePaddingLeading: 8, titlePaddingTrailing: 4, titleFontSize: 15, iconSize: 17,
            iconStrokeWidth: 1.7, segmentedTrackPadding: 4, segmentWidth: 32, segmentHeight: 24)
    }
}

/// The type scale.
public struct TypeScale: Equatable, Sendable {
    public var mini: Double
    public var small: Double
    public var callout: Double
    public var body: Double
    public var name: Double
    public var title3: Double
    public var title2: Double
    public var title1: Double
    public var mono: Double

    static func make() -> TypeScale {
        TypeScale(
            mini: 10, small: 11, callout: 12, body: 13, name: 14, title3: 15, title2: 17,
            title1: 20, mono: 12)
    }
}

public struct Radii: Equatable, Sendable {
    public var xs: Double
    public var control: Double
    public var menu: Double
    public var dialog: Double
    public var capsule: Double

    static func make() -> Radii {
        Radii(xs: 4, control: 6, menu: 10, dialog: 14, capsule: 999)
    }
}

public struct ControlHeights: Equatable, Sendable {
    public var small: Double
    public var regular: Double
    public var large: Double
    public var toolbar: Double

    static func make() -> ControlHeights {
        ControlHeights(small: 22, regular: 24, large: 28, toolbar: 32)
    }
}

/// A CSS `padding` of four lengths.
public struct SidebarInsets: Equatable, Sendable {
    public let top: Double
    public let right: Double
    public let bottom: Double
    public let left: Double

    public init(top: Double, right: Double, bottom: Double, left: Double) {
        self.top = top
        self.right = right
        self.bottom = bottom
        self.left = left
    }
}

/// Sidebar metrics: every length of the sidebar for a density, in points. The
/// small, medium and large sizes are AppKit's source list rows and text; fonts, radii and durations come from
/// `DesignTokens`.
public struct SidebarLayout: Equatable, Sendable {
    /// The sidebar's parts start this far down, under the window's toolbar band and its traffic lights (the band is
    /// the system toolbar's, over the sidebar; the sidebar draws nothing there).
    public let titlebarHeight = 52.0
    /// The sections take at most this share of the sidebar below the title bar.
    public let sectionsMaxHeightShare = 0.6

    // MARK: Rows

    public let rowHeight: Double
    /// The row's inset from the sidebar's sides.
    public let rowMarginX = 10.0
    /// The row's padding; the left one grows by `indent` per level.
    public let rowPaddingLeft = 8.0
    public let rowPaddingRight = 8.0
    public let indent: Double
    /// The gap between the disclosure button, the label and the eject button.
    public let rowGap = 6.0
    public let rowRadius: Double

    // MARK: Inside the row

    /// The disclosure button's box.
    public let chevronBox: Double
    /// The chevron's size and stroke (it overflows its 14 pt box).
    public let chevronIcon = 16.0
    public let chevronStroke = 1.8
    /// The label: the icon, then the text.
    public let iconSize: Double
    /// A favorite's or location's symbol, centered over the icon's box. A source list's symbols are the size of its
    /// text.
    public let symbolPointSize: Double
    public let labelGap: Double
    public let labelFontSize: Double
    public let headingFontSize: Double
    public let badgeFontSize: Double
    public let badgePaddingX = 6.0
    public let badgePaddingY = 1.0
    public let ejectBox = 20.0
    public let ejectIcon = 14.0
    public let ejectStroke = 1.8
    public let ejectMarginRight = -4.0
    /// The line that shows where a dragged favorite will drop.
    public let dropLineHeight = 2.0
    public let dropLineInset = 6.0
    public let draggedRowOpacity = 0.45
    /// The row a context menu is open for: an inset ring.
    public let menuRingWidth = 2.0

    // MARK: Lists

    /// A tree list's padding: 6 on top and 16 below, and 4 and 12 for the small size.
    public let treeListPaddingTop: Double
    public let treeListPaddingBottom: Double
    /// The Folders tree of the separate layout keeps 6 pt on top in every density.
    public let foldersTreePaddingTop = 6.0

    // MARK: Section headers

    public let sectionHeaderHeight: Double
    public let sectionHeaderMarginTop: Double
    public let sectionHeaderFirstMarginTop = 2.0
    public let sectionHeaderMarginX = 10.0
    public let sectionHeaderPaddingLeft = 10.0
    public let sectionHeaderPaddingRight = 6.0
    public let sectionChevron = 12.0
    public let sectionChevronStroke = 2.0
    public let headingFontSizeSmall: Double

    // MARK: The "Folders" label

    public let foldersTitlePadding = SidebarInsets(top: 14, right: 12, bottom: 0, left: 20)
    /// The folders tree fades in from clear over this many points at its top.
    public let treeFadeHeight = 6.0

    public init(density: SidebarDensity) {
        let size: (row: Double, indent: Double, chevron: Double, icon: Double, gap: Double, font: Double)
        switch density {
        case .standard: size = (26, 14, 14, 16, 6, DesignTokens.typeScale.name)
        case .small: size = (24, 12, 12, 14, 4, 11)
        case .medium: size = (32, 14, 14, 16, 6, 13)
        case .large: size = (40, 16, 16, 20, 8, 15)
        }
        let small = density == .small
        rowHeight = size.row
        indent = size.indent
        rowRadius = DesignTokens.radii.control
        chevronBox = size.chevron
        iconSize = size.icon
        symbolPointSize = density == .standard ? size.icon : size.font
        labelGap = size.gap
        labelFontSize = size.font
        headingFontSize = DesignTokens.typeScale.small
        headingFontSizeSmall = DesignTokens.typeScale.small
        badgeFontSize = DesignTokens.typeScale.mini
        treeListPaddingTop = small ? 4 : 6
        treeListPaddingBottom = small ? 12 : 16
        sectionHeaderHeight = small ? 20 : density == .large ? 28 : 24
        sectionHeaderMarginTop = small ? 4 : 8
    }

    /// The left edge of a row's content: `8 + depth * indent` from the row's left edge.
    public func contentLeading(depth: Int) -> Double { rowPaddingLeft + Double(depth) * indent }

    /// The left edge of a loading line or an error under a row: `38 + depth * indent`.
    public func noteLeading(depth: Int) -> Double { 38 + Double(depth) * indent }

    public let noteFontSize = DesignTokens.typeScale.callout
    public let notePadding = SidebarInsets(top: 4, right: 12, bottom: 8, left: 0)

    // MARK: Behavior timings

    /// "Loading folder…" shows when a read has lasted this long.
    public static let loadingDelayMilliseconds = 400
    /// A click opens the row this long after.
    public static let clickDelayMilliseconds = 180
    /// After a hand toggle the sidebar does not scroll to the selection for this long.
    public static let handToggleSettleMilliseconds = 1500
    /// The "Jump to" prefix is forgotten this long after the last key.
    public static let typeaheadResetMilliseconds = 1000
}
