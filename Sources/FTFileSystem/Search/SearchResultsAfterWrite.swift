// Search results kept as they are after a write, but for what it removed and what it renamed
import FTFoundation

/// A renamed item: where it was and where it is.
public struct SearchResultRename: Equatable, Sendable {
    public var from: String
    public var to: String

    public init(from: String, to: String) {
        self.from = from
        self.to = to
    }
}

/// Renames to look a path up in: where a path is after them costs as much as the path is deep, however many they are.
public struct SearchResultRenames: Sendable {
    private var destinations: [DiskPath: String] = [:]

    public init(_ renamed: [SearchResultRename] = []) {
        for rename in renamed { add(rename) }
    }

    public var isEmpty: Bool { destinations.isEmpty }

    /// Of two renames of one path the first is kept.
    public mutating func add(_ rename: SearchResultRename) {
        let key = DiskPath(rename.from)
        if destinations[key] == nil { destinations[key] = rename.to }
    }

    /// Where `path` is after the renames, when it is a renamed item or inside one; nil when it didn't move. Only
    /// renames of the item itself and of folders holding it apply, the deepest first, so items that swapped names
    /// each take the other's. A rename inside a renamed folder finds the item where it was, and the folder then takes
    /// it along, whichever path the write gave the item.
    public func path(_ path: String) -> String? {
        guard !destinations.isEmpty else { return nil }
        let units = Array(path.utf8)
        let slash = UInt8(ascii: "/")
        var current = path
        var moved = false
        var end = units.count
        while end > 0 {
            let from = String(decoding: units[..<end], as: UTF8.self)
            if let to = destinations[DiskPath(from)],
                let next = SearchResults.replacingPrefix(current, from, to)
            {
                current = next
                moved = true
            }
            // The folder above: up to the slash before, the first one aside.
            guard let above = units[..<end].lastIndex(of: slash), above > 0 else { break }
            end = above
        }
        return moved ? current : nil
    }
}

extension SearchResults {
    /// `results` without the items at or inside a path of `removed`, and with those at or inside a renamed item at
    /// their new paths, found as fd would have found them there; nil when no result is one of them. A renamed item
    /// stays though its new name may not match the search. Paths are compared byte for byte.
    public static func afterWrite(
        _ results: [SearchResultItem], rootPath: String, removed: [String], renamed: [SearchResultRename]
    ) -> [SearchResultItem]? {
        guard !removed.isEmpty || !renamed.isEmpty else { return nil }
        let gone = Set(removed.map(DiskPath.init))
        let renames = SearchResultRenames(renamed)
        var changed = false
        var kept: [SearchResultItem] = []
        kept.reserveCapacity(results.count)
        for item in results {
            if isAtOrInsideAny(item.path, gone) {
                changed = true
                continue
            }
            guard let path = renames.path(item.path) else {
                kept.append(item)
                continue
            }
            changed = true
            kept.append(moved(item, to: path, rootPath: rootPath))
        }
        return changed ? kept : nil
    }

    /// Where `path` is after `renamed` (`SearchResultRenames.path`); for many paths, make the renames once.
    public static func path(_ path: String, after renamed: [SearchResultRename]) -> String? {
        SearchResultRenames(renamed).path(path)
    }

    /// Whether `path` is one of `paths` or inside one: each folder above it is looked up, so the cost grows with the
    /// path's depth, not with how many paths there are.
    public static func isAtOrInsideAny(_ path: String, _ paths: Set<DiskPath>) -> Bool {
        guard !paths.isEmpty else { return false }
        if paths.contains(DiskPath(path)) { return true }
        let units = Array(path.utf16)
        let slash = UInt16(UInt8(ascii: "/"))
        var index = 1
        while index < units.count {
            if units[index] == slash {
                let folder = String(decoding: units[..<index], as: UTF16.self)
                if paths.contains(DiskPath(folder)) { return true }
            }
            index += 1
        }
        return false
    }

    /// Whether `path` is `folder` or inside it, byte for byte.
    public static func isAtOrInside(_ path: String, _ folder: String) -> Bool {
        if path.utf8.elementsEqual(folder.utf8) { return true }
        let prefix = folder.hasSuffix("/") ? folder : folder + "/"
        return path.utf8.starts(with: prefix.utf8)
    }

    /// `path` with `from` replaced by `to` when it is `from` or inside it; nil otherwise.
    static func replacingPrefix(_ path: String, _ from: String, _ to: String) -> String? {
        if path.utf8.elementsEqual(from.utf8) { return to }
        guard path.utf8.starts(with: (from + "/").utf8) else { return nil }
        return to + String(decoding: path.utf8.dropFirst(from.utf8.count), as: UTF8.self)
    }

    /// `item` at `path`: its name, extension, hidden mark and folders as the search would give them there; a folder
    /// stays a folder (or becomes a package by its new name), a file a file, a link a link.
    private static func moved(_ item: SearchResultItem, to path: String, rootPath: String) -> SearchResultItem {
        let isFolder = item.kind == .directory || item.kind == .bundle
        var next = SearchResults.item(rootPath: rootPath, outputPath: isFolder ? path + "/" : path)
        if !isFolder { next.kind = item.kind }
        next.isSymlink = item.isSymlink
        return next
    }
}
