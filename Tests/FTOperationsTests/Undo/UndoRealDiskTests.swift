// Port of apps/desktop/src/main/bootstrap/undo.realfs.test.ts: Undo on test disk images, for what the startup disk
// can't show: the Trash of another disk (its own .Trashes folder), and disks that tell names apart by case or don't
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTOperations

@MainActor
@Suite(.serialized, .tags(.diskImage), .diskImages, .localOperationHang)
struct UndoRealDiskTests {
    /// `setUpOn`: the coordinator as the app runs it on a disk image: the real Trash, the home folder elsewhere.
    private func onDisk(_ kind: DiskImage.Kind, _ body: @MainActor (UndoTest, String) async throws -> Void)
        async throws
    {
        try await withUndoFolder { home, trashDir in
            try await DiskImage.withVolume(kind) { volume in
                let trashItem = TrashItem.live(homePath: home)
                let t = UndoTest(root: home, trashDir: trashDir) { fileSystem in
                    fileSystem.trashImpl = { try trashItem($0) }
                }
                try await body(t, volume.path)
                await t.shutDown()
            }
        }
    }

    private func visible(_ folder: String) -> [String] {
        UndoDisk.names(folder).filter { !$0.hasPrefix(".") }
    }

    // T-472f5dcc F-561
    @Test func putsAnItemBackFromItsDisksOwnTrash() async throws {
        try await onDisk(.apfs) { t, disk in
            // Some Macs' Trash refuses a disk image attached by a test ("doesn't exist"; NativeTrashTests sees it too):
            // nothing can be shown there.
            try UndoDisk.write("\(disk)/probe.txt", "probe")
            if (try? NativeFS.trashItem("\(disk)/probe.txt")) == nil {
                withKnownIssue("The Trash can't reach a test disk image on this Mac") {
                    Issue.record("The Trash refused \(disk)/probe.txt")
                }
                return
            }
            try UndoDisk.write("\(disk)/a.txt", "a")
            let trashed = try await t.trash("\(disk)/a.txt")
            #expect(trashed.status == .completed, Comment(rawValue: trashed.result?.error ?? ""))
            #expect(!UndoDisk.names(disk).contains("a.txt"))
            #expect(try await t.undo().status == .completed)
            #expect(try UndoDisk.read("\(disk)/a.txt") == "a")
            #expect(try await t.undo(.redo).status == .completed)
            #expect(!UndoDisk.names(disk).contains("a.txt"))
        }
    }

    // T-bf74e8a4 F-561
    @Test func renamesBackANameThatDiffersOnlyInCaseOnADiskThatIgnoresCase() async throws {
        try await onDisk(.apfs) { t, disk in
            try UndoDisk.write("\(disk)/notes.txt", "n")
            try await t.rename("\(disk)/notes.txt", "Notes.txt")
            #expect(UndoDisk.names(disk).contains("Notes.txt"))
            #expect(try await t.prepare().nameTaken.isEmpty)
            #expect(try await t.undo().status == .completed)
            #expect(visible(disk) == ["notes.txt"])
        }
    }

    // T-5874f7d2 F-561
    @Test func keepsBothOnlyWhenTheVeryNameIsTakenOnADiskThatMindsCase() async throws {
        try await onDisk(.apfsCaseSensitive) { t, disk in
            try UndoDisk.write("\(disk)/a.txt", "a")
            try UndoDisk.write("\(disk)/b.txt", "b")
            try await t.rename("\(disk)/a.txt", "x.txt")
            try await t.rename("\(disk)/b.txt", "y.txt")
            // "A.txt" is another name here; "b.txt" is the very one.
            try UndoDisk.write("\(disk)/A.txt", "someone else's A")
            try UndoDisk.write("\(disk)/b.txt", "someone else's b")
            #expect(try await t.prepare().nameTaken == ["b.txt"])
            try await t.undo()
            #expect(try UndoDisk.read("\(disk)/b 2.txt") == "b")
            #expect(try await t.prepare().nameTaken.isEmpty)
            try await t.undo()
            #expect(try UndoDisk.read("\(disk)/a.txt") == "a")
            #expect(try UndoDisk.read("\(disk)/A.txt") == "someone else's A")
        }
    }
}
