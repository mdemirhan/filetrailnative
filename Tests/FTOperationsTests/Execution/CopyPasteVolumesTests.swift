// Pastes between two disks, so a move there copies and then removes the originals, as it does to a USB drive. A disk
// image is the other disk where the case rule or the file system matters; a folder that seems to be on a disk of its
// own is enough for the moves
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

    // The copy used to retry the failed write forever, so the paste never ended. The disk (32 MB) is filled
    // first, so the copy's first write fails; the source is still larger than the whole disk, so it can't fit
    // whatever APFS gives back after the fill.
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

// FAT32 and exFAT give empty files ids near 2^64, which all round to one double: every empty file looked like
// the same item, so pastes were refused as "already there".
struct EmptyFilesOnFATTests {
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

    // With hidden files shown, Select All picks an item's "._name" file with it. Moved as an item of its own, before
    // the item, it would take the item's attributes away from it.
    @Test(.tags(.diskImage), .diskImages, arguments: [CopyPasteMode.cut, .copy])
    func movesAnItemPickedWithItsAppleDoubleFileWithItsAttributes(mode: CopyPasteMode) async throws {
        try await withTemporaryDirectory { root in
            try await DiskImage.withSharedVolume(.exfat) { stick in
                try Disk.write(stick.path + "/foo.txt", "foo")
                try Disk.write(stick.path + "/bar.txt", "bar")
                try Attributes.write(stick.path + "/foo.txt", "com.filetrail.test", "kept")
                try Attributes.write(stick.path + "/bar.txt", "com.filetrail.test", "too")
                // A "._" file with no item beside it is an item like any other.
                try Disk.write(stick.path + "/._alone", "someone's")
                let picked = ["._alone", "._bar.txt", "._foo.txt", "bar.txt", "foo.txt"]
                #expect(Disk.list(stick.path).filter { !$0.hasPrefix(".") || $0.hasPrefix("._") } == picked)

                let run = try await runPaste(
                    mode: mode, sources: picked.map { stick.path + "/" + $0 }, into: root.path)

                #expect(run.report.summary.totalNodeCount == 3)
                #expect(run.result?.status == .completed)
                #expect(Disk.list(root.path) == ["._alone", "bar.txt", "foo.txt"])
                #expect(Attributes.read(root.path + "/foo.txt", "com.filetrail.test") == "kept")
                #expect(Attributes.read(root.path + "/bar.txt", "com.filetrail.test") == "too")
                if mode == .cut {
                    #expect(Disk.list(stick.path).filter { !$0.hasPrefix(".") || $0.hasPrefix("._") } == [])
                }
            }
        }
    }

    // A file is built under a hidden name and renamed into place. On these disks a name that begins with "._" takes
    // no attributes, and a name of the full length leaves no room for the "._" file that holds them.
    @Test(.tags(.diskImage), .diskImages, arguments: [DiskImage.Kind.exfat, .fat32])
    func copiesAFileWhoseNameBeginsWithAnUnderscoreOrIsVeryLongWithItsAttributes(kind: DiskImage.Kind) async throws {
        try await withTemporaryDirectory { root in
            try await DiskImage.withSharedVolume(kind) { stick in
                let long = String(repeating: "n", count: 240) + ".txt"
                for name in ["_config.yml", "plain.txt", long] {
                    try Disk.write(root.path + "/" + name, name)
                    try Attributes.write(root.path + "/" + name, "com.filetrail.test", "kept")
                }
                let run = try await runPaste(
                    mode: .copy, sources: ["_config.yml", "plain.txt", long].map { root.path + "/" + $0 },
                    into: stick.path)
                #expect(run.result?.status == .completed)
                for name in ["_config.yml", "plain.txt", long] {
                    #expect(Attributes.read(stick.path + "/" + name, "com.filetrail.test") == "kept")
                }
                #expect(Disk.list(stick.path).filter { $0.contains(".filetrail-") } == [])
            }
        }
    }
}

struct TemporaryNameTests {
    private let tag = ".filetrail-0123abcd"

    @Test func isHiddenIsKnownAsTheAppsOwnAndNeverAnAppleDoubleName() {
        #expect(temporaryName(for: "notes.txt", tag: tag) == ".notes.txt.filetrail-0123abcd")
        #expect(temporaryName(for: "_config.yml", tag: tag) == ".~_config.yml.filetrail-0123abcd")
        #expect(temporaryName(for: "__init__.py", tag: tag) == ".~__init__.py.filetrail-0123abcd")
        for name in ["notes.txt", "_config.yml", "_", String(repeating: "\u{65E5}", count: 85)] {
            let temporary = temporaryName(for: name, tag: tag)
            #expect(isStagingName(temporary))
            #expect(!temporary.hasPrefix("._"))
        }
    }

    @Test func leavesRoomForItsOwnAppleDoubleFile() {
        let names = [
            String(repeating: "n", count: 255), String(repeating: "\u{65E5}", count: 85),
            "_" + String(repeating: "n", count: 254),
        ]
        for name in names {
            let temporary = temporaryName(for: name, tag: tag)
            #expect(temporary.utf8.count <= 253)
            #expect(temporary.hasSuffix(tag))
        }
    }
}
