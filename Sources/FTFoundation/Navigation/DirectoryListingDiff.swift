// Port of isFolderGoneError, sameDirectoryEntries, keepUnchangedEntries and sameDetailsByPath
// (apps/desktop/src/renderer/lib/explorerNavigation.ts:293-380)
import Foundation

public enum DirectoryListingDiff {
    /// `isFolderGoneError`: whether reading a folder failed because it is no longer there (removed, renamed or
    /// replaced by a file), not because it can't be read. Only the start of the message counts: the path it ends with
    /// may have any of these words in it.
    public static func isFolderGone(message: String) -> Bool {
        message.hasPrefix("ENOENT:") || message.hasPrefix("ENOTDIR:") || message.hasPrefix("Path is not a directory: ")
    }

    /// `sameDirectoryEntries`: whether two listings show the same items the same way, each with the same details in
    /// the same order.
    public static func sameEntries<T: Equatable>(_ left: [T], _ right: [T]) -> Bool {
        left == right
    }

    /// What `keepUnchangedEntries` decided.
    public struct Kept<T: Equatable>: Equatable {
        /// The new listing, in its order.
        public var entries: [T]
        /// Nothing changed: what is on screen stays as it is.
        public var isUnchanged: Bool
        /// The paths of `entries` that were on screen and are still as they were.
        public var keptPaths: Set<String>
        /// The paths of `entries` that came or changed, in order: the rows to draw again.
        public var changedPaths: [String]
    }

    /// `keepUnchangedEntries`: a folder read again, as `next`, keeping each item of `shown` that is still there as it
    /// was, so that only the rows of the items that changed are drawn again. A value has no identity here, so what
    /// is kept is told by path.
    public static func keepUnchanged<T: Equatable>(
        shown: [T], next: [T], path: (T) -> String
    ) -> Kept<T> {
        if shown == next {
            return Kept(entries: next, isUnchanged: true, keptPaths: Set(next.map(path)), changedPaths: [])
        }
        var shownByPath: [String: T] = [:]
        for entry in shown where shownByPath[path(entry)] == nil { shownByPath[path(entry)] = entry }
        var kept: Set<String> = []
        var changed: [String] = []
        for entry in next {
            let key = path(entry)
            if let before = shownByPath[key], before == entry { kept.insert(key) } else { changed.append(key) }
        }
        return Kept(entries: next, isUnchanged: false, keptPaths: kept, changedPaths: changed)
    }

    /// `sameDetailsByPath` for details that have an identity: the very same objects for the same items, not equal
    /// copies of them.
    public static func sameDetailsByPath<V: AnyObject>(_ left: [String: V], _ right: [String: V]) -> Bool {
        if left.count != right.count { return false }
        return left.allSatisfy { path, details in right[path] === details }
    }

    /// `sameDetailsByPath` for details that are values: equal ones for the same items.
    public static func sameDetailsByPath<V: Equatable>(_ left: [String: V], _ right: [String: V]) -> Bool {
        left == right
    }
}
