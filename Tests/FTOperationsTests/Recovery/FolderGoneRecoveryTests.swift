// Entries of the journal whose folder is gone: told from a disk that is away by the disk each entry was written for
import Darwin
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTOperations

struct FolderGoneRecoveryTests {
    /// A disk of the folders in `folders`; everything else isn't there.
    private func lstat(_ folders: Set<String>, failing: Int32 = ENOENT) -> (String) throws -> WriteServiceStats {
        { path in
            guard folders.contains(path) else { throw OperationError("gone: \(path)", code: .errno(failing)) }
            return WriteServiceStats(type: .directory, ino: 1, dev: 1)
        }
    }

    private let hidden = "/Volumes/Stick/Photos/Trip/.a.txt.filetrail-0123abcd"

    @Test func aFolderGoneFromItsOwnDiskIsGoneForGood() {
        let disk: (String) -> String? = { $0.hasPrefix("/Volumes/Stick") ? "stick-1" : "startup" }
        // "Trip" is gone, "Photos" is there, on the disk the entry was written for.
        let there = lstat(["/", "/Volumes", "/Volumes/Stick", "/Volumes/Stick/Photos"])
        #expect(folderIsGoneForGood(there, hidden, disk: "stick-1", disk))
        // The item's own folder is there: only the item is gone from it, which is another matter.
        let whole = lstat(["/", "/Volumes", "/Volumes/Stick", "/Volumes/Stick/Photos", "/Volumes/Stick/Photos/Trip"])
        #expect(!folderIsGoneForGood(whole, hidden, disk: "stick-1", disk))
    }

    @Test func aDiskThatIsAwayOrAnotherOfItsNameOrUnknownIsNot() {
        let disk: (String) -> String? = { $0.hasPrefix("/Volumes/Stick") ? "stick-2" : "startup" }
        // The disk isn't connected: the nearest folder still there is on the startup disk.
        #expect(!folderIsGoneForGood(lstat(["/", "/Volumes"]), hidden, disk: "stick-1", disk))
        // Another disk of the same name is in its place.
        #expect(!folderIsGoneForGood(lstat(["/", "/Volumes", "/Volumes/Stick"]), hidden, disk: "stick-1", disk))
        // An entry from before the disk was kept, or a disk that has no id.
        #expect(!folderIsGoneForGood(lstat(["/", "/Volumes", "/Volumes/Stick"]), hidden, disk: nil, disk))
        #expect(!folderIsGoneForGood(lstat(["/", "/Volumes", "/Volumes/Stick"]), hidden, disk: "stick-2") { _ in nil })
        // A disk that can't be read says nothing.
        let unreadable = lstat(["/", "/Volumes", "/Volumes/Stick"], failing: EIO)
        #expect(!folderIsGoneForGood(unreadable, hidden, disk: "stick-2", disk))
    }

    @Test func theAppsJournalWritesEachEntrysDiskAndKeepsItWhenTheEntryIsAddedAgain() throws {
        try withTemporaryDirectory(prefix: "journal-disk") { root in
            let path = root.path + "/journal.json"
            let asked = Locked<[String]>([])
            let journal = FileWriteJournal.open(path) { folder in
                asked.mutate { $0.append(folder) }
                return "disk-of-\(NodePath.basename(folder))"
            }
            var replace = ReplaceJournalEntry(
                id: "r", stagingPath: "/a/dst/.x.filetrail-00000000", finalPath: "/a/dst/x", sourcePath: "/a/src/x",
                moved: true, staged: false)
            try journal.add(.replace(replace))
            replace.staged = true
            try journal.addFlushed(.replace(replace))
            try journal.add(
                .partialFile(.init(id: "p", partialPath: "/b/big/.y.filetrail-00000000", finalPath: "/b/big/y")))
            try journal.add(
                .batchRename(
                    .init(
                        id: "b",
                        items: [
                            .init(
                                temporaryPath: "/c/pics/.filetrail-rename-000000000000", originalPath: "/c/pics/1",
                                newPath: "/c/pics/2")
                        ])))
            // Read once for each entry.
            #expect(asked.value == ["/a/dst", "/b/big", "/c/pics"])
            let read = FileWriteJournal.open(path).entries()
            #expect(read.map(\.disk) == ["disk-of-dst", "disk-of-big", "disk-of-pics"])
            replace.disk = "disk-of-dst"
            #expect(read.first == .replace(replace))
            // A journal that doesn't keep the disk, and a file written before it was kept.
            let plain = FileWriteJournal.open(root.path + "/plain.json")
            replace.disk = nil
            try plain.add(.replace(replace))
            #expect(FileWriteJournal.open(root.path + "/plain.json").entries() == [.replace(replace)])
            #expect(try String(contentsOfFile: root.path + "/plain.json", encoding: .utf8).contains("disk") == false)
        }
    }

    // A crash left a moved item under its hidden name; its folder was then removed. The disk is right there, so
    // nothing waits for it: the entry goes, with one notice, instead of asking for the disk at every start.
    @Test func letsGoOfEntriesWhoseFolderIsGoneFromADiskThatIsConnected() throws {
        try withTemporaryDirectory(prefix: "folder-gone") { root in
            let journal = FileWriteJournal.open(root.path + "/journal.json")
            let disk = try #require(NativeFS.diskId(of: root.path))
            let gone = root.path + "/removed-folder"
            let hidden = gone + "/.a.txt.filetrail-0123abcd"
            try journal.add(
                .replace(
                    .init(
                        id: "moved", stagingPath: hidden, finalPath: gone + "/a.txt",
                        sourcePath: root.path + "/src/a.txt", moved: true, staged: true, disk: disk)))
            try journal.add(
                .replace(
                    .init(
                        id: "copied", stagingPath: gone + "/.b.txt.filetrail-0123abcd", finalPath: gone + "/b.txt",
                        sourcePath: root.path + "/src/b.txt", moved: false, staged: false, disk: disk)))
            try journal.add(
                .partialFile(
                    .init(
                        id: "part", partialPath: gone + "/.c.bin.filetrail-0123abcd", finalPath: gone + "/c.bin",
                        disk: disk)))
            try journal.add(
                .batchRename(
                    .init(
                        id: "batch",
                        items: [
                            .init(
                                temporaryPath: gone + "/.filetrail-rename-0123456789ab", originalPath: gone + "/1",
                                newPath: gone + "/2")
                        ], disk: disk)))
            // The same, written before the disk was kept: it may be a disk that is away, and stays.
            try journal.add(
                .replace(
                    .init(
                        id: "old", stagingPath: gone + "/.d.txt.filetrail-0123abcd", finalPath: gone + "/d.txt",
                        sourcePath: root.path + "/src/d.txt", moved: true, staged: true)))

            let report = recoverWrites(journal, NativeWriteFileSystem(), logger: RecordingLogger().logger)

            #expect(journal.entries().map(\.id) == ["old"])
            #expect(report.notices.count == 2)
            #expect(
                report.notices.contains(
                    "“a.txt” was being moved into “removed-folder” when File Trail stopped, and that folder is no longer where it was. If the folder was moved or renamed, “a.txt” is in it under the hidden name “.a.txt.filetrail-0123abcd”."
                ))
            // The next start says nothing more of them.
            let again = recoverWrites(journal, NativeWriteFileSystem(), logger: RecordingLogger().logger)
            #expect(again.notices.count == 1)
            #expect(journal.entries().map(\.id) == ["old"])
        }
    }
}
