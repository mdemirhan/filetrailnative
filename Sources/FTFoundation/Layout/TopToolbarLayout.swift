// Port of apps/desktop/src/renderer/lib/topToolbarLayout.ts
import Foundation

/// An item of the top toolbar with a key that stays the same wherever it is moved: its id, with a count for
/// separators, the one item that can be there more than once (`TopToolbarSlot`).
public struct TopToolbarSlot: Equatable, Hashable, Sendable {
    public var id: ToolbarItemID
    public var key: String

    public init(id: ToolbarItemID, key: String) {
        self.id = id
        self.key = key
    }
}

/// Whether a button starts or ends the capsule it sits on (`ToolbarCapsuleEdges`).
public struct ToolbarCapsuleEdges: Equatable, Sendable {
    public var start: Bool
    public var end: Bool

    public init(start: Bool, end: Bool) {
        self.start = start
        self.end = end
    }

    /// `data-capsule`: single, start, middle or end.
    public var name: String {
        switch (start, end) {
        case (true, true): "single"
        case (true, false): "start"
        case (false, true): "end"
        case (false, false): "middle"
        }
    }
}

/// The top toolbar is one row, in the order chosen in Settings. Two of its items have no width of their own: the
/// title takes whatever room the others leave, and the search field has a resting width and gives way when the row
/// is tight. Every other item is as wide as its contents. This works out which items there is room for, from the
/// numbers the row is laid out with (`ToolbarLayout`).
public enum TopToolbarLayout {
    /// Items that draw an edge of their own (the title has none) are not buttons on a capsule.
    static let notOnACapsule: Set<ToolbarItemID> = [.title, .search, .view, .topSeparator]

    /// `resolveToolbarCapsules`: which items are buttons on a capsule, and whether each starts or ends its capsule.
    /// `isShown` leaves out an item that is in the row but has nothing on screen (the clipboard button with nothing
    /// copied); the buttons on either side of it join.
    public static func capsules(
        _ slots: [TopToolbarSlot], isShown: (TopToolbarSlot) -> Bool = { _ in true }
    ) -> [String: ToolbarCapsuleEdges] {
        let shown = slots.map(isShown)
        let onCapsule = slots.indices.map { !notOnACapsule.contains(slots[$0].id) && shown[$0] }
        func neighbour(_ index: Int, _ step: Int) -> Int {
            var next = index + step
            while next >= 0, next < slots.count, !shown[next] { next += step }
            return next
        }
        func isOnCapsule(_ index: Int) -> Bool { onCapsule.indices.contains(index) && onCapsule[index] }
        var edges: [String: ToolbarCapsuleEdges] = [:]
        for index in slots.indices where onCapsule[index] {
            edges[slots[index].key] = ToolbarCapsuleEdges(
                start: !isOnCapsule(neighbour(index, -1)), end: !isOnCapsule(neighbour(index, 1)))
        }
        return edges
    }

    /// `resolveTopToolbarSlots`.
    public static func slots(_ items: [ToolbarItemID]) -> [TopToolbarSlot] {
        var seen: [ToolbarItemID: Int] = [:]
        return items.map { id in
            let count = seen[id] ?? 0
            seen[id] = count + 1
            return TopToolbarSlot(id: id, key: count == 0 ? id.rawValue : "\(id.rawValue):\(count)")
        }
    }

    /// A separator with nothing on one side of it, or right after another, divides nothing.
    static func withoutIdleSeparators(_ slots: [TopToolbarSlot]) -> [TopToolbarSlot] {
        var result: [TopToolbarSlot] = []
        for slot in slots {
            if slot.id == .topSeparator, result.isEmpty || result.last?.id == .topSeparator { continue }
            result.append(slot)
        }
        if result.last?.id == .topSeparator { result.removeLast() }
        return result
    }

    /// `selectTopToolbarSlots`: the row to draw when there is room for `optionalCount` of the items that can be
    /// taken off the toolbar. Those are kept in order from the start; the required items always stay.
    public static func select(_ slots: [TopToolbarSlot], optionalCount: Int) -> [TopToolbarSlot] {
        var remaining = optionalCount
        return withoutIdleSeparators(
            slots.filter { slot in
                if ToolbarItems.isRequiredTopItem(slot.id) { return true }
                remaining -= 1
                return remaining >= 0
            })
    }

    /// The room a capsule takes past each of its ends: its padding, and the inset it keeps from its neighbours.
    static func capsuleOverhang(_ layout: ToolbarLayout) -> Double {
        layout.capsulePadding + layout.edgedItemInset
    }

    static func rowMinWidth(_ slots: [TopToolbarSlot], widths: [String: Double], layout: ToolbarLayout) -> Double {
        var total = Double(max(0, slots.count - 1)) * layout.itemGap
        let overhang = capsuleOverhang(layout)
        let edges = capsules(slots) { $0.id != .clipboard || (widths[$0.key] ?? 0) > 0 }
        for edge in edges.values {
            total += (edge.start ? overhang : 0) + (edge.end ? overhang : 0)
        }
        for slot in slots {
            switch slot.id {
            case .title: total += layout.titleMinWidth
            case .search: total += layout.searchMinWidth + 2 * layout.edgedItemInset
            default: total += widths[slot.key] ?? 0
            }
        }
        return total
    }

    /// The room the » button takes once any item is left out: a button on a capsule of its own.
    public static func overflowRoom(_ layout: ToolbarLayout) -> Double {
        layout.itemGap + layout.overflowButtonWidth + 2 * capsuleOverhang(layout)
    }

    /// `resolveVisibleOptionalCount`: how many of the removable items fit beside the required ones. The title and
    /// the search field count at their narrowest. `widths` holds the measured width of every item but those two, by
    /// key. Before anything is laid out (no width, or an item not measured) the whole toolbar stays.
    public static func visibleOptionalCount(
        slots: [TopToolbarSlot], widths: [String: Double], availableWidth: Double,
        layout: ToolbarLayout = DesignTokens.toolbar
    ) -> Int {
        let optionalCount = slots.filter { !ToolbarItems.isRequiredTopItem($0.id) }.count
        let laidOut =
            availableWidth > 0
            && slots.allSatisfy { $0.id == .title || $0.id == .search || (widths[$0.key] ?? 0) > 0 }
        guard laidOut else { return optionalCount }
        var count = optionalCount
        while count > 0 {
            let reserved = count < optionalCount ? overflowRoom(layout) : 0
            if rowMinWidth(select(slots, optionalCount: count), widths: widths, layout: layout) + reserved
                <= availableWidth
            {
                return count
            }
            count -= 1
        }
        return 0
    }

    /// `resolveToolbarDropIndex`: where an item dragged along the toolbar lands, its index among the other items:
    /// how many of them have their middle left of the pointer.
    public static func dropIndex(centers: [Double], pointerX: Double) -> Int {
        centers.filter { $0 < pointerX }.count
    }
}
