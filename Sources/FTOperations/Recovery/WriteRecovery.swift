// Port of recoverWrites, putBackRenamedItems, describePutBack, removePartialFiles, recoverReplaces, diskName,
// retryRecovery and RECOVERY_RETRY_INTERVAL_MS (apps/desktop/src/main/bootstrap/writeJournal.ts)
import FTFoundation
import Foundation
import os

/// What the journal recovery reads and writes: the entries kept, and taking one out or putting it back.
public protocol RecoverableWriteJournal: WriteJournal {
    func entries() -> [WriteJournalEntry]
}

extension FileWriteJournal: RecoverableWriteJournal {}

public struct RecoveryReport: Equatable, Sendable {
    /// What the person must know: items left under a hidden name, or waiting for their disk.
    public var notices: [String] = []
    /// Items that waited for their disk and are in place now.
    public var finished: [String] = []

    public init(notices: [String] = [], finished: [String] = []) {
        self.notices = notices
        self.finished = finished
    }
}

/// Where recovery says what it did (the app's log): a line, and its details.
public struct RecoveryLogger: Sendable {
    public var info: @Sendable (_ message: String, _ details: [String: String]) -> Void
    public var error: @Sendable (_ message: String, _ error: String) -> Void

    public init(
        info: @escaping @Sendable (String, [String: String]) -> Void,
        error: @escaping @Sendable (String, String) -> Void
    ) {
        self.info = info
        self.error = error
    }

    /// The app's own log.
    public static let system: RecoveryLogger = {
        let log = Logger(subsystem: "app.filetrail", category: "recovery")
        return RecoveryLogger(
            info: { message, details in
                let said = details.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
                log.info("\(message, privacy: .public) \(said, privacy: .private)")
            },
            error: { message, error in
                log.error("\(message, privacy: .public): \(error, privacy: .private)")
            })
    }()
}

/// What a recovery that put things in place, back, or took them away forgets: folder listings and sizes read
/// before (a retry runs while the app is in use) are out of date there. The app passes the listings cache
/// (`ResponseCache.clear`) and the folder sizes (`FolderSizeWrites.forget`); either may be called on any thread.
public struct RecoveryCaches: Sendable {
    public var clearListings: @Sendable () -> Void
    public var forgetSizes: @Sendable (_ changedPaths: [String]) -> Void

    public init(
        clearListings: @escaping @Sendable () -> Void, forgetSizes: @escaping @Sendable ([String]) -> Void
    ) {
        self.clearListings = clearListings
        self.forgetSizes = forgetSizes
    }

    public static let none = RecoveryCaches(clearListings: {}, forgetSizes: { _ in })

    /// `clearResponseCaches(changedPaths)`.
    func clear(_ changedPaths: [String]) {
        clearListings()
        if !changedPaths.isEmpty {
            forgetSizes(changedPaths)
        }
    }
}

/// How long a disk has to answer at start, and on every retry.
public let recoveryAnswerWithinMs = 3_000

/// Finishes or undoes what an earlier run left half done. Entries that couldn't be dealt with stay for later
/// (see `RecoveryRetry`). Never throws: nothing here may keep the app from starting. `entryIds` limits it to those
/// entries (a retry of what was left at start, never a Replace running now). A retry passes `runWriteAlone`, so
/// its changes never happen alongside an operation the person started.
public func recoverWrites(
    _ journal: some RecoverableWriteJournal, _ fileSystem: some WriteServiceFileSystem, logger: RecoveryLogger,
    caches: RecoveryCaches = .none, entryIds: Set<String>? = nil, answerWithinMs: Int? = nil, retry: Bool = false,
    runWriteAlone: RunWriteAlone? = nil
) -> RecoveryReport {
    var report = RecoveryReport()
    let entries = journal.entries().filter { entryIds == nil || entryIds?.contains($0.id) == true }
    var replaces: [ReplaceJournalEntry] = []
    var partialFiles: [PartialFileJournalEntry] = []
    var batchRenames: [BatchRenameJournalEntry] = []
    for entry in entries {
        switch entry {
        case .replace(let replace): replaces.append(replace)
        case .partialFile(let partial): partialFiles.append(partial)
        case .batchRename(let batchRename): batchRenames.append(batchRename)
        }
    }
    let options = RecoveryOptions(answerWithinMs: answerWithinMs, runWriteAlone: runWriteAlone)
    // Parts of large files first: one inside a folder a paste was building (v0.4.3 wrote those down too) goes
    // with it, and would then look like one on a disk that isn't connected.
    if !partialFiles.isEmpty {
        removePartialFiles(journal, partialFiles, fileSystem, logger, caches, options)
    }
    if !replaces.isEmpty {
        recoverReplaces(journal, replaces, fileSystem, logger, caches, options, retry: retry, &report)
    }
    for entry in batchRenames {
        putBackRenamedItems(journal, entry, fileSystem, logger, caches, options, &report)
    }
    return report
}

/// A rename of several a crash cut short: the items waiting under hidden names are put back, and the person is told
/// where. What can't be reached yet waits for the retry.
private func putBackRenamedItems(
    _ journal: some RecoverableWriteJournal, _ entry: BatchRenameJournalEntry,
    _ fileSystem: some WriteServiceFileSystem, _ logger: RecoveryLogger, _ caches: RecoveryCaches,
    _ options: RecoveryOptions, _ report: inout RecoveryReport
) {
    // Items renamed from search results can be in several folders, on several disks: each must answer, or the whole
    // entry waits, so nothing is put back while a look at a later folder still hangs (and the start with it).
    if let ms = options.answerWithinMs {
        var seen = Set<NameKeys.Exact>()
        let folders = entry.items.map { dirnameOf($0.temporaryPath) }.filter {
            seen.insert(NameKeys.Exact($0)).inserted
        }
        let deadline = DispatchTime.now() + .milliseconds(ms)
        let lookups = folders.map { folder in
            let answered = DispatchSemaphore(value: 0)
            let thread = Thread {
                _ = try? fileSystem.lstat(folder)
                answered.signal()
            }
            thread.name = "FileTrail disk lookup"
            thread.start()
            return answered
        }
        if !lookups.allSatisfy({ $0.wait(timeout: deadline) == .success }) {
            return
        }
    }
    let disk = RecoveryBatchRenameFileSystem(disk: fileSystem)
    guard let recovery = runAlone(options.runWriteAlone, { BatchRenameExecution.recover(entry, disk) }) else {
        return
    }
    if !recovery.restored.isEmpty {
        caches.clear(recovery.restored.map(\.path))
        report.notices.append(describePutBack(recovery.restored))
    }
    do {
        if recovery.remaining.isEmpty {
            try journal.remove(entry.id)
        } else {
            try journal.add(.batchRename(BatchRenameJournalEntry(id: entry.id, items: recovery.remaining)))
        }
    } catch {
        logger.error("[filetrail] couldn't update the write journal", describeCopyPasteError(error))
    }
}

/// `describePutBack`: "A rename of several items was cut short when File Trail stopped. “a.txt” is back under its
/// old name; “b.txt” is named “c.txt”."
func describePutBack(_ restored: [BatchRenameRecovery.Restored]) -> String {
    let said = restored.prefix(3).map { item in
        sameText(item.path, item.originalPath)
            ? "\u{201C}\(basenameOf(item.originalPath))\u{201D} is back under its old name"
            : "\u{201C}\(basenameOf(item.originalPath))\u{201D} is named \u{201C}\(basenameOf(item.path))\u{201D}"
    }
    let more = restored.count - said.count
    let rest = more > 0 ? "; and \(more) more \(more == 1 ? "item was" : "items were") put back" : ""
    return "A rename of several items was cut short when File Trail stopped. \(said.joined(separator: "; "))\(rest)."
}

/// What putting back a rename of several needs of the recovery's file system: looking items up and exclusive renames.
private struct RecoveryBatchRenameFileSystem<Disk: WriteServiceFileSystem>: BatchRenameFileSystem {
    let disk: Disk

    func lstat(_ path: String) throws -> WriteServiceStats { try disk.lstat(path) }
    func renameExclusive(_ from: String, _ to: String) throws { try disk.renameExclusive(from, to) }
    func rename(_ from: String, _ to: String) throws { try disk.renameExclusive(from, to) }
    var readFolder: ((String) throws -> [String])? { nil }
    var readFlags: ((String) throws -> UInt32)? { nil }
    var caseSensitivity: ((String) throws -> Bool?)? { nil }
}

/// What a crash left of large files being copied: only part of a copy, its original in place. Removed quietly;
/// one that can't be reached yet waits for the retry.
private func removePartialFiles(
    _ journal: some RecoverableWriteJournal, _ entries: [PartialFileJournalEntry],
    _ fileSystem: some WriteServiceFileSystem, _ logger: RecoveryLogger, _ caches: RecoveryCaches,
    _ options: RecoveryOptions
) {
    let outcomes = recoverPartialFiles(entries, fileSystem, options)
    let removed = outcomes.filter { $0.outcome == .removedCopy }
    if !removed.isEmpty {
        caches.clear(removed.map(\.entry.partialPath))
    }
    for outcome in outcomes {
        switch outcome.outcome {
        case .unreachable(let error), .failed(let error):
            logger.info(
                "[filetrail] an interrupted copy wasn't removed",
                ["partialPath": outcome.entry.partialPath, "error": error])
            continue
        case .deferred:
            continue
        case .nothingLeft, .removedCopy:
            break
        }
        do {
            try journal.remove(outcome.entry.id)
        } catch {
            logger.error("[filetrail] couldn't update the write journal", describeCopyPasteError(error))
        }
    }
}

/// Replaces a crash cut short: finished or undone, and what the person must know is said.
private func recoverReplaces(
    _ journal: some RecoverableWriteJournal, _ entries: [ReplaceJournalEntry],
    _ fileSystem: some WriteServiceFileSystem, _ logger: RecoveryLogger, _ caches: RecoveryCaches,
    _ options: RecoveryOptions, retry: Bool, _ report: inout RecoveryReport
) {
    let outcomes = recoverInterruptedReplaces(entries, fileSystem, options)
    // Where items were put in place, back, or taken away: folder listings and sizes read before (a retry runs
    // while the app is in use) are out of date there.
    var changedPaths: [String] = []
    for outcome in outcomes {
        if let path = outcome.outcome.path {
            changedPaths += [outcome.entry.stagingPath, path]
        } else if outcome.outcome == .removedCopy {
            changedPaths.append(outcome.entry.stagingPath)
        }
    }
    if !changedPaths.isEmpty {
        caches.clear(changedPaths)
    }
    for outcome in outcomes {
        let entry = outcome.entry
        let name = basenameOf(entry.finalPath)
        switch outcome.outcome {
        case .failed(let error):
            logger.error(
                "[filetrail] couldn't recover an interrupted replace", "\(entry.stagingPath): \(error)")
            if !retry {
                report.notices.append(
                    "\u{201C}\(name)\u{201D} is still under the hidden name \u{201C}\(basenameOf(entry.stagingPath))\u{201D} in \u{201C}\(dirnameOf(entry.stagingPath))\u{201D}. \(error)"
                )
            }
            continue
        case .deferred:
            // An operation was running; the entry stays for the next try.
            continue
        case .unreachable(let error):
            logger.info(
                "[filetrail] an interrupted replace can't be reached",
                ["stagingPath": entry.stagingPath, "error": error])
            // A moved item there is the only copy of what was moved, kept under a hidden name: the person is told
            // once, at start, where to find it. An unfinished copy is only a copy (its original is in place) and
            // is cleared up quietly once the disk is back.
            if entry.moved && !retry {
                report.notices.append(
                    "\u{201C}\(name)\u{201D} was being moved onto \u{201C}\(diskName(entry.stagingPath))\u{201D}, which isn't connected. Connect it and File Trail puts \u{201C}\(name)\u{201D} in place; until then it is under the hidden name \u{201C}\(basenameOf(entry.stagingPath))\u{201D} there."
                )
            }
            continue
        case .nothingLeft, .finished, .restored, .keptVisible, .removedCopy:
            break
        }
        var details = ["outcome": outcomeName(outcome.outcome), "stagingPath": entry.stagingPath]
        details["path"] = outcome.outcome.path
        logger.info("[filetrail] recovered an interrupted replace", details)
        if retry && entry.moved, let path = outcome.outcome.path {
            report.finished.append("\u{201C}\(name)\u{201D} is in place now, in \u{201C}\(dirnameOf(path))\u{201D}.")
        }
        // A folder being moved to another disk, put in place whole: its original wasn't removed yet, and is still
        // where it was.
        if case .finished(let path) = outcome.outcome, entry.movingCopy {
            report.notices.append(
                "\u{201C}\(name)\u{201D} was being moved when File Trail stopped. It is in \u{201C}\(basenameOf(dirnameOf(path)))\u{201D} now, and the original is still in \u{201C}\(basenameOf(dirnameOf(entry.sourcePath)))\u{201D} too."
            )
        }
        do {
            try journal.remove(entry.id)
        } catch {
            // The item was dealt with; the next start finds nothing left for this entry.
            logger.error("[filetrail] couldn't update the write journal", describeCopyPasteError(error))
        }
    }
}

private func outcomeName(_ outcome: ReplaceRecoveryOutcome) -> String {
    switch outcome {
    case .nothingLeft: "nothing_left"
    case .finished: "finished"
    case .restored: "restored"
    case .keptVisible: "kept_visible"
    case .removedCopy: "removed_copy"
    case .unreachable: "unreachable"
    case .deferred: "deferred"
    case .failed: "failed"
    }
}

/// "/Volumes/Backup/x/.y" is on "Backup"; anything else on the disk that holds its folder.
func diskName(_ path: String) -> String {
    let prefix = "/Volumes/"
    if startsWith(path, prefix) {
        let rest = path.unicodeScalars.dropFirst(prefix.unicodeScalars.count)
        let name = rest.prefix { $0 != "/" }
        if !name.isEmpty {
            return String(String.UnicodeScalarView(name))
        }
    }
    return basenameOf(dirnameOf(path))
}

// MARK: Retry

public let recoveryRetryIntervalMs = 60_000

/// A repeating timer: `tick` every `intervalMs` until the returned cancel is called. Injected so a test can tick
/// it by hand.
public typealias RecoveryTimer =
    @Sendable (_ intervalMs: Int, _ tick: @escaping @Sendable () -> Void) -> (@Sendable () -> Void)

/// A dispatch timer on a queue of its own.
public let dispatchRecoveryTimer: RecoveryTimer = { intervalMs, tick in
    let source = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "app.filetrail.recovery-retry"))
    source.schedule(deadline: .now() + .milliseconds(intervalMs), repeating: .milliseconds(intervalMs))
    source.setEventHandler(handler: tick)
    source.resume()
    return { source.cancel() }
}

/// Tries the entries left at start again every minute, while no operation runs, until none of them is left.
/// Tells what was put in place (`retryRecovery`).
public final class RecoveryRetry: Sendable {
    private struct State {
        var waiting: Set<String>
        var running = false
        var cancel: (@Sendable () -> Void)?
        var stopped = false
    }

    private let state: OSAllocatedUnfairLock<State>

    private init(_ waiting: Set<String>) {
        state = OSAllocatedUnfairLock(initialState: State(waiting: waiting))
    }

    @discardableResult
    public static func start(
        leftoverIds: Set<String>, recover: @escaping @Sendable (_ entryIds: Set<String>) -> RecoveryReport,
        remainingIds: @escaping @Sendable () -> Set<String>, isBusy: @escaping @Sendable () -> Bool,
        onFinished: @escaping @Sendable (_ messages: [String]) -> Void, intervalMs: Int = recoveryRetryIntervalMs,
        timer: RecoveryTimer = dispatchRecoveryTimer
    ) -> RecoveryRetry {
        let retry = RecoveryRetry(leftoverIds)
        if leftoverIds.isEmpty {
            return retry
        }
        // Held by the timer, as an interval keeps going whether or not anyone holds it; let go once stopped.
        let cancel = timer(intervalMs) {
            retry.tick(recover: recover, remainingIds: remainingIds, isBusy: isBusy, onFinished: onFinished)
        }
        let stopNow = retry.state.withLock { state -> Bool in
            state.cancel = cancel
            return state.stopped
        }
        if stopNow {
            cancel()
        }
        return retry
    }

    public func stop() {
        let cancel = state.withLock { state -> (@Sendable () -> Void)? in
            state.stopped = true
            defer { state.cancel = nil }
            return state.cancel
        }
        cancel?()
    }

    private func tick(
        recover: @Sendable (Set<String>) -> RecoveryReport, remainingIds: @Sendable () -> Set<String>,
        isBusy: @Sendable () -> Bool, onFinished: @Sendable ([String]) -> Void
    ) {
        let waiting = state.withLock { state -> Set<String>? in
            if state.running || state.stopped {
                return nil
            }
            state.running = true
            return state.waiting
        }
        guard let waiting else { return }
        if isBusy() {
            state.withLock { $0.running = false }
            return
        }
        let report = recover(waiting)
        if !report.finished.isEmpty {
            onFinished(report.finished)
        }
        let remaining = remainingIds()
        let done = state.withLock { state -> Bool in
            state.waiting = state.waiting.filter { remaining.contains($0) }
            state.running = false
            return state.waiting.isEmpty
        }
        if done {
            stop()
        }
    }
}
