// Port of the zoom and density handling around renderer/lib/layoutTokens.ts and the layout modules
import Foundation

/// Every metric and font size the UI uses, scaled by `zoom / 100` for the given density.
///
/// The original zooms the whole page (`webContents.setZoomFactor(zoomPercent / 100)`), so CSS
/// pixels scale linearly and its layout modules round nothing but column counts (`floor`).
/// The same is done here: lengths are plain products, and only the icon grid's column count floors.
public struct Metrics: Equatable, Sendable {
    public static let zoomRange = 75...150

    /// 75...150, in percent; `init` clamps and rounds as `clampZoomPercent` does.
    public let zoomPercent: Int
    public let density: Density
    public let scale: ZoomScale

    public let typeScale: TypeScale
    public let radii: Radii
    public let controlHeights: ControlHeights
    public let spacing: [Double]
    public let explorer: ExplorerLayout
    public let iconGrid: IconGridLayout
    public let details: DetailsLayout
    public let flowList: FlowListLayout
    public let toolbar: ToolbarLayout
    public let tabStrip: TabStripLayout
    public let scrollbarWidth: Double
    public let paneHeaderHeight: Double
    public let breadcrumbRowHeight: Double
    public let settingsSidebarWidth: Double
    public let settingsPopupMinWidth: Double
    public let focusRingWidth: Double

    public init(zoom: Int, density: Density) {
        let percent = min(Self.zoomRange.upperBound, max(Self.zoomRange.lowerBound, zoom))
        let s = ZoomScale(percent: Double(percent))
        zoomPercent = percent
        self.density = density
        scale = s
        typeScale = .make(s)
        radii = .make(s)
        controlHeights = .make(s)
        spacing = DesignTokens.spacing.map { s($0) }
        explorer = .make(density: density, s)
        iconGrid = .make(density: density, s)
        details = .make(density: density, s)
        flowList = .make(density: density, s)
        toolbar = .make(s)
        tabStrip = .make(s)
        scrollbarWidth = s(DesignTokens.scrollbarWidth)
        paneHeaderHeight = s(DesignTokens.paneHeaderHeight)
        breadcrumbRowHeight = s(DesignTokens.breadcrumbRowHeight)
        settingsSidebarWidth = s(DesignTokens.settingsSidebarWidth)
        settingsPopupMinWidth = s(DesignTokens.settingsPopupMinWidth)
        focusRingWidth = s(DesignTokens.focusRingWidth)
    }

    /// Width of a List column, scaled.
    public func columnWidths(_ column: DetailColumn, search: Bool = false) -> ColumnWidths {
        .make(column, search: search, scale)
    }

    /// The saved (100%) pane width as drawn at this zoom.
    public func scaled(_ value: Double) -> Double { scale(value) }
}
