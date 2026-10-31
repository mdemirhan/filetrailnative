// Port of packages/core/src/fs/undoLog.ts
import CryptoKit
import FTFoundation
import Foundation

// What an operation did to the disk, step by step, so it can be undone later. Kept in the engine only: it never
// goes to the window.

/// Which item a step was about: the disk's device number and the item's file id. Steps keep nil when the disk
/// doesn't give a usable id (FAT and exFAT, for empty files).
public struct ItemId: Hashable, Codable, Sendable {
    public var dev: Int64
    public var ino: UInt64

    public init(dev: Int64, ino: UInt64) {
        self.dev = dev
        self.ino = ino
    }
}

public enum ItemKind: String, Codable, Sendable {
    case file, directory, symlink, other
}

/// How an item that an operation made looked just after: Undo asks before moving one to the Trash that has
/// changed since. For a folder only how many items it holds counts, not what is deeper inside, nor its date
/// (which changes with every item in or out).
public struct ItemStamp: Equatable, Codable, Sendable {
    public var kind: ItemKind
    public var size: Int64?
    public var mtimeMs: Double?
    public var entryCount: Int?
    /// For a folder: what its items are called (a digest of their names), to tell one whose items were
    /// renamed, or swapped for others, from one left as it was.
    public var entryNames: String?

    public init(kind: ItemKind, size: Int64?, mtimeMs: Double?, entryCount: Int?, entryNames: String? = nil) {
        self.kind = kind
        self.size = size
        self.mtimeMs = mtimeMs
        self.entryCount = entryCount
        self.entryNames = entryNames
    }

    private enum CodingKeys: String, CodingKey {
        case kind, size, mtimeMs, entryCount, entryNames
    }

    // `size`, `mtimeMs` and `entryCount` are always there (null when unknown); `entryNames` only when read.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(size, forKey: .size)
        try container.encode(mtimeMs, forKey: .mtimeMs)
        try container.encode(entryCount, forKey: .entryCount)
        try container.encodeIfPresent(entryNames, forKey: .entryNames)
    }
}

/// One renamed item of a batch rename.
public struct BatchRenamedItem: Equatable, Codable, Sendable {
    public var from: String
    public var to: String
    public var id: ItemId?
    public var itemKind: ItemKind?

    public init(from: String, to: String, id: ItemId?, itemKind: ItemKind?) {
        self.from = from
        self.to = to
        self.id = id
        self.itemKind = itemKind
    }

    private enum CodingKeys: String, CodingKey {
        case from, to, id, itemKind
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(from, forKey: .from)
        try container.encode(to, forKey: .to)
        try container.encode(id, forKey: .id)
        try container.encode(itemKind, forKey: .itemKind)
    }
}

public enum UndoStep: Equatable, Sendable {
    /// A rename, or a move on one disk. `parentId` is the folder `from` was in, so Undo moves the item back only
    /// into that same folder. `itemKind` lets Undo still move back a file that an app saved under a new id.
    /// `fromTrash` marks putting an item back from the Trash, whose reverse is a fresh move to the Trash (not a
    /// rename into it), and `stamp` how the item looked once back (nil when it couldn't be read), for asking
    /// before trashing it again if it changed. `locked` marks an item put back with what the Trash refuses (a
    /// lock, a read-only folder's mode, a rule against deleting it) that an Undo took off to move it there: it
    /// is taken off again to go back to the Trash.
    case moved(Moved)
    /// An item the operation made: a copy, a duplicate, a new folder.
    case created(path: String, id: ItemId?, stamp: ItemStamp?)
    /// An item moved to the Trash: what was asked for, or an item a Replace pushed out. `stamp` is how it looked
    /// when it went, kept only for an item without a usable id (FAT, exFAT): it is the one way to tell it is
    /// still what is at `trashPath`.
    case trashed(from: String, trashPath: String, id: ItemId?, parentId: ItemId?, stamp: ItemStamp?)
    /// Several items renamed at once, undone as one batch.
    case batchRenamed(items: [BatchRenamedItem])

    public struct Moved: Equatable, Sendable {
        public var from: String
        public var to: String
        public var id: ItemId?
        public var itemKind: ItemKind?
        public var parentId: ItemId?
        /// Set (with `stamp`, possibly nil) only for an item put back from the Trash.
        public var fromTrash: Bool?
        public var stamp: ItemStamp?
        public var locked: Bool?

        public init(
            from: String, to: String, id: ItemId?, itemKind: ItemKind?, parentId: ItemId?, fromTrash: Bool? = nil,
            stamp: ItemStamp? = nil, locked: Bool? = nil
        ) {
            self.from = from
            self.to = to
            self.id = id
            self.itemKind = itemKind
            self.parentId = parentId
            self.fromTrash = fromTrash
            self.stamp = stamp
            self.locked = locked
        }
    }
}

extension UndoStep: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, from, to, id, itemKind, parentId, fromTrash, stamp, locked, path, trashPath, items
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "moved":
            self = .moved(
                Moved(
                    from: try container.decode(String.self, forKey: .from),
                    to: try container.decode(String.self, forKey: .to),
                    id: try container.decodeIfPresent(ItemId.self, forKey: .id),
                    itemKind: try container.decodeIfPresent(ItemKind.self, forKey: .itemKind),
                    parentId: try container.decodeIfPresent(ItemId.self, forKey: .parentId),
                    fromTrash: try container.decodeIfPresent(Bool.self, forKey: .fromTrash),
                    stamp: try container.decodeIfPresent(ItemStamp.self, forKey: .stamp),
                    locked: try container.decodeIfPresent(Bool.self, forKey: .locked)))
        case "created":
            self = .created(
                path: try container.decode(String.self, forKey: .path),
                id: try container.decodeIfPresent(ItemId.self, forKey: .id),
                stamp: try container.decodeIfPresent(ItemStamp.self, forKey: .stamp))
        case "trashed":
            self = .trashed(
                from: try container.decode(String.self, forKey: .from),
                trashPath: try container.decode(String.self, forKey: .trashPath),
                id: try container.decodeIfPresent(ItemId.self, forKey: .id),
                parentId: try container.decodeIfPresent(ItemId.self, forKey: .parentId),
                stamp: try container.decodeIfPresent(ItemStamp.self, forKey: .stamp))
        case "batchRenamed":
            self = .batchRenamed(items: try container.decode([BatchRenamedItem].self, forKey: .items))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: container, debugDescription: "unknown undo step \(kind)")
        }
    }

    // The original's shape: nulls where it writes null, optional keys left out when it leaves them out.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .moved(let moved):
            try container.encode("moved", forKey: .kind)
            try container.encode(moved.from, forKey: .from)
            try container.encode(moved.to, forKey: .to)
            try container.encode(moved.id, forKey: .id)
            try container.encode(moved.itemKind, forKey: .itemKind)
            try container.encode(moved.parentId, forKey: .parentId)
            try container.encodeIfPresent(moved.fromTrash, forKey: .fromTrash)
            if moved.fromTrash != nil {
                try container.encode(moved.stamp, forKey: .stamp)
            } else {
                try container.encodeIfPresent(moved.stamp, forKey: .stamp)
            }
            try container.encodeIfPresent(moved.locked, forKey: .locked)
        case .created(let path, let id, let stamp):
            try container.encode("created", forKey: .kind)
            try container.encode(path, forKey: .path)
            try container.encode(id, forKey: .id)
            try container.encode(stamp, forKey: .stamp)
        case .trashed(let from, let trashPath, let id, let parentId, let stamp):
            try container.encode("trashed", forKey: .kind)
            try container.encode(from, forKey: .from)
            try container.encode(trashPath, forKey: .trashPath)
            try container.encode(id, forKey: .id)
            try container.encode(parentId, forKey: .parentId)
            try container.encodeIfPresent(stamp, forKey: .stamp)
        case .batchRenamed(let items):
            try container.encode("batchRenamed", forKey: .kind)
            try container.encode(items, forKey: .items)
        }
    }
}

/// The steps for one item the person picked, in the order they happened. They are undone together, in reverse;
/// when one can't be, the ones before it in the unit aren't either.
public struct UndoUnit: Equatable, Codable, Sendable {
    public var steps: [UndoStep]

    public init(steps: [UndoStep]) {
        self.steps = steps
    }
}

/// Why an operation can't be undone.
public enum CantUndoReason: String, Codable, Sendable {
    /// A folder was merged into one that was already there (Add Missing).
    case merge
    /// Something was deleted for good: Delete Immediately, Empty Trash, or a Replace on a disk without a Trash.
    case deletedForGood = "deleted_for_good"
    /// Copies, or a new folder, were made on a disk without a Trash: undoing them would mean deleting them.
    case noTrash = "no_trash"
    /// A move to another disk (copied there, then the original deleted).
    case otherDiskMove = "other_disk_move"
    /// An item went to the Trash, but the Trash didn't say where: it can't be put back.
    case trashLocationUnknown = "trash_location_unknown"
}

public enum UndoLog: Equatable, Sendable {
    case undoable(units: [UndoUnit])
    case notUndoable(reason: CantUndoReason)
}

extension UndoLog: Codable {
    private enum CodingKeys: String, CodingKey {
        case undoable, units, reason
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if try container.decode(Bool.self, forKey: .undoable) {
            self = .undoable(units: try container.decode([UndoUnit].self, forKey: .units))
        } else {
            self = .notUndoable(reason: try container.decode(CantUndoReason.self, forKey: .reason))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .undoable(let units):
            try container.encode(true, forKey: .undoable)
            try container.encode(units, forKey: .units)
        case .notUndoable(let reason):
            try container.encode(false, forKey: .undoable)
            try container.encode(reason, forKey: .reason)
        }
    }
}

// MARK: - Ids

/// The id of what `stats` describes, or nil when the disk gives none usable.
public func itemIdOf(_ stats: WriteServiceStats) -> ItemId? {
    itemIdOf(dev: stats.dev, ino: stats.ino)
}

public func itemIdOf(dev: Int64?, ino: UInt64?) -> ItemId? {
    guard let dev, let ino = fileIdOf(ino) else { return nil }
    return ItemId(dev: dev, ino: ino)
}

/// The id of the item at `path` now, or nil when it can't be read or has no usable id.
public func readItemId(_ lstat: (String) throws -> WriteServiceStats, _ path: String) -> ItemId? {
    guard let stats = try? lstat(path) else { return nil }
    return itemIdOf(stats)
}

/// The id of the folder at `path`, a link to a folder followed (`stat`): a folder opened through a link keeps
/// the link's path (~/Projects for /Volumes/Data/Projects), and the folder an item is in is the one the link
/// leads to.
public func readFolderId(_ stat: (String) throws -> WriteServiceStats, _ path: String) -> ItemId? {
    readItemId(stat, path)
}

/// `readFolderId`, each folder read once for one operation: its items are mostly in one folder, and they then
/// share one id.
public struct FolderIds: Sendable {
    private var known: [NameKeys.Exact: ItemId?] = [:]

    public init() {}

    public mutating func id(_ stat: (String) throws -> WriteServiceStats, _ path: String) -> ItemId? {
        let key = NameKeys.Exact(path)
        if let id = known[key] {
            return id
        }
        let id = readFolderId(stat, path)
        known[key] = id
        return id
    }
}

/// The id and kind of the item at `path` now; both nil when it can't be read.
public func readItemRef(_ lstat: (String) throws -> WriteServiceStats, _ path: String) -> (
    id: ItemId?, kind: ItemKind?
) {
    guard let stats = try? lstat(path) else { return (nil, nil) }
    return (itemIdOf(stats), kindOfStats(stats))
}

public func kindOfStats(_ stats: WriteServiceStats) -> ItemKind {
    switch stats.type {
    case .symlink: .symlink
    case .directory: .directory
    case .file: .file
    case .other: .other
    }
}

/// Same item, by id, when both ids are known.
public func sameItemId(_ left: ItemId?, _ right: ItemId?) -> Bool {
    guard let left, let right else { return false }
    return left == right
}

// MARK: - Stamps

/// What stamping an item reads: `lstat`, and the names in a folder when it can (without, a folder's count is
/// unknown).
public struct StampReader: Sendable {
    public var lstat: @Sendable (String) throws -> WriteServiceStats
    public var readdir: (@Sendable (String) throws -> [String])?

    public init(
        lstat: @escaping @Sendable (String) throws -> WriteServiceStats,
        readdir: (@Sendable (String) throws -> [String])? = nil
    ) {
        self.lstat = lstat
        self.readdir = readdir
    }

    public init(_ fileSystem: some IdentityFileSystem) {
        self.init(lstat: { try fileSystem.lstat($0) }, readdir: { try fileSystem.readdir($0) })
    }
}

/// How the item at `path` looks now, or nil when it can't be read.
public func readItemStamp(_ reader: StampReader, _ path: String) -> ItemStamp? {
    readItemIdAndStamp(reader, path).stamp
}

/// The id of the item at `path` and how it looks now, from one look at it; both nil when it can't be read.
public func readItemIdAndStamp(_ reader: StampReader, _ path: String) -> (id: ItemId?, stamp: ItemStamp?) {
    guard let stats = try? reader.lstat(path) else { return (nil, nil) }
    let kind = kindOfStats(stats)
    var entries: [String]?
    if kind == .directory, let readdir = reader.readdir, let names = try? readdir(path) {
        entries = withoutFinderBookkeeping(names)
    }
    let stamp = ItemStamp(
        kind: kind, size: kind == .file ? stats.size : nil, mtimeMs: stats.mtimeMs, entryCount: entries?.count,
        entryNames: entries.map(digestOfNames))
    return (itemIdOf(stats), stamp)
}

/// Files Finder writes into a folder on its own when it is opened or copied to some disks: its view settings
/// (.DS_Store) and the AppleDouble files ("._name") of items beside them. They aren't the person's work, so a
/// new folder holding only them is still empty. A "._name" file with no "name" beside it is an item like any
/// other.
func withoutFinderBookkeeping(_ names: [String]) -> [String] {
    let all = Set(names.map(NameKeys.Exact.init))
    return names.filter { name in
        if sameText(name, ".DS_Store") {
            return false
        }
        let scalars = name.unicodeScalars
        guard startsWith(name, "._"), name.utf16.count > 2 else { return true }
        let rest = String(String.UnicodeScalarView(scalars.dropFirst(2)))
        return !all.contains(NameKeys.Exact(rest))
    }
}

/// A short digest of a folder's item names, whatever order they were listed in: SHA-1 of the names sorted as
/// JavaScript sorts strings (by UTF-16 code unit) and joined by NUL.
func digestOfNames(_ names: [String]) -> String {
    let sorted = names.sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) }
    let digest = Insecure.SHA1.hash(data: Data(sorted.joined(separator: "\0").utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
}

/// For a `trashed` step: how the item at `path` looks, when it has no usable `id` (FAT, exFAT), so it can be
/// told apart in the Trash; nil when it has one, or can't be read.
public func stampWithoutId(_ reader: StampReader, _ path: String, _ id: ItemId?) -> ItemStamp? {
    id == nil ? readItemStamp(reader, path) : nil
}
