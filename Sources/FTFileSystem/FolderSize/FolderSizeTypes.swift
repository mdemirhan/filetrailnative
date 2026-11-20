import CFileTrail
import Foundation

/// What a size leaves out, and why, as the walk found while it measured: empty when it is complete. Kept with each
/// size; nothing shows it yet. *No access* is kept apart because it is ordinary (the home folder, without Full Disk
/// Access, holds app containers no walk may read), where the others are not.
public struct FolderSizePartial: OptionSet, Hashable, Sendable {
    public let rawValue: Int32

    public init(rawValue: Int32) {
        self.rawValue = rawValue
    }

    /// Something inside changed while it was walked: a sub-folder gone, renamed, or replaced by a file or a link.
    public static let changed = FolderSizePartial(rawValue: FT_PARTIAL_CHANGED)
    /// A sub-folder it has no permission to read, counted as an empty folder.
    public static let noAccess = FolderSizePartial(rawValue: FT_PARTIAL_NO_ACCESS)
    /// A listing that broke part way, or a sub-folder that couldn't be opened for another reason.
    public static let readError = FolderSizePartial(rawValue: FT_PARTIAL_READ_ERROR)

    public var isComplete: Bool { isEmpty }
}

/// A path as a dictionary key: compared and hashed by its exact UTF-8.
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

/// Where the app's writes landed under a folder while it was being walked, kept so that each folder the walk
/// finishes is looked up without going through the changes: the folders holding a change, and the changes themselves.
struct ChangesUnderWalk {
    private var changed = Set<PathKey>()
    private var holders = Set<PathKey>()
    // The folders whose holders are all in `holders` already.
    private var looked = Set<PathKey>()

    mutating func add(_ paths: [String]) {
        for path in paths where changed.insert(PathKey(path)).inserted {
            FolderSizeCache.forEachHolder(of: path, looked: &looked) { holders.insert(PathKey($0)) }
        }
    }

    /// Whether `folder` holds a change, is one, or is inside one (as `WriteEffects.isAffectedByChange`): its size
    /// may have seen part of the change.
    func affect(_ folder: String) -> Bool {
        let key = PathKey(folder)
        if holders.contains(key) || changed.contains(key) { return true }
        var inside = false
        var none = Set<PathKey>()
        FolderSizeCache.forEachHolder(of: folder, looked: &none) { holder in
            if !inside, changed.contains(PathKey(holder)) { inside = true }
        }
        return inside
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
    /// What the measurement left out of it.
    public var partial: FolderSizePartial

    public init(
        sizeBytes: Int64, diskBytes: Int64, fileCount: Int, folderCount: Int, dev: Int64?, measurement: Int,
        partial: FolderSizePartial = []
    ) {
        self.sizeBytes = sizeBytes
        self.diskBytes = diskBytes
        self.fileCount = fileCount
        self.folderCount = folderCount
        self.dev = dev
        self.measurement = measurement
        self.partial = partial
    }
}

/// One item as a measurement counts it inside its folder: a file or symlink by its
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
    /// What the walk left out of it.
    public var partial: FolderSizePartial

    public init(
        sizeBytes: Int64, diskBytes: Int64, fileCount: Int, folderCount: Int, partial: FolderSizePartial = []
    ) {
        self.sizeBytes = sizeBytes
        self.diskBytes = diskBytes
        self.fileCount = fileCount
        self.folderCount = folderCount
        self.partial = partial
    }
}

/// Folders a walk finished, each whole. Folders are in the order
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
    /// What the walk left out of the folder.
    public var partial: FolderSizePartial

    public init(
        total: Int64, diskTotal: Int64, fileCount: Int, folderCount: Int, dev: Int64? = nil,
        dirs: [FinishedFolders.Folder] = [], partial: FolderSizePartial = []
    ) {
        self.total = total
        self.diskTotal = diskTotal
        self.fileCount = fileCount
        self.folderCount = folderCount
        self.dev = dev
        self.dirs = dirs
        self.partial = partial
    }
}

/// A walk that failed or was stopped: the errno when there was one (ECANCELED for a stop), and a message.
public struct FolderSizeError: Error, Equatable, Sendable, CustomStringConvertible {
    public var errnum: Int32?
    public var message: String
    /// The folder measured was moved away, removed or replaced while it was walked: what was measured inside it is
    /// no longer at its path.
    public var rootChanged = false

    public init(errnum: Int32?, message: String) {
        self.errnum = errnum
        self.message = message
    }

    public var description: String { message }

    public static let cancelled = FolderSizeError(errnum: ECANCELED, message: "Folder size calculation cancelled")
}
