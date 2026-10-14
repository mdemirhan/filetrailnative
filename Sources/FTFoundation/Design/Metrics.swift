// Port of the density handling around renderer/lib/layoutTokens.ts and the layout modules (zoom dropped, D-005)
import Foundation

/// Every metric and font size the UI uses for a density, in points. The original's zoom preference is not ported
/// (D-005): the saved `zoomPercent` is still read and ignored, and lengths are the original's CSS pixels.
public struct Metrics: Equatable, Sendable {
    public let density: Density

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

    public init(density: Density) {
        self.density = density
        typeScale = .make()
        radii = .make()
        controlHeights = .make()
        spacing = DesignTokens.spacing
        explorer = .make(density: density)
        iconGrid = .make(density: density)
        details = .make(density: density)
        flowList = .make(density: density)
        toolbar = .make()
        tabStrip = .make()
        scrollbarWidth = DesignTokens.scrollbarWidth
        paneHeaderHeight = DesignTokens.paneHeaderHeight
        breadcrumbRowHeight = DesignTokens.breadcrumbRowHeight
        settingsSidebarWidth = DesignTokens.settingsSidebarWidth
        settingsPopupMinWidth = DesignTokens.settingsPopupMinWidth
        focusRingWidth = DesignTokens.focusRingWidth
    }

    /// Width of a List column.
    public func columnWidths(_ column: DetailColumn, search: Bool = false) -> ColumnWidths {
        .make(column, search: search)
    }
}
