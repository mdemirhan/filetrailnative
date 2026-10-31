// Port of AskedItem, canBeToldApart, looksTheSame, lstatOrNull, readItemSize, lstatUnlessMissing, isSameItem,
// hasFileId, describeWriteError and describeTrashError (apps/desktop/src/main/bootstrap/writeOperations.ts)
import FTFileSystem
import FTFoundation
import Foundation

/// An item a no-Trash question was about (`AskedItem`): its id, or how it looked when it has none.
struct AskedItem: Equatable, Sendable {
    var id: ItemId?
    var stamp: ItemStamp?

    /// `canBeToldApart`: whether the item asked about can be told from another one put at its path: by its id, or
    /// with none, by everything `looksTheSame` compares being known.
    var canBeToldApart: Bool {
        if id != nil { return true }
        guard let stamp else { return false }
        return LocalOperations.looksTheSame(stamp, stamp)
    }
}

/// What lstat says of a path (`lstatUnlessMissing`): nothing there, or something that couldn't be read.
enum LstatLook: Sendable {
    case missing
    case unreadable
    case found(WriteServiceStats)
}

/// What `readItemSize` says of a path: gone, unreadable, or the item as a measurement counts it.
enum ItemSizeLook: Sendable {
    case missing
    case unreadable
    case size(ItemSize)
}

enum LocalOperations {
    /// `looksTheSame`: without an id, an item is taken for the one asked about only when everything known about it
    /// is the same and known: its kind, its date, a file's size, a folder's item count (a folder's date changes
    /// whenever an item in it is added, removed or renamed).
    static func looksTheSame(_ asked: ItemStamp, _ now: ItemStamp) -> Bool {
        guard asked.kind == now.kind, let mtimeMs = asked.mtimeMs, mtimeMs == now.mtimeMs else { return false }
        if asked.kind == .directory {
            guard let count = asked.entryCount else { return false }
            return count == now.entryCount
        }
        return asked.size == now.size
    }

    /// `lstatOrNull`.
    static func lstatOrNull(_ fileSystem: some IdentityFileSystem, _ path: String) -> WriteServiceStats? {
        try? fileSystem.lstat(path)
    }

    /// `lstatUnlessMissing`: true only when the item is certainly gone; any other trouble reading it is left for the
    /// operation itself to report.
    static func lstatUnlessMissing(_ fileSystem: some IdentityFileSystem, _ path: String) -> LstatLook {
        do {
            return .found(try fileSystem.lstat(path))
        } catch {
            return errorCode(error) == "ENOENT" ? .missing : .unreadable
        }
    }

    /// `readItemSize`: nil when the disk can't tell (the file system has no `itemSize`).
    static func readItemSize(_ itemSize: ((String) throws -> ItemSize)?, _ path: String) -> ItemSizeLook? {
        guard let itemSize else { return nil }
        do {
            return .size(try itemSize(path))
        } catch {
            return errorCode(error) == "ENOENT" ? .missing : .unreadable
        }
    }

    /// `isSameItem`.
    static func isSameItem(_ left: WriteServiceStats, _ right: WriteServiceStats) -> Bool {
        left.dev != nil && hasFileId(left) && left.dev == right.dev && left.ino == right.ino
    }

    /// `hasFileId`: FAT and exFAT give empty files ids too large to compare (see `fileIdOf`).
    static func hasFileId(_ stats: WriteServiceStats) -> Bool {
        fileIdOf(stats.ino) != nil
    }

    /// `describeWriteError`: a plain sentence for a failed rename, new folder, or the checks before them. Where the
    /// error is about a particular item, it is named.
    static func describeWriteError(_ error: any Error, missing: String? = nil, existing: String? = nil) -> String {
        let code = errorCode(error)
        if code == "ENOENT", let missing, !missing.isEmpty {
            return "\u{201C}\(missing)\u{201D} no longer exists."
        }
        if code == "EEXIST", let existing, !existing.isEmpty {
            return "An item named \u{201C}\(existing)\u{201D} already exists."
        }
        return describeCopyPasteError(error)
    }

    /// `describeTrashError`: the Trash gives its reasons as sentences (see `TrashItem`). On a disk with no Trash the
    /// window then offers to delete the item immediately, as Finder does.
    static func describeTrashError(_ error: any Error, _ path: String) -> String {
        let name = NodePath.basename(path)
        if errorCode(error) == CopyPasteErrors.noTrashErrorCode {
            return "\u{201C}\(name)\u{201D} couldn\u{2019}t be moved to the Trash because its disk has no Trash."
        }
        let described = describeCopyPasteError(error)
        return described.isEmpty ? "\u{201C}\(name)\u{201D} couldn\u{2019}t be moved to the Trash." : described
    }

    /// Disk work, off the main actor, as the original's main process awaits its fs calls. It runs on a queue of its
    /// own rather than in Swift's shared pool: a call can block for long (the Trash, a large folder deleted, a disk
    /// that stops answering), and blocked pool threads would hold up every other task.
    static func onDisk<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try work() })
            }
        }
    }

    static func onDisk<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: work())
            }
        }
    }
}
