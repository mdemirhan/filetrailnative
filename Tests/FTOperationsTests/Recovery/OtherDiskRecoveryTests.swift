// Entries of the journal whose hidden item's folder is now on another disk than the one they were written for: a
// second disk of the same name, or a folder left where the disk was mounted. The item may still be on its own disk.
import Darwin
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTOperations

struct OtherDiskRecoveryTests {
    /// A second stick named as the first, with something of its own on it and nothing of the entry's.
    private func secondStick() -> MockWriteServiceFileSystem {
        MockWriteServiceFileSystem([("/Volumes/NO NAME/keep.txt", .file(size: 1))])
    }

    private func options(_ disk: String?) -> RecoveryOptions {
        RecoveryOptions(diskId: { _ in disk })
    }

    private func moved(disk: String?) -> ReplaceJournalEntry {
        ReplaceJournalEntry(
            id: "1", stagingPath: "/Volumes/NO NAME/.x.filetrail-0000abcd", finalPath: "/Volumes/NO NAME/x",
            sourcePath: "/Volumes/NO NAME/src/x", moved: true, staged: true, disk: disk)
    }

    // A Replace cut short on one stick, its item under the hidden name there; then a second stick of the same name
    // is connected. Nothing of the entry is on it, and the entry stays: the item is still on the first.
    @Test func aMovedItemNotFoundOnAnotherDiskOfTheSameNameStaysWrittenDown() {
        let entry = moved(disk: "stick-1")

        let outcomes = recoverInterruptedReplaces([entry], secondStick(), options("stick-2"))

        #expect(
            outcomes == [
                ReplaceRecovery(entry: entry, outcome: .unreachable(error: "The disk of “x” isn’t connected."))
            ])
    }

    // On the disk the entry was written for, an item no longer under its hidden name is done with, as it is when
    // either disk isn't known: an entry from before the disk was kept, a disk that has no id.
    @Test func aMovedItemNotFoundOnItsOwnDiskOrOnADiskNotKnownIsDoneWith() {
        for (written, found) in [("stick-1", "stick-1"), (nil, "stick-2"), ("stick-1", nil)] as [(String?, String?)] {
            let entry = moved(disk: written)

            let outcomes = recoverInterruptedReplaces([entry], secondStick(), options(found))

            #expect(
                outcomes == [ReplaceRecovery(entry: entry, outcome: .nothingLeft)],
                "written for \(written ?? "no disk"), found on \(found ?? "no disk")")
        }
    }

    // The part of a large file, the same way: not found on another disk, it may still be on its own.
    @Test func aPartialFileNotFoundOnAnotherDiskOfTheSameNameStaysWrittenDown() {
        var entry = PartialFileJournalEntry(
            id: "1", partialPath: "/Volumes/NO NAME/.big.mov.filetrail-0000abcd",
            finalPath: "/Volumes/NO NAME/big.mov", disk: "stick-1")

        let other = recoverPartialFiles([entry], secondStick(), options("stick-2"))
        let own = recoverPartialFiles([entry], secondStick(), options("stick-1"))
        entry.disk = nil
        let unknown = recoverPartialFiles([entry], secondStick(), options("stick-2"))

        #expect(other.map(\.outcome) == [.unreachable(error: "The disk of “big.mov” isn’t connected.")])
        #expect(own.map(\.outcome) == [.nothingLeft])
        #expect(unknown.map(\.outcome) == [.nothingLeft])
    }

    // Through the journal, on a real folder: entries written for another disk than the one their folder is on now
    // stay, the moved item is told of once at start, and a later try says nothing more.
    @Test func entriesWrittenForAnotherDiskStayInTheJournalAndAreToldOfAtStartOnly() throws {
        try withTemporaryDirectory(prefix: "other-disk") { root in
            // The journal as it was when the entries were written: another disk was at the folder then.
            let journal = FileWriteJournal.open(root.path + "/journal.json") { _ in "the-disk-there-before" }
            let folder = root.path + "/stick"
            try Disk.write(folder + "/keep.txt", "its own")
            try journal.add(
                .replace(
                    .init(
                        id: "moved", stagingPath: folder + "/.a.txt.filetrail-0123abcd", finalPath: folder + "/a.txt",
                        sourcePath: folder + "/src/a.txt", moved: true, staged: true)))
            try journal.add(
                .partialFile(
                    .init(
                        id: "part", partialPath: folder + "/.c.bin.filetrail-0123abcd", finalPath: folder + "/c.bin")))
            try journal.add(
                .batchRename(
                    .init(
                        id: "batch",
                        items: [
                            .init(
                                temporaryPath: folder + "/.filetrail-rename-0123456789ab",
                                originalPath: folder + "/1", newPath: folder + "/2")
                        ])))

            let atStart = recoverWrites(journal, NativeWriteFileSystem(), logger: RecordingLogger().logger)
            let later = recoverWrites(journal, NativeWriteFileSystem(), logger: RecordingLogger().logger, retry: true)

            #expect(journal.entries().map(\.id) == ["moved", "part", "batch"])
            #expect(journal.entries().map(\.disk) == Array(repeating: "the-disk-there-before", count: 3))
            #expect(
                atStart.notices == [
                    "“a.txt” was being moved onto “stick”, which isn’t connected. Connect it and File Trail puts “a.txt” in place; until then it is under the hidden name “.a.txt.filetrail-0123abcd” there."
                ])
            #expect(later == RecoveryReport())
            #expect(Disk.list(folder) == ["keep.txt"])
        }
    }
}
