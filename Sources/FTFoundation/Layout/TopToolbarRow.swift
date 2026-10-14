// Port of the toolbar row rules of apps/desktop/src/renderer/styles.css (.toolbar-row, [data-capsule],
// .toolbar-title-block, .toolbar-search-slot) as CSS flexbox lays them out
import Foundation

/// Where each item of the toolbar's row goes, as the original's flexbox puts it: items `itemGap` apart, a capsule's
/// first and last button kept `capsulePadding + edgedItemInset` clear of their neighbours, the title taking the room
/// the others leave (down to its minimum), and the search field giving up room once the title is at its minimum.
public struct TopToolbarRow: Equatable, Sendable {
    /// One item's place along the row, from the row's leading edge: its margin box starts at `x - marginLeading`.
    public struct Place: Equatable, Sendable {
        public var x: Double
        public var width: Double
    }

    /// By slot key; the » button's under `overflowKey`.
    public var places: [String: Place]
    /// How wide the row's contents are; more than the row when even the narrowest items don't fit.
    public var contentWidth: Double

    public static let overflowKey = "overflow"

    /// Lays out `slots` (and the » button after them, with `overflow`) in a row `rowWidth` wide. `widths` holds the
    /// width of every item but the title and the search field. `titleMinWidth` is the title's least width (smaller
    /// while customizing).
    public static func place(
        _ slots: [TopToolbarSlot], widths: [String: Double], capsules: [String: ToolbarCapsuleEdges],
        overflow: Bool, rowWidth: Double, titleMinWidth: Double, layout: ToolbarLayout = DesignTokens.toolbar
    ) -> TopToolbarRow {
        let overhang = TopToolbarLayout.capsuleOverhang(layout)
        let searchBasis = layout.searchWidth + 2 * layout.edgedItemInset
        let searchMin = layout.searchMinWidth + 2 * layout.edgedItemInset

        struct Entry {
            var key: String
            var id: ToolbarItemID?
            var leading: Double
            var trailing: Double
            var width: Double
        }
        var entries: [Entry] = slots.map { slot in
            let edges = capsules[slot.key]
            return Entry(
                key: slot.key, id: slot.id, leading: edges?.start == true ? overhang : 0,
                trailing: edges?.end == true ? overhang : 0, width: widths[slot.key] ?? 0)
        }
        if overflow {
            entries.append(
                Entry(
                    key: overflowKey, id: nil, leading: overhang, trailing: overhang,
                    width: layout.overflowButtonWidth))
        }
        let hasTitle = entries.contains { $0.id == .title }
        let hasSearch = entries.contains { $0.id == .search }
        var fixed = Double(max(0, entries.count - 1)) * layout.itemGap
        for entry in entries {
            fixed += entry.leading + entry.trailing
            if entry.id != .title && entry.id != .search { fixed += entry.width }
        }
        let free = rowWidth - fixed
        var titleWidth = 0.0
        var searchWidth = 0.0
        switch (hasTitle, hasSearch) {
        case (true, true):
            if free >= titleMinWidth + searchBasis {
                titleWidth = free - searchBasis
                searchWidth = searchBasis
            } else {
                titleWidth = titleMinWidth
                searchWidth = max(searchMin, min(searchBasis, free - titleMinWidth))
            }
        case (true, false):
            titleWidth = max(titleMinWidth, free)
        case (false, true):
            searchWidth = max(searchMin, min(searchBasis, free))
        case (false, false):
            break
        }
        var places: [String: Place] = [:]
        var x = 0.0
        for (index, entry) in entries.enumerated() {
            if index > 0 { x += layout.itemGap }
            x += entry.leading
            let width = entry.id == .title ? titleWidth : entry.id == .search ? searchWidth : entry.width
            places[entry.key] = Place(x: x, width: width)
            x += width + entry.trailing
        }
        return TopToolbarRow(places: places, contentWidth: x)
    }
}
