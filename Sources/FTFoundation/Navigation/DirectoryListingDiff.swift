import Foundation

public enum DirectoryListingDiff {

    /// What `keepUnchanged` decided.
    public struct Kept<T: Equatable>: Equatable {
        /// The new listing, in its order.
        public var entries: [T]
        /// Nothing changed: what is on screen stays as it is.
        public var isUnchanged: Bool
        /// The paths of `entries` that were on screen and are still as they were.
        public var keptPaths: Set<DiskPath>
        /// The paths of `entries` that came or changed, in order: the rows to draw again.
        public var changedPaths: [String]
    }

    /// A folder read again, as `next`, keeping each item of `shown` that is still there as it
    /// was, so that only the rows of the items that changed are drawn again. A value has no identity here, so what
    /// is kept is told by path, byte for byte: an item whose name is now spelled with its accent the other way is
    /// another item, though `==` on its text holds the two equal.
    public static func keepUnchanged<T: Equatable>(
        shown: [T], next: [T], path: (T) -> String
    ) -> Kept<T> {
        let nextPaths = next.map { DiskPath(path($0)) }
        if shown == next, zip(shown, nextPaths).allSatisfy({ DiskPath(path($0)) == $1 }) {
            return Kept(entries: next, isUnchanged: true, keptPaths: Set(nextPaths), changedPaths: [])
        }
        var shownByPath: [DiskPath: T] = [:]
        for entry in shown {
            let key = DiskPath(path(entry))
            if shownByPath[key] == nil { shownByPath[key] = entry }
        }
        var kept: Set<DiskPath> = []
        var changed: [String] = []
        for (entry, key) in zip(next, nextPaths) {
            if let before = shownByPath[key], before == entry { kept.insert(key) } else { changed.append(key.string) }
        }
        return Kept(entries: next, isUnchanged: false, keptPaths: kept, changedPaths: changed)
    }
}
