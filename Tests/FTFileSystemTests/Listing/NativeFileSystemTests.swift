import CFileTrail
import FTTestSupport
import Foundation
import Testing

// The getattrlistbulk read (CFileTrail/listing.c) against lstat, and the workers' cases that the actor replaces
@testable import FTFileSystem

struct NativeFileSystemTests {
    private let native = NativeFileSystem()

    // F-165
    @Test func readsEveryEntryWithWhatLstatSays() throws {
        try withTemporaryDirectory { directory in
            let path = directory.path
            try "hello world".write(toFile: path + "/notes.txt", atomically: true, encoding: .utf8)
            try "#!/bin/sh".write(toFile: path + "/run", atomically: true, encoding: .utf8)
            chmod(path + "/run", 0o755)
            try "x".write(toFile: path + "/.hidden", atomically: true, encoding: .utf8)
            try FileManager.default.createDirectory(atPath: path + "/Folder.app", withIntermediateDirectories: false)
            try FileManager.default.createSymbolicLink(atPath: path + "/link", withDestinationPath: "notes.txt")
            try FileManager.default.createSymbolicLink(
                atPath: path + "/dangling", withDestinationPath: "missing/target")
            try FileManager.default.createSymbolicLink(atPath: path + "/folder link", withDestinationPath: "Folder.app")
            mkfifo(path + "/pipe", 0o644)
            try "é".write(toFile: path + "/Café Zoë 日本語 🎉.txt", atomically: true, encoding: .utf8)

            let records = try native.readDirectory(path).sorted { $0.name < $1.name }
            #expect(
                records.map(\.name)
                    == [
                        ".hidden", "Café Zoë 日本語 🎉.txt", "Folder.app", "dangling", "folder link", "link", "notes.txt",
                        "pipe", "run",
                    ].sorted())
            for record in records {
                let expected = try native.lstat(path + "/" + record.name)
                let got = try #require(record.lstat, "\(record.name)")
                #expect(record.type == expected.type, "\(record.name) type")
                #expect(got.type == expected.type, "\(record.name) stats type")
                // A folder's size is not read: listings defer it.
                if expected.type != .directory { #expect(got.size == expected.size, "\(record.name) size") }
                #expect(got.mode & 0o777 == expected.mode & 0o777, "\(record.name) permissions")
                #expect(got.mtimeMs == expected.mtimeMs, "\(record.name) modified")
                #expect(got.birthtimeMs == expected.birthtimeMs, "\(record.name) created")
            }
            let types = Dictionary(uniqueKeysWithValues: records.map { ($0.name, $0.type) })
            #expect(types["Folder.app"] == .directory)
            #expect(types["link"] == .symlink)
            #expect(types["dangling"] == .symlink)
            #expect(types["pipe"] == FileType.other)
            #expect(types["notes.txt"] == .file)
        }
    }

    // F-176
    @Test func readsAFolderTooBigForOneBuffer() throws {
        try withTemporaryDirectory { directory in
            // The listing reads into a buffer of 256 KB. Each entry takes about 85 bytes and its name: with names of
            // 200 bytes, one buffer holds fewer than 1,000 entries.
            let count = 2_000
            let padding = String(repeating: "n", count: 170)
            for index in 0..<count {
                FileManager.default.createFile(
                    atPath: directory.path + "/file number \(index) \(padding).txt", contents: nil)
            }
            let records = try native.readDirectory(directory.path)
            #expect(records.count == count)
            #expect(Set(records.map(\.name)).count == count)
        }
    }

    // A file system that keeps no creation times (devfs here; the same goes for any disk that leaves an attribute out)
    // packs what it has without that slot: what the read gives is still what `lstat` says, where the sorts and the
    // executable icon read it.
    @Test func aFileSystemWithoutCreationTimesReadsAsLstatSays() throws {
        let compared = try native.readDirectory("/dev").filter { $0.type != .symlink }
        #expect(!compared.isEmpty)
        for record in compared {
            guard let real = try? native.lstat("/dev/" + record.name) else { continue }
            let read = record.lstat ?? real
            #expect(read.mode & 0o7777 == real.mode & 0o7777, "\(record.name)")
            // A folder has no size from the read, on any disk.
            if record.type != .directory { #expect(read.size == real.size, "\(record.name)") }
            // A terminal's time moves as it is used.
            let difference = abs((read.mtimeMs ?? 0) - (real.mtimeMs ?? 0))
            #expect(difference < 60_000, "\(record.name)")
        }
    }

    // An entry the disk didn't fully describe has no stats from the read: the listing asks `lstat`.
    @Test func anEntryTheDiskLeftAttributesOutOfHasNoStats() {
        var entry = FTDirEntry()
        entry.mode = 0o100644
        entry.mode_valid = 1
        entry.size = 5
        entry.size_valid = 1
        entry.mtime_valid = 1
        #expect(NativeFileSystem.knownStats(entry, type: .file)?.size == 5)
        #expect(NativeFileSystem.knownStats(entry, type: .file)?.birthtimeMs == nil)
        var noTime = entry
        noTime.mtime_valid = 0
        #expect(NativeFileSystem.knownStats(noTime, type: .file) == nil)
        var noMode = entry
        noMode.mode_valid = 0
        #expect(NativeFileSystem.knownStats(noMode, type: .file) == nil)
        var noSize = entry
        noSize.size_valid = 0
        #expect(NativeFileSystem.knownStats(noSize, type: .file) == nil)
        #expect(NativeFileSystem.knownStats(noSize, type: .directory) != nil)
    }

    @Test func readsAnEmptyFolder() throws {
        try withTemporaryDirectory { directory in
            let records = try native.readDirectory(directory.path)
            #expect(records.isEmpty)
        }
    }

    @Test func failsOnAFileAndOnAMissingFolder() throws {
        try withTemporaryDirectory { directory in
            try "x".write(toFile: directory.path + "/file", atomically: true, encoding: .utf8)
            #expect(throws: ExplorerError.self) { try native.readDirectory(directory.path + "/file") }
            #expect(throws: ExplorerError.self) { try native.readDirectory(directory.path + "/missing") }
        }
    }

    @Test func listsADirectoryItCannotReadAsAnError() async throws {
        try await withTemporaryDirectory { directory in
            try FileManager.default.createDirectory(
                atPath: directory.path + "/closed", withIntermediateDirectories: false)
            chmod(directory.path + "/closed", 0)
            await #expect(throws: ExplorerError.self) {
                try await DirectoryService().snapshot(path: directory.path + "/closed")
            }
        }
    }

    // `toErrorMessage`: the message is Node's, code first, naming the call and the path.
    @Test func aFailureSaysWhatNodeSays() async throws {
        try await withTemporaryDirectory { directory in
            let closed = directory.path + "/closed"
            try FileManager.default.createDirectory(atPath: closed, withIntermediateDirectories: false)
            chmod(closed, 0)
            defer { chmod(closed, 0o755) }
            func message(_ path: String) async -> String {
                do {
                    _ = try await DirectoryService().snapshot(path: path)
                    return ""
                } catch {
                    return String(describing: error)
                }
            }
            let real = try native.realpath(closed)
            #expect(await message(closed) == "EACCES: permission denied, scandir '\(real)'")
            let gone = directory.path + "/gone"
            #expect(await message(gone) == "ENOENT: no such file or directory, stat '\(gone)'")
        }
        #expect(
            ExplorerError.system(code: EPERM, path: "/x", call: "scandir").description
                == "EPERM: operation not permitted, scandir '/x'")
        #expect(ExplorerError.system(code: EIO, path: "/x").description == "EIO: i/o error, scandir '/x'")
    }

    @Test func refusesAFileWhereAFolderIsExpected() async throws {
        try await withTemporaryDirectory { directory in
            try "x".write(toFile: directory.path + "/file", atomically: true, encoding: .utf8)
            await #expect(throws: ExplorerError.notADirectory(directory.path + "/file")) {
                try await DirectoryService().snapshot(path: directory.path + "/file")
            }
        }
    }

    // F-165
    @Test func collapsesAnAliasedFolderToItsRealPath() async throws {
        try await withTemporaryDirectory { directory in
            try FileManager.default.createDirectory(
                atPath: directory.path + "/real", withIntermediateDirectories: false)
            try FileManager.default.createSymbolicLink(atPath: directory.path + "/alias", withDestinationPath: "real")
            let snapshot = try await DirectoryService().snapshot(path: directory.path + "/alias")
            let real = try native.realpath(directory.path + "/real")
            #expect(snapshot.path == real)
            #expect(snapshot.parentPath == NSString(string: real).deletingLastPathComponent)
        }
    }

    @Test func theRootHasNoParent() async throws {
        let snapshot = try await DirectoryService().snapshot(path: "/")
        #expect(snapshot.path == "/")
        #expect(snapshot.parentPath == nil)
        #expect(snapshot.entries.contains { $0.path == "/Users" })
    }

    // F-167 F-168
    @Test func treatsABundleAsAnItemInAListingButNotInTheTree() async throws {
        try await withTemporaryDirectory { directory in
            for name in ["Sample.app", "Plain", "Kit.framework", "Slides.key"] {
                try FileManager.default.createDirectory(
                    atPath: directory.path + "/" + name, withIntermediateDirectories: false)
            }
            let service = DirectoryService()
            let snapshot = try await service.snapshot(path: directory.path)
            let kinds = Dictionary(uniqueKeysWithValues: snapshot.entries.map { ($0.name, $0.kind) })
            #expect(
                kinds == [
                    "Sample.app": .bundle, "Plain": .directory, "Kit.framework": .bundle, "Slides.key": .directory,
                ])
            // A bundle sorts with the files, as the original does.
            #expect(snapshot.entries.map(\.name) == ["Plain", "Slides.key", "Kit.framework", "Sample.app"])
            let tree = try await service.treeChildren(path: directory.path)
            #expect(tree.children.map(\.name) == ["Plain", "Slides.key"])
        }
    }

    // F-166
    @Test func keepsHiddenMeaningALeadingDot() async throws {
        try await withTemporaryDirectory { directory in
            for name in [".config", "visible.txt", "..double"] {
                try "x".write(toFile: directory.path + "/" + name, atomically: true, encoding: .utf8)
            }
            let service = DirectoryService()
            let shown = try await service.snapshot(path: directory.path, includeHidden: false)
            #expect(shown.entries.map(\.name) == ["visible.txt"])
            let all = try await service.snapshot(path: directory.path, includeHidden: true)
            #expect(all.entries.filter(\.isHidden).map(\.name).sorted() == ["..double", ".config"])
            // The extension of "..double" is "double", as Node's path.extname says.
            #expect(all.entries.first { $0.name == "..double" }?.fileExtension == "double")
        }
    }

    // N/A T-2bab67c5 The worker's message loop is replaced by the DirectoryService actor, whose methods are the routes.
    // N/A T-b4e20286 Search channels are routed by the search work package, not by the listing.
    // N/A T-aa5b6a27 There is no worker to close ahead of its queue; searches stop themselves.
    // N/A T-daab225e There are no error envelopes: a failing read throws to its caller.
    // N/A T-91138b37 Item details run at utility priority on their own task (see metadataRunsApartFromListings).
    // N/A T-fac8fb13 There is no worker client: callers await the actor.
    // N/A T-819ddfa3 There are no error envelopes: a failing read throws to its caller.
    // N/A T-d480e22d There is no worker that can exit: the actor lives in the app's process.
    // N/A T-24de1b66 There is no worker to end.
    // N/A T-0552d741 There is no worker that can fail to answer.
    // N/A T-9d23a3df There is no worker that can have ended.
    // F-164
    @Test func metadataRunsApartFromListings() async throws {
        try await withTemporaryDirectory { directory in
            try "x".write(toFile: directory.path + "/a.txt", atomically: true, encoding: .utf8)
            let service = DirectoryService()
            let root = try native.realpath(directory.path)
            async let metadata = service.metadata(directoryPath: directory.path, paths: [root + "/a.txt"])
            async let snapshot = service.snapshot(path: directory.path)
            let (details, listing) = try await (metadata, snapshot)
            #expect(details.items.count == 1)
            #expect(listing.entries.count == 1)
        }
    }
}
