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

    // An image made to hurt whoever looks at it: places near the largest number there is, which adding to would
    // overflow. Nothing past the file is read, and what is certain is still said.
    @Test func placesFarPastTheDiskAreNotFollowed() throws {
        func put(_ value: UInt64, into bytes: inout [UInt8], at: Int, size: Int, bigEndian: Bool) {
            for index in 0..<size {
                let shift = UInt64(8 * (bigEndian ? size - 1 - index : index))
                bytes[at + index] = UInt8(truncatingIfNeeded: value >> shift)
            }
        }
        try withTemporaryDirectory { folder in
            func write(_ name: String, _ bytes: [UInt8]) -> String {
                let path = folder.appending(name).path
                FileManager.default.createFile(atPath: path, contents: Data(bytes))
                return path
            }
            // A GPT whose one partition starts within a sector of the largest place a disk can have.
            var gpt = [UInt8](repeating: 0, count: 512 * 4)
            gpt.replaceSubrange(512..<520, with: Array("EFI PART".utf8))
            put(2, into: &gpt, at: 512 + 72, size: 8, bigEndian: false)
            put(1, into: &gpt, at: 512 + 80, size: 4, bigEndian: false)
            put(128, into: &gpt, at: 512 + 84, size: 4, bigEndian: false)
            gpt[1024] = 0xAF
            put(0x003F_FFFF_FFFF_FFFE, into: &gpt, at: 1024 + 32, size: 8, bigEndian: false)
            #expect(
                DiskImageReader.read(write("far.img", gpt))
                    == Image(format: .readWrite, fileSystems: [], capacity: Int64(gpt.count), encrypted: false))
            // The same from an MBR's extended partition, and a file system looked for at the limit itself.
            #expect(DiskImageVolumes.fileSystem(ImageFile(write("zeros.img", gpt))!, at: Int64.max - 1024) == nil)
            #expect(DiskImageVolumes.fileSystem(ImageFile(folder.appending("zeros.img").path)!, at: -512) == nil)

            // A UDIF table whose chunks are placed from the largest number, and one whose sectors end past it.
            var mish = [UInt8](repeating: 0, count: 204 + 2 * 40)
            mish.replaceSubrange(0..<4, with: Array("mish".utf8))
            put(UInt64.max, into: &mish, at: 24, size: 8, bigEndian: true)
            put(2, into: &mish, at: 200, size: 4, bigEndian: true)
            for (index, sector) in [UInt64(0), UInt64(Int64.max / 1024) - 1].enumerated() {
                let at = 204 + index * 40
                put(1, into: &mish, at: at, size: 4, bigEndian: true)
                put(sector, into: &mish, at: at + 8, size: 8, bigEndian: true)
                put(UInt64(Int64.max / 1024) - 1, into: &mish, at: at + 16, size: 8, bigEndian: true)
                put(2, into: &mish, at: at + 24, size: 8, bigEndian: true)
                put(512, into: &mish, at: at + 32, size: 8, bigEndian: true)
            }
            let plist = try PropertyListSerialization.data(
                fromPropertyList: ["resource-fork": ["blkx": [["Data": Data(mish)]]]], format: .xml, options: 0)
            var trailer = [UInt8](repeating: 0, count: 512)
            trailer.replaceSubrange(0..<4, with: Array("koly".utf8))
            put(0, into: &trailer, at: 216, size: 8, bigEndian: true)
            put(UInt64(plist.count), into: &trailer, at: 224, size: 8, bigEndian: true)
            put(8, into: &trailer, at: 492, size: 8, bigEndian: true)
            #expect(
                DiskImageReader.read(write("base.dmg", [UInt8](plist) + trailer))
                    == Image(capacity: 8 * 512, encrypted: false))

            // A sparse image read past its end, by a count that would overflow added to the place.
            var header = [UInt8](repeating: 0, count: 4096)
            header.replaceSubrange(0..<4, with: Array("sprs".utf8))
            header.replaceSubrange(8..<12, with: [0, 0, 0x08, 0])
            header.replaceSubrange(16..<20, with: [0, 0, 0x08, 0])
            let sparse = try #require(SparseImage(ImageFile(write("s.sparseimage", header))!, header: Bytes(header)))
            #expect(sparse.read(Int64.max - 8, 512) == nil)
            #expect(SparseBundle(path: folder.path, bandSize: 1 << 20, size: 1 << 20).read(Int64.max - 8, 512) == nil)
            #expect(ImageFile(folder.appending("s.sparseimage").path)?.read(Int64.max - 8, 512) == nil)
        }
    }

    // A pipe where a sparse bundle keeps a file would keep a read of it waiting for good: only plain files are read.
    @Test(.timeLimit(.minutes(1))) func aPipeInASparseBundleIsNotWaitedFor() throws {
        try withTemporaryDirectory { folder in
            let bundle = folder.appending("x.sparsebundle").path
            try FileManager.default.createDirectory(atPath: bundle + "/bands", withIntermediateDirectories: true)
            let info: [String: Any] = [
                "diskimage-bundle-type": "com.apple.diskimage.sparsebundle", "size": 1 << 20, "band-size": 1 << 20,
            ]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: URL(fileURLWithPath: bundle + "/Info.plist"))
            #expect(mkfifo(bundle + "/token", 0o644) == 0)
            #expect(mkfifo(bundle + "/bands/0", 0o644) == 0)
            #expect(DiskImageReader.read(bundle) == Image(format: .sparseBundle, capacity: 1 << 20, encrypted: false))
            // One under an image's own name says nothing.
            let pipe = folder.appending("pipe.dmg").path
            #expect(mkfifo(pipe, 0o644) == 0)
            #expect(DiskImageReader.read(pipe) == nil)
            #expect(ImageFile(pipe)?.read(0, 8) == nil)
        }
    }

    // A link to an image says what the image it leads to holds, as a link to a picture says the picture's size.
    @Test func aLinkToAnImageIsReadAsTheImage() throws {
        try withTemporaryDirectory { folder in
            var sparse = [UInt8](repeating: 0, count: 4096)
            sparse.replaceSubrange(0..<4, with: Array("sprs".utf8))
            sparse.replaceSubrange(8..<12, with: [0, 0, 0x08, 0])
            sparse.replaceSubrange(16..<20, with: [0, 0, 0x08, 0])
            let image = folder.appending("disk.sparseimage").path
            FileManager.default.createFile(atPath: image, contents: Data(sparse))
            let link = folder.appending("link.sparseimage").path
            try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: image)
            #expect(DiskImageReader.read(link) == Image(format: .sparse, capacity: 1024 * 1024, encrypted: false))
            #expect(DiskImageReader.read(link) == DiskImageReader.read(image))
            // One that leads nowhere says nothing.
            let broken = folder.appending("broken.dmg").path
            try FileManager.default.createSymbolicLink(atPath: broken, withDestinationPath: folder.path + "/none")
            #expect(DiskImageReader.read(broken) == nil)
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
