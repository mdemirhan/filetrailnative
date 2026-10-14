// Port of the sidebar rules of apps/desktop/src/renderer/styles.css (.tree-pane, .sidebar-main-native, .tree-row, .sidebar-section-header; ui.md section 1.4)
import Foundation

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

/// Every length of the sidebar for a density, in points (the original's CSS pixels). The rows' height is
/// `ExplorerLayout.treeRowHeight`; fonts, radii and durations come from `DesignTokens`. These are named here and not in
/// `DesignTokens` because that file is shared (PLAN.md section 5.4: moved there by the integrator).
public struct SidebarLayout: Equatable, Sendable {
    public let density: Density

    /// `.sidebar-titlebar`: the strip for the traffic lights.
    public let titlebarHeight = 52.0
    /// `.sidebar-sections` takes at most this share of the sidebar below the title bar.
    public let sectionsMaxHeightShare = 0.6

    // MARK: Rows (`.sidebar-main-native .tree-row`)

    public let rowHeight: Double
    /// `margin: 0 10px`.
    public let rowMarginX = 10.0
    /// `padding-left: calc(8px + depth * var(--tree-indent))`.
    public let rowPaddingLeft = 8.0
    public let rowPaddingRight = 8.0
    public let indent: Double
    /// `gap` between the disclosure button, the label and the eject button.
    public let rowGap = 6.0
    public let rowRadius: Double

    // MARK: Inside the row

    /// `.tree-expand`.
    public let chevronBox: Double
    /// The chevron's stroke, `.toolbar-icon { width: 16px }` (it overflows its 14 pt box).
    public let chevronIcon = 16.0
    public let chevronStroke = 1.8
    /// `.tree-label`: the icon, then the text.
    public let iconSize: Double
    public let labelGap: Double
    public let labelFontSize: Double
    public let headingFontSize: Double
    public let badgeFontSize: Double
    public let badgePaddingX = 6.0
    public let badgePaddingY = 1.0
    public let badgeGap: Double
    public let ejectBox = 20.0
    public let ejectIcon = 14.0
    public let ejectStroke = 1.8
    public let ejectMarginRight = -4.0
    /// `.favorite-drop-line`.
    public let dropLineHeight = 2.0
    public let dropLineInset = 6.0
    public let dropLineOffset = -3.0
    public let draggedRowOpacity = 0.45
    /// `.menu-target`: an inset ring.
    public let menuRingWidth = 2.0

    // MARK: Lists

    /// `.tree-list { padding: 6px 0 16px }` and its compact form (`4px 0 12px`).
    public let treeListPaddingTop: Double
    public let treeListPaddingBottom: Double

    // MARK: Section headers (`.sidebar-section-header`)

    public let sectionHeaderHeight: Double
    public let sectionHeaderMarginTop: Double
    public let sectionHeaderFirstMarginTop = 2.0
    public let sectionHeaderMarginX = 10.0
    public let sectionHeaderPaddingLeft = 10.0
    public let sectionHeaderPaddingRight = 6.0
    public let sectionChevron = 12.0
    public let sectionChevronStroke = 2.0
    public let headingFontSizeSmall: Double

    // MARK: The "Folders" label (`.sidebar-header`)

    public let foldersTitlePadding = SidebarInsets(top: 14, right: 12, bottom: 0, left: 20)
    /// The height the label box is left with in the original's flex column (measured: 14.7 pt with its padding).
    public let foldersTitleContentHeight = 0.7
    /// `mask-image: linear-gradient(to bottom, transparent 0, #000 6px)` over the folders tree.
    public let treeFadeHeight = 6.0

    public init(density: Density) {
        self.density = density
        let compact = density.isCompact
        rowHeight = DesignTokens.explorer(density: density).treeRowHeight
        indent = compact ? 11 : 14
        rowRadius = DesignTokens.radii.control
        chevronBox = compact ? 12 : 14
        iconSize = compact ? 14 : 16
        labelGap = compact ? 4 : 6
        labelFontSize = compact ? DesignTokens.typeScale.callout : DesignTokens.typeScale.name
        headingFontSize = DesignTokens.typeScale.small
        headingFontSizeSmall = DesignTokens.typeScale.small
        badgeFontSize = DesignTokens.typeScale.mini
        badgeGap = compact ? 4 : 6
        treeListPaddingTop = compact ? 4 : 6
        treeListPaddingBottom = compact ? 12 : 16
        sectionHeaderHeight = compact ? 20 : 24
        sectionHeaderMarginTop = compact ? 4 : 8
    }

    /// The left edge of a row's content: `8 + depth * indent` from the row's left edge.
    public func contentLeading(depth: Int) -> Double { rowPaddingLeft + Double(depth) * indent }

    /// `margin-left: 38px + depth * indent` of a loading line or an error under a row.
    public func noteLeading(depth: Int) -> Double { 38 + Double(depth) * indent }

    public let noteFontSize = DesignTokens.typeScale.callout
    public let notePadding = SidebarInsets(top: 4, right: 12, bottom: 8, left: 0)

    // MARK: Behavior timings

    /// "Loading folder…" shows when a read has lasted this long (`TREE_LOADING_DELAY_MS`).
    public static let loadingDelayMilliseconds = 400
    /// A click opens the row this long after (`activateTreeItem` timer).
    public static let clickDelayMilliseconds = 180
    /// After a hand toggle the sidebar does not scroll to the selection for this long (`HAND_TOGGLE_SETTLE_MS`).
    public static let handToggleSettleMilliseconds = 1500
    /// A valid drag over a collapsed folder expands it after this long.
    public static let dragHoverExpandMilliseconds = 700
    /// The "Jump to" prefix is forgotten this long after the last key (`TREE_TYPEAHEAD_RESET_MS`).
    public static let typeaheadResetMilliseconds = 1000
}
