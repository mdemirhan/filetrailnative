// Port of packages/core/src/fs/copyPasteRecovery.ts
import Dispatch
import FTFoundation
import Foundation
import os

public enum ReplaceRecoveryOutcome: Equatable, Sendable {
    /// The Replace had finished, or had been undone: nothing was left behind.
    case nothingLeft
    /// The old item was already in the Trash, so the new one was put in its place.
    case finished(path: String)
    /// A moved item went back where it came from.
    case restored(path: String)
    /// Both places were taken: the item was given a visible name next to the old one.
    case keptVisible(path: String)
    /// An unfinished copy was removed; the original is untouched.
    case removedCopy
    /// The hidden item couldn't be reached (its disk isn't connected, or it can't be read): it may still be
    /// there, so the entry is kept for the next start.
    case unreachable(error: String)
    /// Another operation was writing, so nothing was touched; the entry is tried again later.
    case deferred
    case failed(error: String)

    /// Where the item is now, for the outcomes that put it somewhere.
    public var path: String? {
        switch self {
        case .finished(let path), .restored(let path), .keptVisible(let path): path
        default: nil
        }
    }
}

public struct ReplaceRecovery: Equatable, Sendable {
    public var entry: ReplaceJournalEntry
    public var outcome: ReplaceRecoveryOutcome

    public init(entry: ReplaceJournalEntry, outcome: ReplaceRecoveryOutcome) {
        self.entry = entry
        self.outcome = outcome
    }
}

public enum PartialFileRecoveryOutcome: Equatable, Sendable {
    case nothingLeft, removedCopy, deferred
    case unreachable(error: String)
    case failed(error: String)
}

public struct PartialFileRecovery: Equatable, Sendable {
    public var entry: PartialFileJournalEntry
    public var outcome: PartialFileRecoveryOutcome

    public init(entry: PartialFileJournalEntry, outcome: PartialFileRecoveryOutcome) {
        self.entry = entry
        self.outcome = outcome
    }
}

/// Runs `write` only if nothing else is writing to the disk, holding everything else off until it is done, and
/// returns whether it ran at all.
public typealias RunWriteAlone = @Sendable (_ write: () -> Void) -> Bool

/// How recovery works through its entries: a disk that doesn't answer within `answerWithinMs` is left for later,
/// and, once the app is running, each entry's changes go through `runWriteAlone`.
public struct RecoveryOptions: Sendable {
    /// A network disk that doesn't answer mustn't hold up the start: after this long its entry is left for later,
    /// as for a disk that isn't connected.
    public var answerWithinMs: Int?
    /// Once the app is running, each entry's changes go through it, so they never happen alongside a paste or any
    /// other operation. Whether the disk answers is found out first, outside it: that can take seconds and
    /// changes nothing.
    public var runWriteAlone: RunWriteAlone?

    public init(answerWithinMs: Int? = nil, runWriteAlone: RunWriteAlone? = nil) {
        self.answerWithinMs = answerWithinMs
        self.runWriteAlone = runWriteAlone
    }
}

private let didntAnswer = "The disk didn't answer."

/// Finishes or undoes Replaces that were cut short (a crash, a power cut), so no item stays under the hidden name
/// it was built under. Run once at start, before any paste.
public func recoverInterruptedReplaces(
    _ entries: [ReplaceJournalEntry], _ fileSystem: some WriteServiceFileSystem, _ options: RecoveryOptions = .init()
) -> [ReplaceRecovery] {
    var outcomes: [ReplaceRecovery] = []
    for entry in entries {
        if let ms = options.answerWithinMs, !allAnswerWithin(fileSystem, foldersReadFor(entry), ms) {
            outcomes.append(ReplaceRecovery(entry: entry, outcome: .unreachable(error: didntAnswer)))
            continue
        }
        let outcome = runAlone(options.runWriteAlone) { () -> ReplaceRecoveryOutcome in
            do {
                return try recoverEntry(entry, fileSystem)
            } catch {
                return .failed(error: describeCopyPasteError(error))
            }
        }
        outcomes.append(ReplaceRecovery(entry: entry, outcome: outcome ?? .deferred))
    }
    return outcomes
}

/// Removes the parts of large files a crash cut short (see PartialFileJournalEntry). Each is a hidden file of
/// this app's own naming; anything else found there is left alone.
public func recoverPartialFiles(
    _ entries: [PartialFileJournalEntry], _ fileSystem: some WriteServiceFileSystem,
    _ options: RecoveryOptions = .init()
) -> [PartialFileRecovery] {
    var outcomes: [PartialFileRecovery] = []
    for entry in entries {
        if let ms = options.answerWithinMs, !answersWithin(fileSystem, dirnameOf(entry.partialPath), ms) {
            outcomes.append(PartialFileRecovery(entry: entry, outcome: .unreachable(error: didntAnswer)))
            continue
        }
        let outcome = runAlone(options.runWriteAlone) { () -> PartialFileRecoveryOutcome in
            do {
                return try removePartialFile(entry, fileSystem)
            } catch {
                return .failed(error: describeCopyPasteError(error))
            }
        }
        outcomes.append(PartialFileRecovery(entry: entry, outcome: outcome ?? .deferred))
    }
    return outcomes
}

/// `write`'s value, run through `runWriteAlone` when there is one; nil when it didn't run.
func runAlone<T>(_ runWriteAlone: RunWriteAlone?, _ write: () -> T) -> T? {
    guard let runWriteAlone else { return write() }
    var value: T?
    let ran = runWriteAlone { value = write() }
    return ran ? value : nil
}

private func removePartialFile(_ entry: PartialFileJournalEntry, _ fileSystem: some WriteServiceFileSystem) throws
    -> PartialFileRecoveryOutcome
{
    // Builds after v0.4.3 that were never released copied a large file as "part" inside a hidden folder of its
    // own: that folder goes, with the part.
    let inFolder =
        sameText(basenameOf(entry.partialPath), "part") && isStagingName(basenameOf(dirnameOf(entry.partialPath)))
    let path = inFolder ? dirnameOf(entry.partialPath) : entry.partialPath
    do {
        _ = try fileSystem.lstat(path)
    } catch {
        if errorCode(error) == "ENOENT" && folderIsThere(fileSystem, path) {
            return .nothingLeft
        }
        return .unreachable(error: describeCopyPasteError(error))
    }
    // Only what this app names its partial files (see isStagingName).
    if !isStagingName(basenameOf(path)) {
        return .nothingLeft
    }
    // A copy is locked, or carries a rule against deleting it, as its original does: those go on as it is
    // finished, and come off for it to be removed.
    try removeStagedItem(fileSystem, path)
    return .removedCopy
}

/// The hidden name this app builds an item under: "."+name+".filetrail-" and 8 hex digits
/// (`/^\..*\.filetrail-[0-9a-f]{8}$/su`).
func isStagingName(_ name: String) -> Bool {
    let scalars = Array(name.unicodeScalars)
    let tag = Array(".filetrail-".unicodeScalars)
    // ".", at least nothing, ".filetrail-", 8 hex digits.
    guard scalars.count >= 1 + tag.count + 8, scalars[0] == "." else { return false }
    let hex = scalars[(scalars.count - 8)...]
    guard hex.allSatisfy({ ("0"..."9").contains($0) || ("a"..."f").contains($0) }) else { return false }
    let tagStart = scalars.count - 8 - tag.count
    return tagStart >= 1 && Array(scalars[tagStart..<(scalars.count - 8)]) == tag
}

/// Every folder recovering `entry` looks in: the hidden item's, its final place's, and for a moved item its
/// original's (on another disk, maybe), which may not answer either.
private func foldersReadFor(_ entry: ReplaceJournalEntry) -> [String] {
    var folders = [dirnameOf(entry.stagingPath), dirnameOf(entry.finalPath)]
    // Only a moved item may go back where it came from; a copy never looks there.
    if entry.moved {
        folders.append(dirnameOf(entry.sourcePath))
    }
    var seen = Set<NameKeys.Exact>()
    return folders.filter { seen.insert(NameKeys.Exact($0)).inserted }
}

/// Whether looking up each of `paths` comes back within `ms`, all looked up at once.
private func allAnswerWithin(_ fileSystem: some WriteServiceFileSystem, _ paths: [String], _ ms: Int) -> Bool {
    let deadline = DispatchTime.now() + .milliseconds(ms)
    let lookups = paths.map { lookUp(fileSystem, $0) }
    return lookups.allSatisfy { $0.wait(timeout: deadline) == .success }
}

/// Whether looking up `path` comes back (found or not) within `ms`.
public func answersWithin(_ fileSystem: some IdentityFileSystem, _ path: String, _ ms: Int) -> Bool {
    lookUp(fileSystem, path).wait(timeout: .now() + .milliseconds(ms)) == .success
}

/// Looks `path` up on a thread of its own: one that hangs (a network disk) is left hanging, never waited for
/// past the time given, and holds none of the threads the rest of the app's work runs on (a busy shared pool
/// would make a disk that answers at once look as if it didn't). The semaphore is signalled once it comes back.
private func lookUp(_ fileSystem: some IdentityFileSystem, _ path: String) -> DispatchSemaphore {
    let answered = DispatchSemaphore(value: 0)
    let thread = Thread {
        _ = try? fileSystem.lstat(path)
        answered.signal()
    }
    thread.name = "FileTrail disk lookup"
    thread.start()
    return answered
}

private func recoverEntry(_ entry: ReplaceJournalEntry, _ fileSystem: some WriteServiceFileSystem) throws
    -> ReplaceRecoveryOutcome
{
    // Only an item that is really gone counts as gone. A disk that isn't connected, or a folder that can't be
    // read, hides an item that may be the only copy of someone's data.
    let isDirectory: Bool
    do {
        isDirectory = try fileSystem.lstat(entry.stagingPath).isDirectory
    } catch {
        if errorCode(error) == "ENOENT" && folderIsThere(fileSystem, entry.stagingPath) {
            return .nothingLeft
        }
        return .unreachable(error: describeCopyPasteError(error))
    }
    // The hidden name was made for this Replace alone (see isStagingName): what is there is its.
    if !isStagingName(basenameOf(entry.stagingPath)) {
        return .nothingLeft
    }
    let finalTaken = captureFingerprint(fileSystem, entry.finalPath).exists
    if entry.moved {
        // The staged item is the only copy of what was moved: it is never removed.
        if !finalTaken {
            try moveUnlocked(fileSystem, entry.stagingPath, entry.finalPath)
            return .finished(path: entry.finalPath)
        }
        if !captureFingerprint(fileSystem, entry.sourcePath).exists {
            try moveUnlocked(fileSystem, entry.stagingPath, entry.sourcePath)
            return .restored(path: entry.sourcePath)
        }
        let visiblePath = try resolveDuplicateName(
            basenameOf(entry.finalPath), in: dirnameOf(entry.finalPath), fileSystem,
            options: .init(
                isDirectory: isDirectory,
                // The staged item's hidden name has no package extension: its source tells.
                isPackage: isDirectory && isPackageFolder(fileSystem, entry.sourcePath)))
        try moveUnlocked(fileSystem, entry.stagingPath, visiblePath)
        return .keptVisible(path: visiblePath)
    }
    // A copy: the original is still in place. Only a complete copy whose old item already went to the Trash is
    // worth keeping. A folder put in place here goes without its own tags and dates, which it would have had once
    // named (see metadataLaterFor).
    if entry.staged && !finalTaken {
        try moveUnlocked(fileSystem, entry.stagingPath, entry.finalPath)
        return .finished(path: entry.finalPath)
    }
    try removeStagedItem(fileSystem, entry.stagingPath)
    return .removedCopy
}

private func folderIsThere(_ fileSystem: some IdentityFileSystem, _ path: String) -> Bool {
    (try? fileSystem.lstat(dirnameOf(path)).isDirectory) ?? false
}

/// A copy of a locked item is locked, and a locked item can't be renamed: unlocked for the move and locked again
/// after.
private func moveUnlocked(_ fileSystem: some WriteServiceFileSystem, _ from: String, _ to: String) throws {
    let flags = try unlockForMove(fileSystem, from)
    do {
        try moveExclusive(fileSystem, from, to)
    } catch {
        if let flags {
            try? fileSystem.setFlags(from, flags)
        }
        throw error
    }
    if let flags {
        try? fileSystem.setFlags(to, flags)
    }
}
