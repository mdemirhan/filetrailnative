import Darwin
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTOperations

/// What recovery said to the log, in order.
final class RecordingLogger: Sendable {
    struct Line: Equatable {
        var level: String
        var message: String
        var details: [String: String]
    }

    private let lines = Locked<[Line]>([])

    var logger: RecoveryLogger {
        let lines = lines
        return RecoveryLogger(
            info: { message, details in
                lines.mutate { $0.append(Line(level: "info", message: message, details: details)) }
            },
            error: { message, error in
                lines.mutate { $0.append(Line(level: "error", message: message, details: ["error": error])) }
            })
    }

    var all: [Line] { lines.value }
    var infos: [Line] { all.filter { $0.level == "info" } }
    var errors: [Line] { all.filter { $0.level == "error" } }
}

/// What a recovery told the caches to forget.
final class RecordingCaches: Sendable {
    private let listingsCleared = Locked(0)
    private let forgotten = Locked<[[String]]>([])

    var caches: RecoveryCaches {
        let (listingsCleared, forgotten) = (listingsCleared, forgotten)
        return RecoveryCaches(
            clearListings: { listingsCleared.mutate { $0 += 1 } },
            forgetSizes: { paths in forgotten.mutate { $0.append(paths) } })
    }

    var listingClears: Int { listingsCleared.value }
    var sizesForgotten: [[String]] { forgotten.value }
}

/// A journal that reads as `base` does, but whose writes fail as a full startup disk does.
private struct FailingWritesJournal: RecoverableWriteJournal {
    let base: FileWriteJournal

    func entries() -> [WriteJournalEntry] { base.entries() }
    func add(_ entry: WriteJournalEntry) throws { throw codedError(.errno(ENOSPC), "ENOSPC: no space left on device") }
    func remove(_ id: String) throws { throw codedError(.errno(ENOSPC), "ENOSPC: no space left on device") }
}

/// A timer ticked by hand.
private final class ManualTimer: Sendable {
    private let tickHandler = Locked<(@Sendable () -> Void)?>(nil)
    private let cancelled = Locked(false)
    private let interval = Locked<Int?>(nil)

    var timer: RecoveryTimer {
        { [self] intervalMs, tick in
            interval.mutate { $0 = intervalMs }
            tickHandler.mutate { $0 = tick }
            return { [self] in cancelled.mutate { $0 = true } }
        }
    }

    func tick(_ times: Int = 1) {
        for _ in 0..<times where !cancelled.value {
            tickHandler.value?()
        }
    }

    var isCancelled: Bool { cancelled.value }
    var intervalMs: Int? { interval.value }
}

struct WriteRecoveryTests {
    private func withJournal(_ body: (_ root: String, _ journal: FileWriteJournal) throws -> Void) throws {
        try withTemporaryDirectory { root in
            try body(root.path, FileWriteJournal.open(root.path + "/replace-journal.json"))
        }
    }

    private func createEntry(
        _ root: String, _ id: String, stagingPath: String? = nil, finalPath: String? = nil, sourcePath: String? = nil,
        moved: Bool = false, staged: Bool = true, movingCopy: Bool = false
    ) -> ReplaceJournalEntry {
        ReplaceJournalEntry(
            id: id, stagingPath: stagingPath ?? root + "/.\(id).txt.filetrail-00000000",
            finalPath: finalPath ?? root + "/\(id).txt", sourcePath: sourcePath ?? root + "/source/\(id).txt",
            moved: moved, staged: staged, movingCopy: movingCopy)
    }

    private func ids(_ journal: some RecoverableWriteJournal) -> [String] {
        journal.entries().map(\.id)
    }

    @Test func removesTheEntriesItRecoveredAndKeepsTheOnesItCouldnt() throws {
        try withJournal { root, journal in
            // A complete copy whose old item already went to the Trash: it is put in place.
            let finished = createEntry(root, "finished")
            try Disk.write(finished.stagingPath, "new contents")
            // Nothing was left behind.
            let nothingLeft = createEntry(root, "nothing-left")
            // The staged item can't be moved into place: its folder doesn't exist.
            let failing = createEntry(root, "failing", finalPath: root + "/no-such-folder/failing.txt")
            try Disk.write(failing.stagingPath, "stuck")
            for entry in [finished, nothingLeft, failing] {
                try journal.add(.replace(entry))
            }
            let log = RecordingLogger()

            let report = recoverWrites(journal, NativeWriteFileSystem(), logger: log.logger)

            #expect(Disk.read(finished.finalPath) == "new contents")
            #expect(!Disk.exists(finished.stagingPath))
            #expect(journal.entries() == [.replace(failing)])
            #expect(FileWriteJournal.open(root + "/replace-journal.json").entries() == [.replace(failing)])
            #expect(log.errors.count == 1)
            #expect(log.infos.count == 2)
            // The person is told where the item that couldn't be put right is.
            #expect(report.notices.count == 1)
            #expect(
                report.notices.first?.contains(
                    "\u{201C}failing.txt\u{201D} is still under the hidden name \u{201C}.failing.txt.filetrail-00000000\u{201D} in \u{201C}\(root)\u{201D}."
                ) == true)
        }
    }

    // Its disk isn't connected now: the item may be the only copy of something, so the entry stays until it can be
    // dealt with, and the person is told where the item waits.
    @Test func keepsAnEntryWhoseHiddenItemCantBeReachedAndSaysWhereItWaits() throws {
        try withJournal { root, journal in
            let unreachable = createEntry(
                root, "unreachable", stagingPath: "/Volumes/FileTrailNotConnected/.moved.filetrail-00000001",
                finalPath: "/Volumes/FileTrailNotConnected/report.txt", moved: true)
            let unfinishedCopy = createEntry(
                root, "copy", stagingPath: "/Volumes/FileTrailNotConnected/.copy.filetrail-00000002")
            try journal.add(.replace(unreachable))
            try journal.add(.replace(unfinishedCopy))

            let report = recoverWrites(journal, NativeWriteFileSystem(), logger: RecordingLogger().logger)

            // Only the moved item: an unfinished copy's original is in place.
            #expect(
                report.notices == [
                    "\u{201C}report.txt\u{201D} was being moved onto \u{201C}FileTrailNotConnected\u{201D}, which isn't connected. Connect it and File Trail puts \u{201C}report.txt\u{201D} in place; until then it is under the hidden name \u{201C}.moved.filetrail-00000001\u{201D} there."
                ])
            #expect(journal.entries() == [.replace(unreachable), .replace(unfinishedCopy)])
        }
    }

    // A network share that doesn't answer mustn't hold up the window.
    @Test func leavesForLaterAnEntryWhoseDiskDoesntAnswerInTime() throws {
        try withJournal { root, journal in
            let hanging = createEntry(root, "hanging", moved: true)
            try journal.add(.replace(hanging))
            let gate = DispatchSemaphore(value: 0)
            defer { gate.signal() }
            let fileSystem = TestFileSystem()
            fileSystem.lstatImpl = { path in
                gate.wait()
                gate.signal()
                return try NativeWriteFileSystem().lstat(path)
            }
            let started = Date()

            let report = recoverWrites(
                journal, fileSystem, logger: RecordingLogger().logger, answerWithinMs: 50)

            #expect(Date().timeIntervalSince(started) < 10)
            #expect(report.notices.count == 1)
            #expect(journal.entries() == [.replace(hanging)])
        }
    }

    // Once the disk is back the item is put in place, and the person told.
    @Test func finishesAWaitingEntryOnARetryAndSaysSo() throws {
        try withJournal { root, journal in
            let waiting = createEntry(root, "waiting", moved: true)
            try Disk.write(waiting.stagingPath, "moved contents")
            try journal.add(.replace(waiting))

            let report = recoverWrites(
                journal, NativeWriteFileSystem(), logger: RecordingLogger().logger, entryIds: [waiting.id],
                retry: true)

            #expect(report.finished == ["\u{201C}waiting.txt\u{201D} is in place now, in \u{201C}\(root)\u{201D}."])
            #expect(Disk.read(waiting.finalPath) == "moved contents")
            #expect(journal.entries().isEmpty)
        }
    }

    @Test func forgetsTheFolderListingsReadBeforeARetryPutAnItemInPlace() throws {
        try withJournal { root, journal in
            let waiting = createEntry(root, "waiting", moved: true)
            try Disk.write(waiting.stagingPath, "moved contents")
            try journal.add(.replace(waiting))
            let caches = RecordingCaches()

            _ = recoverWrites(
                journal, NativeWriteFileSystem(), logger: RecordingLogger().logger, caches: caches.caches,
                entryIds: [waiting.id], retry: true,
                runWriteAlone: { write in
                    write()
                    return true
                })

            #expect(Disk.read(waiting.finalPath) == "moved contents")
            #expect(caches.listingClears == 1)
            #expect(caches.sizesForgotten == [[waiting.stagingPath, waiting.finalPath]])
        }
    }

    @Test func keepsTheFolderListingsWhenARetryChangedNothing() throws {
        try withJournal { root, journal in
            let waiting = createEntry(root, "waiting", moved: true)
            try Disk.write(waiting.stagingPath, "moved contents")
            try journal.add(.replace(waiting))
            let caches = RecordingCaches()

            _ = recoverWrites(
                journal, NativeWriteFileSystem(), logger: RecordingLogger().logger, caches: caches.caches,
                entryIds: [waiting.id], retry: true, runWriteAlone: { _ in false })

            #expect(caches.listingClears == 0)
            #expect(caches.sizesForgotten.isEmpty)
        }
    }

    // A retry runs while the app is in use: it waits for a moment when nothing else writes, and touches nothing
    // while an operation runs.
    @Test func leavesAWaitingEntryAloneWhileAnotherOperationWritesAndFinishesItAfter() throws {
        try withJournal { root, journal in
            let waiting = createEntry(root, "waiting", moved: true)
            try Disk.write(waiting.stagingPath, "moved contents")
            try journal.add(.replace(waiting))
            let log = RecordingLogger()
            let busyCalls = Locked(0)

            let report = recoverWrites(
                journal, NativeWriteFileSystem(), logger: log.logger, entryIds: [waiting.id], retry: true,
                runWriteAlone: { _ in
                    busyCalls.mutate { $0 += 1 }
                    return false
                })

            #expect(busyCalls.value == 1)
            #expect(report == RecoveryReport())
            #expect(Disk.read(waiting.stagingPath) == "moved contents")
            #expect(journal.entries() == [.replace(waiting)])
            #expect(log.errors.isEmpty)

            let writing = Locked(false)
            let seenWhileWriting = Locked<[Bool]>([])
            let watching = TestFileSystem()
            // Whether the disk answers is checked before the slot is taken.
            watching.lstatImpl = { path in
                let now = writing.value
                seenWhileWriting.mutate { $0.append(now) }
                return try NativeWriteFileSystem().lstat(path)
            }
            let retried = recoverWrites(
                journal, watching, logger: log.logger, entryIds: [waiting.id], answerWithinMs: 1_000, retry: true,
                runWriteAlone: { write in
                    writing.mutate { $0 = true }
                    write()
                    writing.mutate { $0 = false }
                    return true
                })

            #expect(retried.finished == ["\u{201C}waiting.txt\u{201D} is in place now, in \u{201C}\(root)\u{201D}."])
            #expect(Disk.read(waiting.finalPath) == "moved contents")
            #expect(journal.entries().isEmpty)
            #expect(seenWhileWriting.value.first == false)
        }
    }

    @Test func retriesEverySoOftenWhileNothingRunsUntilNothingIsLeft() {
        let left = Locked<Set<String>>(["a"])
        let recovered = Locked(0)
        let finished = Locked<[[String]]>([])
        let busy = Locked(true)
        let timer = ManualTimer()

        RecoveryRetry.start(
            leftoverIds: ["a"],
            recover: { _ in
                recovered.mutate { $0 += 1 }
                left.mutate { $0 = [] }
                return RecoveryReport(finished: ["\u{201C}a.txt\u{201D} is in place now, in \u{201C}/x\u{201D}."])
            }, remainingIds: { left.value }, isBusy: { busy.value },
            onReport: { report in finished.mutate { $0.append(report.finished) } }, intervalMs: 1_000,
            timer: timer.timer)

        #expect(timer.intervalMs == 1_000)
        timer.tick()
        #expect(recovered.value == 0)
        busy.mutate { $0 = false }
        timer.tick()
        #expect(finished.value == [["\u{201C}a.txt\u{201D} is in place now, in \u{201C}/x\u{201D}."]])
        timer.tick(5)
        #expect(recovered.value == 1)
        #expect(timer.isCancelled)
        #expect(recoveryRetryIntervalMs == 60_000)
    }

    // An operation can leave an item under its hidden name while the app runs (its disk went away part way): it is
    // tried again like what was left at start, with a timer only while something waits.
    @Test func takesOnWhatAnOperationLeavesWhileTheAppRuns() {
        let left = Locked<Set<String>>([])
        let tried = Locked<[Set<String>]>([])
        let made = Locked(0)
        let ended = Locked(0)
        let handler = Locked<(@Sendable () -> Void)?>(nil)
        let timer: RecoveryTimer = { _, tick in
            made.mutate { $0 += 1 }
            handler.mutate { $0 = tick }
            return {
                ended.mutate { $0 += 1 }
                handler.mutate { $0 = nil }
            }
        }
        let retry = RecoveryRetry.start(
            leftoverIds: [],
            recover: { ids in
                tried.mutate { $0.append(ids) }
                return RecoveryReport()
            }, remainingIds: { left.value }, isBusy: { false }, onReport: { _ in }, timer: timer)
        // Nothing was left at start: no timer.
        #expect(made.value == 0)
        retry.watch([])
        #expect(made.value == 0)

        left.mutate { $0 = ["b"] }
        retry.watch(["b"])
        retry.watch(["b"])
        #expect(made.value == 1)
        // Its disk is still away.
        handler.value?()
        #expect(tried.value == [["b"]])
        #expect(ended.value == 0)
        // Back: nothing waits, and the timer ends.
        left.mutate { $0 = [] }
        handler.value?()
        #expect(tried.value == [["b"], ["b"]])
        #expect(ended.value == 1)

        // The next one starts a timer again.
        left.mutate { $0 = ["c"] }
        retry.watch(["c"])
        #expect(made.value == 2)
        retry.stop()
        #expect(ended.value == 2)
        retry.watch(["d"])
        #expect(made.value == 2)
    }

    /// What a retry passes on, each time it does.
    private func retryReports(
        leftoverIds: Set<String> = ["a"], told: [String] = [], ticks: Int,
        recover: @escaping @Sendable (Set<String>) -> RecoveryReport,
        remainingIds: @escaping @Sendable () -> Set<String>
    ) -> [RecoveryReport] {
        let reports = Locked<[RecoveryReport]>([])
        let timer = ManualTimer()
        RecoveryRetry.start(
            leftoverIds: leftoverIds, told: told, recover: recover, remainingIds: remainingIds, isBusy: { false },
            onReport: { report in reports.mutate { $0.append(report) } }, timer: timer.timer)
        timer.tick(ticks)
        return reports.value
    }

    @Test func passesOnWhatARetryFoundThatThePersonMustKnow() {
        let reports = retryReports(
            ticks: 1, recover: { _ in RecoveryReport(notices: ["Found in place."]) }, remainingIds: { [] })
        #expect(reports == [RecoveryReport(notices: ["Found in place."])])
    }

    @Test func passesOnBothKindsOfMessageApart() {
        let reports = retryReports(
            ticks: 1, recover: { _ in RecoveryReport(notices: ["Put back."], finished: ["In place now."]) },
            remainingIds: { [] })
        #expect(reports == [RecoveryReport(notices: ["Put back."], finished: ["In place now."])])
    }

    // An entry whose record can't be removed is found again at every try: what it says is told once, and not again
    // when the start already told it.
    @Test func tellsEachMessageOnceThoughTheEntryIsFoundAgainAtEveryTry() {
        let reports = retryReports(
            leftoverIds: ["a", "b"], told: ["Told at start."], ticks: 4,
            recover: { _ in RecoveryReport(notices: ["Told at start.", "Found in place."]) },
            remainingIds: { ["a", "b"] })
        #expect(reports == [RecoveryReport(notices: ["Found in place."])])
    }

    // A folder moved to another disk, found in place while its originals went; its source couldn't be read at start,
    // so nothing was said then. Once it can, the retry says what is where.
    @Test func aMoveFoundInPlaceOnARetryIsTold() throws {
        try withJournal { root, journal in
            let source = root + "/src"
            try Disk.write(source + "/F/a.txt", "a")
            try Disk.write(root + "/dst/F/a.txt", "a")
            let entry = createEntry(
                root, "move", stagingPath: root + "/dst/.F.filetrail-00000000", finalPath: root + "/dst/F",
                sourcePath: source + "/F", staged: true, movingCopy: true)
            try journal.add(.replace(entry))
            let log = RecordingLogger()
            Darwin.chmod(source, 0)
            defer { Darwin.chmod(source, 0o755) }

            let atStart = recoverWrites(journal, NativeWriteFileSystem(), logger: log.logger)
            #expect(atStart == RecoveryReport())
            #expect(ids(journal) == ["move"])
            Darwin.chmod(source, 0o755)

            let reports = retryReports(
                leftoverIds: ["move"], ticks: 1,
                recover: { entryIds in
                    recoverWrites(
                        journal, NativeWriteFileSystem(), logger: log.logger, entryIds: entryIds, retry: true)
                }, remainingIds: { Set(journal.entries().map(\.id)) })

            #expect(
                reports.map(\.notices) == [
                    [
                        "\u{201C}F\u{201D} was being moved when File Trail stopped. It is in \u{201C}dst\u{201D} now, and what was left of the original is still in \u{201C}src\u{201D}, perhaps not all of it."
                    ]
                ])
            #expect(journal.entries().isEmpty)
        }
    }

    // A rename of several whose folder couldn't be read at start is put back by a retry, and the person is told.
    @Test func aRenameOfSeveralPutBackOnARetryIsTold() throws {
        try withJournal { root, journal in
            let folder = root + "/trip"
            try Disk.write(folder + "/.filetrail-rename-aaaaaaaaaaaa", "a")
            let entry = BatchRenameJournalEntry(
                id: "rename",
                items: [
                    .init(
                        temporaryPath: folder + "/.filetrail-rename-aaaaaaaaaaaa", originalPath: folder + "/a.jpg",
                        newPath: folder + "/b.jpg")
                ])
            try journal.add(.batchRename(entry))
            let log = RecordingLogger()
            Darwin.chmod(folder, 0)
            defer { Darwin.chmod(folder, 0o755) }
            #expect(recoverWrites(journal, NativeWriteFileSystem(), logger: log.logger) == RecoveryReport())
            #expect(ids(journal) == ["rename"])
            Darwin.chmod(folder, 0o755)

            let reports = retryReports(
                leftoverIds: ["rename"], ticks: 1,
                recover: { entryIds in
                    recoverWrites(
                        journal, NativeWriteFileSystem(), logger: log.logger, entryIds: entryIds, retry: true)
                }, remainingIds: { Set(journal.entries().map(\.id)) })

            #expect(
                reports.map(\.notices) == [
                    [
                        "A rename of several items was cut short when File Trail stopped. \u{201C}a.jpg\u{201D} is back under its old name."
                    ]
                ])
            #expect(Disk.list(folder) == ["a.jpg"])
        }
    }

    // A folder moved to another disk, its hidden copy already gone: where it went can't be read just now, so whether it
    // is in place isn't known. The entry waits rather than being taken as done.
    @Test func keepsAMovesEntryWhenItsPlaceCantBeRead() throws {
        try withJournal { root, journal in
            let entry = createEntry(
                root, "move", stagingPath: root + "/.F.filetrail-00000000", finalPath: root + "/F",
                sourcePath: root + "/src/F", staged: true, movingCopy: true)
            try journal.add(.replace(entry))
            let fileSystem = TestFileSystem()
            fileSystem.lstatImpl = { path in
                if path == entry.finalPath { throw codedError(.errno(EIO), "EIO: i/o error") }
                return try NativeWriteFileSystem().lstat(path)
            }

            let report = recoverWrites(journal, fileSystem, logger: RecordingLogger().logger)

            #expect(report == RecoveryReport())
            #expect(ids(journal) == ["move"])
        }
    }

    // A crash during a Replace that filled the disk must not keep the app from starting.
    @Test func neverThrowsWhenTheJournalCantBeWritten() throws {
        try withJournal { root, journal in
            let finished = createEntry(root, "finished")
            try Disk.write(finished.stagingPath, "new contents")
            try journal.add(.replace(finished))
            let log = RecordingLogger()

            let report = recoverWrites(FailingWritesJournal(base: journal), NativeWriteFileSystem(), logger: log.logger)

            #expect(report == RecoveryReport())
            #expect(Disk.read(finished.finalPath) == "new contents")
            #expect(log.errors.map(\.message) == ["[filetrail] couldn't update the write journal"])
        }
    }

    // A large file a crash cut short while it was being copied: only part of a copy, its original in place. It is
    // removed; an item of another name stays.
    @Test func removesThePartOfALargeFileLeftByACrashAndNothingElse() throws {
        try withJournal { root, journal in
            let partial = root + "/.movie.mov.filetrail-0a1b2c3d"
            try Disk.write(partial, "part of it")
            let notOurs = root + "/notes.txt"
            try Disk.write(notOurs, "someone's notes")
            for (id, partialPath) in [
                ("partial", partial), ("not-ours", notOurs), ("gone", root + "/.gone.mov.filetrail-11111111"),
            ] {
                try journal.add(
                    .partialFile(PartialFileJournalEntry(id: id, partialPath: partialPath, finalPath: root + "/" + id)))
            }
            let log = RecordingLogger()

            #expect(recoverWrites(journal, NativeWriteFileSystem(), logger: log.logger) == RecoveryReport())

            #expect(Disk.list(root) == ["notes.txt", "replace-journal.json"])
            #expect(journal.entries().isEmpty)
            // Kept for a later try when its disk can't be read.
            let unreachable = root + "/gone-disk/.big.filetrail-22222222"
            try journal.add(.partialFile(PartialFileJournalEntry(id: "away", partialPath: unreachable, finalPath: "x")))
            _ = recoverWrites(journal, NativeWriteFileSystem(), logger: log.logger)
            #expect(ids(journal) == ["away"])
            #expect(
                log.infos.contains {
                    $0.message == "[filetrail] an interrupted copy wasn't removed"
                        && $0.details["partialPath"] == unreachable
                })
        }
    }

    // A copy of a locked file is locked as it is finished, before it takes its name.
    @Test func removesALockedPartOfALargeFile() throws {
        try withJournal { root, journal in
            let partial = root + "/.movie.mov.filetrail-0a1b2c3d"
            try Disk.write(partial, "all of it")
            Disk.lock(partial)
            try journal.add(.partialFile(PartialFileJournalEntry(id: "p", partialPath: partial, finalPath: "x")))

            _ = recoverWrites(journal, NativeWriteFileSystem(), logger: RecordingLogger().logger)

            #expect(!Disk.exists(partial))
            #expect(journal.entries().isEmpty)
        }
    }

    // Keys this build doesn't know are passed over: the entry is read by the ones it does.
    @Test func readsAnEntryWithKeysItDoesntKnow() throws {
        try withTemporaryDirectory { directory in
            let root = directory.path
            let filePath = root + "/replace-journal.json"
            var folder = JournalJSON.object(WriteJournalEntry.replace(createEntry(root, "folder")).jsonObject)
            folder.removeLast()
            folder += ",\"stagingId\":{\"dev\":1,\"ino\":2},\"stagingBornMs\":3}"
            try Disk.write(
                filePath,
                "[\(folder),{\"kind\":\"partial_file\",\"id\":\"p\",\"partialPath\":\"/a/.b.filetrail-00000000\",\"finalPath\":\"/a/b\",\"folderBornMs\":3}]"
            )

            let journal = FileWriteJournal.open(filePath)

            #expect(ids(journal) == ["folder", "p"])
            #expect(journal.entries().first == .replace(createEntry(root, "folder")))
        }
    }

    @Test func readsEntriesBackAndLeavesOutWhatItCantRead() throws {
        try withTemporaryDirectory { directory in
            let root = directory.path
            let filePath = root + "/replace-journal.json"
            let old = JournalJSON.object(WriteJournalEntry.replace(createEntry(root, "old")).jsonObject)
            try Disk.write(
                filePath,
                "[\(old),{\"kind\":\"partial_file\",\"id\":\"p\",\"partialPath\":\"/a/.b.filetrail-00000000\",\"finalPath\":\"/a/b\"},{\"kind\":\"partial_file\",\"id\":\"broken\"},{\"kind\":\"something_newer\",\"id\":\"n\",\"finalPath\":\"/x\"}]"
            )

            #expect(ids(FileWriteJournal.open(filePath)) == ["old", "p"])
        }
    }

    @Test func doesNothingWhenThereIsNothingToRecover() throws {
        try withJournal { root, journal in
            let log = RecordingLogger()

            _ = recoverWrites(journal, NativeWriteFileSystem(), logger: log.logger)

            #expect(log.infos.isEmpty)
            #expect(!Disk.exists(root + "/replace-journal.json"))
        }
    }
}
