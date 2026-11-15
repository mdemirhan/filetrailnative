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

    /// A hole longer than the disk has room for (a disk image, a virtual machine's disk) comes out on a disk that keeps
    /// holes, at its length and taking almost nothing: it is refused only where the disk would have to write it all.
    @Test func aHoleLongerThanTheDisksFreeSpaceComesOutWhereTheDiskKeepsHoles() throws {
        let folders = try Folders()
        defer { folders.directory.remove() }
        // Elsewhere making the file to archive would write it all.
        guard pathconf(folders.root, _PC_MIN_HOLE_SIZE) > 0 else { return }
        let sparse = "\(folders.source)/hole.bin"
        let file = open(sparse, O_WRONLY | O_CREAT, 0o644)
        try #require(file >= 0)
        // Twice what the disk has free: the system's tar takes minutes to write down a hole a thousand times that.
        let free = try #require(
            try FileManager.default.attributesOfFileSystem(forPath: folders.root)[.systemFreeSize] as? Int64)
        let length = off_t(free) * 2 + (1 << 30)
        let stretched = ftruncate(file, length)
        close(file)
        try #require(stretched == 0)
        let archive = try folders.archive("hole.tar", ["-c"], of: ["hole.bin"])
        let size = try #require(try FileManager.default.attributesOfItem(atPath: archive)[.size] as? Int)
        try #require(size < 1 << 20)
        let made = try Self.extract(archive, into: folders.out)
        var stats = stat()
        try #require(stat(made, &stats) == 0)
        #expect(stats.st_size == length)
        // What it takes on the disk is next to nothing.
        #expect(Int64(stats.st_blocks) * 512 < 1 << 20)
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

    /// A name with an accented letter or a Hangul syllable comes out composed, as the archive has it and as Windows,
    /// Linux and most network disks expect it: the reader hands every name it converts over decomposed, which looks the
    /// same on a Mac and is another name elsewhere.
    @Test(arguments: [
        ("Names.zip", ["-c", "--format", "zip"]), ("Names.7z", ["-c", "--format", "7zip"]),
        ("Names.tar.gz", ["-cz", "--format", "pax"]),
    ])
    func namesBeyondASCIIComeOutComposed(name: String, options: [String]) throws {
        let folders = try Folders()
        defer { folders.directory.remove() }
        let composed = "caf\u{E9} \u{D55C}.txt"
        try Data("x".utf8).write(to: URL(fileURLWithPath: "\(folders.source)/\(composed)"))
        let archive = try folders.archive(name, options, of: [composed])
        let made = try Self.extract(archive, into: folders.out)
        let names = try FileManager.default.contentsOfDirectory(atPath: folders.out)
        #expect(names.map { Array($0.utf8) } == [Array(composed.utf8)], "\(names.map { Array($0.unicodeScalars) })")
        #expect(try Self.text(made) == "x")
    }

    /// Nothing comes out writable by anyone but its owner, whatever the archive says (a zip made on Windows says
    /// nothing, and the reader's stand-in would let every account of the Mac write to it); what the owner may do
    /// stays as the archive has it.
    @Test func whatComesOutIsWritableByItsOwnerAlone() throws {
        let folders = try Folders()
        defer { folders.directory.remove() }
        chmod("\(folders.source)/notes.txt", 0o666)
        chmod("\(folders.source)/Photos", 0o777)
        chmod("\(folders.source)/Photos/a.txt", 0o750)
        let archive = try folders.archive("Open.tar", ["-c"])
        let made = try Self.extract(archive, into: folders.out)
        func mode(_ path: String) -> mode_t {
            var stats = stat()
            return stat(path, &stats) == 0 ? stats.st_mode & 0o777 : 0
        }
        #expect(mode("\(made)/notes.txt") == 0o644)
        #expect(mode("\(made)/Photos") == 0o755)
        #expect(mode("\(made)/Photos/a.txt") == 0o750)
    }

    /// An extraction done has read all of its archive, as its progress says: a zip's list of items, at its end, is
    /// never read, and the card ended part of the way.
    @Test func aZipExtractedIsAllDone() throws {
        let folders = try Folders()
        defer { folders.directory.remove() }
        for index in 0..<200 {
            try Data("x".utf8).write(to: URL(fileURLWithPath: "\(folders.source)/Photos/\(index).txt"))
        }
        let archive = try folders.archive("Many.zip", ["-c", "--format", "zip"], of: ["Photos"])
        let control = NativeArchive.Control()
        _ = try WriteCoordinator.extractOne(archive, into: folders.out, NativeWriteFileSystem(), control)
        #expect(control.total > 0)
        #expect(control.done == control.total)
    }

    /// A Compress that fails on an item names that item, not the zip it was making.
    @Test func aCompressThatFailsNamesTheItemItFailedOn() throws {
        let folders = try Folders()
        defer {
            chmod("\(folders.source)/Photos/sub", 0o755)
            folders.directory.remove()
        }
        chmod("\(folders.source)/Photos/sub", 0o000)
        #expect {
            try NativeArchive.compressZip(
                ["Photos"], in: folders.source, to: "\(folders.root)/Photos.zip", control: NativeArchive.Control())
        } throws: { error in
            errorMessage(error).contains("\(folders.source)/Photos/sub")
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
