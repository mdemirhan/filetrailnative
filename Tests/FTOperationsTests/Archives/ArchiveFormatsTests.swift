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
