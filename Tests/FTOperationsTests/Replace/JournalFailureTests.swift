// A Replace of a folder, and a large file, whose journal can't be written: nothing of what was there is lost, and no
// hidden copy is left without a record
import FTTestSupport
import Foundation
import Testing
import os

@testable import FTOperations

struct JournalFailureTests {
    private func withPlaces(
        _ body: (_ src: String, _ dst: String, _ trash: String) async throws -> Void
    ) async throws {
        try await withTemporaryDirectory { root in
            let (src, dst, trash) = (root.path + "/src", root.path + "/dst", root.path + "/trash")
            for folder in [src, dst, trash] {
                try Disk.makeDirectories(folder)
            }
            try await body(src, dst, trash)
        }
    }

    /// A folder F pasted over the F already in `dst`, which holds old.txt.
    private func folders(_ src: String, _ dst: String) throws {
        try Disk.write(src + "/F/a.txt", "new a")
        try Disk.write(src + "/F/b.txt", "new b")
        try Disk.write(dst + "/F/old.txt", "old")
    }

    private func replaceFolder(_ src: String, _ dst: String, _ trash: String, _ journal: MemoryJournal) async throws
        -> PasteRun
    {
        try await runPaste(
            mode: .copy, sources: [src + "/F"], into: dst, policy: NativePaste.replaceAll,
            fileSystem: NativePaste.withTrash(trash), writeJournal: journal)
    }

    private static let full = OperationError("The disk is full.")

    // The record of the hidden folder can't be made: the hidden folder goes, and the old one stays.
    @Test func aFolderWhoseHiddenCopyCantBeWrittenDownIsNotReplaced() async throws {
        try await withPlaces { src, dst, trash in
            try folders(src, dst)
            let journal = MemoryJournal(failOn: { write in
                if case .add(.replace) = write { return Self.full }
                return nil
            })

            let run = try await replaceFolder(src, dst, trash, journal)

            #expect(run.result?.status == .failed)
            #expect(Disk.list(dst) == ["F"])
            #expect(Disk.list(dst + "/F") == ["old.txt"])
            #expect(Disk.read(dst + "/F/old.txt") == "old")
            #expect(Disk.list(trash) == [])
            #expect(journal.entries.isEmpty)
        }
    }

    // The hidden folder is whole but that can't be written down: it is written down as not whole again, removed,
    // and its record goes; the old folder stays.
    @Test func aFolderWhoseCompleteCopyCantBeWrittenDownIsTakenBack() async throws {
        try await withPlaces { src, dst, trash in
            try folders(src, dst)
            let journal = MemoryJournal(failOn: { write in
                if case .add(.replace(let entry)) = write, entry.staged { return Self.full }
                return nil
            })

            let run = try await replaceFolder(src, dst, trash, journal)

            #expect(run.result?.status == .failed)
            #expect(Disk.list(dst) == ["F"])
            #expect(Disk.read(dst + "/F/old.txt") == "old")
            #expect(Disk.list(trash) == [])
            #expect(journal.entries.isEmpty)
        }
    }

    // Once the hidden folder is whole nothing more can be written down: it is left whole, with its record, for the
    // next start; the old folder stays where it was.
    @Test func aFolderWhoseRecordCantBeChangedOnceWholeIsLeftForTheNextStart() async throws {
        try await withPlaces { src, dst, trash in
            try folders(src, dst)
            let added = OSAllocatedUnfairLock(initialState: 0)
            let journal = MemoryJournal(failOn: { write in
                guard case .add(.replace) = write else { return nil }
                return added.withLock { count in
                    count += 1
                    return count > 1 ? Self.full : nil
                }
            })

            let run = try await replaceFolder(src, dst, trash, journal)

            #expect(run.result?.status == .failed)
            #expect(Disk.read(dst + "/F/old.txt") == "old")
            #expect(Disk.list(trash) == [])
            let hidden = Disk.list(dst).filter { $0 != "F" }
            #expect(hidden.count == 1)
            let staging = dst + "/" + (hidden.first ?? "")
            #expect(Disk.list(staging) == ["a.txt", "b.txt"])
            guard case .replace(let entry)? = journal.entries.first, journal.entries.count == 1 else {
                Issue.record("the hidden folder has no record: \(journal.entries)")
                return
            }
            #expect(entry.stagingPath == staging)
            #expect(entry.finalPath == dst + "/F")
        }
    }

    // A file large enough to be written down before it is copied, whose record can't be made: nothing is copied,
    // and no part is left under a hidden name.
    @Test func aLargeFileWhosePartCantBeWrittenDownIsNotCopied() async throws {
        try await withPlaces { src, dst, trash in
            let big = src + "/big.bin"
            #expect(FileManager.default.createFile(atPath: big, contents: nil))
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: big))
            try handle.truncate(atOffset: UInt64(journaledFileBytes) + 1)
            try handle.close()
            let journal = MemoryJournal(failOn: { write in
                if case .add(.partialFile) = write { return Self.full }
                return nil
            })

            let run = try await runPaste(
                mode: .copy, sources: [big], into: dst, fileSystem: NativePaste.withTrash(trash),
                writeJournal: journal)

            #expect(run.result?.status == .failed)
            #expect(Disk.list(dst) == [])
            #expect(Disk.exists(big))
            #expect(journal.entries.isEmpty)
        }
    }
}
