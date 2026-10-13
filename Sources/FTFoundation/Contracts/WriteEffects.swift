// Port of packages/contracts/src/writeEffects.ts
import Foundation

/// An item of a finished operation, as far as `WriteEffects` looks at it.
public protocol WrittenItem {
    var sourcePath: String? { get }
    var destinationPath: String? { get }
    var status: String { get }
}

public struct WriteEffectItem: WrittenItem, Equatable, Sendable {
    public var sourcePath: String?
    public var destinationPath: String?
    public var status: String

    public init(sourcePath: String?, destinationPath: String?, status: String = "completed") {
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.status = status
    }
}

/// What a finished file operation changed, for whatever was worked out from the folders it touched
/// (folder sizes). Paths are compared by their exact bytes, as the original compares JavaScript
/// strings; Swift's `==` on `String` would take NFC and NFD as equal.
public enum WriteEffects {
    typealias Bytes = [UInt8]
    private static let slash = UInt8(ascii: "/")

    /// What a finished operation changed: the items it moved, made, renamed or removed, the folder it
    /// wrote into, and where in the Trash the items it replaced went. Anything at, inside or around
    /// these paths may be different now. A path inside another is left out.
    public static func pathsChangedByWrite(
        targetPath: String? = nil, destinationDirectoryPath: String? = nil,
        items: [(sourcePath: String?, destinationPath: String?)], trashedPaths: [String] = []
    ) -> [String] {
        var seen = Set<Bytes>()
        var ordered: [Bytes] = []
        func add(_ path: String?) {
            guard let path, !path.isEmpty else { return }
            let bytes = Array(path.utf8)
            if seen.insert(bytes).inserted {
                ordered.append(bytes)
            }
        }
        add(targetPath)
        add(destinationDirectoryPath)
        for item in items {
            add(item.sourcePath)
            add(item.destinationPath)
        }
        for path in trashedPaths {
            add(path)
        }
        return outermostPaths(ordered, set: seen).map { String(decoding: $0, as: UTF8.self) }
    }

    /// The paths not inside another of them. Each folder holding one is looked at once, so the files of
    /// one folder stop at the folder.
    private static func outermostPaths(_ ordered: [Bytes], set paths: Set<Bytes>) -> [Bytes] {
        // Whether each folder looked at is one of the paths, or inside one.
        var insideOne: [Bytes: Bool] = [:]
        func isInsideOne(_ path: Bytes) -> Bool {
            var visited: [Bytes] = []
            var inside = false
            var index = path.lastIndex(of: slash)
            while let end = index {
                // "/a/" holds "/a/b" as "/a" does, but not itself.
                if end + 1 < path.count && paths.contains(Array(path[...end])) {
                    inside = true
                    break
                }
                let folder = Array(path[..<end])
                if let known = insideOne[folder] {
                    inside = known
                    break
                }
                visited.append(folder)
                if paths.contains(folder) {
                    inside = true
                    break
                }
                index = end == 0 ? nil : path[..<end].lastIndex(of: slash)
            }
            for folder in visited {
                insideOne[folder] = inside
            }
            return inside
        }
        return ordered.filter { !isInsideOne($0) }
    }

    /// Where a rename or move took an item, for a window to follow it there: only what really moved, and
    /// for a rename of several also an item put back under another name ("b 2").
    public static func isFollowedMove(_ item: some WrittenItem, action: String) -> Bool {
        guard let source = item.sourcePath, !source.isEmpty, let destination = item.destinationPath,
            !destination.isEmpty
        else { return false }
        return !source.utf8.elementsEqual(destination.utf8)
            && (item.status == "completed" || action == "batch_rename")
    }

    /// The items of a finished operation that windows other than its own need, out of what can be
    /// 100,000. Those windows forget or measure again the folder sizes the operation changed
    /// (`pathsChangedByWrite`, `ChangeMatcher`) and follow a moved folder in their tabs
    /// (`isFollowedMove`; the first move holding a path wins). An item is left out when neither tells it
    /// apart from the items kept before it: each of its paths is at or inside one of theirs, in a folder
    /// that holds one of theirs, and it either didn't move or a move kept before it holds it.
    public static func itemsForOtherWindows<T: WrittenItem>(action: String, targetPath: String? = nil, items: [T])
        -> [T]
    {
        // As ChangeMatcher tells what is at or inside a change ("/a/" holds "/a/b" too).
        let changed = PathSet(withTrailingSlash: true)
        // Every folder holding a kept path (written without a trailing "/").
        var holders = Set<Bytes>()
        // As a tab follows a move: the path moved, or what starts with it and a "/".
        let movedFrom = PathSet(withTrailingSlash: false)
        // The last folder whose every item was found covered, for sources and for destinations.
        var coveredFolders: [Bytes?] = [nil, nil]

        func isCovered(_ path: String?, side: Int) -> Bool {
            guard let path, !path.isEmpty else { return true }
            let bytes = Array(path.utf8)
            let end = bytes.lastIndex(of: slash)
            if let known = coveredFolders[side], end == known.count, bytes.starts(with: known) {
                return true
            }
            guard let end else { return changed.isAtOrInside(bytes) }
            let folder = Array(bytes[..<end])
            // Both only ever become true as more items are kept.
            if holders.contains(folder) && changed.isFolderAtOrInside(folder) {
                coveredFolders[side] = folder
                return true
            }
            return changed.isAtOrInside(bytes) && holders.contains(folder)
        }
        func addChanged(_ path: String?) {
            guard let path, !path.isEmpty else { return }
            let bytes = Array(path.utf8)
            changed.add(bytes)
            // Up from its folder, until a folder already there: the ones above it are too.
            var index = bytes.lastIndex(of: slash)
            while let end = index {
                let folder = Array(bytes[..<end])
                if holders.contains(folder) {
                    break
                }
                holders.insert(folder)
                if end == 0 {
                    break
                }
                index = bytes[..<end].lastIndex(of: slash)
            }
        }

        addChanged(targetPath)
        var kept: [T] = []
        for item in items {
            let movedFromPath = isFollowedMove(item, action: action) ? item.sourcePath : nil
            if isCovered(item.sourcePath, side: 0) && isCovered(item.destinationPath, side: 1)
                && (movedFromPath.map { movedFrom.isAtOrInside(Array($0.utf8)) } ?? true)
            {
                continue
            }
            kept.append(item)
            addChanged(item.sourcePath)
            addChanged(item.destinationPath)
            if let movedFromPath {
                movedFrom.add(Array(movedFromPath.utf8))
            }
        }
        return kept
    }

    /// Paths, and whether a path is one of them or inside one: in time for the path's length, and at
    /// once for another path in a folder already known to be inside one.
    private final class PathSet {
        let withTrailingSlash: Bool
        private var paths = Set<Bytes>()
        // Folders found to be at or inside one of the paths; with more paths, they still are.
        private var foldersInside = Set<Bytes>()

        init(withTrailingSlash: Bool) {
            self.withTrailingSlash = withTrailingSlash
        }

        func add(_ path: Bytes) {
            paths.insert(path)
        }

        func isFolderAtOrInside(_ folder: Bytes) -> Bool {
            if foldersInside.contains(folder) || paths.contains(folder)
                || (withTrailingSlash && paths.contains(folder + [WriteEffects.slash]))
            {
                foldersInside.insert(folder)
                return true
            }
            guard let end = folder.lastIndex(of: WriteEffects.slash),
                isFolderAtOrInside(Array(folder[..<end]))
            else { return false }
            foldersInside.insert(folder)
            return true
        }

        func isAtOrInside(_ path: Bytes) -> Bool {
            if paths.contains(path) { return true }
            guard let end = path.lastIndex(of: WriteEffects.slash) else { return false }
            return isFolderAtOrInside(Array(path[..<end]))
        }
    }

    /// Whether `path` is one of `changedPaths`, holds one (so what it holds changed), or is inside one
    /// (so it was moved, removed or replaced).
    public static func isAffectedByChange(_ path: String, changedPaths: [String]) -> Bool {
        let bytes = Array(path.utf8)
        return changedPaths.contains {
            let other = Array($0.utf8)
            return isSameOrInside(bytes, folder: other) || isSameOrInside(other, folder: bytes)
        }
    }

    fileprivate static func isSameOrInside(_ path: Bytes, folder: Bytes) -> Bool {
        if path == folder { return true }
        let prefix = folder.last == slash ? folder : folder + [slash]
        return path.starts(with: prefix)
    }

    /// Calls `visit` with every folder that holds `path` by `isSameOrInside`, until it answers true: each
    /// part of the path before a "/", with and without that "/" ("/a" and "/a/" hold "/a/b"), and "" before
    /// a leading "/". Not the path itself, when it ends in "/": nothing holds itself.
    fileprivate static func foldersHolding(_ path: Bytes, _ visit: (Bytes) -> Bool) -> Bool {
        var from = 0
        while let index = path[from...].firstIndex(of: slash) {
            if visit(Array(path[..<index])) {
                return true
            }
            if index + 1 < path.count && visit(Array(path[...index])) {
                return true
            }
            from = index + 1
        }
        return false
    }
}

/// What a set of changes touched, for asking about many paths at once (every cached folder size after
/// a write): each answer takes time in the length of the path asked about, not in the number of
/// changes, which can be tens of thousands.
public struct ChangeMatcher: Sendable {
    private let changed: Set<[UInt8]>
    // Every folder holding a change, as the paths are written.
    private let holders: Set<[UInt8]>

    public init(changedPaths: [String]) {
        var changed = Set<[UInt8]>()
        var holders = Set<[UInt8]>()
        for path in changedPaths {
            let bytes = Array(path.utf8)
            changed.insert(bytes)
        }
        for path in changed {
            _ = WriteEffects.foldersHolding(path) { folder in
                holders.insert(folder)
                return false
            }
        }
        self.changed = changed
        self.holders = holders
    }

    /// Whether `path` holds one of the changes, somewhere inside it.
    public func holdsChange(_ path: String) -> Bool {
        holders.contains(Array(path.utf8))
    }

    /// Whether `path` is one of the changes, or inside one.
    public func isAtOrInsideChange(_ path: String) -> Bool {
        let bytes = Array(path.utf8)
        return changed.contains(bytes) || WriteEffects.foldersHolding(bytes) { changed.contains($0) }
    }

    /// Either: as `WriteEffects.isAffectedByChange`.
    public func isAffected(_ path: String) -> Bool {
        holdsChange(path) || isAtOrInsideChange(path)
    }
}
