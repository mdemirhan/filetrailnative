import Foundation

/// Items added to and taken from a list whose other items stay in the same order: what a folder's views put in and take
/// out in place, instead of drawing every row again.
public struct ListChange: Equatable, Sendable {
    /// The places, in the list before, of the items taken out.
    public var removed: IndexSet
    /// The places, in the list after, of the items put in.
    public var inserted: IndexSet

    /// Whether `after` is `before` with this change made: the items taken out of the one, and those put into the
    /// other, leave the same list. A view checks the list it holds by it before it makes the change in place.
    public func takes(_ before: [DiskPath], to after: [DiskPath]) -> Bool {
        guard before.count - removed.count + inserted.count == after.count,
            removed.last.map({ $0 < before.count }) ?? true, inserted.last.map({ $0 < after.count }) ?? true
        else { return false }
        let staying = before.indices.lazy.filter { !removed.contains($0) }.map { before[$0] }
        let kept = after.indices.lazy.filter { !inserted.contains($0) }.map { after[$0] }
        return staying.elementsEqual(kept)
    }

    /// Changes larger than this are drawn again whole: a few hundred rows put in one by one cost more than a reload.
    public static let largest = 200

    /// The change from `before` to `after`, when the items in both are in the same order in each and something came or
    /// went, and no more than `largest` did; nil otherwise (a new order, a list read again as it was, a key twice).
    public static func between(_ before: [DiskPath], _ after: [DiskPath]) -> ListChange? {
        let old = Set(before)
        let new = Set(after)
        guard old.count == before.count, new.count == after.count else { return nil }
        var removed = IndexSet()
        for (index, key) in before.enumerated() where !new.contains(key) { removed.insert(index) }
        var inserted = IndexSet()
        for (index, key) in after.enumerated() where !old.contains(key) { inserted.insert(index) }
        let count = removed.count + inserted.count
        guard count > 0, count <= largest else { return nil }
        let staying = before.filter { new.contains($0) }
        guard staying == after.filter({ old.contains($0) }) else { return nil }
        return ListChange(removed: removed, inserted: inserted)
    }
}
