import Foundation

public struct CubicBezier: Equatable, Sendable {
    public var x1: Double
    public var y1: Double
    public var x2: Double
    public var y2: Double

    public init(x1: Double, y1: Double, x2: Double, y2: Double) {
        self.x1 = x1
        self.y1 = y1
        self.x2 = x2
        self.y2 = y2
    }
}

/// Motion durations in milliseconds and the standard easing.
public struct Motion: Equatable, Sendable {
    public var fast = 120.0
    public var base = 180.0
    public var slow = 220.0
    public var flash = 700.0
    public var spin = 700.0
    /// A cubic Bézier through (0.2, 0) and (0, 1): quick to start, slow to settle.
    public var easing = CubicBezier(x1: 0.2, y1: 0, x2: 0, y2: 1)

    public init() {}
}

/// Everything the UI draws with, (no zoom). `Metrics` is the same set for a density.
public enum DesignTokens {
    public static let typeScale = TypeScale.make()
    public static let radii = Radii.make()
    public static let controlHeights = ControlHeights.make()
    public static let toolbar = ToolbarLayout.make()
    public static let motion = Motion()

    /// A control that can't be used now is drawn at this opacity.
    public static let disabledOpacity = 0.4
    /// Width of the keyboard focus ring; its colour is the accent at 50%.
    public static let focusRingWidth = 3.0
    public static let scrollbarWidth = 8.0
    public static let paneHeaderHeight = 30.0
    public static let breadcrumbRowHeight = 33.0
    public static let settingsSidebarWidth = 196.0
    public static let settingsPopupMinWidth = 120.0

    /// Odd rows of the List view: the ink colour at this alpha.
    public static let stripeInkAlpha = 0.035

    public static func palette(for appearance: ThemeAppearance) -> ThemePalette {
        ThemePalette.palette(for: appearance)
    }

    public static let explorer = ExplorerLayout.make()
    public static func iconGrid(density: Density) -> IconGridLayout { .make(density: density) }
    public static func details(density: Density) -> DetailsLayout { .make(density: density) }
    public static func flowList(density: Density) -> FlowListLayout { .make(density: density) }
    public static func sidebar(density: SidebarDensity) -> SidebarLayout { SidebarLayout(density: density) }

    /// Column widths of the folder's List view, or of search results' (`search`).
    public static func columnWidths(_ column: DetailColumn, search: Bool = false) -> ColumnWidths {
        .make(column, search: search)
    }
}
