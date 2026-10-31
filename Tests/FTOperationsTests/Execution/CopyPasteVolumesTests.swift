// Port of packages/core/src/fs/copyPasteVolumes.realfs.test.ts, but for the cases that Replace (P3-04's): pastes
// between two disks, so a move there copies and then removes the originals, as it does to a USB drive. A disk image
// is the other disk where the case rule or the file system matters; a folder that seems to be on a disk of its own
// is enough for the moves
import Darwin
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTOperations

/// Names a test made; a disk's own hidden folders (.fseventsd, .Trashes) are left out.
private func visible(_ folder: String) -> [String] {
    Disk.list(folder).filter { !$0.hasPrefix(".") }
}

struct CopyPasteVolumesTests {
    /// A source folder that seems to be on a disk of its own (another device number, EXDEV out of it), and a
    /// destination beside it: a move between them copies and then removes the originals, as one to a real other
    /// disk does. The engine tells disks apart by device number alone.
    private func withOtherDisk(
        _ body: (_ source: String, _ destination: String, _ fileSystem: TestFileSystem) async throws -> Void
    ) async throws {
        try await withTemporaryDirectory { root in
            let (source, destination) = (root.path + "/src", root.path + "/dst")
            try Disk.makeDirectories(source)
            try Disk.makeDirectories(destination)
            try await body(source, destination, NativePaste.asOnAnotherDisk(source))
        }
    }

    // T-9e45f62e F-467
    @Test func movesAFileCopiedThereThenTheOriginalRemoved() async throws {
        try await withOtherDisk { source, destination, fileSystem in
            try Disk.write(source + "/a.txt", "a")

            let run = try await runPaste(
                mode: .cut, sources: [source + "/a.txt"], into: destination, fileSystem: fileSystem)

            #expect(run.result?.status == .completed)
            #expect(Disk.read(destination + "/a.txt") == "a")
            #expect(visible(source) == [])
        }
    }

    // T-9a785996 F-467
    @Test func movesAFolderWithEverythingInIt() async throws {
        try await withOtherDisk { source, destination, fileSystem in
            try Disk.write(source + "/Docs/a.txt", "a")
            try Disk.write(source + "/Docs/Nested/b.txt", "b")

            let run = try await runPaste(
                mode: .cut, sources: [source + "/Docs"], into: destination, fileSystem: fileSystem)

            #expect(run.result?.status == .completed)
            #expect(Disk.read(destination + "/Docs/Nested/b.txt") == "b")
            #expect(visible(source) == [])
        }
    }

    // T-86ed4168 F-286 F-467
    @Test func saysSoWhenItemsWereAddedToAFolderWhileItWasBeingMoved() async throws {
        try await withOtherDisk { source, destination, fileSystem in
            try Disk.write(source + "/Docs/a.txt", "a")

            let run = try await runPaste(
                mode: .cut, sources: [source + "/Docs"], into: destination, fileSystem: fileSystem,
                beforeExecute: { try Disk.write(source + "/Docs/late.txt", "late") })

            #expect(run.result?.status != .completed)
            let first = run.result?.items.first
            #expect(first?.sourcePath == source + "/Docs")
            #expect(first?.status == .failed)
            #expect(
                first?.error
                    == "\u{201C}late.txt\u{201D} was added to \u{201C}Docs\u{201D} while it was being moved, so it was left in the original \u{201C}Docs\u{201D}."
            )
            #expect(Disk.read(destination + "/Docs/a.txt") == "a")
            #expect(visible(source + "/Docs") == ["late.txt"])
        }
    }

    // T-9e513fd2 F-286 F-467
    @Test func removesTheMovedFolderWhenFinderOnlyWroteItsDSStoreIntoIt() async throws {
        try await withOtherDisk { source, destination, fileSystem in
            try Disk.write(source + "/Docs/a.txt", "a")

            let run = try await runPaste(
                mode: .cut, sources: [source + "/Docs"], into: destination, fileSystem: fileSystem,
                beforeExecute: { try Disk.write(source + "/Docs/.DS_Store", "view settings") })

            #expect(run.result?.status == .completed)
            #expect(!Disk.exists(source + "/Docs"))
        }
    }

    // On the startup disk "A.txt" and "a.txt" are one name: one would replace the other, and after a move its
    // original would be gone. The review stops the paste instead.
    // T-86f085a0 F-470
    @Test(.tags(.diskImage), .diskImages)
    func stopsBeforePastingAFolderHoldingTwoItemsWhoseNamesDifferOnlyInCase() async throws {
        try await withTemporaryDirectory { root in
            try await DiskImage.withSharedVolume(.apfsCaseSensitive) { volume in
                let folder = volume.path + "/F"
                try Disk.write(folder + "/A.txt", "upper")
                try Disk.write(folder + "/a.txt", "lower")

                let run = try await runPaste(mode: .cut, sources: [folder], into: root.path)

                #expect(run.report.issues.map(\.code) == [.duplicateDestinationName])
                #expect(run.report.issues.first?.sourcePath == folder + "/a.txt")
                #expect(run.report.issues.first?.destinationPath == root.path + "/F/a.txt")
                #expect(run.result == nil)
                #expect(visible(folder) == ["A.txt", "a.txt"])
                #expect(visible(root.path) == [])
            }
        }
    }

    // T-76cb8bae F-470
    @Test(.tags(.diskImage), .diskImages)
    func pastesACaseSensitiveFolderWhoseNamesStayApart() async throws {
        try await withTemporaryDirectory { root in
            try await DiskImage.withSharedVolume(.apfsCaseSensitive) { volume in
                let folder = volume.path + "/F"
                try Disk.write(folder + "/A.txt", "upper")
                try Disk.write(folder + "/b.txt", "b")

                let run = try await runPaste(mode: .copy, sources: [folder], into: root.path)

                #expect(run.report.issues.isEmpty)
                #expect(run.result?.status == .completed)
                #expect(visible(root.path + "/F") == ["A.txt", "b.txt"])
            }
        }
    }

    // The copy used to retry the failed write forever, so the paste never ended. The disk (32 MB, as the
    // original's) is filled first, so the copy's first write fails; the source is still larger than the whole
    // disk, so it can't fit whatever APFS gives back after the fill.
    // T-0e57438e F-471
    @Test(.tags(.diskImage), .diskImages, .enabled(if: LargeFileTests.enabled))
    func failsAMoveWithTheReasonKeepsTheOriginalAndLeavesNoPartialFile() async throws {
        try await withTemporaryDirectory { root in
            try await DiskImage.withVolume(.apfsSmall) { volume in
                let source = root.path + "/src/big.bin"
                try Disk.makeDirectories(root.path + "/src")
                try NativeTestFiles.makeFile(
                    source, megabytes: NativeTestFiles.totalBytes(volume.path) / (1024 * 1024) + 2)
                let destination = volume.path + "/target"
                try Disk.makeDirectories(destination)
                let full = volume.path + "/full"
                try Disk.makeDirectories(full)
                try NativeTestFiles.fillDisk(full)

                let run = try await runPaste(mode: .cut, sources: [source], into: destination)

                #expect(run.result?.status == .failed)
                #expect(run.result?.items.first?.error == "There isn't enough free space on the destination disk.")
                #expect(visible(root.path + "/src") == ["big.bin"])
                #expect(Disk.list(destination) == [])
            }
        }
    }
}

// FAT32 and exFAT give empty files ids near 2^64, which all round to one JS number: every empty file looked like
// the same item, so pastes were refused as "already there".
struct EmptyFilesOnFATTests {
    // T-960f8f4b F-472
    @Test(.tags(.diskImage), .diskImages, arguments: [DiskImage.Kind.fat32, .exfat])
    func asksAboutAnEmptyFileOfTheSameNameInsteadOfRefusing(kind: DiskImage.Kind) async throws {
        try await DiskImage.withSharedVolume(kind) { stick in
            try Disk.write(stick.path + "/d1/empty.txt", "")
            try Disk.write(stick.path + "/d2/empty.txt", "")

            let run = try await runPaste(mode: .copy, sources: [stick.path + "/d1/empty.txt"], into: stick.path + "/d2")

            #expect(run.report.issues.isEmpty)
            #expect(run.report.nodes.first?.conflictClass == .fileConflict)
        }
    }

    // T-14350ea9 F-472
    @Test(.tags(.diskImage), .diskImages, arguments: [DiskImage.Kind.fat32, .exfat])
    func movesAnEmptyFileIntoAFolderHoldingOtherEmptyFiles(kind: DiskImage.Kind) async throws {
        try await DiskImage.withSharedVolume(kind) { stick in
            try Disk.write(stick.path + "/d1/a.txt", "")
            try Disk.write(stick.path + "/d2/b.txt", "")

            let run = try await runPaste(mode: .cut, sources: [stick.path + "/d1/a.txt"], into: stick.path + "/d2")

            #expect(run.result?.status == .completed)
            #expect(visible(stick.path + "/d2") == ["a.txt", "b.txt"])
        }
    }

    // FAT, exFAT and SMB keep an item's extended attributes in a "._name" file beside it.
    // T-239428cb F-473
    @Test(.tags(.diskImage), .diskImages)
    func copiesAnItemWithItsAttributesAndNotItsAppleDoubleFileAsAnItem() async throws {
        try await withTemporaryDirectory { root in
            try await DiskImage.withSharedVolume(.fat32) { stick in
                let folder = stick.path + "/pkg"
                try Disk.write(folder + "/a.py", "print()")
                try Attributes.write(folder + "/a.py", "com.filetrail.test", "kept")
                #expect(Disk.list(folder).contains("._a.py"))

                let run = try await runPaste(mode: .copy, sources: [folder], into: root.path)

                #expect(run.report.summary.totalNodeCount == 2)
                #expect(run.result?.status == .completed)
                #expect(Disk.list(root.path + "/pkg") == ["a.py"])
                #expect(Attributes.read(root.path + "/pkg/a.py", "com.filetrail.test") == "kept")
            }
        }
    }
}
