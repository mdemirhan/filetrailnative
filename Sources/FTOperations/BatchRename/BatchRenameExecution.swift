// Port of apps/desktop/src/main/bootstrap/batchRenameExecution.ts (and of the request useBatchRename makes of a plan,
// apps/desktop/src/renderer/hooks/useBatchRename.ts)
import FTFoundation
import Foundation

/// What a rename of several items asks for (`writeOperation:batchRename`): each item's new name, in its own folder,
/// and what to do with a name found taken while renaming.
public struct BatchRenameRequest: Equatable, Sendable {
    public struct Item: Equatable, Sendable {
        public var sourcePath: String
        public var destinationName: String
        /// Says where a number goes when the name is taken: at the end of a folder's name, before a file's (or a
        /// package's) extension.
        public var isFolder: Bool

        public init(sourcePath: String, destinationName: String, isFolder: Bool) {
            self.sourcePath = sourcePath
            self.destinationName = destinationName
            self.isFolder = isFolder
        }
    }

    public var items: [Item]
    public var onConflict: BatchRenameOnConflict
    /// " ", "-" or "_": what goes before a number added to a name found taken.
    public var numberSeparator: String

    public init(items: [Item], onConflict: BatchRenameOnConflict = .number, numberSeparator: String = " ") {
        self.items = items
        self.onConflict = onConflict
        self.numberSeparator = numberSeparator
    }
}

/// What renaming several items needs of the file system (`BatchRenameFs`). The calls a disk may not have are nil.
public protocol BatchRenameFileSystem: Sendable {
    func lstat(_ path: String) throws -> WriteServiceStats
    /// rename(2) that fails with EEXIST rather than replace anything.
    func renameExclusive(_ from: String, _ to: String) throws
    /// rename(2): only for a name that changes nothing but its case on a disk that ignores case.
    func rename(_ from: String, _ to: String) throws
    /// Every name in a folder.
    var readFolder: ((String) throws -> [String])? { get }
    /// The item's BSD flags, to tell a locked item.
    var readFlags: ((String) throws -> UInt32)? { get }
    /// Whether the folder's disk tells names apart by case; nil when it doesn't say.
    var caseSensitivity: ((String) throws -> Bool?)? { get }
}

/// The local operations' file system as a batch rename uses it.
public struct LocalBatchRenameFileSystem: BatchRenameFileSystem {
    public let disk: any LocalWriteFileSystem

    public init(_ disk: any LocalWriteFileSystem) {
        self.disk = disk
    }

    public func lstat(_ path: String) throws -> WriteServiceStats { try disk.lstat(path) }
    public func renameExclusive(_ from: String, _ to: String) throws { try disk.renameExclusive(from, to) }
    public func rename(_ from: String, _ to: String) throws { try disk.rename(from, to) }
    public var readFolder: ((String) throws -> [String])? { { [disk] in try disk.readdir($0) } }
    public var readFlags: ((String) throws -> UInt32)? { { [disk] in try disk.getFlags($0) } }
    public var caseSensitivity: ((String) throws -> Bool?)? { { [disk] in try disk.isCaseSensitive($0) } }
}

/// What a batch rename did (`BatchRenameRun`): every item has a result, in the order asked for.
public struct BatchRenameRun: Equatable, Sendable {
    public var items: [WriteOperationItem]
    public var completedItemCount: Int
    public var cancelled: Bool

    public init(items: [WriteOperationItem], completedItemCount: Int, cancelled: Bool) {
        self.items = items
        self.completedItemCount = completedItemCount
        self.cancelled = cancelled
    }
}

/// Where the items a crash left under hidden names went (`BatchRenameRecovery`).
public struct BatchRenameRecovery: Equatable, Sendable {
    public struct Restored: Equatable, Sendable {
        public var originalPath: String
        public var path: String

        public init(originalPath: String, path: String) {
            self.originalPath = originalPath
            self.path = path
        }
    }

    /// Each item found under its hidden name, and where it is now.
    public var restored: [Restored] = []
    /// What stays written down: its disk can't be read, or the item couldn't be moved.
    public var remaining: [BatchRenameJournalEntry.Item] = []

    public init(restored: [Restored] = [], remaining: [BatchRenameJournalEntry.Item] = []) {
        self.restored = restored
        self.remaining = remaining
    }
}

public enum BatchRenameExecution {
    /// A name taken during the rename gets the first free number up to this; past it, it fails.
    public static let maxAddedNumber = 10_000

    /// Told as each item starts: where it is, where it goes, and how many are done. A throw is ignored.
    public typealias ItemStart = (_ sourcePath: String, _ destinationPath: String, _ completed: Int) throws -> Void

    private struct PlannedItem {
        var index: Int
        var sourcePath: String
        var folder: String
        var sourceName: String
        var destinationName: String
        var destinationPath: String
        var isFolder: Bool
        /// Where the item waits while another item takes its name (a swap or a chain).
        var temporaryPath: String?
    }

    /// `runBatchRename`: renames items to the names asked for, each in its own folder, one after another.
    ///
    /// Items may swap names or pass them along ("File 2" to "File 1" while "File 1" becomes "File 2"): an item whose
    /// name another item wants is first moved to a hidden temporary name in its folder, and takes its new name after
    /// the others. Every rename refuses to replace what is already there (renamex_np with RENAME_EXCL); a name found
    /// taken is handled as `onConflict` says: a number added, the item left as it is, or a failure. Whatever happens,
    /// no item is left under a temporary name if it can be helped: an item that can't take its new name is put back
    /// under its old one. Blocks on the disk: call it off the main thread.
    public static func run(
        _ request: BatchRenameRequest, fileSystem: some BatchRenameFileSystem, signal: StopSignal,
        onItemStart: ItemStart? = nil, temporaryName: (() -> String)? = nil, journal: (any WriteJournal)? = nil
    ) -> BatchRenameRun {
        let makeTemporaryName = temporaryName ?? defaultTemporaryName
        var planned = request.items.enumerated().map { index, item -> PlannedItem in
            let sourcePath = NodePath.resolve(item.sourcePath)
            let folder = NodePath.dirname(sourcePath)
            let destinationName = InlineRenameRules.trimmedName(item.destinationName)
            return PlannedItem(
                index: index, sourcePath: sourcePath, folder: folder, sourceName: NodePath.basename(sourcePath),
                destinationName: destinationName, destinationPath: NodePath.join(folder, destinationName),
                isFolder: item.isFolder, temporaryPath: nil)
        }
        var results: [WriteOperationItem?] = Array(repeating: nil, count: planned.count)
        var completedItemCount = 0
        // Whether each folder's disk tells names apart by case, asked once per folder.
        var caseSensitivity: [NameKeys.Exact: Bool?] = [:]
        let isCaseSensitive = { (folder: String) -> Bool? in
            if let known = caseSensitivity[NameKeys.Exact(folder)] {
                return known
            }
            let answer = fileSystem.caseSensitivity.flatMap { ask in try? ask(folder) }
            caseSensitivity[NameKeys.Exact(folder)] = .some(answer)
            return answer
        }
        // The folders that hold other items of the batch: only their renames take paths along.
        var holdsItems = Set<NameKeys.Exact>()
        for item in planned {
            var folder = item.folder
            while holdsItems.insert(NameKeys.Exact(folder)).inserted {
                folder = NodePath.dirname(folder)
            }
        }
        func followRenamed(_ item: PlannedItem) {
            if holdsItems.contains(NameKeys.Exact(item.sourcePath)) {
                followFolderRename(&results, from: item.sourcePath, to: results[item.index]?.destinationPath)
            }
        }
        var cancelled = false

        // Items another item wants the name of. Names are compared as a disk that ignores case would: on one that
        // doesn't, an item moved aside for nothing only costs a rename.
        var wantedNames: [NameKeys.Exact: [Int]] = [:]
        for item in planned {
            wantedNames[wantKey(item.folder, item.destinationName), default: []].append(item.index)
        }
        let isBlocker = { (item: PlannedItem) -> Bool in
            (wantedNames[wantKey(item.folder, item.sourceName)] ?? []).contains { $0 != item.index }
        }

        // A folder and items inside it may be renamed together (search results reach into folders): the deepest
        // items go first, so every path still leads where it did when it is used, and a folder is renamed once what
        // is inside it is done. Items in one folder are at one depth, so names are swapped and passed along within a
        // level.
        var levels: [Int: [Int]] = [:]
        for item in planned {
            let depth = item.sourcePath.unicodeScalars.filter { $0 == "/" }.count + 1
            levels[depth, default: []].append(item.index)
        }
        let deepestFirst = levels.keys.sorted(by: >).map { levels[$0] ?? [] }

        // Items still under hidden names once their depth was done, as written down: the folder holding one isn't
        // renamed, so the next start finds it where it is written down.
        var stillWritten: [BatchRenameJournalEntry] = []
        func holdsHiddenItem(_ folder: String) -> Bool {
            stillWritten.contains { entry in
                entry.items.contains { startsWith($0.temporaryPath, folder + "/") }
            }
        }
        for allOfLevel in deepestFirst {
            // A folder holding an item still under a hidden name keeps its name (and isn't moved aside), so the next
            // start finds the item where it is written down.
            var level: [Int] = []
            for index in allOfLevel {
                let item = planned[index]
                if holdsHiddenItem(item.sourcePath) {
                    results[index] = failed(
                        item,
                        "\u{201C}\(item.sourceName)\u{201D} wasn't renamed because an item in it is still under a hidden name."
                    )
                } else {
                    level.append(index)
                }
            }
            // The hidden names the items in the way will wait under, written down before any moves.
            let blockers = level.filter { isBlocker(planned[$0]) }.map { index in
                (index: index, temporaryPath: NodePath.join(planned[index].folder, makeTemporaryName()))
            }
            var entry = BatchRenameJournalEntry(
                id: randomHex(bytes: 8),
                items: blockers.map {
                    .init(
                        temporaryPath: $0.temporaryPath, originalPath: planned[$0.index].sourcePath,
                        newPath: planned[$0.index].destinationPath)
                })
            if let journal, !blockers.isEmpty {
                do {
                    try journal.add(.batchRename(entry))
                } catch {
                    // Nothing of this depth is renamed: an item moved aside now could be stranded.
                    for index in level where results[index] == nil {
                        results[index] = failed(
                            planned[index], "It wasn't renamed. \(describeCopyPasteError(error))")
                    }
                    continue
                }
            }

            // First, the items in the way move aside. Only when all of them have can the swaps go on after a stop;
            // stopped before, every item goes back as it was.
            var allMovedAside = true
            for blocker in blockers {
                if signal.isStopped {
                    cancelled = true
                    allMovedAside = false
                    break
                }
                let item = planned[blocker.index]
                do {
                    // Never onto anything: a hidden name found taken fails the item like any other error.
                    try fileSystem.renameExclusive(item.sourcePath, blocker.temporaryPath)
                    planned[blocker.index].temporaryPath = blocker.temporaryPath
                } catch {
                    // Still under its name: an item waiting for it can't finish a swap after a stop.
                    allMovedAside = false
                    results[blocker.index] = failed(
                        item, describeRenameError(fileSystem, error, item, from: item.sourcePath))
                }
            }

            // Then every item takes its new name, in the order asked for. Stopped before any of this depth has, they
            // all go back as they were; stopped later, an item already moved aside still takes its new name, so a
            // swap under way is finished rather than left with a name taken from it.
            var levelRenamed = false
            for index in level {
                if results[index] != nil {
                    continue
                }
                let item = planned[index]
                let finishesSwap = allMovedAside && levelRenamed && item.temporaryPath != nil
                if (cancelled || signal.isStopped) && !finishesSwap {
                    cancelled = true
                    results[index] = leaveUnrenamed(
                        fileSystem, item, status: .cancelled, error: "Not started because the operation was stopped.",
                        skipReason: nil)
                    followRenamed(item)
                    continue
                }
                // Saying how far it got must never stop it halfway, with items under hidden names.
                try? onItemStart?(item.sourcePath, item.destinationPath, completedItemCount)
                let result = renameItem(fileSystem, item, request, isCaseSensitive)
                results[index] = result
                if result.status == .completed {
                    completedItemCount += 1
                    levelRenamed = true
                }
                // Renamed, or put back under another name ("sub 2"): what is inside goes along.
                followRenamed(item)
                if signal.isStopped {
                    cancelled = true
                }
            }
            // Every item of this depth is settled. One that could go nowhere else is still under its hidden name (its
            // result says so): it stays written down, for the next start.
            if let journal, !blockers.isEmpty {
                var stillHidden = Set<NameKeys.Exact>()
                for index in level {
                    if let at = results[index]?.destinationPath, let waited = planned[index].temporaryPath,
                        sameText(at, waited)
                    {
                        stillHidden.insert(NameKeys.Exact(at))
                    }
                }
                entry.items = entry.items.filter { stillHidden.contains(NameKeys.Exact($0.temporaryPath)) }
                if entry.items.isEmpty {
                    try? journal.remove(entry.id)
                } else {
                    try? journal.add(.batchRename(entry))
                    stillWritten.append(entry)
                }
            }
        }

        // Every item has its result by now: the loops above give one to each.
        let items = results.compactMap { $0 }
        // A stop that came as the last item finished stopped nothing.
        return BatchRenameRun(
            items: items, completedItemCount: completedItemCount,
            cancelled: cancelled && items.contains { $0.status == .cancelled })
    }

    /// `followFolderRename`: a folder that just changed its name (renamed, or put back under another) takes along
    /// the items inside it, which were all settled before it: their paths say where they are now, under the folder's
    /// new name, renamed or not.
    private static func followFolderRename(_ results: inout [WriteOperationItem?], from: String, to: String?) {
        guard let to, !sameText(to, from) else { return }
        let prefix = from + "/"
        for index in results.indices {
            // Only what was inside this very item: another item may have its old name by now, with items of its own
            // under it. Only this item has moved them since they were settled, and a folder's items stay in it, so
            // their paths still start where it was.
            guard let result = results[index], let sourcePath = result.sourcePath else { continue }
            let at = result.destinationPath ?? sourcePath
            if startsWith(sourcePath, prefix) && startsWith(at, prefix) {
                let rest = String(String.UnicodeScalarView(at.unicodeScalars.dropFirst(prefix.unicodeScalars.count)))
                results[index]?.destinationPath = to + "/" + rest
            }
        }
    }

    private static func renameItem(
        _ fileSystem: some BatchRenameFileSystem, _ item: PlannedItem, _ request: BatchRenameRequest,
        _ isCaseSensitive: (String) -> Bool?
    ) -> WriteOperationItem {
        let from = item.temporaryPath ?? item.sourcePath
        if item.temporaryPath == nil && renamesItself(fileSystem, item, isCaseSensitive) {
            // "notes" to "Notes" on a disk that ignores case: the new name is the item's own.
            do {
                try fileSystem.rename(item.sourcePath, item.destinationPath)
                return completed(item, item.destinationPath)
            } catch {
                return failed(item, describeRenameError(fileSystem, error, item, from: from))
            }
        }
        var destinationPath = item.destinationPath
        var number = 2
        while true {
            do {
                try fileSystem.renameExclusive(from, destinationPath)
                return completed(item, destinationPath)
            } catch {
                let taken = errorCode(error) == "EEXIST"
                if taken && request.onConflict == .number && number <= maxAddedNumber {
                    destinationPath = NodePath.join(
                        item.folder,
                        numberedName(
                            item.destinationName, isFolder: item.isFolder, separator: request.numberSeparator,
                            number: number))
                    number += 1
                    continue
                }
                if taken && request.onConflict == .skip {
                    return leaveUnrenamed(
                        fileSystem, item, status: .skipped,
                        error: "An item named \u{201C}\(NodePath.basename(destinationPath))\u{201D} already exists.",
                        skipReason: .runtimeConflictResolution)
                }
                return leaveUnrenamed(
                    fileSystem, item, status: .failed,
                    error: describeRenameError(
                        fileSystem, error, item, from: from, takenName: NodePath.basename(destinationPath)),
                    skipReason: nil)
            }
        }
    }

    /// `leaveUnrenamed`: an item that won't take its new name. If it was moved aside, it goes back under its old one.
    /// When another item has taken that meanwhile, it gets the old name with a number ("b 2"), and only if even that
    /// fails is it left under the hidden name, and said so.
    private static func leaveUnrenamed(
        _ fileSystem: some BatchRenameFileSystem, _ item: PlannedItem, status: CopyPasteItemResult.Status,
        error: String, skipReason: CopyPasteItemResult.SkipReason?
    ) -> WriteOperationItem {
        if let temporaryPath = item.temporaryPath {
            let restoredPath = restoreFromTemporaryName(fileSystem, item, temporaryPath)
            if !sameText(restoredPath, item.sourcePath) {
                let hidden = sameText(restoredPath, temporaryPath) ? " (hidden)" : ""
                return WriteOperationItem(
                    sourcePath: item.sourcePath, destinationPath: restoredPath,
                    status: status == .skipped ? .failed : status,
                    error:
                        "\(error) Another item has its old name now, so it is named \u{201C}\(NodePath.basename(restoredPath))\u{201D}\(hidden)."
                )
            }
        }
        return WriteOperationItem(
            sourcePath: item.sourcePath, destinationPath: nil, status: status, error: error, skipReason: skipReason)
    }

    /// `restoreFromTemporaryName`: where an item moved aside ends up: its old path, else its old name with the first
    /// free number, else (nothing else could be done) the temporary path it is still at.
    private static func restoreFromTemporaryName(
        _ fileSystem: some BatchRenameFileSystem, _ item: PlannedItem, _ temporaryPath: String
    ) -> String {
        var candidate = item.sourcePath
        var number = 2
        while true {
            do {
                try fileSystem.renameExclusive(temporaryPath, candidate)
                return candidate
            } catch {
                if errorCode(error) != "EEXIST" || number > maxAddedNumber {
                    return temporaryPath
                }
                candidate = NodePath.join(
                    item.folder, numberedName(item.sourceName, isFolder: item.isFolder, separator: " ", number: number))
                number += 1
            }
        }
    }

    /// `renamesItself`: whether the new name is the item's own name spelled differently: only its case (or how an
    /// accented letter is encoded) changes, and the disk finds the item itself under it, not another item spelled
    /// exactly so.
    private static func renamesItself(
        _ fileSystem: some BatchRenameFileSystem, _ item: PlannedItem, _ isCaseSensitive: (String) -> Bool?
    ) -> Bool {
        guard sameText(NameKeys.looseKey(item.sourceName), NameKeys.looseKey(item.destinationName)) else {
            return false
        }
        guard let source = try? fileSystem.lstat(item.sourcePath),
            let destination = try? fileSystem.lstat(item.destinationPath)
        else { return false }
        let sameItem =
            source.dev != nil && fileIdOf(source.ino) != nil && source.dev == destination.dev
            && source.ino == destination.ino
        let idsUnusable = fileIdOf(source.ino) == nil || fileIdOf(destination.ino) == nil
        if !sameItem && !idsUnusable {
            return false
        }
        // Only the case changes, on a disk that ignores case: no other item can be spelled so. Elsewhere, or when how
        // an accent is encoded changes too, the folder says.
        let onlyCaseChanges =
            !sameText(item.sourceName, item.destinationName)
            && sameText(lowercased(item.sourceName), lowercased(item.destinationName))
        if onlyCaseChanges && isCaseSensitive(item.folder) == false {
            return true
        }
        let entries = fileSystem.readFolder.flatMap { read in try? read(item.folder) }
        return !(entries?.contains { sameText($0, item.destinationName) } ?? false)
    }

    /// `numberedName`: "Lisbon 2.jpg": the number before the extension, or at the end of a folder's name.
    public static func numberedName(_ name: String, isFolder: Bool, separator: String, number: Int) -> String {
        NumberedNames.addNumberToName(name, isFolder: isFolder, separator: separator, number: number).name
    }

    private static func completed(_ item: PlannedItem, _ destinationPath: String) -> WriteOperationItem {
        WriteOperationItem(sourcePath: item.sourcePath, destinationPath: destinationPath, status: .completed)
    }

    /// An item that couldn't be renamed and is still where it was: it has no new path.
    private static func failed(_ item: PlannedItem, _ error: String) -> WriteOperationItem {
        WriteOperationItem(sourcePath: item.sourcePath, destinationPath: nil, status: .failed, error: error)
    }

    private static func describeRenameError(
        _ fileSystem: some BatchRenameFileSystem, _ error: any Error, _ item: PlannedItem, from: String,
        takenName: String? = nil
    ) -> String {
        let code = errorCode(error)
        if code == "ENOENT" && sameText(from, item.sourcePath) {
            return "\u{201C}\(item.sourceName)\u{201D} no longer exists."
        }
        if code == "EEXIST" {
            return "An item named \u{201C}\(takenName ?? item.destinationName)\u{201D} already exists."
        }
        return findLockedRefusal(fileSystem.readFlags, error, [from, item.folder])?.message
            ?? describeCopyPasteError(error)
    }

    /// `toLowerCase()` (names never hold a NUL, which Foundation's version stops at).
    private static func lowercased(_ text: String) -> String {
        text.lowercased(with: nil)
    }

    /// The key of a name wanted in a folder: the folder, and the name as a disk that ignores case and accent
    /// encoding takes it (`looseKey`).
    private static func wantKey(_ folder: String, _ name: String) -> NameKeys.Exact {
        NameKeys.Exact("\(folder)\0\(NameKeys.looseKey(name))")
    }

    /// `defaultTemporaryName`.
    static func defaultTemporaryName() -> String {
        ".filetrail-rename-\(randomHex(bytes: 6))"
    }

    /// `randomBytes(count).toString("hex")`.
    static func randomHex(bytes count: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<count).map { _ in
            let byte = UInt8.random(in: 0...255, using: &generator)
            return String(byte, radix: 16).leftPadded(to: 2)
        }.joined()
    }

    // MARK: Undo

    /// `movedItemsOf`: what a batch rename moved, for Undo: each item that is somewhere else than it was, and still
    /// there. That is every item renamed, and an item that couldn't take its new name and was left under another name
    /// than its own ("b 2", or the hidden name it waited under). An item that kept its name (skipped, or failed) but
    /// is elsewhere only because its folder was renamed isn't one: undoing the folder's rename takes it back.
    public static func movedItemsOf(_ fileSystem: some BatchRenameFileSystem, _ items: [WriteOperationItem])
        -> [BatchRenamedItem]
    {
        var moved: [BatchRenamedItem] = []
        for item in items {
            guard let sourcePath = item.sourcePath, let destinationPath = item.destinationPath,
                !sameText(destinationPath, sourcePath),
                !sameText(NodePath.basename(destinationPath), NodePath.basename(sourcePath))
            else { continue }
            let now = readItemRef({ try fileSystem.lstat($0) }, destinationPath)
            if let kind = now.kind {
                moved.append(BatchRenamedItem(from: sourcePath, to: destinationPath, id: now.id, itemKind: kind))
            }
        }
        return moved
    }

    // MARK: Recovery

    /// `TEMPORARY_NAME_PATTERN`: the hidden names a rename of several gives items (`/^\.filetrail-rename-[0-9a-f]{12}$/u`).
    static func isTemporaryName(_ name: String) -> Bool {
        let prefix = ".filetrail-rename-"
        guard startsWith(name, prefix) else { return false }
        let hex = name.unicodeScalars.dropFirst(prefix.unicodeScalars.count)
        return hex.count == 12 && hex.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    /// `recoverBatchRename`: puts back the items a crash left under hidden names in a rename of several: under the
    /// old name when it is free, else the new one asked for, else the old one with a number. Never replaces
    /// anything, and moves only what has this app's hidden naming.
    public static func recover(_ entry: BatchRenameJournalEntry, _ fileSystem: some BatchRenameFileSystem)
        -> BatchRenameRecovery
    {
        var recovery = BatchRenameRecovery()
        for written in entry.items {
            if !isTemporaryName(NodePath.basename(written.temporaryPath)) {
                continue
            }
            let isFolder: Bool
            do {
                isFolder = try fileSystem.lstat(written.temporaryPath).isDirectory
            } catch {
                // Gone: it took its name before the crash. Unreadable: its disk may be away.
                let folderThere = (try? fileSystem.lstat(NodePath.dirname(written.temporaryPath)).isDirectory) ?? false
                if errorCode(error) != "ENOENT" || !folderThere {
                    recovery.remaining.append(written)
                }
                continue
            }
            // `placesToPutBack`: its old name, its new one, then its old one numbered.
            var path: String?
            var candidates = [written.originalPath, written.newPath].makeIterator()
            var number = 1
            while true {
                let candidate: String
                if let next = candidates.next() {
                    candidate = next
                } else {
                    number += 1
                    if number > maxAddedNumber { break }
                    candidate = NodePath.join(
                        NodePath.dirname(written.originalPath),
                        numberedName(
                            NodePath.basename(written.originalPath), isFolder: isFolder, separator: " ", number: number
                        ))
                }
                do {
                    try fileSystem.renameExclusive(written.temporaryPath, candidate)
                    path = candidate
                    break
                } catch {
                    if errorCode(error) != "EEXIST" {
                        break
                    }
                }
            }
            if let path {
                recovery.restored.append(.init(originalPath: written.originalPath, path: path))
            } else {
                recovery.remaining.append(written)
            }
        }
        return recovery
    }
}

extension String {
    fileprivate func leftPadded(to length: Int) -> String {
        count >= length ? self : String(repeating: "0", count: length - count) + self
    }
}

extension UndoBatchRename {
    /// `runBatchRename` as a batch undo runs it: a taken name numbered with a space, on the Undo's file system.
    public static let runBatchRename: UndoBatchRenamer = { items, fileSystem, signal, journal in
        let request = BatchRenameRequest(
            items: items.map {
                .init(sourcePath: $0.sourcePath, destinationName: $0.destinationName, isFolder: $0.isFolder)
            },
            onConflict: .number, numberSeparator: " ")
        let run = BatchRenameExecution.run(
            request, fileSystem: LocalBatchRenameFileSystem(fileSystem), signal: signal, journal: journal)
        return UndoBatchRenameRun(items: run.items, cancelled: run.cancelled)
    }
}

extension BatchRenameRequest {
    /// What to ask for once the plan can be carried out (the `request` of `useBatchRename`): each item the plan
    /// renames, with its planned name, and the number separator the settings give (Format's, or a space). Nil when
    /// the plan can't be carried out: its settings are broken, an item must be fixed first, or nothing is renamed.
    public init?(plan: BatchRenamePlan, items: [BatchRenameItem], settings: BatchRenameSettings) {
        guard plan.settingsError == nil, plan.blockingCount == 0, plan.renameCount > 0 else { return nil }
        var renamed: [Item] = []
        for (index, planItem) in plan.items.enumerated() where index < items.count {
            if case .rename(let name, _, _, _, _, _) = planItem {
                renamed.append(
                    Item(sourcePath: items[index].path, destinationName: name, isFolder: items[index].isFolder))
            }
        }
        let separator = settings.mode == .format ? settings.separator : .space
        self.init(
            items: renamed, onConflict: settings.onConflict,
            numberSeparator: separator == .hyphen || separator == .underscore ? separator.rawValue : " ")
    }
}
