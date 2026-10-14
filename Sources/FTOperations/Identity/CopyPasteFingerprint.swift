// Port of packages/core/src/fs/copyPasteFingerprint.ts
import FTFoundation
import Foundation
import os

public enum CopyPasteNodeKind: String, Codable, Sendable {
    case missing, file, directory, symlink
}

/// How an item looked when it was read: what the engine compares to tell whether it changed since.
public struct NodeFingerprint: Equatable, Codable, Sendable {
    public var exists: Bool
    public var kind: CopyPasteNodeKind
    /// For a file only.
    public var size: Int64?
    public var mtimeMs: Double?
    public var mode: UInt32?
    /// nil when the disk gives no usable id (see `fileIdOf`).
    public var ino: UInt64?
    public var dev: Int64?
    /// For a symlink whose target could be read.
    public var symlinkTarget: String?

    public init(
        exists: Bool, kind: CopyPasteNodeKind, size: Int64? = nil, mtimeMs: Double? = nil, mode: UInt32? = nil,
        ino: UInt64? = nil, dev: Int64? = nil, symlinkTarget: String? = nil
    ) {
        self.exists = exists
        self.kind = kind
        self.size = size
        self.mtimeMs = mtimeMs
        self.mode = mode
        self.ino = ino
        self.dev = dev
        self.symlinkTarget = symlinkTarget
    }

    public static let missing = NodeFingerprint(exists: false, kind: .missing)

    // `===` on strings: scalar for scalar.
    public static func == (left: NodeFingerprint, right: NodeFingerprint) -> Bool {
        left.exists == right.exists && left.kind == right.kind && left.size == right.size
            && left.mtimeMs == right.mtimeMs && left.mode == right.mode && left.ino == right.ino
            && left.dev == right.dev && sameText(left.symlinkTarget, right.symlinkTarget)
    }
}

/// An item's fingerprint, read with `lstat` (a symlink is fingerprinted as the link); a missing fingerprint
/// when it can't be read.
public func captureFingerprint(_ fileSystem: some IdentityFileSystem, _ path: String) -> NodeFingerprint {
    guard let stats = try? fileSystem.lstat(path) else { return .missing }
    let kind = detectKind(stats)
    return NodeFingerprint(
        exists: true, kind: kind, size: kind == .file ? stats.size : nil, mtimeMs: stats.mtimeMs,
        mode: stats.mode, ino: fileIdOf(stats.ino), dev: stats.dev,
        symlinkTarget: kind == .symlink ? try? fileSystem.readlink(path) : nil)
}

/// A folder that may be given by a symlink to it (a link to Desktop, say): pasting into the link pastes into
/// the folder, so it is that folder's fingerprint, followed through the link. Anything else is fingerprinted as
/// it is.
public func captureFolderFingerprint(_ fileSystem: some IdentityFileSystem, _ path: String) -> NodeFingerprint {
    let fingerprint = captureFingerprint(fileSystem, path)
    guard fingerprint.kind == .symlink, let stats = try? fileSystem.stat(path), stats.isDirectory else {
        return fingerprint
    }
    return NodeFingerprint(
        exists: true, kind: .directory, mtimeMs: stats.mtimeMs, mode: stats.mode, ino: fileIdOf(stats.ino),
        dev: stats.dev)
}

public func detectKind(_ stats: WriteServiceStats) -> CopyPasteNodeKind {
    if stats.isSymbolicLink {
        return .symlink
    }
    if stats.isDirectory {
        return .directory
    }
    return .file
}

/// The same item, as it was: every field alike, ids compared only where both are known.
public func fingerprintsEqual(_ left: NodeFingerprint, _ right: NodeFingerprint) -> Bool {
    left.exists == right.exists && left.kind == right.kind && left.size == right.size
        && left.mtimeMs == right.mtimeMs && left.mode == right.mode
        && sameText(left.symlinkTarget, right.symlinkTarget)
        && (left.ino == nil || right.ino == nil || left.ino == right.ino)
        && (left.dev == nil || right.dev == nil || left.dev == right.dev)
}

/// Two fingerprints of one existing item, by identity (dev:ino) alone.
public func isSameExistingItem(_ left: NodeFingerprint, _ right: NodeFingerprint) -> Bool {
    left.exists && right.exists && left.ino != nil && left.dev != nil && left.ino == right.ino
        && left.dev == right.dev
}

public enum SourceRelation: String, Sendable {
    case same, contains
}

/// Whether the item at `destinationPath` is (`.same`) or contains (`.contains`) the item at `sourcePath`, so
/// replacing it would destroy the source. Compares where both really are on disk: the source may be reached
/// through a symlinked folder or a different letter case ("L/X" where "L" links to "X" lives inside "X").
public func findSourceRelation(
    _ fileSystem: some IdentityFileSystem, sourcePath: String, destinationPath: String,
    destination: NodeFingerprint
) -> SourceRelation? {
    let source = captureFingerprint(fileSystem, sourcePath)
    if sameText(sourcePath, destinationPath) || isSameExistingItem(source, destination) {
        return .same
    }
    if destination.kind != .directory {
        return nil
    }
    if startsWith(sourcePath, destinationPath + "/") {
        return .contains
    }
    let realSourcePath = realItemPath(fileSystem, sourcePath)
    let realDestinationPath = (try? fileSystem.realpath(destinationPath)) ?? destinationPath
    if sameText(realSourcePath, realDestinationPath) {
        return .same
    }
    let destinationPrefix = realDestinationPath.hasSuffix("/") ? realDestinationPath : realDestinationPath + "/"
    if startsWith(realSourcePath, destinationPrefix) {
        return .contains
    }
    // The real path has no symlinks left in it, so its ancestors are the folders that really hold the
    // source. Comparing identities also catches names that differ only by case.
    var ancestor = NodePath.dirname(realSourcePath)
    while true {
        if isSameExistingItem(captureFingerprint(fileSystem, ancestor), destination) {
            return .contains
        }
        let parent = NodePath.dirname(ancestor)
        if sameText(parent, ancestor) {
            return nil
        }
        ancestor = parent
    }
}

/// Where the items of a paste really are (see `realItemPath`), to tell whether replacing a folder would
/// destroy one of them.
public func realItemPaths(_ fileSystem: some IdentityFileSystem, _ paths: [String]) -> [String] {
    paths.map { realItemPath(fileSystem, $0) }
}

/// The items of a paste (by their real paths) and the folders holding them, read once for the whole review
/// or paste, so asking about one more item costs a look at that item alone, not at every item pasted.
public final class PastedItems: Sendable {
    public let realPaths: [String]
    private let index = OSAllocatedUnfairLock<Index?>(initialState: nil)

    struct Index: Sendable {
        /// Each item's real path, by the item's identity and by its real path.
        var items: [NameKeys.Exact: String] = [:]
        /// The items' real paths, by the identity and the path of each item and of every folder holding it.
        var holders: [NameKeys.Exact: [String]] = [:]
    }

    public init(realPaths: [String]) {
        self.realPaths = realPaths
    }

    func read(_ fileSystem: some IdentityFileSystem) -> Index {
        if let known = index.withLock({ $0 }) {
            return known
        }
        let built = Self.build(fileSystem, realPaths)
        return index.withLock { state in
            if let known = state {
                return known
            }
            state = built
            return built
        }
    }

    // An item's real path has no symlinks left in it, so its folders are the ones that really hold it.
    private static func build(_ fileSystem: some IdentityFileSystem, _ realPaths: [String]) -> Index {
        // Items side by side share their folders: each folder is read once.
        var folderIds: [NameKeys.Exact: NameKeys.Exact?] = [:]
        func idOf(_ path: String) -> NameKeys.Exact? {
            let key = NameKeys.Exact(path)
            if let known = folderIds[key] {
                return known
            }
            let id = idKey(captureFingerprint(fileSystem, path))
            folderIds[key] = id
            return id
        }
        var index = Index()
        for realPath in realPaths {
            for key in [idOf(realPath), pathKey(realPath), foldedPathKey(realPath)] {
                if let key {
                    index.items[key] = realPath
                }
            }
            var path = realPath
            while true {
                for key in [idOf(path), pathKey(path), foldedPathKey(path)] {
                    if let key {
                        index.holders[key, default: []].append(realPath)
                    }
                }
                let parent = NodePath.dirname(path)
                if sameText(parent, path) {
                    break
                }
                path = parent
            }
        }
        return index
    }
}

/// Whether the folder at `destinationPath` is or holds any of the pasted items: replacing it would destroy them
/// along with it. Told by identity: a real path can still name a folder another way (the firmlinked
/// "/System/Volumes/Data/Users/…" for "/Users/…"), so the folder is looked for among each item's own folders.
/// On a disk that gives no identities, paths are compared ignoring case: such disks (FAT, exFAT) don't tell case
/// apart, while ignoring it elsewhere would take "/d/Sub" for "/d/sub" on a disk that does.
public func holdsAnyOf(_ fileSystem: some IdentityFileSystem, _ destinationPath: String, _ pasted: PastedItems)
    -> Bool
{
    let realDestination = (try? fileSystem.realpath(destinationPath)) ?? destinationPath
    let id = idKey(captureFingerprint(fileSystem, destinationPath))
    let holders = pasted.read(fileSystem).holders
    let held: [String] =
        if let id {
            (holders[id] ?? []) + (holders[pathKey(realDestination)] ?? [])
        } else {
            holders[foldedPathKey(realDestination)] ?? []
        }
    // One already moved out (earlier in the same move) is no longer at risk.
    return held.contains { captureFingerprint(fileSystem, $0).exists }
}

/// Whether the item at `path` is one of the pasted items, as the review tells "another item being pasted":
/// replacing it would destroy that item. Told by identity too, as for `holdsAnyOf`, so a hard link to an item
/// counts. One already moved away (earlier in the same move) no longer is: what is at `path` now is looked up.
public func isAnyOf(_ fileSystem: some IdentityFileSystem, _ path: String, _ pasted: PastedItems) -> Bool {
    let id = idKey(captureFingerprint(fileSystem, path))
    let items = pasted.read(fileSystem).items
    if let id, items[id] != nil {
        return true
    }
    let spellings = [realItemPath(fileSystem, path), (try? fileSystem.realpath(path)) ?? path]
    if id != nil {
        return spellings.contains { items[pathKey($0)] != nil }
    }
    for spelling in spellings {
        if let item = items[foldedPathKey(spelling)], captureFingerprint(fileSystem, item).exists {
            return true
        }
    }
    return false
}

// Keys for the items of a paste and the folders holding them: an identity ("dev:ino"), a path, or a path
// ignoring case, each spelled so that no two kinds can meet.
private func pathKey(_ path: String) -> NameKeys.Exact {
    NameKeys.Exact("=" + path.decomposedStringWithCanonicalMapping)
}

private func foldedPathKey(_ path: String) -> NameKeys.Exact {
    NameKeys.Exact("~" + NameKeys.placeKey(path))
}

private func idKey(_ fingerprint: NodeFingerprint) -> NameKeys.Exact? {
    guard fingerprint.exists, let dev = fingerprint.dev, let ino = fingerprint.ino else { return nil }
    return NameKeys.Exact("\(dev):\(ino)")
}

/// Where an item really is: its folder resolved, but not the item itself (a pasted symlink is the link, not
/// what it points to).
func realItemPath(_ fileSystem: some IdentityFileSystem, _ path: String) -> String {
    guard let folder = try? fileSystem.realpath(NodePath.dirname(path)) else { return path }
    return NodePath.join(folder, NodePath.basename(path))
}

public func pathExists(_ fileSystem: some IdentityFileSystem, _ path: String) -> Bool {
    captureFingerprint(fileSystem, path).exists
}

/// The first id that a JavaScript number can't hold exactly.
private let firstUnsafeFileId: UInt64 = 1 << 53

/// A file id usable to tell items apart, or nil. FAT and exFAT give empty files ids near 2^64, which the
/// original (a JavaScript number) can't hold exactly: they all round to the same value, so every empty file
/// would look like the same item. Such an id, and any other of 2^53 or more, is treated as unknown.
public func fileIdOf(_ ino: UInt64?) -> UInt64? {
    guard let ino, ino < firstUnsafeFileId else { return nil }
    return ino
}

/// `===` on two strings: scalar for scalar (Swift's `==` takes NFC and NFD as equal).
func sameText(_ left: String?, _ right: String?) -> Bool {
    switch (left, right) {
    case (nil, nil): true
    case let (left?, right?): left.unicodeScalars.elementsEqual(right.unicodeScalars)
    default: false
    }
}

/// `text.startsWith(prefix)`, scalar for scalar.
func startsWith(_ text: String, _ prefix: String) -> Bool {
    text.unicodeScalars.starts(with: prefix.unicodeScalars)
}
