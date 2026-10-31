// Port of apps/desktop/src/renderer/lib/entriesAtPaths.ts
import Foundation

/// A folder's listing can hold tens of thousands of items, and ⌘A selects all of them, so finding the selected items must
/// not walk the listing once per selected path. A listing is indexed by path once; build a new index when the listing
/// changes.
public struct PathIndex<Element> {
    public let elements: [Element]
    private let positions: [String: Int]

    public init(_ elements: [Element], path: (Element) -> String) {
        self.elements = elements
        var made: [String: Int] = [:]
        made.reserveCapacity(elements.count)
        for (position, element) in elements.enumerated() {
            let key = path(element)
            // The first of two items with one path wins, as a search from the start would.
            if made[key] == nil { made[key] = position }
        }
        positions = made
    }

    /// `findEntryAtPath`: the item at `path`, or nil.
    public func find(_ path: String?) -> Element? {
        guard let path, let position = positions[path] else { return nil }
        return elements[position]
    }

    /// Where the item is in the listing.
    public func position(of path: String?) -> Int? {
        path.flatMap { positions[$0] }
    }

    /// `resolveEntriesAtPaths`: the items at `paths`, in the order of `paths`, leaving out paths not there.
    public func resolve(_ paths: [String]) -> [Element] {
        paths.compactMap { path in positions[path].map { elements[$0] } }
    }
}
