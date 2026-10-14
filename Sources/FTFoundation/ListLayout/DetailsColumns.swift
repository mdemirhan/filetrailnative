// Port of apps/desktop/src/renderer/lib/detailsLayout.ts
import Foundation

/// The List view's columns as it draws them: which are shown (Name first), and how wide each is.
public struct DetailsColumnSet: Equatable, Sendable {
    public var columns: [DetailColumn]
    public var widths: [DetailColumn: Double]

    public init(columns: [DetailColumn], widths: [DetailColumn: Double]) {
        self.columns = columns
        self.widths = widths
    }

    public func width(_ column: DetailColumn) -> Double { widths[column] ?? 0 }
}

public enum DetailsColumns {
    /// `getVisibleDetailColumns`: Name is always first; the chosen optional columns follow in the order set in
    /// Settings.
    public static func visible(visibility: DetailColumnVisibility, order: [OptionalDetailColumnKey]) -> [DetailColumn] {
        [.name] + order.filter { visibility[$0] }.compactMap { DetailColumn(rawValue: $0.rawValue) }
    }

    /// The same for search results, whose columns add Folder.
    public static func visible(visibility: SearchColumnVisibility, order: [OptionalSearchColumnKey]) -> [DetailColumn] {
        [.name] + order.filter { visibility[$0] }.compactMap { DetailColumn(rawValue: $0.rawValue) }
    }

    /// The saved widths of a folder's columns (Folder has none there).
    public static func widths(_ saved: DetailColumnWidths) -> [DetailColumn: Double] {
        [
            .name: Double(saved.name), .modified: Double(saved.modified), .size: Double(saved.size),
            .kind: Double(saved.kind), .created: Double(saved.created), .permissions: Double(saved.permissions),
            .folder: 0,
        ]
    }

    public static func widths(_ saved: SearchColumnWidths) -> [DetailColumn: Double] {
        [
            .name: Double(saved.name), .folder: Double(saved.folder), .modified: Double(saved.modified),
            .size: Double(saved.size), .kind: Double(saved.kind), .created: Double(saved.created),
            .permissions: Double(saved.permissions),
        ]
    }

    /// `getDetailsTableWidth`: the columns, the gaps between them and the row padding. Rows are also at least as
    /// wide as the pane.
    public static func tableWidth(widths: [DetailColumn: Double], columns: [DetailColumn], layout: DetailsLayout)
        -> Double
    {
        let content = columns.reduce(0) { $0 + (widths[$1] ?? 0) }
        return content + Double(max(0, columns.count - 1)) * layout.columnGap + layout.rowPadding
    }

    /// `fitDetailColumns`: fits the columns into the pane instead of letting the table scroll sideways. When the
    /// pane is too narrow, Name first gives up width (down to `nameFloorWidth`), then columns drop away one at a
    /// time from the right. The saved widths and the saved column choices are not changed: everything comes back
    /// when the pane is wider again. An `availableWidth` of 0 means the pane has not been measured yet, so nothing
    /// is fitted.
    public static func fit(
        columns: [DetailColumn], widths: [DetailColumn: Double], availableWidth: Double, layout: DetailsLayout
    ) -> DetailsColumnSet {
        if availableWidth <= 0 || tableWidth(widths: widths, columns: columns, layout: layout) <= availableWidth {
            return DetailsColumnSet(columns: columns, widths: widths)
        }
        let savedName = widths[.name] ?? 0
        let nameFloor = min(savedName, layout.nameFloorWidth)
        var kept = columns
        var floored = widths
        floored[.name] = nameFloor
        while kept.count > 1, tableWidth(widths: floored, columns: kept, layout: layout) > availableWidth {
            kept.removeLast()
        }
        // Name takes whatever the remaining columns leave over.
        var withoutName = widths
        withoutName[.name] = 0
        let rest = tableWidth(widths: withoutName, columns: kept, layout: layout)
        let name = max(min(layout.nameMinWidth, savedName), min(savedName, availableWidth - rest))
        var fitted = widths
        fitted[.name] = name
        return DetailsColumnSet(columns: kept, widths: fitted)
    }

    /// `getColumnFitWidth`: the width that shows a column's title and its widest value whole (a double-click on its
    /// divider, as in Finder), kept within the column's limits by `clamp`. Permissions fits its codes alone: its
    /// title is three times as wide as "755", and ends in an ellipsis instead. `valueExtraWidth` is what a cell
    /// holds besides its text: the icon and its gap, in the Name column.
    public static func fitWidth(
        for column: DetailColumn, headerWidth: Double, valueWidths: [Double], valueExtraWidth: Double,
        layout: DetailsLayout, clamp: (Double) -> Double
    ) -> Double {
        let widest = valueWidths.reduce(0, max)
        let title = column == .permissions ? 0 : headerWidth
        return clamp((max(title, widest + valueExtraWidth)).rounded(.up) + layout.fitSlack)
    }

    /// `clampDetailColumnWidth` / `clampSearchColumnWidth`: a width rounded and kept within the column's limits.
    public static func clamp(_ width: Double, column: DetailColumn, search: Bool) -> Double {
        let limits = ColumnWidths.make(column, search: search)
        return min(max(width.rounded(), limits.min), limits.max)
    }

    /// The titles of the columns (`LIST_COLUMN_LABELS`).
    public static func title(_ column: DetailColumn) -> String {
        SearchColumnKey(rawValue: column.rawValue)?.label ?? column.rawValue
    }
}
