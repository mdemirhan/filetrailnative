import CFileTrail
import FTTestSupport
import Foundation
import Testing

// The getattrlistbulk read (CFileTrail/listing.c) checked against lstat, and what the directory service makes of a
// folder: its entries, its failures, packages and hidden items
@testable import FTFileSystem

struct NativeFileSystemTests {
    private let native = NativeFileSystem()

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

    // On exFAT and FAT32, which leave attributes out, a folder lists what `lstat` says and is measured whole. Only a
    // release runs it: it mounts an image of each.
    @Test(
        .tags(.diskImage), .diskImages, .enabled(if: ReleaseTests.enabled), arguments: [DiskImage.Kind.exfat, .fat32])
    func aDiskThatLeavesAttributesOutListsAndMeasuresAsLstatSays(kind: DiskImage.Kind) async throws {
        try await DiskImage.withVolume(kind) { volume in
            let folder = volume.path + "/folder"
            try FileManager.default.createDirectory(atPath: folder + "/inner", withIntermediateDirectories: true)
            try Data("12345".utf8).write(to: URL(fileURLWithPath: folder + "/five.txt"))
            try Data("123".utf8).write(to: URL(fileURLWithPath: folder + "/inner/three.txt"))

            // macOS keeps the attributes these disks can't in "._" files beside each item: they are listed and
            // measured too, as the disk lists them (Foundation hides them).
            func names(_ path: String) -> [String] {
                guard let directory = opendir(path) else { return [] }
                defer { closedir(directory) }
                var found: [String] = []
                while let entry = readdir(directory) {
                    let name = withUnsafeBytes(of: entry.pointee.d_name) {
                        String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
                    }
                    if name != "." && name != ".." { found.append(name) }
                }
                return found.sorted()
            }
            let records = try native.readDirectory(folder)
            #expect(records.map(\.name).sorted() == names(folder))
            #expect(records.contains { $0.name == "five.txt" } && records.contains { $0.name == "inner" })
            for record in records {
                let real = try native.lstat(folder + "/" + record.name)
                let read = record.lstat ?? real
                #expect(read.mode & 0o170000 == real.mode & 0o170000, "\(record.name)")
                if record.type != .directory { #expect(read.size == real.size, "\(record.name)") }
            }

            // Everything inside, as lstat has it.
            var total: Int64 = 0
            var files = 0
            var folders = 0
            func count(_ path: String) throws {
                for name in names(path) {
                    let stats = try native.lstat(path + "/" + name)
                    if stats.mode & 0o170000 == 0o040000 {
                        folders += 1
                        try count(path + "/" + name)
                    } else {
                        files += 1
                        total += stats.size
                    }
                }
            }
            try count(folder)
            let walk = try await measure(NativeFolderSize(), folder)
            #expect(walk.result.total == total)
            #expect(walk.result.fileCount == files)
            #expect(walk.result.folderCount == folders)
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

    // APFS keeps when each item was put in its folder: the folder read and the one-item read agree, and a move into
    // another folder gives a later date there while the item's other dates stay.
    @Test func readsWhenEachItemWasAddedToItsFolder() throws {
        try withTemporaryDirectory { directory in
            let file = directory.url.appendingPathComponent("a.txt").path
            FileManager.default.createFile(atPath: file, contents: Data("a".utf8))
            let listed = try #require(try native.readDirectory(directory.path).first { $0.name == "a.txt" })
            let added = try #require(listed.addedMs)
            #expect(FileTimes.addedMs(file) == added)
            #expect(native.addedMs(file) == added)
            Thread.sleep(forTimeInterval: 0.02)
            let other = directory.url.appendingPathComponent("sub")
            try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
            let moved = other.appendingPathComponent("a.txt").path
            try FileManager.default.moveItem(atPath: file, toPath: moved)
            #expect(try #require(FileTimes.addedMs(moved)) > added)
            #expect(FileTimes.addedMs(directory.url.appendingPathComponent("missing").path) == nil)
        }
    }

    // What macOS writes when a file is opened, read back; none for a file never opened. The home folder's Desktop,
    // Documents and Downloads aren't read, as reading them asks for permission.
    @Test func readsWhenAnItemWasLastOpened() throws {
        try withTemporaryDirectory { directory in
            let file = directory.url.appendingPathComponent("a.txt").path
            FileManager.default.createFile(atPath: file, contents: Data("a".utf8))
            #expect(FileTimes.lastOpenedMs(file) == nil)
            var stamp = (Int64(1_700_000_000).littleEndian, Int64(250_000_000).littleEndian)
            let written = withUnsafeBytes(of: &stamp) {
                setxattr(file, FileTimes.lastUsedAttribute, $0.baseAddress, $0.count, 0, 0)
            }
            #expect(written == 0)
            #expect(FileTimes.lastOpenedMs(file) == 1_700_000_000_250)
            #expect(native.lastOpenedMs(file) == 1_700_000_000_250)
            #expect(FileTimes.lastOpenedMs(NSHomeDirectory() + "/Downloads") == nil)
        }
    }

    // A folder sorted by Date Last Opened takes the home folder's path once for all its items. Read that way, the
    // same folders are left unread as when one item is asked about: the home folder's Desktop, Documents and
    // Downloads, and nothing inside them or beside them. A folder standing in for the home folder shows it, as each
    // of its items has a date to be read or refused.
    @Test func aFolderReadLeavesTheSameFoldersUnreadAsOneItems() throws {
        try withTemporaryDirectory { directory in
            let home = directory.path
            let guarded = ["Desktop", "Documents", "Downloads"]
            let read = ["Pictures", "Desktops", "Desktop/inner", "Documents/inner", "Downloads/inner"]
            var stamp = (Int64(1_700_000_000).littleEndian, Int64(250_000_000).littleEndian)
            for name in guarded + read {
                let path = home + "/" + name
                try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
                let written = withUnsafeBytes(of: &stamp) {
                    setxattr(path, FileTimes.lastUsedAttribute, $0.baseAddress, $0.count, 0, 0)
                }
                #expect(written == 0)
            }
            // Asked with the home folder's path ending in a slash, as with none.
            for reader in [
                FileTimes.lastOpenedReader(homePath: home), FileTimes.lastOpenedReader(homePath: home + "/"),
            ] {
                for name in guarded {
                    #expect(reader(home + "/" + name) == nil, "\(name)")
                    #expect(reader(home + "/" + name + "/") == nil, "\(name)")
                    #expect(FileTimes.lastOpenedMs(home + "/" + name, homePath: home) == nil, "\(name)")
                }
                for name in read {
                    #expect(reader(home + "/" + name) == 1_700_000_000_250, "\(name)")
                    #expect(FileTimes.lastOpenedMs(home + "/" + name, homePath: home) == 1_700_000_000_250, "\(name)")
                }
            }
            // With the real home folder, which is what the app's reads take: its three folders are refused, and
            // the ones made here, outside it, are all read.
            let real = native.lastOpenedReader()
            for name in guarded {
                #expect(real(NSHomeDirectory() + "/" + name) == nil, "\(name)")
                #expect(real(home + "/" + name) == 1_700_000_000_250, "\(name)")
                #expect(FileTimes.lastOpenedMs(home + "/" + name) == 1_700_000_000_250, "\(name)")
            }
        }
    }

    /// A FUSE or network disk can report any number as a time: none of them stops the listing.
    @Test func aTimeOutOfRangeIsHeldToTheLimit() {
        let limit = NativeFileSystem.secondsLimit * 1000
        #expect(NativeFileSystem.milliseconds(1_700_000_000, Int32(987_654_321)) == 1_700_000_000_987)
        #expect(NativeFileSystem.milliseconds(-2, Int32(500_000_000)) == -1500)
        #expect(NativeFileSystem.milliseconds(.max, Int32(0)) == limit)
        #expect(NativeFileSystem.milliseconds(9_300_000_000_000_000, Int32(999_999_999)) == limit + 999)
        #expect(NativeFileSystem.milliseconds(.min, Int32(0)) == -limit)
        #expect(NativeFileSystem.milliseconds(5, Int32.max) == 5999)
        #expect(NativeFileSystem.milliseconds(5, Int32.min) == 5000)
        #expect(NativeFileSystem.milliseconds(5, Int.max) == 5999)
        #expect(NativeFileSystem.milliseconds(5, Int.min) == 5000)
        // Any two such times can be taken from each other.
        #expect(limit + 999 - -limit > 0)
    }

    @Test func statsWithWildTimesAreRead() {
        var info = SystemStat()
        info.st_mode = S_IFREG | 0o644
        info.st_mtimespec = timespec(tv_sec: .max, tv_nsec: .max)
        info.st_birthtimespec = timespec(tv_sec: .min, tv_nsec: .min)
        let stats = NativeFileSystem.stats(info)
        #expect(stats.type == .file)
        #expect(stats.mtimeMs == NativeFileSystem.secondsLimit * 1000 + 999)
        #expect(stats.birthtimeMs == -NativeFileSystem.secondsLimit * 1000)
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

    // The message gives the code first, naming the call and the path.
    @Test func aFailureNamesTheCodeTheCallAndThePath() async throws {
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

    @Test func treatsABundleAsAnItemInAListingButNotInTheTree() async throws {
        try await withTemporaryDirectory { directory in
            for name in ["Sample.app", "Plain", "Kit.framework", "Slides.key", "Notes.d"] {
                try FileManager.default.createDirectory(
                    atPath: directory.path + "/" + name, withIntermediateDirectories: false)
            }
            let service = DirectoryService()
            let snapshot = try await service.snapshot(path: directory.path)
            let kinds = Dictionary(uniqueKeysWithValues: snapshot.entries.map { ($0.name, $0.kind) })
            // A Keynote document is a package as much as an app is; a folder whose extension is no package's is a folder.
            #expect(
                kinds == [
                    "Sample.app": .bundle, "Plain": .directory, "Kit.framework": .bundle, "Slides.key": .bundle,
                    "Notes.d": .directory,
                ])
            // A bundle sorts with the files.
            #expect(snapshot.entries.map(\.name) == ["Notes.d", "Plain", "Kit.framework", "Sample.app", "Slides.key"])
            let tree = try await service.treeChildren(path: directory.path)
            #expect(tree.children.map(\.name) == ["Notes.d", "Plain"])
        }
    }

    @Test func treatsAFolderTheSystemCallsAPackageAsOneItemWhateverItsExtension() async throws {
        try await withTemporaryDirectory { directory in
            let path = directory.path
            // "Machine.utm" has the package bit, as a virtual machine of UTM's has; ".scptd" is a package type macOS
            // declares itself. Neither extension is on the app's list.
            for name in ["Machine.utm", "Plain.utm", "Script.scptd", "Notes.d", "Plain", "Sample.app"] {
                try FileManager.default.createDirectory(atPath: path + "/" + name, withIntermediateDirectories: false)
            }
            try Self.setPackageBit(path + "/Machine.utm")
            try FileManager.default.createSymbolicLink(atPath: path + "/Link.utm", withDestinationPath: "Machine.utm")
            try "x".write(toFile: path + "/notes.txt", atomically: true, encoding: .utf8)
            let disk = AskedDisk()
            let service = DirectoryService(fileSystem: disk, kinds: .system)
            let snapshot = try await service.snapshot(path: path)
            let kinds = Dictionary(uniqueKeysWithValues: snapshot.entries.map { ($0.name, $0.kind) })
            #expect(
                kinds == [
                    "Machine.utm": .bundle, "Plain.utm": .directory, "Script.scptd": .bundle, "Notes.d": .directory,
                    "Plain": .directory, "Sample.app": .bundle, "Link.utm": .bundle, "notes.txt": .file,
                ])
            // With Folders First, the packages sort with the files.
            #expect(
                snapshot.entries.map(\.name) == [
                    "Notes.d", "Plain", "Plain.utm", "Link.utm", "Machine.utm", "notes.txt", "Sample.app",
                    "Script.scptd",
                ])
            // The read gives the bundle bit. The system's types are asked once for each other folder whose extension
            // isn't on the list, and no folder is looked into but the one the link named so leads to.
            let root = try native.realpath(path)
            let records = try native.readDirectory(root)
            #expect(Set(records.filter(\.hasBundleBit).map(\.name)) == ["Machine.utm"])
            #expect(disk.askedTypes.sorted() == ["d", "scptd", "utm"])
            #expect(disk.askedPaths == [root + "/Machine.utm"])
            // The tree doesn't open a package.
            let tree = try await service.treeChildren(path: path)
            #expect(tree.children.map(\.name) == ["Notes.d", "Plain", "Plain.utm"])
            // A package's kind is the one the system gives it, as for the packages of the list.
            let details = try await service.metadata(
                directoryPath: path, paths: [root + "/Script.scptd", root + "/Plain.utm"])
            let labels = details.items.map(\.kindLabel)
            #expect(labels.count == 2 && labels[1] == "Folder")
            #expect(labels.first.map { !["Folder", "Bundle"].contains($0) } == true, "\(labels)")
            // A search result is a package as the listing says, by its type: fd's results aren't looked into, so a
            // folder known only by its bundle bit is a folder there.
            #expect(SearchResults.item(rootPath: root, outputPath: root + "/Script.scptd/").kind == .bundle)
            #expect(SearchResults.item(rootPath: root, outputPath: root + "/Plain.utm/").kind == .directory)
            // An alias's original is not a folder to open in place when it is such a package.
            #expect(Links.originalItem(of: root + "/Link.utm")?.isFolder == false)
            #expect(Links.originalItem(of: root + "/Plain.utm")?.isFolder == true)
        }
    }

    /// Sets the folder's package bit (`kHasBundle` in its Finder flags), which macOS goes by whatever the name.
    private static func setPackageBit(_ path: String) throws {
        var info = [UInt8](repeating: 0, count: 32)
        info[8] = 0x20  // The Finder flags are a big-endian UInt16 at offset 8; kHasBundle is 0x2000.
        guard setxattr(path, "com.apple.FinderInfo", &info, info.count, 0, 0) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    /// The disk, keeping what it was asked about packages: the extensions whose type, and the folders.
    private final class AskedDisk: ExplorerFileSystem, @unchecked Sendable {
        private let disk = NativeFileSystem()
        private let lock = NSLock()
        private var types: [String] = []
        private var paths: [String] = []
        var askedTypes: [String] { lock.withLock { types } }
        var askedPaths: [String] { lock.withLock { paths } }

        func readDirectory(_ path: String) throws -> [DirectoryRecord] { try disk.readDirectory(path) }
        func stat(_ path: String) throws -> FileStats { try disk.stat(path) }
        func lstat(_ path: String) throws -> FileStats { try disk.lstat(path) }
        func realpath(_ path: String) throws -> String { try disk.realpath(path) }
        func isPackageType(_ fileExtension: String) -> Bool {
            lock.withLock { types.append(fileExtension) }
            return disk.isPackageType(fileExtension)
        }
        func isPackage(_ path: String) -> Bool? {
            lock.withLock { paths.append(path) }
            return disk.isPackage(path)
        }
    }

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
            // The extension of "..double" is "double".
            #expect(all.entries.first { $0.name == "..double" }?.fileExtension == "double")
        }
    }

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
