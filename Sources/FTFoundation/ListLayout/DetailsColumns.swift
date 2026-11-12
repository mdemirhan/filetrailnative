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
    /// Name is always first; the chosen optional columns follow in the order set in
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

    /// The columns, the gaps between them and the row padding. Rows are also at least as
    /// wide as the pane.
    public static func tableWidth(widths: [DetailColumn: Double], columns: [DetailColumn], layout: DetailsLayout)
        -> Double
    {
        let content = columns.reduce(0) { $0 + (widths[$1] ?? 0) }
        return content + Double(max(0, columns.count - 1)) * layout.columnGap + layout.rowPadding
    }

    /// The width that shows a column's title and its widest value whole (a double-click on its
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

    /// A width rounded and kept within the column's limits, a folder's List or search results'.
    public static func clamp(_ width: Double, column: DetailColumn, search: Bool) -> Double {
        let limits = ColumnWidths.make(column, search: search)
        return min(max(width.rounded(), limits.min), limits.max)
    }

    /// The titles of the columns.
    public static func title(_ column: DetailColumn) -> String {
        SearchColumnKey(rawValue: column.rawValue)?.label ?? column.rawValue
    }
}
