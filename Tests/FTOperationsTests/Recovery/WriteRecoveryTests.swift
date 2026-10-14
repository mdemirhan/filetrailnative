// Port of the recoverWrites and retryRecovery cases of apps/desktop/src/main/bootstrap/writeJournal.test.ts (the two
// rename-of-several cases are P3-08's; openWriteJournal's are in Journal/FileWriteJournalTests.swift)
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
    func add(_ entry: WriteJournalEntry) throws { throw codedError("ENOSPC", "ENOSPC: no space left on device") }
    func remove(_ id: String) throws { throw codedError("ENOSPC", "ENOSPC: no space left on device") }
}

/// A timer ticked by hand, as the original's tests advance fake timers.
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

    // T-39c40f5b F-528 F-637
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
    // T-bbfba98c F-528 F-637
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
    // T-01f0d271 F-353 F-528
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
    // T-b9902d4e F-357 F-528
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

    // T-209072c1 F-528
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

    // T-b2efb3f5 F-528
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
    // T-49414386 F-357 F-528
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

    // T-4f7f9c91 F-357
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
            onFinished: { messages in finished.mutate { $0.append(messages) } }, intervalMs: 1_000,
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

    // A crash during a Replace that filled the disk must not keep the app from starting.
    // T-c7bfc4aa F-528
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
    // T-a6a8250b F-354 F-513
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
    // T-6f64ddff F-354 F-346
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

    /// v0.4.3's way of writing a folder down: ids along with it, no longer read.
    private func legacyFolderJSON(_ entry: ReplaceJournalEntry) -> String {
        var json = JournalJSON.object(WriteJournalEntry.replace(entry).jsonObject)
        json.removeLast()
        return json + ",\"stagingId\":{\"dev\":1,\"ino\":2},\"stagingBornMs\":3,\"sourceId\":{\"dev\":4,\"ino\":5}}"
    }

    // v0.4.3 wrote down a large file copied inside a folder a paste was building, and ids along with each folder:
    // read back from its file, the folder and the part both go, by their paths, and neither record stays.
    // T-6378e158 F-354 F-355
    @Test func clearsAFolderAndThePartOfALargeFileInItWrittenDownByV043() throws {
        try withTemporaryDirectory { directory in
            let root = directory.path
            let filePath = root + "/replace-journal.json"
            let staging = root + "/.F.filetrail-0a1b2c3d"
            let partial = staging + "/.movie.mov.filetrail-11111111"
            try Disk.write(partial, "part of it")
            let folder = createEntry(
                root, "folder", stagingPath: staging, finalPath: root + "/F", sourcePath: root + "/source/F",
                staged: false)
            try Disk.write(
                filePath,
                "[\(legacyFolderJSON(folder)),{\"kind\":\"partial_file\",\"id\":\"p\",\"partialPath\":\(JournalJSON.string(partial)),\"finalPath\":\"x\"}]"
            )
            let journal = FileWriteJournal.open(filePath)

            _ = recoverWrites(journal, NativeWriteFileSystem(), logger: RecordingLogger().logger)

            #expect(!Disk.exists(staging))
            #expect(journal.entries().isEmpty)
        }
    }

    // A folder being moved to another disk, complete under its hidden name when v0.4.3 stopped: put in place by its
    // path (the ids it was written down with don't matter), and the person is told the original is still where it
    // was.
    // T-47906982 F-355 F-637
    @Test func putsInPlaceAMovedFoldersCopyWrittenDownByV043AndSaysSo() throws {
        try withTemporaryDirectory { directory in
            let root = directory.path
            let filePath = root + "/replace-journal.json"
            let staging = root + "/.F.filetrail-0a1b2c3d"
            try Disk.write(staging + "/a.txt", "a")
            let folder = createEntry(
                root, "folder", stagingPath: staging, finalPath: root + "/F", sourcePath: root + "/source/F",
                staged: true, movingCopy: true)
            try Disk.write(filePath, "[\(legacyFolderJSON(folder))]")
            let journal = FileWriteJournal.open(filePath)

            let report = recoverWrites(journal, NativeWriteFileSystem(), logger: RecordingLogger().logger)

            #expect(Disk.read(root + "/F/a.txt") == "a")
            #expect(!Disk.exists(staging))
            #expect(
                report.notices == [
                    "\u{201C}F\u{201D} was being moved when File Trail stopped. It is in \u{201C}\(NodePath.basename(root))\u{201D} now, and the original is still in \u{201C}source\u{201D} too."
                ])
            #expect(journal.entries().isEmpty)
        }
    }

    // Builds after v0.4.3 that were never released copied a large file as "part" in a hidden folder of its own:
    // that folder goes, and a record of one already gone clears.
    // T-b34cde9f F-354 F-526
    @Test func removesTheHiddenFolderALargeFileWasCopiedInByABuildAfterV043() throws {
        try withTemporaryDirectory { directory in
            let root = directory.path
            let filePath = root + "/replace-journal.json"
            let folder = root + "/.movie.mov.filetrail-0a1b2c3d"
            try Disk.write(folder + "/part", "part of it")
            let gone = root + "/.gone.mov.filetrail-11111111/part"
            let entries = [("p", folder + "/part"), ("gone", gone)].map { id, partialPath in
                "{\"kind\":\"partial_file\",\"id\":\"\(id)\",\"partialPath\":\(JournalJSON.string(partialPath)),\"finalPath\":\(JournalJSON.string(root + "/movie.mov")),\"folderId\":{\"dev\":1,\"ino\":2},\"folderBornMs\":3}"
            }
            try Disk.write(filePath, "[" + entries.joined(separator: ",") + "]")
            let journal = FileWriteJournal.open(filePath)

            _ = recoverWrites(journal, NativeWriteFileSystem(), logger: RecordingLogger().logger)

            #expect(Disk.list(root) == ["replace-journal.json"])
            #expect(journal.entries().isEmpty)
        }
    }

    // A rename of several is P3-08's to put back: its entry is read, and left as it is.
    // T-7a6bb677 F-352 F-527
    @Test func readsBothKindsOfEntryBackAndLeavesOutWhatItCantRead() throws {
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

    // T-fb074512 F-528
    @Test func doesNothingWhenThereIsNothingToRecover() throws {
        try withJournal { root, journal in
            let log = RecordingLogger()

            _ = recoverWrites(journal, NativeWriteFileSystem(), logger: log.logger)

            #expect(log.infos.isEmpty)
            #expect(!Disk.exists(root + "/replace-journal.json"))
        }
    }

    // Keep batch_rename entries readable and written back untouched: their put-back is P3-08's.
    @Test func leavesARenameOfSeveralAsItIs() throws {
        try withJournal { root, journal in
            let rename = WriteJournalEntry.batchRename(
                BatchRenameJournalEntry(
                    id: "r",
                    items: [
                        .init(
                            temporaryPath: root + "/.a.filetrail-rename-000000000000", originalPath: root + "/a",
                            newPath: root + "/b")
                    ]))
            try journal.add(rename)

            let report = recoverWrites(journal, NativeWriteFileSystem(), logger: RecordingLogger().logger)

            #expect(report == RecoveryReport())
            #expect(journal.entries() == [rename])
            #expect(FileWriteJournal.open(root + "/replace-journal.json").entries() == [rename])
        }
    }
}
