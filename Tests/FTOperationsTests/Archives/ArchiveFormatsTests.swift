// Every kind Extract takes apart besides zip, tar and gzip: 7z, RAR (4 and 5), xar, tar with bzip2 or xz, and single
// files compressed with bzip2 or xz
import Darwin
import FTFileSystem
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTOperations

@Suite struct ArchiveFormatsTests {
    /// A folder `source` holding "Photos" (a.txt, sub/b.txt) and notes.txt, and an empty one to extract into.
    struct Folders {
        let directory: TemporaryDirectory
        var root: String { directory.path }
        var source: String { "\(root)/source" }
        var out: String { "\(root)/out" }

        init() throws {
            directory = try TemporaryDirectory(prefix: "filetrail-formats")
            try FileManager.default.createDirectory(atPath: "\(source)/Photos/sub", withIntermediateDirectories: true)
            try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: false)
            try Data("a".utf8).write(to: URL(fileURLWithPath: "\(source)/Photos/a.txt"))
            try Data("b".utf8).write(to: URL(fileURLWithPath: "\(source)/Photos/sub/b.txt"))
            try Data("notes".utf8).write(to: URL(fileURLWithPath: "\(source)/notes.txt"))
        }

        /// The archive `name` in `root`, made by the system's tar (libarchive's own writer) with `options`.
        func archive(_ name: String, _ options: [String], of items: [String] = ["Photos", "notes.txt"]) throws
            -> String
        {
            let path = "\(root)/\(name)"
            try ArchiveOperationsTests.run("/usr/bin/tar", options + ["-f", path] + items, in: source)
            return path
        }
    }

    /// Takes `archive` apart as Extract does, into `folder`: what it gave.
    static func extract(_ archive: String, into folder: String) throws -> String {
        try WriteCoordinator.extractOne(archive, into: folder, NativeWriteFileSystem(), NativeArchive.Control()).path
    }

    static func text(_ path: String) throws -> String { try String(contentsOfFile: path, encoding: .utf8) }

    /// Each kind of archive of items, as libarchive writes it: a folder named after it, holding what went in.
    @Test(arguments: [
        ("Photos.7z", ["-c", "--format", "7zip"]), ("Photos.xar", ["-c", "--format", "xar"]),
        ("Photos.tar.bz2", ["-cj"]), ("Photos.tbz2", ["-cj"]), ("Photos.tar.xz", ["-cJ"]), ("Photos.txz", ["-cJ"]),
    ])
    func anArchiveOfItemsComesOutWhole(name: String, options: [String]) throws {
        let folders = try Folders()
        defer { folders.directory.remove() }
        let archive = try folders.archive(name, options)
        let made = try Self.extract(archive, into: folders.out)
        #expect(made == "\(folders.out)/Photos")
        #expect(try Self.text("\(made)/Photos/a.txt") == "a")
        #expect(try Self.text("\(made)/Photos/sub/b.txt") == "b")
        #expect(try Self.text("\(made)/notes.txt") == "notes")
    }

    /// One folder in a 7z comes out as that folder.
    @Test func aSevenZipHoldingOneFolderGivesThatFolder() throws {
        let folders = try Folders()
        defer { folders.directory.remove() }
        let archive = try folders.archive("Box.7z", ["-c", "--format", "7zip"], of: ["Photos"])
        let made = try Self.extract(archive, into: folders.out)
        #expect(made == "\(folders.out)/Photos")
        #expect(try Self.text("\(made)/sub/b.txt") == "b")
    }

    /// A file compressed on its own with bzip2 or xz comes out as itself, under the archive's name without its end.
    @Test(arguments: [("notes.txt.bz2", ["-cj"]), ("notes.txt.xz", ["-cJ"])])
    func aSingleCompressedFileComesOutUnderItsName(name: String, options: [String]) throws {
        let folders = try Folders()
        defer { folders.directory.remove() }
        let archive = try folders.archive(name, ["--format", "raw"] + options, of: ["notes.txt"])
        let made = try Self.extract(archive, into: folders.out)
        #expect(made == "\(folders.out)/notes.txt")
        #expect(try Self.text(made) == "notes")
    }

    /// A file that holds nothing, compressed on its own, comes out as the empty file it is: the reader finds no data
    /// to know it by, which is not damage.
    @Test(arguments: [("empty.txt.gz", ["-cz"]), ("empty.txt.bz2", ["-cj"]), ("empty.txt.xz", ["-cJ"])])
    func anEmptyCompressedFileComesOutEmpty(name: String, options: [String]) throws {
        let folders = try Folders()
        defer { folders.directory.remove() }
        try Data().write(to: URL(fileURLWithPath: "\(folders.source)/empty.txt"))
        let archive = try folders.archive(name, ["--format", "raw"] + options, of: ["empty.txt"])
        let made = try Self.extract(archive, into: folders.out)
        #expect(made == "\(folders.out)/empty.txt")
        #expect(try Data(contentsOf: URL(fileURLWithPath: made)).isEmpty)
    }

    /// Data that isn't what the archive says it holds (one byte of a stored file changed, so its checksum no longer
    /// matches) fails the archive, and nothing of it is left: the reader only warns of it, and the file came out as
    /// if it were whole.
    @Test func aSevenZipWhoseDataIsDamagedFails() throws {
        let folders = try Folders()
        defer { folders.directory.remove() }
        let noise = ArchivePipe.noise(200_000)
        try noise.write(to: URL(fileURLWithPath: "\(folders.source)/noise.bin"))
        let archive = try folders.archive(
            "noise.7z", ["-c", "--format", "7zip", "--options", "compression=store"], of: ["noise.bin"])
        // Whole, it comes out as it went in.
        let whole = try Self.extract(archive, into: folders.out)
        #expect(try Data(contentsOf: URL(fileURLWithPath: whole)) == noise)
        try FileManager.default.removeItem(atPath: whole)

        var bytes = try Data(contentsOf: URL(fileURLWithPath: archive))
        // Stored, the file's bytes follow the 32-byte header as they are.
        bytes[1000] ^= 0xFF
        try bytes.write(to: URL(fileURLWithPath: archive))
        #expect(throws: ArchiveError.self) { try Self.extract(archive, into: folders.out) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folders.out).isEmpty)
    }

    /// An archive of a few kilobytes can say a file is a hole of any length. One longer than the disk has room for is
    /// refused, and leaves nothing.
    @Test func aHoleLongerThanTheDiskHasRoomForIsRefused() throws {
        let folders = try Folders()
        defer { folders.directory.remove() }
        // Only where the disk keeps holes: elsewhere making the file to archive would write it all.
        guard pathconf(folders.root, _PC_MIN_HOLE_SIZE) > 0 else { return }
        let sparse = "\(folders.source)/hole.bin"
        let file = open(sparse, O_WRONLY | O_CREAT, 0o644)
        try #require(file >= 0)
        // Twice what the disk has free: the system's tar takes minutes to write down a hole a thousand times that.
        let free = try #require(
            try FileManager.default.attributesOfFileSystem(forPath: folders.root)[.systemFreeSize] as? Int64)
        let stretched = ftruncate(file, off_t(free) * 2 + (1 << 30))
        close(file)
        try #require(stretched == 0)
        let archive = try folders.archive("hole.tar", ["-c"], of: ["hole.bin"])
        let size = try #require(try FileManager.default.attributesOfItem(atPath: archive)[.size] as? Int)
        try #require(size < 1 << 20)
        #expect(throws: (any Error).self) { try Self.extract(archive, into: folders.out) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folders.out).isEmpty)
    }

    /// A file with a hole the disk has room for comes out with it.
    @Test func aFileWithAHoleComesOutAsItWas() throws {
        let folders = try Folders()
        defer { folders.directory.remove() }
        guard pathconf(folders.root, _PC_MIN_HOLE_SIZE) > 0 else { return }
        let sparse = "\(folders.source)/hole.bin"
        let file = open(sparse, O_WRONLY | O_CREAT, 0o644)
        try #require(file >= 0)
        let end = Data("end".utf8)
        let written = end.withUnsafeBytes { pwrite(file, $0.baseAddress, $0.count, 200_000_000) }
        close(file)
        try #require(written == end.count)
        let archive = try folders.archive("hole.tar", ["-c"], of: ["hole.bin"])
        let made = try Self.extract(archive, into: folders.out)
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: made))
        defer { try? handle.close() }
        #expect(try handle.seekToEnd() == 200_000_003)
        try handle.seek(toOffset: 200_000_000)
        #expect(try handle.readToEnd() == end)
    }

    /// A folder that takes nothing new refuses before the archive is taken apart elsewhere: said at once, not after
    /// gigabytes were written out of sight.
    @Test func aFolderThatCantBeWrittenRefusesBeforeAnythingIsExtracted() throws {
        let folders = try Folders()
        defer {
            chmod(folders.out, 0o755)
            folders.directory.remove()
        }
        chmod(folders.out, 0o555)
        // The archive isn't even there: the folder's refusal comes first.
        #expect {
            try Self.extract("\(folders.root)/missing.zip", into: folders.out)
        } throws: { error in
            errorCode(error) == .errno(EACCES)
        }
    }

    /// RAR can't be written by libarchive: two files stored in a folder "notes", as a RAR 5 and a RAR 4 archive
    /// hold them, written byte by byte from the format's description, are read.
    @Test(arguments: [
        // RAR 5.
        "UmFyIRoHAQDFGjMyAwEAADx7r5MiAgIPBg+kgwIA8VNl4BLc2wABD25vdGVzL2hlbGxvLnR4dGhlbGxvIGZyb20gcmFyCqPhzgEjAgIHBgekgw"
            + "IA8VNlfsAPBgABEG5vdGVzL3NlY29uZC50eHRzZWNvbmQKGbI6NQMFAAA=",
        // RAR 4.
        "UmFyIRoHAM+QcwAADQAAAAAAAAALnnQAgC8ADwAAAA8AAAAD4BLc26qxblcUMA8ApIEAAG5vdGVzL2hlbGxvLnR4dGhlbGxvIGZyb20gcmFy"
            + "Clm0dACAMAAHAAAABwAAAAN+wA8GqrFuVxQwEACkgQAAbm90ZXMvc2Vjb25kLnR4dHNlY29uZArEPXsAQAcA",
    ])
    func aRarArchiveComesOutWhole(base64: String) throws {
        let folders = try Folders()
        defer { folders.directory.remove() }
        let archive = "\(folders.root)/notes.rar"
        try #require(Data(base64Encoded: base64)).write(to: URL(fileURLWithPath: archive))
        let made = try Self.extract(archive, into: folders.out)
        #expect(made == "\(folders.out)/notes")
        #expect(try Self.text("\(made)/hello.txt") == "hello from rar\n")
        #expect(try Self.text("\(made)/second.txt") == "second\n")
    }
}
