// Undo on test disk images, for what the startup disk can't show: the Trash of another disk (its own .Trashes folder),
// and disks that tell names apart by case or don't
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTOperations

@MainActor
@Suite(.serialized, .tags(.diskImage), .diskImages, .localOperationHang)
struct UndoRealDiskTests {
    /// The coordinator as the app runs it on a disk image: the real Trash, the home folder elsewhere.
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

    @Test func putsAnItemBackFromItsDisksOwnTrash() async throws {
        try await onDisk(.apfs) { t, disk in
            TrashProbe.touch()
            try UndoDisk.write("\(disk)/a.txt", "a")
            let trashed = try await t.trash("\(disk)/a.txt")
            // Fails whenever the Trash can't move the item; then says whether the Mac gave the disk a volume
            // reference at all (see TrashProbe.volumeReference).
            try #require(
                trashed.status == .completed,
                Comment(rawValue: "\(trashed.result?.error ?? ""): \(TrashProbe.volumeReferenceReport(of: disk))"))
            #expect(!UndoDisk.names(disk).contains("a.txt"))
            #expect(try await t.undo().status == .completed)
            #expect(try UndoDisk.read("\(disk)/a.txt") == "a")
            #expect(try await t.undo(.redo).status == .completed)
            #expect(!UndoDisk.names(disk).contains("a.txt"))
        }
    }

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

    // "Notes.txt" replaces "notes.txt", the same name on this disk: Undo puts the old item back as "notes.txt", and
    // Redo brings the new one back as "Notes.txt".
    @Test func putsAReplacedItemBackUnderItsOwnNameOnADiskThatIgnoresCase() async throws {
        try await onDisk(.apfs) { t, disk in
            try UndoDisk.mkdir("\(disk)/src")
            try UndoDisk.mkdir("\(disk)/dst")
            try UndoDisk.write("\(disk)/src/Notes.txt", "new")
            try UndoDisk.write("\(disk)/dst/notes.txt", "old")
            let pasteTrash = "\(disk)/paste-trash"
            try UndoDisk.mkdir(pasteTrash)
            try await t.paste(
                .cut, ["\(disk)/src/Notes.txt"], into: "\(disk)/dst", policy: NativePaste.replaceAll,
                fileSystem: NativePaste.withTrash(pasteTrash))
            #expect(visible("\(disk)/dst") == ["Notes.txt"])

            #expect(try await t.undo().status == .completed)
            #expect(visible("\(disk)/dst") == ["notes.txt"])
            #expect(try UndoDisk.read("\(disk)/dst/notes.txt") == "old")
            #expect(visible("\(disk)/src") == ["Notes.txt"])

            #expect(try await t.undo(.redo).status == .completed)
            #expect(visible("\(disk)/dst") == ["Notes.txt"])
            #expect(try UndoDisk.read("\(disk)/dst/Notes.txt") == "new")
        }
    }

    // On a disk that minds case "Notes.txt" and "notes.txt" are two names: the paste replaces nothing, and Undo takes
    // back only the item it moved.
    @Test func replacesNothingSpelledOtherwiseOnADiskThatMindsCase() async throws {
        try await onDisk(.apfsCaseSensitive) { t, disk in
            try UndoDisk.mkdir("\(disk)/src")
            try UndoDisk.mkdir("\(disk)/dst")
            try UndoDisk.write("\(disk)/src/Notes.txt", "new")
            try UndoDisk.write("\(disk)/dst/notes.txt", "old")
            let pasteTrash = "\(disk)/paste-trash"
            try UndoDisk.mkdir(pasteTrash)
            try await t.paste(
                .cut, ["\(disk)/src/Notes.txt"], into: "\(disk)/dst", policy: NativePaste.replaceAll,
                fileSystem: NativePaste.withTrash(pasteTrash))
            #expect(visible("\(disk)/dst") == ["Notes.txt", "notes.txt"])
            #expect(visible(pasteTrash).isEmpty)

            #expect(try await t.undo().status == .completed)
            #expect(visible("\(disk)/dst") == ["notes.txt"])
            #expect(try UndoDisk.read("\(disk)/dst/notes.txt") == "old")
            #expect(visible("\(disk)/src") == ["Notes.txt"])
        }
    }

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
