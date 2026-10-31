// Port of apps/desktop/src/main/bootstrap/folderSizeCache.ts
import Foundation

/// The folder sizes known. All are kept: a measurement's sizes are what the folders inside it show, and
/// one let go would show none until the folder holding it is measured again. Measuring the home folder
/// stores hundreds of thousands, so what a write changed is found from the paths it changed, not by
/// looking at every size: each folder is listed under the folder holding it.
public final class FolderSizeCache {
    private var sizes: [PathKey: FolderSizeStats] = [:]
    // The paths directly in each folder that have a size, or hold one (see `parentOf`). A folder is listed
    // while it has a size or holds one, so walking down from a folder finds every size inside it.
    private var children: [PathKey: Set<PathKey>] = [:]
    // The paths stored while a write runs (see `startRecording`); nil when none runs.
    private var recorded: Set<PathKey>?

    public init() {}

    public var size: Int { sizes.count }

    public func has(_ path: String) -> Bool {
        sizes[PathKey(path)] != nil
    }

    public func get(_ path: String) -> FolderSizeStats? {
        sizes[PathKey(path)]
    }

    public func entries() -> [(path: String, stats: FolderSizeStats)] {
        sizes.map { (path: $0.key.value, stats: $0.value) }
    }

    /// A size measured.
    public func store(_ path: String, _ stats: FolderSizeStats) {
        let key = PathKey(path)
        if sizes.updateValue(stats, forKey: key) == nil {
            link(path)
        }
        recorded?.insert(key)
    }

    /// A size changed where it is kept (something taken off it), not as one measured.
    public func set(_ path: String, _ stats: FolderSizeStats) {
        let key = PathKey(path)
        if sizes[key] != nil {
            sizes[key] = stats
        } else {
            store(path, stats)
        }
    }

    @discardableResult
    public func delete(_ path: String) -> Bool {
        let key = PathKey(path)
        guard sizes.removeValue(forKey: key) != nil else { return false }
        recorded?.remove(key)
        if children[key] == nil {
            unlink(path)
        }
        return true
    }

    public func clear() {
        sizes.removeAll()
        children.removeAll()
        recorded?.removeAll()
    }

    /// The sizes a change at `changedPaths` may have made wrong: of the folders holding one, and of what is
    /// at or inside one (as `WriteEffects.isAffectedByChange`). Each folder holding a change is looked at
    /// once, and only the sizes inside a change are walked.
    public func forgetAffected(_ changedPaths: [String]) {
        var looked = Set<PathKey>()
        for changed in changedPaths {
            Self.forEachHolder(of: changed, looked: &looked) { holder in
                delete(holder)
            }
            forgetAtOrInsideOne(changed)
        }
    }

    /// The sizes of `paths` and of everything inside them.
    public func forgetAtOrInside(_ paths: [String]) {
        for path in paths {
            forgetAtOrInsideOne(path)
        }
    }

    /// From now on, what is stored is noted, until `stopRecording`: what was stored while a write ran may
    /// have been measured after it removed something.
    public func startRecording() {
        recorded = []
    }

    public func stopRecording() {
        recorded = nil
    }

    /// How many sizes are noted (see `startRecording`): never more than are kept.
    public var recordedCount: Int { recorded?.count ?? 0 }

    /// Of the sizes stored since `startRecording`, those of the folders holding one of `paths` (and of
    /// `paths` themselves, with `atToo`), forgotten.
    public func forgetRecordedHolding(_ paths: [String], atToo: Bool) {
        guard let noted = recorded, !noted.isEmpty else { return }
        var looked = Set<PathKey>()
        for path in paths {
            Self.forEachHolder(of: path, looked: &looked) { candidate in
                if recorded?.contains(PathKey(candidate)) == true {
                    delete(candidate)
                }
            }
            if atToo, recorded?.contains(PathKey(path)) == true {
                delete(path)
            }
        }
    }

    private func forgetAtOrInsideOne(_ path: String) {
        delete(path)
        // What is inside "/a/" is what is inside "/a".
        let folder =
            path.utf8.last == Self.slash ? String(path[..<path.utf8.index(before: path.utf8.endIndex)]) : path
        guard children[PathKey(folder)] != nil else { return }
        for inside in self.inside(folder) {
            delete(inside)
        }
    }

    /// Every path with a size inside `folder` (not `folder` itself).
    private func inside(_ folder: String) -> [String] {
        var found: [String] = []
        var pending = [PathKey(folder)]
        while let next = pending.popLast() {
            for child in children[next] ?? [] {
                if sizes[child] != nil {
                    found.append(child.value)
                }
                pending.append(child)
            }
        }
        return found
    }

    /// Lists `path` under the folders holding it, as far up as one is listed already.
    private func link(_ path: String) {
        var current = PathKey(path)
        var parent = Self.parentOf(path)
        while let parentPath = parent {
            let parentKey = PathKey(parentPath)
            if children[parentKey] != nil {
                children[parentKey]?.insert(current)
                return
            }
            children[parentKey] = [current]
            if sizes[parentKey] != nil {
                return
            }
            current = parentKey
            parent = Self.parentOf(parentPath)
        }
    }

    /// Takes `path`, which no longer has a size or holds one, off the folders holding it, as far up as they
    /// still have a size or hold another.
    private func unlink(_ path: String) {
        var current = PathKey(path)
        var parent = Self.parentOf(path)
        while let parentPath = parent {
            let parentKey = PathKey(parentPath)
            guard children[parentKey] != nil else { return }
            children[parentKey]?.remove(current)
            if children[parentKey]?.isEmpty == false {
                return
            }
            children[parentKey] = nil
            if sizes[parentKey] != nil {
                return
            }
            current = parentKey
            parent = Self.parentOf(parentPath)
        }
    }

    private static let slash = UInt8(ascii: "/")

    /// The folder a path is listed under: the part before its last "/" ("" for "/a", "/a" for "/a/" and
    /// "/a/b"). Everything inside a folder by `isSameOrInside` ("/a/", "/a/b", "/a//b") is found under it
    /// this way.
    static func parentOf(_ path: String) -> String? {
        let utf8 = path.utf8
        guard let index = utf8.lastIndex(of: slash) else { return nil }
        return String(path[..<index])
    }

    /// Calls `visit` with the folders holding `path` by `isSameOrInside`, nearest first (as
    /// `ChangeMatcher.holdsChange`: each part before a "/", with and without it), leaving out those in
    /// `looked` and what holds them, which were visited already. Adds those it visits to `looked`.
    static func forEachHolder(of path: String, looked: inout Set<PathKey>, visit: (String) -> Void) {
        let bytes = Array(path.utf8)
        var index = bytes.lastIndex(of: slash)
        while let current = index {
            // Not the path itself, when it ends in "/".
            if current + 1 < bytes.count {
                visit(String(decoding: bytes[...current], as: UTF8.self))
            }
            let folder = String(decoding: bytes[..<current], as: UTF8.self)
            let key = PathKey(folder)
            if looked.contains(key) {
                return
            }
            looked.insert(key)
            visit(folder)
            index = current == 0 ? nil : bytes[..<current].lastIndex(of: slash)
        }
    }
}
