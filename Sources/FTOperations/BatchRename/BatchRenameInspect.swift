// Port of apps/desktop/src/main/bootstrap/batchRenameInspect.ts and createOriginalBatchRenameInspectDeps
// (apps/desktop/src/main/originalFileSystem.ts)
import Darwin
import FTFileSystem
import FTFoundation
import Foundation

/// What the Rename sheet asks about the items it renames (`batchRename:inspect`).
public struct BatchRenameInspectRequest: Equatable, Sendable {
    public var paths: [String]
    /// Whether to read when each photo was taken: only the date settings that use it ask.
    public var includeDateTaken: Bool

    public init(paths: [String], includeDateTaken: Bool) {
        self.paths = paths
        self.includeDateTaken = includeDateTaken
    }
}

/// The items' dates, whether each can be renamed, and every name in their folders.
public struct BatchRenameInspection: Equatable, Sendable {
    public struct Item: Equatable, Sendable {
        public var path: String
        public var createdAt: LocalDateTime?
        public var modifiedAt: LocalDateTime?
        public var takenAt: LocalDateTime?
        /// Why it can't be renamed, as a sentence; nil when it can.
        public var cannotRename: String?

        public init(
            path: String, createdAt: LocalDateTime?, modifiedAt: LocalDateTime?, takenAt: LocalDateTime?,
            cannotRename: String?
        ) {
            self.path = path
            self.createdAt = createdAt
            self.modifiedAt = modifiedAt
            self.takenAt = takenAt
            self.cannotRename = cannotRename
        }
    }

    public struct Folder: Equatable, Sendable {
        public var path: String
        /// Every name in it, hidden ones included; none when it can't be read.
        public var names: [String]
        public var caseSensitive: Bool

        public init(path: String, names: [String], caseSensitive: Bool) {
            self.path = path
            self.names = names
            self.caseSensitive = caseSensitive
        }
    }

    public var items: [Item]
    public var folders: [Folder]

    public init(items: [Item], folders: [Folder]) {
        self.items = items
        self.folders = folders
    }
}

/// What the Rename sheet's checks need of the file system and the native module (`BatchRenameInspectDeps`). Each
/// disk call blocks; `inspect` makes them off the caller's thread.
public struct BatchRenameInspectDeps: Sendable {
    public var lstat: @Sendable (String) throws -> WriteServiceStats
    public var readdir: @Sendable (String) throws -> [String]
    /// Whether names in the folder differ by case; nil when the disk doesn't say.
    public var isCaseSensitive: @Sendable (String) throws -> Bool?
    public var getFlags: (@Sendable (String) throws -> UInt32)?
    /// Whether items in the folder can be renamed: it can be written to.
    public var canWriteFolder: @Sendable (String) throws -> Bool
    /// When each photo was taken, from its own metadata, on this Mac's clock.
    public var readDatesTaken: @Sendable ([String]) async throws -> [String?]
    /// Refuses the folders that are never renamed (the startup disk, the home folder…).
    public var assertRenamable: @Sendable (String) throws -> Void
    public var homePath: String

    public init(
        lstat: @escaping @Sendable (String) throws -> WriteServiceStats,
        readdir: @escaping @Sendable (String) throws -> [String],
        isCaseSensitive: @escaping @Sendable (String) throws -> Bool?,
        getFlags: (@Sendable (String) throws -> UInt32)?,
        canWriteFolder: @escaping @Sendable (String) throws -> Bool,
        readDatesTaken: @escaping @Sendable ([String]) async throws -> [String?],
        assertRenamable: @escaping @Sendable (String) throws -> Void, homePath: String
    ) {
        self.lstat = lstat
        self.readdir = readdir
        self.isCaseSensitive = isCaseSensitive
        self.getFlags = getFlags
        self.canWriteFolder = canWriteFolder
        self.readDatesTaken = readDatesTaken
        self.assertRenamable = assertRenamable
        self.homePath = homePath
    }

    /// `createOriginalBatchRenameInspectDeps`: the disk itself. The app refuses the same folders as for a rename of
    /// one (`assertNotSystemLocation`).
    public static func native(homePath: String, assertRenamable: @escaping @Sendable (String) throws -> Void)
        -> BatchRenameInspectDeps
    {
        let disk = NativeWriteFileSystem()
        return BatchRenameInspectDeps(
            lstat: { try disk.lstat($0) }, readdir: { try disk.readdir($0) },
            isCaseSensitive: { try disk.isCaseSensitive($0) }, getFlags: { try disk.getFlags($0) },
            canWriteFolder: { access($0, W_OK) == 0 }, readDatesTaken: { await DatesTaken.read($0) },
            assertRenamable: assertRenamable, homePath: homePath)
    }

    /// The app's own: the disk, refusing what the write coordinator refuses to rename.
    public static func native(homePath: String) -> BatchRenameInspectDeps {
        let disk = NativeWriteFileSystem()
        return native(homePath: homePath) { path in
            try WriteGuards.assertNotSystemLocation([path], verb: "renamed", fileSystem: disk, homePath: homePath)
        }
    }
}

public enum BatchRenameInspect {
    /// `inspectBatchRename`: the items' dates, whether each can be renamed, and every name in their folders.
    public static func inspect(_ request: BatchRenameInspectRequest, _ deps: BatchRenameInspectDeps) async
        -> BatchRenameInspection
    {
        let paths = request.paths.map(NodePath.resolve)
        let datesTaken: [String?]
        if request.includeDateTaken {
            datesTaken = (try? await deps.readDatesTaken(paths)) ?? paths.map { _ in nil }
        } else {
            datesTaken = paths.map { _ in nil }
        }
        return await LocalOperations.onDisk { inspectOnDisk(paths, datesTaken, deps) }
    }

    private struct FolderLook {
        var folder: BatchRenameInspection.Folder
        var writable: Bool
        var locked: Bool
    }

    private static func inspectOnDisk(_ paths: [String], _ datesTaken: [String?], _ deps: BatchRenameInspectDeps)
        -> BatchRenameInspection
    {
        var seen = Set<NameKeys.Exact>()
        let folderPaths = paths.map(NodePath.dirname).filter { seen.insert(NameKeys.Exact($0)).inserted }
        let trashPath = lowercased(NodePath.resolve(NodePath.join(deps.homePath, ".Trash")))
        let folders = folderPaths.map { path in
            FolderLook(
                folder: .init(
                    path: path, names: (try? deps.readdir(path)) ?? [],
                    caseSensitive: ((try? deps.isCaseSensitive(path)) ?? nil) == true),
                writable: (try? deps.canWriteFolder(path)) ?? false, locked: isLocked(deps.getFlags, path))
        }
        var folderByPath: [NameKeys.Exact: FolderLook] = [:]
        for folder in folders {
            folderByPath[NameKeys.Exact(folder.folder.path)] = folder
        }
        let items = paths.enumerated().map { index, path -> BatchRenameInspection.Item in
            let stats = try? deps.lstat(path)
            let folder = folderByPath[NameKeys.Exact(NodePath.dirname(path))]
            var cannotRename: String?
            if stats == nil {
                cannotRename = "\u{201C}\(NodePath.basename(path))\u{201D} no longer exists."
            } else if lowercased(path).unicodeScalars.elementsEqual(trashPath.unicodeScalars) {
                cannotRename = "The Trash can\u{2019}t be renamed."
            } else if folder?.locked == true {
                cannotRename = lockedMessage(NodePath.dirname(path))
            } else if let folder, !folder.writable {
                cannotRename =
                    "You don\u{2019}t have permission to rename items in \u{201C}\(NodePath.basename(NodePath.dirname(path)))\u{201D}."
            } else if isLocked(deps.getFlags, path) {
                cannotRename = lockedMessage(path)
            } else {
                do {
                    try deps.assertRenamable(path)
                } catch {
                    cannotRename = errorMessage(error)
                }
            }
            let taken = index < datesTaken.count ? datesTaken[index] : nil
            return BatchRenameInspection.Item(
                path: path, createdAt: stats.flatMap { localDateTimeOrNil($0.birthtimeMs) },
                modifiedAt: stats.flatMap { localDateTimeOrNil($0.mtimeMs) },
                takenAt: taken.flatMap { isLocalDateTime($0) ? $0 : nil }, cannotRename: cannotRename)
        }
        return BatchRenameInspection(items: items, folders: folders.map(\.folder))
    }

    /// `localDateTimeOrNull`: a date the disk doesn't really have (no birth time on some disks) is left out.
    static func localDateTimeOrNil(_ milliseconds: Double?) -> LocalDateTime? {
        guard let milliseconds, milliseconds.isFinite, milliseconds > 0 else { return nil }
        // A JavaScript Date keeps whole milliseconds.
        let local = BatchRename.toLocalDateTime(Date(timeIntervalSince1970: milliseconds.rounded(.down) / 1000))
        return isLocalDateTime(local) ? local : nil
    }

    /// `LOCAL_DATE_TIME`: `/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}$/u`.
    static func isLocalDateTime(_ text: String) -> Bool {
        let scalars = Array(text.unicodeScalars)
        guard scalars.count == 19 else { return false }
        for (index, scalar) in scalars.enumerated() {
            switch index {
            case 4, 7: if scalar != "-" { return false }
            case 10: if scalar != "T" { return false }
            case 13, 16: if scalar != ":" { return false }
            default: if !("0"..."9").contains(scalar) { return false }
            }
        }
        return true
    }

    private static func lowercased(_ text: String) -> String {
        text.lowercased(with: nil)
    }
}
