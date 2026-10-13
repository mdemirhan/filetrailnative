// Port of renderer/lib/layoutTokens.ts, iconGridLayout.ts, detailsLayout.ts, flowListLayout.ts, topToolbarLayout.ts
import Foundation

/// Multiplies CSS pixels by the zoom, as Electron's `setZoomFactor` does: every length scales
/// linearly and nothing is rounded (Chromium lays out in 1/64 px units, AppKit in points).
public struct ZoomScale: Equatable, Sendable {
    public let percent: Double

    public static let identity = ZoomScale(percent: 100)

    public init(percent: Double) {
        self.percent = percent
    }

    public func callAsFunction(_ value: Double) -> Double {
        percent == 100 ? value : value * percent / 100
    }
}

public enum Density: String, CaseIterable, Sendable {
    case comfortable
    case compact

    public var isCompact: Bool { self == .compact }
}

/// Shell constraints from `EXPLORER_LAYOUT` and the preferences' default pane widths.
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
    /// Toolbar padding-left with the sidebar hidden, clearing the traffic lights.
    public var toolbarInsetWithoutTree: Double
    public var treeRowHeight: Double

    static func make(density: Density, _ s: ZoomScale) -> ExplorerLayout {
        ExplorerLayout(
            treeMinWidth: s(220), treeMaxWidth: s(520), inspectorMinWidth: s(260), inspectorMaxWidth: s(480),
            resizerWidth: s(8), paneResizeStep: s(12), paneResizeStepLarge: s(24), minContentWidth: s(420),
            defaultTreeWidth: s(280), defaultInspectorWidth: s(320), toolbarInsetWithoutTree: s(76),
            treeRowHeight: s(density.isCompact ? 21 : 26))
    }
}

/// Icon view metrics (`ICON_GRID_LAYOUT` / `COMPACT_ICON_GRID_LAYOUT` and the `.icon-grid` rules).
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

    static func make(density: Density, _ s: ZoomScale) -> IconGridLayout {
        if density.isCompact {
            return IconGridLayout(
                iconSize: s(48), iconBoxSize: s(56), cellMinWidth: s(88), rowHeight: s(94), itemPaddingTop: s(3),
                labelGap: s(3), labelWidth: s(86), paddingTop: s(8), paddingBottom: s(8), paddingInline: s(16),
                labelFontSize: s(12), labelLineHeight: s(15), labelPaddingVertical: s(1),
                labelPaddingHorizontal: s(2), labelRadius: s(4), clipboardBadgeSize: s(18),
                clipboardBadgeOffset: s(-4))
        }
        return IconGridLayout(
            iconSize: s(64), iconBoxSize: s(72), cellMinWidth: s(104), rowHeight: s(116), itemPaddingTop: s(5),
            labelGap: s(4), labelWidth: s(102), paddingTop: s(10), paddingBottom: s(10), paddingInline: s(16),
            labelFontSize: s(13), labelLineHeight: s(16), labelPaddingVertical: s(1), labelPaddingHorizontal: s(4),
            labelRadius: s(4), clipboardBadgeSize: s(18), clipboardBadgeOffset: s(-4))
    }

    /// How many columns fit across the pane (`computeIconGridColumns`); `containerWidth` is in
    /// this layout's own (zoomed) points.
    public func columns(containerWidth: Double) -> Int {
        Int(max(1, ((containerWidth - paddingInline * 2) / cellMinWidth).rounded(.down)))
    }
}

/// List view (`details`) metrics: `DETAILS_LAYOUT` plus the row and header rules of section 2.2.
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

    static func make(density: Density, _ s: ZoomScale) -> DetailsLayout {
        DetailsLayout(
            rowHeight: s(density.isCompact ? 24 : 28), columnGap: s(12), rowPadding: s(24), rowInset: s(10),
            rowRadius: s(6), nameFloorWidth: s(160), nameMinWidth: s(96), cellFontSize: s(density.isCompact ? 13 : 14),
            headerHeight: s(28), headerFontSize: s(11), sortChevronWidth: s(9), sortChevronHeight: s(6),
            separatorWidth: s(1), separatorHeight: s(14), separatorHitWidth: s(12), columnKeyboardStep: s(12))
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

    static func make(_ column: DetailColumn, search: Bool, _ s: ZoomScale) -> ColumnWidths {
        func spec(_ defaultWidth: Double, _ min: Double, _ max: Double) -> ColumnWidths {
            ColumnWidths(defaultWidth: s(defaultWidth), min: s(min), max: s(max))
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

/// Compact List (`list`) metrics: `FLOW_LIST_LAYOUT` / `COMPACT_FLOW_LIST_LAYOUT`.
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

    static func make(density: Density, _ s: ZoomScale) -> FlowListLayout {
        FlowListLayout(
            rowHeight: s(density.isCompact ? 24 : 28), rowGap: s(0), itemWidth: s(density.isCompact ? 252 : 292),
            columnGap: s(18), paddingTop: s(8), paddingBottom: s(4), paddingInline: s(10),
            fontSize: s(density.isCompact ? 13 : 14), iconSize: s(18), iconGap: s(8))
    }
}

/// Top toolbar metrics: `TOP_TOOLBAR_LAYOUT` and the toolbar rules of section 1.2.
public struct ToolbarLayout: Equatable, Sendable {
    public var itemGap: Double
    public var edgedItemInset: Double
    public var capsulePadding: Double
    public var titleMinWidth: Double
    public var overflowButtonWidth: Double
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

    static func make(_ s: ZoomScale) -> ToolbarLayout {
        ToolbarLayout(
            itemGap: s(2), edgedItemInset: s(5), capsulePadding: s(3), titleMinWidth: s(96),
            overflowButtonWidth: s(32), searchWidth: s(200), searchMinWidth: s(110), controlHeight: s(32),
            buttonWidth: s(32), minHeight: s(52), paddingLeading: s(8), paddingTrailing: s(12),
            titlePaddingLeading: s(8), titlePaddingTrailing: s(4), titleFontSize: s(15), iconSize: s(17),
            iconStrokeWidth: s(1.7), segmentedTrackPadding: s(4), segmentWidth: s(32), segmentHeight: s(24))
    }
}

/// Tab strip metrics (section 1.3).
public struct TabStripLayout: Equatable, Sendable {
    public var height: Double
    public var tabWidth: Double
    public var tabMinWidth: Double
    public var tabPaddingLeading: Double
    public var tabPaddingTrailing: Double
    public var fontSize: Double
    public var activeLineHeight: Double
    public var closeButtonSize: Double
    public var closeButtonTrailing: Double
    public var newTabButtonWidth: Double
    public var leadingOverlap: Double
    public var dragThreshold: Double

    static func make(_ s: ZoomScale) -> TabStripLayout {
        TabStripLayout(
            height: s(29), tabWidth: s(180), tabMinWidth: s(96), tabPaddingLeading: s(12), tabPaddingTrailing: s(28),
            fontSize: s(13), activeLineHeight: s(2), closeButtonSize: s(16), closeButtonTrailing: s(7),
            newTabButtonWidth: s(34), leadingOverlap: s(4), dragThreshold: s(6))
    }
}

/// The type scale (`--font-size-*`).
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

    static func make(_ s: ZoomScale) -> TypeScale {
        TypeScale(
            mini: s(10), small: s(11), callout: s(12), body: s(13), name: s(14), title3: s(15), title2: s(17),
            title1: s(20), mono: s(12))
    }
}

public struct Radii: Equatable, Sendable {
    public var xs: Double
    public var control: Double
    public var menu: Double
    public var dialog: Double
    public var capsule: Double

    static func make(_ s: ZoomScale) -> Radii {
        Radii(xs: s(4), control: s(6), menu: s(10), dialog: s(14), capsule: s(999))
    }
}

public struct ControlHeights: Equatable, Sendable {
    public var small: Double
    public var regular: Double
    public var large: Double
    public var toolbar: Double

    static func make(_ s: ZoomScale) -> ControlHeights {
        ControlHeights(small: s(22), regular: s(24), large: s(28), toolbar: s(32))
    }
}
