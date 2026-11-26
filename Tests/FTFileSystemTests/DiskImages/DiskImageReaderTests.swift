import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTFileSystem

/// The disk images of the fixture (`bun tools/fixtures/generate.ts diskimages`), one of each kind hdiutil makes: what
/// each is made with is what its header must say.
enum DiskImageFixtures {
    static var folder: String { Fixtures.root + "/diskimages" }
    static var available: Bool { FileManager.default.fileExists(atPath: folder + "/.fixture-version") }

    static func read(_ name: String) -> InfoDetails.DiskImage? { DiskImageReader.read(folder + "/" + name) }
}

struct DiskImageReaderTests {
    typealias Image = InfoDetails.DiskImage
    static let twenty: Int64 = 20 * 1024 * 1024

    @Test(.enabled(if: DiskImageFixtures.available, "needs the disk images fixture"))
    func readWriteImagesSayTheirPartitionMapsFileSystems() {
        let expected: [(String, [String], Int64)] = [
            ("rw-apfs.dmg", ["APFS"], Self.twenty),
            ("rw-hfs-journaled.dmg", ["Mac OS Extended (Journaled)"], Self.twenty),
            ("rw-hfs-casesensitive.dmg", ["Mac OS Extended (Case-sensitive, Journaled)"], Self.twenty),
            // Apple's partition map, and HFS+ without a journal.
            ("rw-hfs-apm.dmg", ["Mac OS Extended"], Self.twenty),
            // No partition map: the file system from the first byte.
            ("rw-hfs-nomap.dmg", ["Mac OS Extended (Journaled)"], Self.twenty),
            ("rw-exfat-mbr.dmg", ["ExFAT"], 2 * Self.twenty),
            ("rw-fat32-gpt.dmg", ["MS-DOS (FAT32)"], 2 * Self.twenty),
            ("rw-fat16-mbr.dmg", ["MS-DOS (FAT16)"], Self.twenty),
            ("rw-fat12-nomap.img", ["MS-DOS (FAT12)"], 2 * 1024 * 1024),
        ]
        for (name, systems, size) in expected {
            #expect(
                DiskImageFixtures.read(name)
                    == Image(format: .readWrite, fileSystems: systems, capacity: size, encrypted: false), "\(name)")
        }
    }

    @Test(.enabled(if: DiskImageFixtures.available, "needs the disk images fixture"))
    func udifImagesSayHowTheyAreCompressed() {
        let expected: [(String, Image.Format, [String])] = [
            ("lzfse-hfs.dmg", .compressed("LZFSE"), ["Mac OS Extended (Journaled)"]),
            ("bzip2-hfs.dmg", .compressed("bzip2"), ["Mac OS Extended (Journaled)"]),
            ("lzma-apfs.dmg", .compressed("LZMA"), ["APFS"]),
            ("readonly-hfs-casesensitive.dmg", .readOnly, ["Mac OS Extended (Case-sensitive, Journaled)"]),
        ]
        for (name, format, systems) in expected {
            #expect(
                DiskImageFixtures.read(name)
                    == Image(format: format, fileSystems: systems, capacity: Self.twenty, encrypted: false), "\(name)")
        }
        // Made from a folder: as large as hdiutil chose, which the trailer says.
        let zlib = DiskImageFixtures.read("zlib-apfs.dmg")
        #expect(zlib?.format == .compressed("zlib") && zlib?.fileSystems == ["APFS"] && zlib?.encrypted == false)
        #expect((zlib?.capacity ?? 0) > 1024 * 1024)
    }

    @Test(.enabled(if: DiskImageFixtures.available, "needs the disk images fixture"))
    func cdAndDVDImagesSayISOAndUDF() {
        #expect(DiskImageFixtures.read("iso9660.iso")?.fileSystems == ["ISO 9660"])
        #expect(DiskImageFixtures.read("udf.iso")?.fileSystems == ["UDF"])
        #expect(DiskImageFixtures.read("iso-udf.iso")?.fileSystems == ["UDF", "ISO 9660"])
        #expect(DiskImageFixtures.read("iso9660.iso")?.format == .cdMaster)
    }

    @Test(.enabled(if: DiskImageFixtures.available, "needs the disk images fixture"))
    func sparseImagesAndBundlesSayTheirSize() {
        #expect(
            DiskImageFixtures.read("sparse-hfs.sparseimage")
                == Image(
                    format: .sparse, fileSystems: ["Mac OS Extended (Journaled)"], capacity: 50 * 1024 * 1024,
                    encrypted: false))
        // 2 TB, more sectors than 32 bits count: its EFI partition isn't named.
        #expect(
            DiskImageFixtures.read("sparse-apfs-2t.sparseimage")
                == Image(format: .sparse, fileSystems: ["APFS"], capacity: 2 << 40, encrypted: false))
        #expect(
            DiskImageFixtures.read("bundle-apfs.sparsebundle")
                == Image(format: .sparseBundle, fileSystems: ["APFS"], capacity: 100 * 1024 * 1024, encrypted: false))
    }

    // An encrypted image says only that: what is in it can't be read without its password, which is never asked.
    @Test(.enabled(if: DiskImageFixtures.available, "needs the disk images fixture"))
    func anEncryptedImageSaysOnlyThat() {
        #expect(DiskImageFixtures.read("encrypted.dmg") == Image(encrypted: true))
        #expect(DiskImageFixtures.read("encrypted.sparsebundle") == Image(format: .sparseBundle, encrypted: true))
    }

    // What isn't a disk image of a kind that is read says nothing; what is damaged says what is certain.
    @Test func whatIsNotReadSaysNothing() throws {
        try withTemporaryDirectory { folder in
            func write(_ name: String, _ bytes: [UInt8]) -> String {
                let path = folder.appending(name).path
                FileManager.default.createFile(atPath: path, contents: Data(bytes))
                return path
            }
            #expect(DiskImageReader.read(write("empty.dmg", [])) == Image())
            #expect(
                DiskImageReader.read(write("noise.dmg", (0..<70_000).map { UInt8(truncatingIfNeeded: $0 &* 31) }))
                    == Image())
            // A split image's segment holds part of a disk.
            #expect(DiskImageReader.read(write("a.dmgpart", [UInt8](repeating: 0, count: 4096))) == Image())
            // A trailer whose plist lies past the file's end: its sector count, nothing more.
            var trailer = [UInt8](repeating: 0, count: 512)
            trailer.replaceSubrange(0..<4, with: Array("koly".utf8))
            trailer.replaceSubrange(216..<224, with: [0, 0, 0, 0, 0x7F, 0, 0, 0])
            trailer.replaceSubrange(224..<232, with: [0, 0, 0, 0, 0, 0, 0x10, 0])
            trailer.replaceSubrange(492..<500, with: [0, 0, 0, 0, 0, 0, 0x08, 0])
            #expect(
                DiskImageReader.read(write("lying.dmg", [UInt8](repeating: 0, count: 1024) + trailer))
                    == Image(capacity: 2048 * 512, encrypted: false))
            // A sparse image whose band table points nowhere: its size, and no file system.
            var sparse = [UInt8](repeating: 0, count: 4096)
            sparse.replaceSubrange(0..<4, with: Array("sprs".utf8))
            sparse.replaceSubrange(8..<12, with: [0, 0, 0x08, 0])
            sparse.replaceSubrange(16..<20, with: [0, 0, 0x08, 0])
            sparse.replaceSubrange(64..<68, with: [0x7F, 0xFF, 0xFF, 0xFF])
            #expect(
                DiskImageReader.read(write("broken.sparseimage", sparse))
                    == Image(format: .sparse, capacity: 1024 * 1024, encrypted: false))
            // A folder named as a sparse bundle, with no plist.
            let bundle = folder.appending("x.sparsebundle").path
            try FileManager.default.createDirectory(atPath: bundle, withIntermediateDirectories: true)
            #expect(DiskImageReader.read(bundle) == Image())
        }
    }

    // NTFS can't be made on a Mac: its boot sector's name is what tells it.
    @Test func anNTFSBootSectorIsNamed() {
        var sector = [UInt8](repeating: 0, count: 2048)
        sector.replaceSubrange(0..<3, with: [0xEB, 0x52, 0x90])
        sector.replaceSubrange(3..<11, with: Array("NTFS    ".utf8))
        sector[510] = 0x55
        sector[511] = 0xAA
        struct Disk: DiskBytes {
            let bytes: [UInt8]
            func read(_ offset: Int64, _ count: Int) -> [UInt8]? {
                guard offset >= 0, Int(offset) + count <= bytes.count else { return nil }
                return Array(bytes[Int(offset)..<(Int(offset) + count)])
            }
        }
        #expect(DiskImageVolumes.fileSystems(Disk(bytes: sector + [UInt8](repeating: 0, count: 40_000))) == ["NTFS"])
    }
}
