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

    /// A chain of `depth` folders in the new folder `top`, each holding a file, made one from inside the other so
    /// that their paths can pass the longest a path can be.
    private static func makeChain(_ top: String, depth: Int) throws {
        try #require(mkdir(top, 0o755) == 0)
        var folder = open(top, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        try #require(folder >= 0)
        defer { close(folder) }
        for level in 0..<depth {
            let file = openat(folder, "f.txt", O_WRONLY | O_CREAT | O_CLOEXEC, 0o644)
            try #require(file >= 0)
            close(file)
            let name = "level-\(level)"
            try #require(mkdirat(folder, name, 0o755) == 0)
            let next = openat(folder, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            try #require(next >= 0)
            close(folder)
            folder = next
        }
    }

    /// Removes what a removal that failed left of a chain, which the temporary folder's own clearing can't reach.
    private static func clearAway(_ top: String) {
        guard Disk.exists(top) else { return }
        let remove = Process()
        remove.executableURL = URL(fileURLWithPath: "/bin/rm")
        remove.arguments = ["-rf", top]
        try? remove.run()
        remove.waitUntilExit()
    }

    // A tree whose paths pass the longest a path can be (1024 bytes) is removed whole: its folders are reached one
    // from inside the other, not by their paths.
    @Test func aTreeDeeperThanAPathCanBeLongIsRemovedWhole() throws {
        try withTemporaryDirectory(prefix: "native-removal") { root in
            let tree = root.path + "/tree"
            defer { Self.clearAway(tree) }
            // "level-0/level-1/…": some 2,700 bytes.
            try Self.makeChain(tree, depth: 300)

            try NativeWriteFileSystem().rm(tree, recursive: true, force: false)

            #expect(!Disk.exists(tree))
        }
    }

    // However deep the tree, one folder is open at a time, and a second only while the removal goes from one to the
    // next: a folder held open for each level would run out of descriptors.
    @Test func aDeepTreeIsRemovedWithOneFolderOpenAtATime() throws {
        try withTemporaryDirectory(prefix: "native-removal") { root in
            let tree = root.path + "/tree"
            defer { Self.clearAway(tree) }
            try Self.makeChain(tree, depth: 300)
            // The folders opened so far that are still open, each with what tells it from any other: a descriptor
            // closed since no longer leads to its folder.
            var open: [(descriptor: Int32, dev: dev_t, ino: ino_t)] = []
            var mostOpenBeforeTheNext = 0
            var calls = RemovalCalls()
            let openFolder = calls.openFolder
            calls.openFolder = { parent, name in
                open.removeAll { folder in
                    var info = stat()
                    return fstat(folder.descriptor, &info) != 0 || info.st_dev != folder.dev
                        || info.st_ino != folder.ino
                }
                mostOpenBeforeTheNext = max(mostOpenBeforeTheNext, open.count)
                let descriptor = openFolder(parent, name)
                var info = stat()
                if descriptor >= 0, fstat(descriptor, &info) == 0 {
                    open.append((descriptor, info.st_dev, info.st_ino))
                }
                return descriptor
            }

            try NativeRemoval.rm(tree, recursive: true, force: false, calls: calls)

            #expect(!Disk.exists(tree))
            #expect(mostOpenBeforeTheNext == 1)
        }
    }

    // A folder swapped for a link to another folder, between the look at it and its opening, is not gone into: the
    // removal stops there, and what the link points to stays.
    @Test func aFolderSwappedForALinkWhileItIsRemovedIsNotFollowed() throws {
        try withTemporaryDirectory(prefix: "native-removal") { root in
            let outside = root.path + "/outside"
            try Disk.write(outside + "/kept.txt", "keep")
            try Disk.write(outside + "/inner/kept.txt", "keep")
            let folder = root.path + "/folder"
            try Disk.write(folder + "/swapped/a.txt", "a")
            var calls = RemovalCalls()
            let openFolder = calls.openFolder
            calls.openFolder = { parent, name in
                if name == "swapped" {
                    // Looked at as a folder; a link to another folder by the time it is opened.
                    #expect(rename(folder + "/swapped", root.path + "/moved-away") == 0)
                    #expect(symlink(outside, folder + "/swapped") == 0)
                }
                return openFolder(parent, name)
            }

            let error = #expect(throws: NativeError.self) {
                try NativeRemoval.rm(folder, recursive: true, force: false, calls: calls)
            }

            #expect(error?.path == folder + "/swapped")
            #expect(Disk.list(outside) == ["inner", "kept.txt"])
            #expect(Disk.read(outside + "/inner/kept.txt") == "keep")
            #expect(Disk.read(root.path + "/moved-away/a.txt") == "a")
        }
    }

    // A folder moved elsewhere while it is being emptied is not followed there: the folder around it is then not the
    // one the removal came from, and nothing in that one is removed.
    @Test func aFolderMovedWhileItIsEmptiedStopsTheRemoval() throws {
        try withTemporaryDirectory(prefix: "native-removal") { root in
            let elsewhere = root.path + "/elsewhere"
            try Disk.write(elsewhere + "/kept.txt", "keep")
            let folder = root.path + "/folder"
            try Disk.write(folder + "/inner/a.txt", "a")
            var calls = RemovalCalls()
            let openFolder = calls.openFolder
            calls.openFolder = { parent, name in
                if name == ".." {
                    #expect(rename(folder + "/inner", elsewhere + "/inner") == 0)
                }
                return openFolder(parent, name)
            }

            let error = #expect(throws: NativeError.self) {
                try NativeRemoval.rm(folder, recursive: true, force: false, calls: calls)
            }

            #expect(error?.message.contains("was moved while it was being deleted") == true)
            #expect(error?.path == folder + "/inner")
            #expect(Disk.list(elsewhere) == ["inner", "kept.txt"])
        }
    }

    // An empty folder that can be listed but not gone into is removed with the rest, from the folder it is in.
    @Test func anEmptyFolderThatCantBeGoneIntoIsRemoved() throws {
        try withTemporaryDirectory(prefix: "native-removal") { root in
            let folder = root.path + "/folder"
            try Disk.write(folder + "/sub/a.txt", "a")
            try Disk.makeDirectories(folder + "/sub/listed-only")
            Disk.chmod(folder + "/sub/listed-only", 0o444)

            try NativeWriteFileSystem().rm(folder, recursive: true, force: false)

            #expect(!Disk.exists(folder))
        }
    }

    // On each kind of disk, folders inside folders go deepest first, and the folder itself last.
    @Test(.tags(.diskImage), .diskImages, arguments: [DiskImage.Kind.fat32, .exfat, .hfs, .apfs])
    func removesFoldersInsideFoldersOnEachKindOfDisk(kind: DiskImage.Kind) async throws {
        try await DiskImage.withSharedVolume(kind) { volume in
            let folder = volume.path + "/folder"
            try Disk.write(folder + "/a/b/c/deep.txt", "deep")
            try Disk.write(folder + "/a/b/beside.txt", "beside")
            try Disk.write(folder + "/a/other/x.txt", "x")
            try Disk.makeDirectories(folder + "/a/empty")
            try Disk.write(folder + "/top.txt", "top")

            try NativeWriteFileSystem().rm(folder, recursive: true, force: false)

            #expect(!Disk.exists(folder))
            #expect(Disk.list(volume.path) == [])
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
