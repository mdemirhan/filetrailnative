import Darwin
import FTTestSupport
import Foundation
import Testing

@testable import FTFileSystem

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

    /// A folder's listing marks its aliases, and lists an alias of a folder with the folders, as Finder does with
    /// Folders First; an alias of a file stays with the files.
    @Test func aListingKnowsAliasesAndPutsThoseOfFoldersWithTheFolders() async throws {
        let folder = try TemporaryDirectory(prefix: "filetrail-links")
        defer { folder.remove() }
        let base = real(folder)
        try FileManager.default.createDirectory(atPath: base + "/Zeta", withIntermediateDirectories: true)
        _ = try file(folder, "a.txt")
        try Links.writeAlias(of: base + "/Zeta", at: base + "/Zeta alias")
        try Links.writeAlias(of: base + "/a.txt", at: base + "/a.txt alias")

        let snapshot = try await DirectoryService().snapshot(path: base, foldersFirst: true)
        #expect(snapshot.entries.map(\.name) == ["Zeta", "Zeta alias", "a.txt", "a.txt alias"])
        #expect(snapshot.entries.map(\.kind) == [.directory, .aliasDirectory, .file, .alias])
    }

    /// Finder's flag tells an alias as the system's own check by its URL does: of an alias of a file and of a folder,
    /// a file, a folder, a package, a symbolic link to an alias, and what isn't there.
    @Test func theFlagTellsAnAliasAsTheSystemDoes() throws {
        let folder = try TemporaryDirectory(prefix: "filetrail-links")
        defer { folder.remove() }
        let original = try file(folder, "a.txt")
        try FileManager.default.createDirectory(atPath: folder.path + "/Inner", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: folder.path + "/Tool.app", withIntermediateDirectories: true)
        try Links.writeAlias(of: original, at: folder.path + "/a alias")
        try Links.writeAlias(of: folder.path + "/Inner", at: folder.path + "/Inner alias")
        try FileManager.default.createSymbolicLink(atPath: folder.path + "/link", withDestinationPath: "a alias")
        let paths = ["a.txt", "Inner", "Tool.app", "a alias", "Inner alias", "link", "missing"].map {
            folder.path + "/" + $0
        }
        for path in paths {
            #expect(Links.isFinderAlias(path) == Links.isFinderAliasByURL(path), "\(path)")
        }
        #expect(
            paths.filter(Links.isFinderAlias).map { ($0 as NSString).lastPathComponent } == ["a alias", "Inner alias"])
    }

    /// A search may ask each file it passes whether it is an alias: Finder's flag, read with one call, costs well under
    /// half of asking through the item's URL.
    @Test func anAliasIsToldWithOneCall() throws {
        let folder = try TemporaryDirectory(prefix: "filetrail-links")
        defer { folder.remove() }
        let paths = try (0..<2_000).map { try file(folder, "file \($0).txt") }
        var flag = Double.infinity
        var url = Double.infinity
        for _ in 0..<3 {
            flag = min(flag, CPUTime.measureThread { for path in paths { _ = Links.isFinderAlias(path) } }.seconds)
            url = min(url, CPUTime.measureThread { for path in paths { _ = Links.isFinderAliasByURL(path) } }.seconds)
        }
        #expect(flag * 2 < url, "flag \(flag), URL \(url)")
    }

    /// A link or an alias whose original is gone is broken; one whose original is there, on a disk not connected,
    /// or anything else isn't.
    @Test func brokenIsALinkOrAnAliasLeadingNowhere() throws {
        let folder = try TemporaryDirectory(prefix: "filetrail-links")
        defer { folder.remove() }
        let original = try file(folder, "a.txt")
        let gone = try file(folder, "gone.txt")
        try Links.writeAlias(of: original, at: folder.path + "/a alias")
        try Links.writeAlias(of: gone, at: folder.path + "/gone alias")
        try FileManager.default.createSymbolicLink(atPath: folder.path + "/a link", withDestinationPath: "a.txt")
        try FileManager.default.createSymbolicLink(atPath: folder.path + "/gone link", withDestinationPath: "gone.txt")
        try FileManager.default.createSymbolicLink(
            atPath: folder.path + "/unplugged link", withDestinationPath: "/Volumes/No Such Disk 7f72e9/a.txt")
        try FileManager.default.removeItem(atPath: gone)
        func broken(_ name: String, link: Bool = false) -> Bool {
            Links.isBroken(folder.path + "/" + name, isLink: link)
        }
        #expect(broken("gone link", link: true))
        #expect(broken("gone alias"))
        #expect(!broken("a link", link: true))
        #expect(!broken("a alias"))
        #expect(!broken("unplugged link", link: true))
        #expect(!broken("a.txt"))
        // A relative link to a disk not connected, by as many `..` as lead to the top.
        let up = String(repeating: "../", count: real(folder).split(separator: "/").count)
        try FileManager.default.createSymbolicLink(
            atPath: folder.path + "/unplugged relative link", withDestinationPath: up + "Volumes/No Such Disk 7f72e9/a")
        #expect(!broken("unplugged relative link", link: true))
        // An original that is there, in a folder that can't be entered, isn't gone.
        try FileManager.default.createDirectory(atPath: folder.path + "/shut", withIntermediateDirectories: false)
        _ = try file(folder, "shut/in.txt")
        try FileManager.default.createSymbolicLink(
            atPath: folder.path + "/shut link", withDestinationPath: "shut/in.txt")
        chmod(folder.path + "/shut", 0)
        defer { chmod(folder.path + "/shut", 0o700) }
        #expect(!broken("shut link", link: true))
        // A link that leads round to itself leads nowhere.
        try FileManager.default.createSymbolicLink(atPath: folder.path + "/round", withDestinationPath: "round")
        #expect(broken("round", link: true))
    }
}
