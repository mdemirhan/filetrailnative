// Port of the types of apps/desktop/src/main/bootstrap/folderSizeAdjust.ts and responseCache.ts (folder-size jobs)
import Foundation

/// A path as a dictionary key: compared and hashed by its exact UTF-8, as JavaScript compares strings.
/// Swift's `String` takes NFC and NFD spellings as equal, and a folder can have either as its name.
struct PathKey: Hashable, Sendable {
    let value: String

    init(_ value: String) {
        self.value = value
    }

    static func == (lhs: PathKey, rhs: PathKey) -> Bool {
        var lhs = lhs.value
        var rhs = rhs.value
        return lhs.withUTF8 { left in
            rhs.withUTF8 { right in
                left.count == right.count
                    && (left.isEmpty || memcmp(left.baseAddress, right.baseAddress, left.count) == 0)
            }
        }
    }

    func hash(into hasher: inout Hasher) {
        var copy = value
        copy.withUTF8 { hasher.combine(bytes: UnsafeRawBufferPointer($0)) }
    }
}

/// A folder's measured size, the disk it was measured on, and the measurement that stored it. A
/// measurement never leaves the disk it starts on, so only the folders below on the same disk are in its
/// total. The sizes one measurement stores add up: a folder's total is what it measured of the folders
/// inside. Sizes from different measurements may not (the folder inside measured again after it grew), so
/// one is never taken off the other.
public struct FolderSizeStats: Equatable, Sendable {
    public var sizeBytes: Int64
    public var diskBytes: Int64
    public var fileCount: Int
    public var folderCount: Int
    public var dev: Int64?
    public var measurement: Int

    public init(
        sizeBytes: Int64, diskBytes: Int64, fileCount: Int, folderCount: Int, dev: Int64?, measurement: Int
    ) {
        self.sizeBytes = sizeBytes
        self.diskBytes = diskBytes
        self.fileCount = fileCount
        self.folderCount = folderCount
        self.dev = dev
        self.measurement = measurement
    }
}

/// One item as a measurement counts it inside its folder (`nativeItemSize`): a file or symlink by its
/// sizes, a folder only as one (its contents are its own measurement's), anything else not at all.
public struct ItemSize: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case file, folder, other
    }

    public var kind: Kind
    public var sizeBytes: Int64
    public var diskBytes: Int64
    public var dev: Int64

    public init(kind: Kind, sizeBytes: Int64, diskBytes: Int64, dev: Int64) {
        self.kind = kind
        self.sizeBytes = sizeBytes
        self.diskBytes = diskBytes
        self.dev = dev
    }
}

/// An item a delete removed, as it was just before: nil `item` when it couldn't be read (it was gone
/// already, say). An item moved to the Trash from the home folder's disk lands in the home folder's Trash,
/// which measurements of the folders holding it may or may not count; nil `intoHomeTrash` when that isn't
/// known (it went to the Trash, but couldn't be read first).
public struct RemovedItem: Equatable, Sendable {
    public var path: String
    public var item: ItemSize?
    public var intoHomeTrash: Bool?

    public init(path: String, item: ItemSize?, intoHomeTrash: Bool?) {
        self.path = path
        self.item = item
        self.intoHomeTrash = intoHomeTrash
    }
}

/// The home folder's Trash, and whether a measurement that reached it could read it (only an app with Full
/// Disk Access can): nil until one has tried.
public struct HomeTrash: Equatable, Sendable {
    public var path: String
    public var counted: Bool?

    public init(path: String, counted: Bool?) {
        self.path = path
        self.counted = counted
    }
}

/// The totals of a folder as the walk reports them, one per finished folder.
public struct FolderTotals: Equatable, Sendable {
    public var sizeBytes: Int64
    public var diskBytes: Int64
    public var fileCount: Int
    public var folderCount: Int

    public init(sizeBytes: Int64, diskBytes: Int64, fileCount: Int, folderCount: Int) {
        self.sizeBytes = sizeBytes
        self.diskBytes = diskBytes
        self.fileCount = fileCount
        self.folderCount = folderCount
    }
}

/// Folders a walk finished, each whole: `{"dev":N,"dirs":{...}}` in the original. Folders are in the order
/// they were finished, a folder after the folders inside it.
public struct FinishedFolders: Equatable, Sendable {
    public var dev: Int64?
    public var dirs: [Folder]

    public struct Folder: Equatable, Sendable {
        public var path: String
        public var totals: FolderTotals

        public init(path: String, totals: FolderTotals) {
            self.path = path
            self.totals = totals
        }
    }

    public init(dev: Int64?, dirs: [Folder]) {
        self.dev = dev
        self.dirs = dirs
    }
}

/// What a walk ends with: the root's totals, the disk, and the folders finished and not taken yet.
public struct FolderSizeResult: Equatable, Sendable {
    public var total: Int64
    public var diskTotal: Int64
    public var fileCount: Int
    public var folderCount: Int
    public var dev: Int64?
    public var dirs: [FinishedFolders.Folder]

    public init(
        total: Int64, diskTotal: Int64, fileCount: Int, folderCount: Int, dev: Int64? = nil,
        dirs: [FinishedFolders.Folder] = []
    ) {
        self.total = total
        self.diskTotal = diskTotal
        self.fileCount = fileCount
        self.folderCount = folderCount
        self.dev = dev
        self.dirs = dirs
    }
}

/// A walk that failed or was stopped: the original's Node error with a `code` and a message.
public struct FolderSizeError: Error, Equatable, Sendable, CustomStringConvertible {
    public var code: String?
    public var message: String

    public init(code: String?, message: String) {
        self.code = code
        self.message = message
    }

    public var description: String { message }

    public static let cancelled = FolderSizeError(
        code: "ECANCELLED", message: "Folder size calculation cancelled")
}
