// Folders copied or moved whole, large files, AppleDouble files and the smaller cases
import Darwin
import FTFoundation
import FTTestSupport
import Foundation
import Testing
import os

@testable import FTOperations

/// The start of an AppleDouble file (its magic number and version).
private let appleDoubleData: [UInt8] = [0x00, 0x05, 0x16, 0x07, 0x00, 0x02, 0x00, 0x00]

/// Runs a command line tool, such as chmod or chflags.
func runTool(_ tool: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0, "\(tool) \(arguments)")
}

/// A copy that fails with `code` at `when(source, count)`, otherwise the base's.
private func failingCopy(
    _ fileSystem: TestFileSystem, code: ErrorCode, when: @escaping @Sendable (String, Int) -> Bool
) {
    let base = fileSystem.base
    let written = OSAllocatedUnfairLock(initialState: 0)
    fileSystem.copyFileImpl = { from, to, stop, progress in
        let count = written.withLock { value in
            value += 1
            return value
        }
        if when(from, count) {
            throw codedError(code, "\(code.name): \(from)")
        }
        try base.copyFile(from, to, stop: stop, onProgress: progress)
    }
}

/// A folder copied or moved whole.
struct WholeFolderTests {
    /// Four files in a package, the third of which can't be written (a disk error); as to another disk.
    private func packageWithAFailingFile(_ f: SafetyFolders) throws -> TestFileSystem {
        for name in ["Index.zip", "Data/a.png", "Data/b.png", "Metadata.plist"] {
            try Disk.write(f.src + "/Talk.key/" + name, name)
        }
        let fileSystem = f.withoutRenameAtAll()
        failingCopy(fileSystem, code: .errno(EIO)) { _, count in count == 3 }
        return fileSystem
    }

    // An incomplete package inside a folder being copied, which the disk won't let go of: the folder around it
    // isn't put in place either, and nothing of it is left.
    @Test func copiesNothingOfAFolderWhoseIncompletePackageCantBeClearedAway() async throws {
        try await withSafetyFolders { f in
            let fileSystem = try packageWithAFailingFile(f)
            try Disk.makeDirectories(f.src + "/F")
            #expect(rename(f.src + "/Talk.key", f.src + "/F/Talk.key") == 0)
            let base = fileSystem.base
            fileSystem.rmImpl = { path, recursive, force in
                if NodePath.basename(path) == "Talk.key" {
                    throw codedError(.errno(EACCES), "EACCES: permission denied")
                }
                try base.rm(path, recursive: recursive, force: force)
            }

            let run = try await runPaste(mode: .copy, sources: [f.src + "/F"], into: f.dst, fileSystem: fileSystem)

            #expect(run.result?.status == .failed)
            #expect(run.result?.items.first?.error == "You don't have permission to access this item.")
            #expect(Disk.list(f.dst) == [])
        }
    }

    // As to another disk: no part of the package is left in either place.
    @Test func movesNothingOfAFolderSomeOfWhoseItemsCouldntBeCopied() async throws {
        try await withSafetyFolders { f in
            let run = try await runPaste(
                mode: .cut, sources: [f.src + "/Talk.key"], into: f.dst, fileSystem: try packageWithAFailingFile(f))

            #expect(run.result?.status == .failed)
            #expect(
                run.result?.items.first?.error
                    == "\u{201C}Talk.key\u{201D} wasn't moved because some items in it were skipped or couldn't be copied. Nothing in it was moved."
            )
            #expect(run.result?.items.filter { $0.status == .failed }.count == 2)
            #expect(Disk.list(f.dst) == [])
            #expect(Disk.list(f.src + "/Talk.key") == ["Data", "Index.zip", "Metadata.plist"])
            #expect(Disk.list(f.src + "/Talk.key/Data") == ["a.png", "b.png"])
        }
    }

    @Test func copiesNothingOfAPackageSomeOfWhoseItemsCouldntBeCopied() async throws {
        try await withSafetyFolders { f in
            let run = try await runPaste(
                mode: .copy, sources: [f.src + "/Talk.key"], into: f.dst, fileSystem: try packageWithAFailingFile(f))

            #expect(
                run.result?.items.first?.error
                    == "\u{201C}Talk.key\u{201D} wasn't copied because some items in it were skipped or couldn't be copied."
            )
            #expect(Disk.list(f.dst) == [])
        }
    }

    // An ordinary folder is put in place with what could be copied, the rest named.
    @Test func putsAnOrdinaryFolderInPlaceWithWhatCouldBeCopied() async throws {
        try await withSafetyFolders { f in
            let fileSystem = try packageWithAFailingFile(f)
            #expect(rename(f.src + "/Talk.key", f.src + "/Talk") == 0)

            let run = try await runPaste(mode: .copy, sources: [f.src + "/Talk"], into: f.dst, fileSystem: fileSystem)

            #expect(run.result?.status == .partial)
            // The folder, and the file in it that couldn't be written.
            let failed = run.result?.items.filter { $0.status == .failed } ?? []
            #expect(failed.count == 2)
            #expect(failed.first?.sourcePath == f.src + "/Talk")
            #expect(failed.first?.childFailureCount == 1)
            #expect(failed.last?.error == "A disk error occurred.")
            #expect(Disk.list(f.dst) == ["Talk"])
            #expect(Disk.list(f.dst + "/Talk").count + Disk.list(f.dst + "/Talk/Data").count == 4)
        }
    }

    // A copy of a folder with a rule against deleting it (as ~/Documents has) carries the rule: a move that can't
    // go on still removes all of its hidden copy.
    @Test func removesAHiddenCopyHoldingAFolderWithARuleAgainstDeletingIt() async throws {
        try await withSafetyFolders { f in
            try Disk.write(f.src + "/F/A/a.txt", "a")
            try Disk.write(f.src + "/F/z.txt", "z")
            try runTool("/bin/chmod", ["+a", "group:everyone deny delete", f.src + "/F/A"])
            defer { try? runTool("/bin/chmod", ["-R", "-N", f.root]) }
            let fileSystem = f.withoutRenameAtAll()
            failingCopy(fileSystem, code: .errno(EIO)) { from, _ in NodePath.basename(from) == "z.txt" }

            let run = try await runPaste(mode: .cut, sources: [f.src + "/F"], into: f.dst, fileSystem: fileSystem)

            #expect(run.result?.status == .failed)
            #expect(Disk.list(f.dst) == [])
            #expect(Disk.list(f.src + "/F") == ["A", "z.txt"])
        }
    }

    // The item Replace was to replace went away before the paste: the package is then moved as any other, whole or
    // not at all.
    @Test func movesAPackageWholeWhenTheItemItWasToReplaceIsGone() async throws {
        try await withSafetyFolders { f in
            let fileSystem = try packageWithAFailingFile(f)
            try Disk.makeDirectories(f.dst + "/Talk.key")

            let run = try await runPaste(
                mode: .cut, sources: [f.src + "/Talk.key"], into: f.dst, policy: NativePaste.replaceAll,
                fileSystem: fileSystem,
                beforeExecute: { try FileManager.default.removeItem(atPath: f.dst + "/Talk.key") })

            #expect(run.result?.status == .failed)
            #expect(Disk.list(f.dst) == [])
            #expect(Disk.list(f.src + "/Talk.key") == ["Data", "Index.zip", "Metadata.plist"])
        }
    }

    // A file in the package changed after the review and was skipped: the rest of it isn't a whole package, so
    // none of it is put in place.
    @Test func copiesNothingOfAPackageAnItemOfWhichWasSkipped() async throws {
        try await withSafetyFolders { f in
            try Disk.write(f.src + "/Talk.key/Index.zip", "index")
            try Disk.write(f.src + "/Talk.key/Metadata.plist", "meta")

            let run = try await runPaste(
                mode: .copy, sources: [f.src + "/Talk.key"], into: f.dst,
                beforeExecute: { try Disk.write(f.src + "/Talk.key/Index.zip", "changed index") },
                resolve: { _ in .skip })

            #expect(
                run.result?.items.first?.error
                    == "\u{201C}Talk.key\u{201D} wasn't copied because some items in it were skipped or couldn't be copied."
            )
            #expect(Disk.list(f.dst) == [])
        }
    }

    // A folder in a moved folder became a file after the review and was skipped: it stays, and the rest moves.
    @Test func leavesASkippedFolderWhereItWasWhenMovingTheRest() async throws {
        try await withSafetyFolders { f in
            try Disk.makeDirectories(f.src + "/F/E")
            try Disk.write(f.src + "/F/a.txt", "a")

            let run = try await runPaste(
                mode: .cut, sources: [f.src + "/F"], into: f.dst, fileSystem: f.withoutRenameAtAll(),
                beforeExecute: {
                    try FileManager.default.removeItem(atPath: f.src + "/F/E")
                    try Disk.write(f.src + "/F/E", "now a file")
                },
                resolve: { _ in .skip })

            #expect(run.result?.items.first { $0.sourcePath == f.src + "/F/E" }?.status == .skipped)
            #expect(Disk.list(f.dst + "/F") == ["a.txt"])
            #expect(Disk.list(f.src + "/F") == ["E"])
        }
    }

    // An app inside an ordinary folder is whole or not at all, like the folder's own items.
    @Test func leavesOutAnAppInsideAFolderThatCouldntBeCopiedWhole() async throws {
        try await withSafetyFolders { f in
            try Disk.write(f.src + "/F/readme.txt", "readme")
            try Disk.write(f.src + "/F/Tool.app/Contents/a", "a")
            try Disk.write(f.src + "/F/Tool.app/Contents/b", "b")
            let fileSystem = TestFileSystem()
            failingCopy(fileSystem, code: .errno(EIO)) { from, _ in from.hasSuffix("Contents/b") }

            let run = try await runPaste(mode: .copy, sources: [f.src + "/F"], into: f.dst, fileSystem: fileSystem)

            #expect(Disk.list(f.dst + "/F") == ["readme.txt"])
            #expect(
                run.result?.items.first { $0.sourcePath == f.src + "/F/Tool.app" }?.error
                    == "\u{201C}Tool.app\u{201D} wasn't copied because some items in it were skipped or couldn't be copied."
            )
        }
    }

    // Skipped deep inside: "Contents" was done, the app it is in wasn't.
    @Test func leavesOutAnAppWithAnItemSkippedDeepInsideIt() async throws {
        try await withSafetyFolders { f in
            try Disk.write(f.src + "/F/readme.txt", "readme")
            try Disk.write(f.src + "/F/App.app/Contents/a", "a")

            _ = try await runPaste(
                mode: .copy, sources: [f.src + "/F"], into: f.dst,
                beforeExecute: { try Disk.write(f.src + "/F/App.app/Contents/a", "changed") }, resolve: { _ in .skip })

            #expect(Disk.list(f.dst + "/F") == ["readme.txt"])
        }
    }

    // Stopped as its last file is written, before the folder is put in place.
    @Test func movesNothingWhenStoppedAsItsLastItemIsCopied() async throws {
        try await withSafetyFolders { f in
            try Disk.write(f.src + "/F/a.txt", "a")
            let signal = StopSignal()
            let fileSystem = f.withoutRenameAtAll()
            let base = fileSystem.base
            fileSystem.copyFileImpl = { from, to, stop, progress in
                try base.copyFile(from, to, stop: stop, onProgress: progress)
                signal.stop()
            }

            let run = try await runPaste(
                mode: .cut, sources: [f.src + "/F"], into: f.dst, fileSystem: fileSystem, signal: signal)

            #expect(run.result?.status == .cancelled)
            #expect(Disk.list(f.dst) == [])
            #expect(Disk.list(f.src + "/F") == ["a.txt"])
        }
    }

    // What couldn't be cleared away (its disk went away) stays written down for the next start.
    @Test func keepsTheRecordOfAHiddenFolderItCouldntClearAway() async throws {
        try await withSafetyFolders { f in
            try Disk.write(f.src + "/F/a.txt", "a")
            let fileSystem = f.withoutRenameAtAll()
            let base = fileSystem.base
            fileSystem.copyFileImpl = { _, _, _, _ in
                throw codedError(.errno(EIO), "EIO: input/output error")
            }
            fileSystem.rmImpl = { path, recursive, force in
                if path.contains(".F.filetrail-") {
                    throw codedError(.errno(EIO), "EIO: i/o error")
                }
                try base.rm(path, recursive: recursive, force: force)
            }
            let journal = MemoryJournal()

            _ = try await runPaste(
                mode: .cut, sources: [f.src + "/F"], into: f.dst, fileSystem: fileSystem, writeJournal: journal)

            #expect(journal.entries.count == 1)
            if case .replace(let entry)? = journal.entries.first {
                #expect(entry.finalPath == f.dst + "/F")
                #expect(entry.movingCopy)
            } else {
                Issue.record("no folder entry: \(journal.entries)")
            }
        }
    }

    @Test func movesNothingWhenStoppedPartWayAndLeavesNothingHidden() async throws {
        try await withSafetyFolders { f in
            for name in ["a.txt", "b.txt", "c.txt"] {
                try Disk.write(f.src + "/F/" + name, name)
            }
            let signal = StopSignal()
            let fileSystem = f.withoutRenameAtAll()
            let base = fileSystem.base
            fileSystem.copyFileImpl = { from, to, stop, progress in
                try base.copyFile(from, to, stop: stop, onProgress: progress)
                if from.hasSuffix("b.txt") {
                    signal.stop()
                }
            }

            let run = try await runPaste(
                mode: .cut, sources: [f.src + "/F"], into: f.dst, fileSystem: fileSystem, signal: signal)

            #expect(run.result?.status == .cancelled)
            #expect(Disk.list(f.dst) == [])
            #expect(Disk.list(f.src + "/F") == ["a.txt", "b.txt", "c.txt"])
        }
    }

    // Written down while it is built, so a crash leaves nothing under the hidden name.
    @Test func writesTheFolderDownWhileItIsBuiltAndLetsGoOnceItIsInPlace() async throws {
        try await withSafetyFolders { f in
            try Disk.write(f.src + "/F/a.txt", "a")
            let journal = MemoryJournal()

            let run = try await runPaste(
                mode: .cut, sources: [f.src + "/F"], into: f.dst, fileSystem: f.withoutRenameAtAll(),
                writeJournal: journal)

            #expect(run.result?.status == .completed)
            let added = journal.writes.compactMap { write -> ReplaceJournalEntry? in
                if case .add(.replace(let entry)) = write { return entry }
                return nil
            }
            #expect(added.map(\.finalPath) == [f.dst + "/F", f.dst + "/F"])
            #expect(added.map(\.staged) == [false, true])
            #expect(journal.entries.isEmpty)
            #expect(Disk.list(f.dst) == ["F"])
            #expect(Disk.list(f.src) == [])
        }
    }

    // Killed while the originals of a folder moved to another disk are being removed, once the folder is in place:
    // it is in both places, and the next start says so.
    @Test func aMoveToAnotherDiskKilledWhileItsOriginalsGoIsToldAtTheNextStart() async throws {
        try await withSafetyFolders { f in
            try Disk.write(f.src + "/F/a.txt", "a")
            try Disk.write(f.src + "/F/b.txt", "b")
            let fileSystem = f.withoutRenameAtAll()
            let base = fileSystem.base
            let journal = MemoryJournal()
            // What the journal held as the first original was about to go: all that a process killed then leaves.
            let left = Locked<[WriteJournalEntry]?>(nil)
            fileSystem.rmImpl = { path, recursive, force in
                guard path.hasPrefix(f.src + "/") else {
                    return try base.rm(path, recursive: recursive, force: force)
                }
                if left.value == nil {
                    left.mutate { $0 = journal.entries }
                }
                throw codedError(.errno(ECANCELED), "ECANCELED: the process was killed")
            }

            _ = try await runPaste(
                mode: .cut, sources: [f.src + "/F"], into: f.dst, fileSystem: fileSystem, writeJournal: journal)

            #expect(Disk.read(f.dst + "/F/a.txt") == "a")
            #expect(Disk.read(f.src + "/F/a.txt") == "a")
            let file = FileWriteJournal.open(f.root + "/replace-journal.json")
            for entry in try #require(left.value) {
                try file.add(entry)
            }
            let report = recoverWrites(file, NativeWriteFileSystem(), logger: RecordingLogger().logger)

            #expect(
                report.notices == [
                    "\u{201C}F\u{201D} was being moved when File Trail stopped. It is in \u{201C}dst\u{201D} now, and what was left of the original is still in \u{201C}src\u{201D}, perhaps not all of it."
                ])
            #expect(file.entries().isEmpty)
        }
    }
}

extension WholeFolderTests {
    // As above, for a folder that replaces one of its name: the Replace's record stays until the originals are gone,
    // and the next start says the folder is in both places.
    @Test func aReplaceByAMoveToAnotherDiskKilledWhileItsOriginalsGoIsToldAtTheNextStart() async throws {
        try await withSafetyFolders { f in
            try Disk.write(f.src + "/F/a.txt", "a")
            try Disk.write(f.dst + "/F/old.txt", "old")
            let fileSystem = NativePaste.asOnAnotherDisk(f.src, f.withTrash())
            let base = fileSystem.base
            let journal = MemoryJournal()
            let left = Locked<[WriteJournalEntry]?>(nil)
            fileSystem.rmImpl = { path, recursive, force in
                guard path.hasPrefix(f.src + "/") else {
                    return try base.rm(path, recursive: recursive, force: force)
                }
                if left.value == nil {
                    left.mutate { $0 = journal.entries }
                }
                throw codedError(.errno(ECANCELED), "ECANCELED: the process was killed")
            }

            _ = try await runPaste(
                mode: .cut, sources: [f.src + "/F"], into: f.dst, policy: NativePaste.replaceAll,
                fileSystem: fileSystem, writeJournal: journal)

            #expect(Disk.read(f.dst + "/F/a.txt") == "a")
            #expect(Disk.read(f.src + "/F/a.txt") == "a")
            let file = FileWriteJournal.open(f.root + "/replace-journal.json")
            for entry in try #require(left.value) {
                try file.add(entry)
            }
            let report = recoverWrites(file, NativeWriteFileSystem(), logger: RecordingLogger().logger)

            #expect(
                report.notices == [
                    "\u{201C}F\u{201D} was being moved when File Trail stopped. It is in \u{201C}dst\u{201D} now, and what was left of the original is still in \u{201C}src\u{201D}, perhaps not all of it."
                ])
            #expect(file.entries().isEmpty)
            // Once the move ends, its record goes.
            #expect(journal.entries.isEmpty)
        }
    }
}

/// A large file being copied: a crash part way would leave the part copied under a hidden name: it is written down
/// first, and let go of once the file has its name, or once the copy failed.
struct LargeFileBeingCopiedTests {
    /// Sparse: as large as that, written in no time.
    private func sparseLargeFile(_ path: String) throws {
        try Disk.write(path, "")
        #expect(truncate(path, off_t(journaledFileBytes)) == 0)
    }

    @Test func isWrittenDownInTheJournalWhileItIsCopied() async throws {
        try await withSafetyFolders { f in
            try sparseLargeFile(f.src + "/movie.mov")
            try Disk.write(f.src + "/small.txt", "small")
            let journal = MemoryJournal()

            let run = try await runPaste(
                mode: .copy, sources: [f.src + "/movie.mov", f.src + "/small.txt"], into: f.dst, writeJournal: journal)

            #expect(run.result?.status == .completed)
            let recorded = journal.writes.compactMap { write -> PartialFileJournalEntry? in
                if case .add(.partialFile(let entry)) = write { return entry }
                return nil
            }
            #expect(recorded.count == 1)
            #expect(journal.writes.count == 2)
            // Under a hidden name next to its place.
            #expect(recorded.first?.partialPath.firstMatch(of: /\/\.movie\.mov\.filetrail-[0-9a-f]{8}$/) != nil)
            #expect(recorded.first?.finalPath == f.dst + "/movie.mov")
            #expect(journal.entries.isEmpty)
            #expect(Disk.list(f.dst) == ["movie.mov", "small.txt"])
        }
    }

    @Test func letsGoOfTheEntryWhenTheCopyFails() async throws {
        try await withSafetyFolders { f in
            try sparseLargeFile(f.src + "/movie.mov")
            let journal = MemoryJournal()
            let fileSystem = TestFileSystem()
            fileSystem.copyFileImpl = { _, _, _, _ in
                throw codedError(.errno(EIO), "EIO: input/output error")
            }

            let run = try await runPaste(
                mode: .copy, sources: [f.src + "/movie.mov"], into: f.dst, fileSystem: fileSystem, writeJournal: journal
            )

            #expect(run.result?.status == .failed)
            #expect(journal.entries.isEmpty)
            #expect(Disk.list(f.dst) == [])
        }
    }
}

/// Files that look like AppleDouble files, and a moved folder that stays.
struct AppleDoubleLookalikeTests {
    private func writeBytes(_ path: String, _ bytes: [UInt8]) throws {
        try Disk.makeDirectories(NodePath.dirname(path))
        try NativeTestFiles.write(path, bytes)
    }

    // On APFS a "._name" file is an ordinary file unless it really is AppleDouble data.
    @Test func copiesADotUnderscoreFileThatIsntAppleDoubleDataAndOneWithoutItsItem() async throws {
        try await withSafetyFolders { f in
            try Disk.write(f.src + "/F/a.txt", "a")
            try Disk.write(f.src + "/F/._a.txt", "just a file")
            try writeBytes(f.src + "/F/._alone", [0x00, 0x05, 0x16, 0x07, 0x00])

            let run = try await runPaste(mode: .copy, sources: [f.src + "/F"], into: f.dst)

            #expect(run.result?.status == .completed)
            #expect(Disk.list(f.dst + "/F") == ["._a.txt", "._alone", "a.txt"])
        }
    }

    // APFS keeps attributes natively, so AppleDouble data in "._a.txt" (left by rsync, tar or a NAS) isn't "a.txt"'s
    // attributes: copying "a.txt" wouldn't carry it.
    @Test func copiesAppleDoubleDataBesideItsItemOnAPFSAndMovesIt() async throws {
        try await withSafetyFolders { f in
            try Disk.write(f.src + "/F/a.txt", "a")
            try writeBytes(f.src + "/F/._a.txt", appleDoubleData)

            let copy = try await runPaste(mode: .copy, sources: [f.src + "/F"], into: f.dst)
            #expect(copy.report.summary.totalNodeCount == 3)
            #expect(Disk.list(f.dst + "/F") == ["._a.txt", "a.txt"])

            try FileManager.default.removeItem(atPath: f.dst + "/F")
            let move = try await runPaste(
                mode: .cut, sources: [f.src + "/F"], into: f.dst, fileSystem: f.withoutRenameAtAll())
            #expect(move.result?.status == .completed)
            #expect(Disk.list(f.dst + "/F") == ["._a.txt", "a.txt"])
            #expect(NativeTestFiles.read(f.dst + "/F/._a.txt") == appleDoubleData)
        }
    }

    // On APFS "._a.txt" is never "a.txt"'s attributes, even when it holds AppleDouble data: one put in the folder
    // while it was being moved stays there, and is named.
    @Test func keepsADotUnderscoreFileAddedToAMovedFolderOnAPFSAndNamesIt() async throws {
        try await withSafetyFolders { f in
            try Disk.write(f.src + "/F/a.txt", "a")

            let run = try await runPaste(
                mode: .cut, sources: [f.src + "/F"], into: f.dst, fileSystem: f.withoutRenameAtAll(),
                beforeExecute: { try self.writeBytes(f.src + "/F/._a.txt", appleDoubleData) })

            #expect(
                run.result?.items.first { $0.sourcePath == f.src + "/F" }?.error
                    == "\u{201C}._a.txt\u{201D} was added to \u{201C}F\u{201D} while it was being moved, so it was left in the original \u{201C}F\u{201D}."
            )
            #expect(Disk.list(f.src + "/F") == ["._a.txt"])
            #expect(Disk.list(f.dst + "/F") == ["a.txt"])
        }
    }

    @Test func namesADotUnderscoreFileAddedToAFolderWhileItWasCopiedOnAPFS() async throws {
        try await withSafetyFolders { f in
            try Disk.write(f.src + "/F/new", "n")

            let run = try await runPaste(
                mode: .copy, sources: [f.src + "/F"], into: f.dst,
                beforeExecute: { try Disk.write(f.src + "/F/._new", "an ordinary file") })

            #expect(
                run.result?.items.first { $0.sourcePath == f.src + "/F" }?.error
                    == "\u{201C}._new\u{201D} was added to \u{201C}F\u{201D} after the copy began, so it wasn't copied."
            )
        }
    }

    // The move empties "F" but for the "._a.txt" the person chose to keep: it isn't cleared away with the folder
    // as if it were "a.txt"'s attributes.
    @Test func keepsADotUnderscoreFileTheMoveSkippedInAFolderItOtherwiseEmptied() async throws {
        try await withSafetyFolders { f in
            try Disk.write(f.src + "/F/a.txt", "a")
            try writeBytes(f.src + "/F/._a.txt", appleDoubleData)
            try Disk.write(f.dst + "/F/._a.txt", "theirs")

            for fileSystem: any WriteServiceFileSystem in [NativeWriteFileSystem(), f.withoutRenameAtAll()] {
                let run = try await runPaste(mode: .cut, sources: [f.src + "/F"], into: f.dst, fileSystem: fileSystem)

                #expect(run.result?.status == .partial)
                #expect(Disk.list(f.src + "/F") == ["._a.txt"])
                #expect(NativeTestFiles.read(f.src + "/F/._a.txt") == appleDoubleData)
                #expect(Disk.read(f.dst + "/F/._a.txt") == "theirs")
                // Back where it started, for the next way of moving it.
                #expect(rename(f.dst + "/F/a.txt", f.src + "/F/a.txt") == 0)
            }
        }
    }

    @Test func keepsFindersViewSettingsInAMovedFolderThatStaysBecauseSomethingInItStayed() async throws {
        try await withSafetyFolders { f in
            try Disk.write(f.src + "/F/a.txt", "new")
            try Disk.write(f.dst + "/F/a.txt", "old")

            _ = try await runPaste(
                mode: .cut, sources: [f.src + "/F"], into: f.dst, fileSystem: f.withoutRenameAtAll(),
                // Finder writes it while the folder is on screen.
                beforeExecute: { try Disk.write(f.src + "/F/.DS_Store", "view") })

            #expect(Disk.list(f.src + "/F") == [".DS_Store", "a.txt"])
        }
    }
}

/// Smaller cases a copy gets right, and a file being copied.
struct SmallerCasesTests {
    @Test func saysAPipeCantBeCopiedInsteadOfBlamingTheDisk() async throws {
        try await withSafetyFolders { f in
            #expect(mkfifo(f.src + "/pipe", 0o644) == 0)

            let run = try await runPaste(mode: .copy, sources: [f.src + "/pipe"], into: f.dst)

            #expect(
                run.result?.items.first?.error
                    == "\u{201C}pipe\u{201D} is a special file (such as a pipe or a socket), which can't be copied.")
        }
    }

    @Test func namesCopiesTheSameWayWhateverOrderTheItemsComeIn() async throws {
        try await withSafetyFolders { f in
            try Disk.write(f.dst + "/a.txt", "a")
            try Disk.write(f.src + "/x/a copy.txt", "other")

            let run = try await runPaste(
                mode: .copy, sources: [f.dst + "/a.txt", f.src + "/x/a copy.txt"], into: f.dst)

            #expect(run.report.issues.isEmpty)
            #expect(run.result?.status == .completed)
            #expect(Disk.list(f.dst) == ["a copy 2.txt", "a copy.txt", "a.txt"])
            #expect(Disk.read(f.dst + "/a copy.txt") == "other")
        }
    }

    // "/d/a.txt" is copied too (it becomes "a copy.txt"), so it isn't there to be replaced.
    @Test func doesntOfferToReplaceAnItemThatIsItselfBeingPasted() async throws {
        try await withSafetyFolders { f in
            try Disk.write(f.dst + "/a.txt", "dst a")
            try Disk.write(f.src + "/x/a.txt", "x a")

            let run = try await runPaste(mode: .copy, sources: [f.src + "/x/a.txt", f.dst + "/a.txt"], into: f.dst)

            let node = run.report.nodes.first { $0.sourcePath == f.src + "/x/a.txt" }
            #expect(node?.replaceBlockedReason == "It is another item being pasted.")
        }
    }

    @Test func checksReplaceInsideAMergedFolderToo() async throws {
        try await withSafetyFolders { f in
            try Disk.write(f.src + "/F/inner/n.txt", "n")
            try Disk.write(f.dst + "/F/inner/keep.txt", "keep")

            let run = try await runPaste(mode: .cut, sources: [f.src + "/F", f.dst + "/F/inner/keep.txt"], into: f.dst)

            let inner = run.report.nodes.first?.children.first { $0.sourcePath.hasSuffix("inner") }
            #expect(inner?.replaceBlockedReason == "It contains another item being pasted.")
        }
    }

    @Test func saysAMovedFolderWasKeptWhenItChangedDuringTheMove() async throws {
        try await withSafetyFolders { f in
            try Disk.write(f.src + "/F/a.txt", "a")

            let run = try await runPaste(
                mode: .cut, sources: [f.src + "/F"], into: f.dst, fileSystem: f.withoutRenameAtAll(),
                beforeExecute: { Disk.chmod(f.src + "/F", 0o700) })

            #expect(
                run.result?.items.first?.error
                    == "Its items were moved, but the original \u{201C}F\u{201D} changed during the move, so it was kept."
            )
            #expect(Disk.list(f.dst + "/F") == ["a.txt"])
        }
    }

    // Quitting or a crash part way must never leave a cut-short file under the real name.
    @Test func isWrittenUnderAHiddenNameAndTakesItsOwnOnlyOnceComplete() async throws {
        try await withSafetyFolders { f in
            try Disk.write(f.src + "/report.pdf", "contents")
            let writtenAs = Recorded<String>()
            let fileSystem = TestFileSystem()
            let base = fileSystem.base
            fileSystem.copyFileImpl = { from, to, stop, progress in
                writtenAs.append(to)
                #expect(!Disk.list(f.dst).contains("report.pdf"))
                try base.copyFile(from, to, stop: stop, onProgress: progress)
            }

            let run = try await runPaste(
                mode: .copy, sources: [f.src + "/report.pdf"], into: f.dst, fileSystem: fileSystem)

            #expect(run.result?.status == .completed)
            #expect(writtenAs.all.count == 1)
            #expect(writtenAs.all.first?.firstMatch(of: /\/dst\/\.report\.pdf\.filetrail-[0-9a-f]+$/) != nil)
            #expect(Disk.list(f.dst) == ["report.pdf"])
            #expect(Disk.read(f.dst + "/report.pdf") == "contents")
        }
    }

    @Test func keepsALockedFilesLockOnceItHasItsName() async throws {
        try await withSafetyFolders { f in
            try Disk.write(f.src + "/locked.txt", "keep")
            Disk.lock(f.src + "/locked.txt")

            let run = try await runPaste(mode: .copy, sources: [f.src + "/locked.txt"], into: f.dst)

            #expect(run.result?.status == .completed)
            #expect(Disk.flags(f.dst + "/locked.txt") & UInt32(UF_IMMUTABLE) != 0)
        }
    }
}
