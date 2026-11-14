// Which files Extract takes apart, and what Extract and Compress name what they make
import FTFoundation
import Testing

@Suite struct ArchiveNamesTests {
    @Test(arguments: [
        ("Photos.zip", ArchiveNames.Kind.items), ("src.tar.gz", .items), ("src.TGZ", .items), ("a.tar.bz2", .items),
        ("a.tbz2", .items), ("a.tar.xz", .items), ("a.txz", .items), ("a.tar", .items), ("a.7z", .items),
        ("a.rar", .items), ("a.xar", .items), ("notes.txt.gz", .singleFile), ("dump.bz2", .singleFile),
        ("log.xz", .singleFile),
    ])
    func archivesAreKnownByTheirSuffix(_ name: String, _ kind: ArchiveNames.Kind) {
        #expect(ArchiveNames.kind(of: name) == kind)
    }

    @Test(arguments: [
        "report.docx", "book.epub", "app.jar", "Installer.pkg", "disk.dmg", "image.iso", "src.tar.zst",
        "src.tar.lz4", ".zip", "zip", "notes.txt",
    ])
    func documentsInstallersDiskImagesAndWhatTheSystemCantReadAreNot(_ name: String) {
        #expect(!ArchiveNames.isArchive(name))
    }

    @Test(arguments: [
        ("Photos.zip", "Photos"), ("src.tar.gz", "src"), ("src.TGZ", "src"), ("Backup 2.tar.bz2", "Backup 2"),
        ("notes.txt.gz", "notes.txt"), ("v1.2.7z", "v1.2"), ("plain", "plain"),
    ])
    func whatComesOutIsNamedAfterTheArchiveWithoutItsSuffix(_ name: String, _ extracted: String) {
        #expect(ArchiveNames.extractedName(name) == extracted)
    }

    @Test func compressNamesTheZipAsFinderDoes() {
        #expect(ArchiveNames.zipName(for: ["Photos"]) == "Photos.zip")
        #expect(ArchiveNames.zipName(for: ["notes.txt"]) == "notes.txt.zip")
        #expect(ArchiveNames.zipName(for: ["a", "b"]) == "Archive.zip")
    }

    @Test func theMenusNameWhatIsCompressed() {
        #expect(ArchiveNames.compressTitle(["Photos"]) == "Compress \u{201C}Photos\u{201D}")
        #expect(ArchiveNames.compressTitle(count: 1_234, firstName: "a") == "Compress 1,234 Items")
        #expect(ArchiveNames.compressTitle(count: 0, firstName: nil) == nil)
    }
}
