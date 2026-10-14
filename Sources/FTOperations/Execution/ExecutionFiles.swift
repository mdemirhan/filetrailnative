// Port of copyFileContents, writeIntoHiddenFolder, writeFileContents and the hidden-name helpers (temporarySiblingPath,
// reserveStagingFolder, recordIncomplete, removeOwnStaging, removeStagedItem, unlockForMove, openForMove,
// restoreAfterMove) of packages/core/src/fs/copyPasteExecution.ts
import Darwin
import FTFoundation
import Foundation

/// Files at least this large are written down in the journal while they are copied.
public let journaledFileBytes: Int64 = 32 * 1024 * 1024

/// `randomBytes(count).toString("hex")`.
func randomHex(bytes count: Int) -> String {
    var generator = SystemRandomNumberGenerator()
    return (0..<count).map { _ in
        let byte = UInt8.random(in: 0...255, using: &generator)
        let hex = String(byte, radix: 16)
        return hex.count == 1 ? "0" + hex : hex
    }.joined()
}

/// A file is written under a hidden name next to its place, and takes its name only once it is complete:
/// quitting, a crash or a disk that stops answering part way never leaves a cut-short file under the real name,
/// where it would pass for the whole one.
func copyFileContents(
    _ context: ExecutionContext, _ sourcePath: String, _ targetPath: String,
    onProgress: (@Sendable (Int64) -> Void)? = nil
) throws {
    let fileSystem = context.fileSystem
    if context.folderMadeAt != nil {
        try writeIntoHiddenFolder(context, sourcePath, targetPath, onProgress)
        return
    }
    if captureFingerprint(fileSystem, targetPath).exists {
        throw DestinationTakenError(
            original: NativeError(message: "EEXIST: \(targetPath)", code: "EEXIST", path: targetPath))
    }
    let partialPath = try temporarySiblingPath(fileSystem, targetPath)
    // A large file is written down first: cut short by a crash, the part copied would take up space under a
    // hidden name, unseen, until the next start removes it. Small ones aren't, for speed (two writes to the
    // journal for each file), nor is one inside a folder built under a hidden name: that folder's own record
    // covers it.
    let journal = context.folderMadeAt == nil ? context.writeJournal : nil
    let journalId: String? =
        journal != nil && ((try? fileSystem.lstat(sourcePath))?.size ?? 0) >= journaledFileBytes
        ? randomHex(bytes: 8) : nil
    if let journal, let journalId {
        try journal.add(
            .partialFile(PartialFileJournalEntry(id: journalId, partialPath: partialPath, finalPath: targetPath)))
    }
    defer {
        // Complete under its name, or cleared away: nothing is left to recover. A part that couldn't be cleared
        // away (its disk went away) stays written down for the next start.
        if let journal, let journalId, isGone(fileSystem, partialPath) {
            try? journal.remove(journalId)
        }
    }
    try writeFileContents(context, sourcePath, partialPath, onProgress)
    do {
        // A copy of a locked file is locked too, and a locked file can't be renamed.
        let flags = try unlockForMove(fileSystem, partialPath)
        try moveExclusive(fileSystem, partialPath, targetPath)
        if let flags {
            try? fileSystem.setFlags(targetPath, flags)
        }
    } catch {
        try? removeStagedItem(fileSystem, partialPath)
        throw errorCode(error) == "EEXIST"
            ? DestinationTakenError(original: error) : explainMissingFolder(fileSystem, targetPath, error)
    }
}

/// Inside a folder built under a hidden name, a file is written straight under its name: the folder is put in
/// place only once complete, and a crash or Stop takes it away whole. A file that failed is cleared away; should
/// any of it stay (the disk refused, or can't say), the folder isn't put in place either, or the cut-short file
/// would pass for the whole one.
private func writeIntoHiddenFolder(
    _ context: ExecutionContext, _ sourcePath: String, _ targetPath: String,
    _ onProgress: (@Sendable (Int64) -> Void)?
) throws {
    do {
        try writeFileContents(context, sourcePath, targetPath, onProgress)
    } catch {
        if rootError(error) is DestinationTakenError || isAbortError(error) || context.signal.isStopped {
            throw error
        }
        let fileSystem = context.fileSystem
        if !isGone(fileSystem, targetPath) {
            try? removeStagedItem(fileSystem, targetPath)
            if !isGone(fileSystem, targetPath) {
                throw StagingCleanupError(original: error)
            }
        }
        throw error
    }
}

/// Whether nothing is at `path` for certain: not merely unreadable, and not on a disk gone away (its folder is
/// still there).
func isGone(_ fileSystem: some IdentityFileSystem, _ path: String) -> Bool {
    do {
        _ = try fileSystem.lstat(path)
        return false
    } catch {
        if errorCode(error) != "ENOENT" {
            return false
        }
    }
    return (try? fileSystem.lstat(NodePath.dirname(path)).isDirectory) ?? false
}

private func writeFileContents(
    _ context: ExecutionContext, _ sourcePath: String, _ targetPath: String,
    _ onProgress: (@Sendable (Int64) -> Void)?
) throws {
    let fileSystem = context.fileSystem
    let before = captureFingerprint(fileSystem, targetPath)
    do {
        try fileSystem.copyFile(sourcePath, targetPath, stop: context.signal, onProgress: onProgress)
    } catch {
        let code = errorCode(error)
        if code == "EEXIST" {
            throw DestinationTakenError(original: error)
        }
        if code == "ENOENT" {
            throw explainMissingFolder(fileSystem, targetPath, error)
        }
        if code == "ENOTSUP" || code == "EOPNOTSUPP", let source = try? fileSystem.lstat(sourcePath),
            source.type == .other
        {
            throw OperationError(
                "\u{201C}\(NodePath.basename(sourcePath))\u{201D} is a special file (such as a pipe or a socket), which can't be copied."
            )
        }
        // Leave no half-written file behind, but only one this copy created: an item that was already there, or
        // something other than a file, belongs to someone else.
        if !before.exists {
            let after = captureFingerprint(fileSystem, targetPath)
            if after.exists && after.kind == .file {
                try? fileSystem.rm(targetPath, recursive: false, force: true)
            }
        }
        throw error
    }
}

/// A hidden name next to `finalPath` for building an item under, within the volume's name length limit.
func temporarySiblingPath(_ fileSystem: some IdentityFileSystem, _ finalPath: String) throws -> String {
    for _ in 0..<10 {
        let tag = ".filetrail-\(randomHex(bytes: 4))"
        let candidate = NodePath.join(
            NodePath.dirname(finalPath),
            CopyPasteNames.fitName(".\(NodePath.basename(finalPath))", suffix: tag, extension: ""))
        if !captureFingerprint(fileSystem, candidate).exists {
            return candidate
        }
    }
    throw OperationError(
        "Couldn't find a free temporary name next to \u{201C}\(NodePath.basename(finalPath))\u{201D}.")
}

/// A folder made under a hidden name next to `finalPath` for an item to be built in: made exclusively (a name
/// found taken is passed over), so what is at that name is this paste's.
func reserveStagingFolder(_ fileSystem: some WriteServiceFileSystem, _ finalPath: String) throws -> String {
    for _ in 0..<10 {
        let path = try temporarySiblingPath(fileSystem, finalPath)
        do {
            try fileSystem.mkdir(path)
            return path
        } catch {
            if errorCode(error) != "EEXIST" {
                throw explainMissingFolder(fileSystem, path, error)
            }
        }
    }
    throw OperationError(
        "Couldn't find a free temporary name next to \u{201C}\(NodePath.basename(finalPath))\u{201D}.")
}

/// A hidden copy written down as complete is put in place at the next start: before any of it is removed, its
/// record says it isn't, or a removal stopped part way (a disk error) would have what is left of it put in place
/// as if whole. False when that can't be written down: the copy is then left whole, for the next start to put in
/// place.
func recordIncomplete(_ journal: (any WriteJournal)?, _ entry: ReplaceJournalEntry, _ recordedComplete: Bool) -> Bool {
    guard recordedComplete, let journal else { return true }
    var incomplete = entry
    incomplete.staged = false
    do {
        try journal.add(.replace(incomplete))
        return true
    } catch {
        return false
    }
}

/// Removes what a paste built under a hidden name; nothing when it is gone already.
func removeOwnStaging(_ fileSystem: some WriteServiceFileSystem, _ path: String) throws {
    if isGone(fileSystem, path) {
        return
    }
    // Read for certain (an error here is thrown: the record of it then stays). Removing with `force` would take a
    // disk gone away for an item removed.
    _ = try fileSystem.lstat(path)
    try removeStagedItem(fileSystem, path)
}

/// Removes a hidden copy. A read-only folder inside it can't have its items removed, so folders are opened up
/// first when that is what stopped it.
public func removeStagedItem(_ fileSystem: some WriteServiceFileSystem, _ path: String) throws {
    do {
        try fileSystem.rm(path, recursive: true, force: true)
        return
    } catch {
        let code = errorCode(error)
        if code != "EACCES" && code != "EPERM" {
            throw error
        }
    }
    makeFoldersWritable(fileSystem, path)
    try fileSystem.rm(path, recursive: true, force: true)
}

/// Opens up a hidden copy so it can be removed: locked items (a copy of a locked item is locked too) are unlocked,
/// rules against deleting them (a copy of ~/Documents has one) taken off, and read-only folders made writable.
private func makeFoldersWritable(_ fileSystem: some WriteServiceFileSystem, _ path: String) {
    let flags = (try? fileSystem.getFlags(path)) ?? 0
    if flags & CopyPasteErrors.userLockFlags != 0 {
        try? fileSystem.setFlags(path, flags & ~CopyPasteErrors.userLockFlags)
    }
    try? fileSystem.setAcl?(path, nil)
    guard captureFingerprint(fileSystem, path).kind == .directory else { return }
    try? fileSystem.chmod?(path, 0o700)
    for entry in (try? fileSystem.readdir(path)) ?? [] {
        makeFoldersWritable(fileSystem, NodePath.join(path, entry))
    }
}

/// Clears the lock (Finder's "Locked") on an item about to be renamed, and returns the flags to put back once it
/// has its new name; nil when it wasn't locked. An item locked in a way its owner can't undo is refused here,
/// before anything else changes.
public func unlockForMove(_ fileSystem: some WriteServiceFileSystem, _ path: String) throws -> UInt32? {
    let flags = (try? fileSystem.getFlags(path)) ?? 0
    if flags & CopyPasteErrors.lockFlags == 0 {
        return nil
    }
    if flags & CopyPasteErrors.lockFlags & ~CopyPasteErrors.userLockFlags != 0 {
        throw OperationError(lockedMessage(path))
    }
    try fileSystem.setFlags(path, flags & ~CopyPasteErrors.userLockFlags)
    return flags
}

/// A folder that can't be written to can't always be renamed: macOS 14 refuses it. The hidden copy of a
/// read-only folder is made writable for the move, and given its mode back by restoreAfterMove.
func openForMove(_ fileSystem: some WriteServiceFileSystem, _ path: String) throws -> UInt32? {
    guard let chmod = fileSystem.chmod else { return nil }
    let fingerprint = captureFingerprint(fileSystem, path)
    guard fingerprint.kind == .directory, let fullMode = fingerprint.mode else { return nil }
    let mode = fullMode & 0o7777
    if mode & 0o200 != 0 {
        return nil
    }
    try chmod(path, mode | 0o200)
    return mode
}

/// Puts back what openForMove and unlockForMove took off, the mode before the lock (a locked item can't have its
/// mode changed).
func restoreAfterMove(_ fileSystem: some WriteServiceFileSystem, _ path: String, _ mode: UInt32?, _ flags: UInt32?) {
    if let mode {
        try? fileSystem.chmod?(path, mode)
    }
    if let flags {
        try? fileSystem.setFlags(path, flags)
    }
}

func rebaseResolvedNode(_ node: ResolvedCopyPasteNode, _ fromPath: String, _ toPath: String)
    -> ResolvedCopyPasteNode
{
    let destinationPath = rebasePath(node.destinationPath, fromPath, toPath)
    var rebased = node
    rebased.destinationPath = destinationPath
    rebased.node.destinationPath = destinationPath
    rebased.node.disposition = .new
    rebased.node.conflictClass = nil
    rebased.node.destinationKind = .missing
    rebased.node.destinationFingerprint = .missing
    rebased.children = node.children.map { rebaseResolvedNode($0, fromPath, toPath) }
    return rebased
}

func rebaseItemResults(_ items: [CopyPasteItemResult], _ fromPath: String, _ toPath: String)
    -> [CopyPasteItemResult]
{
    items.map { item in
        var rebased = item
        rebased.destinationPath = rebasePath(item.destinationPath, fromPath, toPath)
        return rebased
    }
}

/// `path` under `toPath` instead of `fromPath`, compared byte for byte (scalar for scalar, as `===` and
/// `startsWith` compare): a folder of 100,000 items has each of their paths rebased.
func rebasePath(_ path: String, _ fromPath: String, _ toPath: String) -> String {
    let bytes = path.utf8
    let from = fromPath.utf8
    if bytes.elementsEqual(from) {
        return toPath
    }
    guard bytes.count > from.count, bytes.starts(with: from),
        bytes[bytes.index(bytes.startIndex, offsetBy: from.count)] == UInt8(ascii: "/")
    else { return path }
    return toPath + String(decoding: bytes.dropFirst(from.count), as: UTF8.self)
}
