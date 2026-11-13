// Removing folders on the disk: what a removal reaches and what it leaves
import Darwin
import FTTestSupport
import Foundation
import Testing

@testable import FTOperations

struct NativeRemovalTests {
    // A folder removed with what is in it: a link inside to a folder or a file elsewhere goes, and what it points
    // to stays.
    @Test func removingAFolderRemovesTheLinksInItAndNotWhatTheyPointTo() throws {
        try withTemporaryDirectory(prefix: "native-removal") { root in
            let files = FileManager.default
            let outside = root.path + "/outside"
            try files.createDirectory(atPath: outside + "/inner", withIntermediateDirectories: true)
            try Data("keep".utf8).write(to: URL(fileURLWithPath: outside + "/inner/kept.txt"))
            try Data("keep".utf8).write(to: URL(fileURLWithPath: outside + "/file.txt"))
            let folder = root.path + "/folder"
            try files.createDirectory(atPath: folder + "/sub/deeper", withIntermediateDirectories: true)
            try Data("x".utf8).write(to: URL(fileURLWithPath: folder + "/sub/deeper/a.txt"))
            try files.createSymbolicLink(atPath: folder + "/to-folder", withDestinationPath: outside)
            try files.createSymbolicLink(atPath: folder + "/sub/to-file", withDestinationPath: outside + "/file.txt")
            try files.createSymbolicLink(atPath: folder + "/sub/to-nothing", withDestinationPath: root.path + "/gone")

            try NativeWriteFileSystem().rm(folder, recursive: true, force: false)

            #expect(!files.fileExists(atPath: folder))
            #expect(try files.contentsOfDirectory(atPath: outside).sorted() == ["file.txt", "inner"])
            #expect(files.contents(atPath: outside + "/inner/kept.txt") == Data("keep".utf8))
            #expect(files.contents(atPath: outside + "/file.txt") == Data("keep".utf8))
        }
    }

    // rmdir(2) on macOS deletes a folder holding nothing but "._name" files, and those files with it: a folder is
    // removed only when it lists nothing at all, so one that holds such a file stays, and the file in it.
    @Test func anEmptyFolderIsRemovedAndOneHoldingOnlyADotUnderscoreFileStays() throws {
        try withTemporaryDirectory(prefix: "native-removal") { root in
            let files = FileManager.default
            let empty = root.path + "/empty"
            let holding = root.path + "/holding"
            try files.createDirectory(atPath: empty, withIntermediateDirectories: false)
            try files.createDirectory(atPath: holding, withIntermediateDirectories: false)
            try Data("someone's".utf8).write(to: URL(fileURLWithPath: holding + "/._notes"))

            try NativeWriteFileSystem().rmdir(empty)
            let error = #expect(throws: NativeError.self) { try NativeWriteFileSystem().rmdir(holding) }

            #expect(!files.fileExists(atPath: empty))
            #expect(error?.code == .errno(ENOTEMPTY))
            #expect(files.contents(atPath: holding + "/._notes") == Data("someone's".utf8))
        }
    }

    // A disk mounted inside the folder is someone's other disk: the removal stops at it, and nothing on it is touched.
    @Test(.tags(.diskImage), .diskImages)
    func stopsAtADiskMountedInsideTheFolderAndTouchesNothingOnIt() async throws {
        try await DiskImage.withVolume(.apfsSmall, ownMountPoint: true) { volume in
            let files = FileManager.default
            try files.createDirectory(atPath: volume.path + "/dir", withIntermediateDirectories: false)
            try Data("s".utf8).write(to: volume.appendingPathComponent("SENTINEL.txt"))
            try Data("t".utf8).write(to: volume.appendingPathComponent("dir/inner.txt"))
            // The folder the volume is mounted in.
            let around = volume.deletingLastPathComponent().path
            var parent = stat()
            var mounted = stat()
            #expect(lstat(around, &parent) == 0 && lstat(volume.path, &mounted) == 0)
            #expect(parent.st_dev != mounted.st_dev)
            let refused = #expect(throws: NativeError.self) {
                try NativeWriteFileSystem().rm(around, recursive: true, force: true)
            }
            #expect(refused?.message.contains("is another disk") == true)
            #expect(refused?.path == volume.path)
            #expect(files.fileExists(atPath: volume.path + "/SENTINEL.txt"))
            #expect(files.fileExists(atPath: volume.path + "/dir/inner.txt"))
        }
    }
}
