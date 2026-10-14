// Port of sortEntriesBySize, isFolderSizeEligibleKind and folderRank of apps/desktop/src/renderer/lib/explorerAppUtils.ts
// (:589-640)
import Foundation

/// What the size order needs to know of an item.
public struct SizeSortKey: Equatable, Sendable {
    public var path: String
    public var name: String
    /// A folder or a link to one (`folderRank` 0): what Folders First puts ahead.
    public var isDirectoryKind: Bool
    /// A folder or a bundle: its size is calculated, not listed (`isFolderSizeEligibleKind`).
    public var isFolderSizeEligible: Bool
    /// The size the listing reported (files).
    public var listedSize: Int64?

    public init(path: String, name: String, isDirectoryKind: Bool, isFolderSizeEligible: Bool, listedSize: Int64?) {
        self.path = path
        self.name = name
        self.isDirectoryKind = isDirectoryKind
        self.isFolderSizeEligible = isFolderSizeEligible
        self.listedSize = listedSize
    }
}

private struct SizeOrderRow<Item> {
    var item: Item
    var key: SizeSortKey
    var size: Int64?
}

public enum SizeOrder {
    /// `localeCompare(b, undefined, { numeric: true, sensitivity: "base" })`: numbers in order, case and accents aside.
    public static func compareNames(_ left: String, _ right: String) -> Int {
        switch left.compare(
            right, options: [.numeric, .caseInsensitive, .diacriticInsensitive], range: nil,
            locale: Locale(identifier: "en_US"))
        {
        case .orderedAscending: -1
        case .orderedDescending: 1
        case .orderedSame: 0
        }
    }

    /// The listing is sorted before folder sizes are known (they come from a separate folder size calculation), so
    /// sorting by size is finished here: files use the size the listing reported, folders and bundles the size
    /// calculated for them, and items without a known size stay at the end in both directions. Ties are ordered by
    /// name, in the direction of the sort.
    public static func sorted<Item>(
        _ items: [Item], key: (Item) -> SizeSortKey, descending: Bool, foldersFirst: Bool,
        folderSizeBytes: (String) -> Int64?
    ) -> [Item] {
        let rows = items.map { item -> SizeOrderRow<Item> in
            let k = key(item)
            return SizeOrderRow(
                item: item, key: k, size: k.isFolderSizeEligible ? folderSizeBytes(k.path) : k.listedSize)
        }
        let direction = descending ? -1 : 1
        return rows.enumerated().sorted { left, right in
            let l = left.element
            let r = right.element
            if foldersFirst {
                let rank = (l.key.isDirectoryKind ? 0 : 1) - (r.key.isDirectoryKind ? 0 : 1)
                if rank != 0 { return rank < 0 }
            }
            if l.size == nil || r.size == nil {
                if (l.size == nil) != (r.size == nil) { return l.size != nil }
            } else if let ls = l.size, let rs = r.size, ls != rs {
                return (ls < rs ? -1 : 1) * direction < 0
            }
            let byName = compareNames(l.key.name, r.key.name) * direction
            if byName != 0 { return byName < 0 }
            return left.offset < right.offset
        }.map { $0.element.item }
    }
}
