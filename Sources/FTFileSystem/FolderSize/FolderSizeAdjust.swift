// Port of apps/desktop/src/main/bootstrap/folderSizeAdjust.ts
import FTFoundation
import Foundation

/// After a delete, each measured folder that held a removed item has the item taken off its size instead
/// of being forgotten, when its measurement is known to have counted the item, and with what. Anything
/// uncertain is forgotten and measured again when next asked for, as before. Sizes of the removed items
/// and everything inside them are forgotten.
public enum FolderSizeAdjust {
    private enum Counted {
        case yes, no, unknown
    }

    private struct Contribution {
        var sizeBytes: Int64
        var diskBytes: Int64
        var fileCount: Int
        var folderCount: Int
    }

    public static func adjustForRemovals(
        _ cache: FolderSizeCache, _ removals: [RemovedItem], _ homeTrash: HomeTrash
    ) {
        var removedFolders: [String] = []
        for removal in removals {
            adjustForRemoval(cache, removal, homeTrash)
            removedFolders.append(removal.path)
        }
        cache.forgetAtOrInside(removedFolders)
    }

    private static func adjustForRemoval(_ cache: FolderSizeCache, _ removal: RemovedItem, _ homeTrash: HomeTrash) {
        let path = removal.path
        let item = removal.item
        // Every measured folder whose total can change: those that held the item, and, for an item moved to
        // the home folder's Trash, the Trash and those that hold it.
        var holders: [String] = []
        var seen = Set<PathKey>()
        func addHolder(_ folder: String) {
            if cache.has(folder), seen.insert(PathKey(folder)).inserted {
                holders.append(folder)
            }
        }
        for folder in ancestorsOf(path) {
            addHolder(folder)
        }
        let trashPath: String? = removal.intoHomeTrash == false ? nil : homeTrash.path
        if let trashPath {
            for folder in [trashPath] + ancestorsOf(trashPath) {
                addHolder(folder)
            }
        }

        // Decided against the sizes as they were, then applied.
        var changes: [(folder: String, change: Contribution?)] = []
        for folder in holders {
            let left: Counted
            if isInside(path, folder) {
                left = item != nil ? countedIn(cache, NodePath.dirname(path), folder) : .unknown
            } else {
                left = .no
            }
            let arrived = trashPath.map { isSameOrInside($0, folder) } ?? false
            let landed: Counted
            if !arrived {
                landed = .no
            } else if removal.intoHomeTrash == nil {
                landed = .unknown
            } else if let trashPath, same(folder, trashPath) {
                landed = .yes
            } else if homeTrash.counted == nil {
                landed = .unknown
            } else if homeTrash.counted == true, let trashPath {
                landed = countedIn(cache, NodePath.dirname(trashPath), folder)
            } else {
                landed = .no
            }
            if left == .unknown || landed == .unknown {
                changes.append((folder, nil))
                continue
            }
            let sign = (left == .yes ? -1 : 0) + (landed == .yes ? 1 : 0)
            if sign == 0 {
                continue
            }
            // Taken off, it is what this folder's measurement counted of it; added (it landed in the Trash),
            // it brings its own size as last measured.
            let contribution = item.flatMap { contributionTo(cache, path, $0, folder, sameMeasurement: sign < 0) }
            changes.append((folder, contribution.map { scale($0, sign) }))
        }

        for (folder, change) in changes {
            guard let stats = cache.get(folder) else { continue }
            if let change, let next = add(stats, change) {
                cache.set(folder, next)
            } else {
                cache.delete(folder)
            }
        }
    }

    /// Whether the measurement of `folder` counted what is directly in `from` (inside it): it walked down to
    /// `from` when every folder on the way has a size it stored, from the same disk. A folder on the way
    /// without one may not have been readable (or had a volume mounted on it, or was a link to a folder), or
    /// was forgotten since; one stored by another measurement may hold more or less than this one counted of it.
    private static func countedIn(_ cache: FolderSizeCache, _ from: String, _ folder: String) -> Counted {
        guard let folderStats = cache.get(folder), let folderDev = folderStats.dev else { return .unknown }
        var current = from
        while true {
            guard let stats = cache.get(current), let dev = stats.dev else { return .unknown }
            if dev != folderDev {
                return .no
            }
            if stats.measurement != folderStats.measurement {
                return .unknown
            }
            if same(current, folder) {
                return .yes
            }
            let parent = NodePath.dirname(current)
            if same(parent, current) {
                return .unknown
            }
            current = parent
        }
    }

    /// What the item added to the measurement of `folder`, which counted its parent folder. A folder's
    /// contents count as its own size, which with `sameMeasurement` must be the one `folder`'s measurement stored.
    private static func contributionTo(
        _ cache: FolderSizeCache, _ path: String, _ item: ItemSize, _ folder: String, sameMeasurement: Bool
    ) -> Contribution? {
        switch item.kind {
        case .file:
            return Contribution(
                sizeBytes: item.sizeBytes, diskBytes: item.diskBytes, fileCount: 1, folderCount: 0)
        case .other:
            return Contribution(sizeBytes: 0, diskBytes: 0, fileCount: 0, folderCount: 0)
        case .folder:
            break
        }
        let holder = cache.get(folder)
        // A folder on another disk is counted as a folder, and nothing inside it.
        if item.dev != holder?.dev {
            return Contribution(sizeBytes: 0, diskBytes: 0, fileCount: 0, folderCount: 1)
        }
        guard let own = cache.get(path), own.dev == item.dev,
            !(sameMeasurement && own.measurement != holder?.measurement)
        else { return nil }
        return Contribution(
            sizeBytes: own.sizeBytes, diskBytes: own.diskBytes, fileCount: own.fileCount,
            folderCount: own.folderCount + 1)
    }

    private static func scale(_ contribution: Contribution, _ sign: Int) -> Contribution {
        Contribution(
            sizeBytes: contribution.sizeBytes * Int64(sign), diskBytes: contribution.diskBytes * Int64(sign),
            fileCount: contribution.fileCount * sign, folderCount: contribution.folderCount * sign)
    }

    /// The sizes with the change made, or nil when they would go below zero: the measurement didn't count
    /// what it was thought to, so it is measured again.
    private static func add(_ stats: FolderSizeStats, _ change: Contribution) -> FolderSizeStats? {
        var next = stats
        next.sizeBytes += change.sizeBytes
        next.diskBytes += change.diskBytes
        next.fileCount += change.fileCount
        next.folderCount += change.folderCount
        return next.sizeBytes < 0 || next.diskBytes < 0 || next.fileCount < 0 || next.folderCount < 0 ? nil : next
    }

    private static func ancestorsOf(_ path: String) -> [String] {
        var ancestors: [String] = []
        var current = path
        while true {
            let parent = NodePath.dirname(current)
            if same(parent, current) {
                return ancestors
            }
            ancestors.append(parent)
            current = parent
        }
    }

    private static func same(_ first: String, _ second: String) -> Bool {
        first.utf8.elementsEqual(second.utf8)
    }

    private static func isInside(_ path: String, _ folder: String) -> Bool {
        let prefix = folder.utf8.last == UInt8(ascii: "/") ? Array(folder.utf8) : Array(folder.utf8) + [UInt8(ascii: "/")]
        return path.utf8.starts(with: prefix)
    }

    private static func isSameOrInside(_ path: String, _ folder: String) -> Bool {
        same(path, folder) || isInside(path, folder)
    }
}
