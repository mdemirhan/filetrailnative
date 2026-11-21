import FTFileSystem
import FTTestSupport
import Foundation
import Testing

/// What a Finder alias and a symbolic link are told apart by, and where each leads.
@Suite struct LinksTests {
    /// The folder's real path, as an original is given (/private/var for /var).
    private func real(_ folder: TemporaryDirectory) -> String {
        guard let pointer = realpath(folder.path, nil) else { return folder.path }
        defer { free(pointer) }
        return String(cString: pointer)
    }

    private func file(_ folder: TemporaryDirectory, _ name: String) throws -> String {
        let path = real(folder) + "/" + name
        try "text".write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    @Test func anAliasIsOneAndASymbolicLinkIsNot() throws {
        let folder = try TemporaryDirectory(prefix: "filetrail-links")
        defer { folder.remove() }
        let original = try file(folder, "a.txt")
        try Links.writeAlias(of: original, at: folder.path + "/a.txt alias")
        try FileManager.default.createSymbolicLink(atPath: folder.path + "/a link", withDestinationPath: "a.txt")

        #expect(Links.isFinderAlias(folder.path + "/a.txt alias"))
        #expect(!Links.isFinderAlias(folder.path + "/a link"))
        #expect(!Links.isFinderAlias(original))
        #expect(!Links.isFinderAlias(folder.path + "/nothing here"))
    }

    /// An alias, a link, and a link to an alias all lead to the original; anything else is its own.
    @Test func eachLeadsToItsOriginal() throws {
        let folder = try TemporaryDirectory(prefix: "filetrail-links")
        defer { folder.remove() }
        let original = try file(folder, "a.txt")
        try Links.writeAlias(of: original, at: folder.path + "/a.txt alias")
        try FileManager.default.createSymbolicLink(atPath: folder.path + "/a link", withDestinationPath: "a.txt")
        try FileManager.default.createSymbolicLink(
            atPath: folder.path + "/link to alias", withDestinationPath: "a.txt alias")

        #expect(Links.original(of: folder.path + "/a.txt alias") == original)
        #expect(Links.original(of: folder.path + "/a link") == original)
        #expect(Links.original(of: folder.path + "/link to alias") == original)
        #expect(Links.original(of: original) == original)
    }

    /// An alias finds its original after the original is renamed, as Finder's does.
    @Test func anAliasFollowsItsOriginalWhenItIsRenamed() throws {
        let folder = try TemporaryDirectory(prefix: "filetrail-links")
        defer { folder.remove() }
        let original = try file(folder, "a.txt")
        try Links.writeAlias(of: original, at: folder.path + "/a.txt alias")
        try FileManager.default.moveItem(atPath: original, toPath: folder.path + "/b.txt")

        #expect(Links.original(of: folder.path + "/a.txt alias") == real(folder) + "/b.txt")
    }

    /// An original in a folder whose name has a composed accent is given as the disk spells it, byte for byte, not
    /// with the accent taken apart as a URL spells it: it is how the folder's rows are named.
    @Test func anOriginalIsSpelledAsItsDiskSpellsIt() throws {
        let folder = try TemporaryDirectory(prefix: "filetrail-links")
        defer { folder.remove() }
        // Made with the system's calls, which keep the bytes as given: Foundation's would take the accents apart.
        let accented = real(folder) + "/Caf\u{E9}"
        #expect(mkdir(accented, 0o755) == 0)
        let original = accented + "/r\u{E9}sum\u{E9}.txt"
        let descriptor = open(original, O_CREAT | O_WRONLY, 0o644)
        #expect(descriptor >= 0)
        close(descriptor)
        try Links.writeAlias(of: original, at: accented + "/alias")
        try Links.writeAlias(of: accented, at: real(folder) + "/folder alias")

        let found = try #require(Links.original(of: accented + "/alias"))
        #expect(found.utf8.elementsEqual(original.utf8))
        let folderFound = try #require(Links.originalItem(of: real(folder) + "/folder alias"))
        #expect(folderFound.path.utf8.elementsEqual(accented.utf8))
    }

    @Test func aFolderIsOneToOpenInPlaceAndAMissingOriginalIsNothing() throws {
        let folder = try TemporaryDirectory(prefix: "filetrail-links")
        defer { folder.remove() }
        try FileManager.default.createDirectory(atPath: folder.path + "/Inner", withIntermediateDirectories: true)
        try Links.writeAlias(of: folder.path + "/Inner", at: folder.path + "/Inner alias")
        let gone = try file(folder, "gone.txt")
        try Links.writeAlias(of: gone, at: folder.path + "/gone alias")
        try FileManager.default.removeItem(atPath: gone)
        try FileManager.default.createSymbolicLink(atPath: folder.path + "/broken", withDestinationPath: "nowhere")

        let inner = Links.originalItem(of: folder.path + "/Inner alias")
        #expect(inner?.path == real(folder) + "/Inner")
        #expect(inner?.isFolder == true)
        #expect(Links.originalItem(of: folder.path + "/gone alias") == nil)
        #expect(Links.original(of: folder.path + "/broken") == nil)
    }
}
