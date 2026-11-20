// What extracting writes to the disk, item by item: archives that try to get out of the folder, names twice, items
// that can't be kept, read-only items, and the umask left alone
import Darwin
import FTFoundation
import FTTestSupport
import Foundation
import Synchronization
import Testing

@testable import FTOperations

@Suite struct NativeArchiveTests {
    /// A folder with `archive` (a path for the archive to be written at) and `out` (an empty folder to extract into).
    struct Folders {
        let directory: TemporaryDirectory
        var root: String { directory.path }
        var archive: String { "\(root)/test.tar" }
        var out: String { "\(root)/out" }

        init() throws {
            directory = try TemporaryDirectory(prefix: "filetrail-archive")
            try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: false)
        }
    }

    /// Extracts `archive` into `folder`; how many items were left out.
    @discardableResult
    static func extract(_ archive: String, into folder: String) throws -> Int64 {
        let control = NativeArchive.Control()
        try NativeArchive.extract(archive, into: folder, rawName: nil, quarantine: true, control: control)
        return control.skipped
    }

    static func names(_ folder: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder).sorted()
    }

    static func status(_ path: String) throws -> Darwin.stat {
        var info = Darwin.stat()
        guard lstat(path, &info) == 0 else { throw OperationError("lstat \(path): \(errno)") }
        return info
    }

    static func mode(_ path: String) throws -> mode_t { try status(path).st_mode & 0o7777 }

    static let quarantine = "0083;6734a1b2;Safari;"

    // MARK: Quarantine and permissions

    @Test func readOnlyItemsGetTheQuarantineAndTheirPermissions() throws {
        let folders = try Folders()
        defer { folders.directory.remove() }
        var tar = TarBuilder()
        tar.add("locked/", .folder, mode: 0o555)
        tar.add("locked/inside.txt", mode: 0o444, contents: "inside")
        tar.add("locked/deeper/", .folder, mode: 0o500)
        tar.add("locked/deeper/leaf.txt", mode: 0o400, contents: "leaf")
        tar.add("plain.txt", mode: 0o444, contents: "plain")
        tar.add("made/on/the/way.txt", contents: "way")
        try tar.write(to: folders.archive)
        ArchiveOperationsTests.setAttribute(folders.archive, "com.apple.quarantine", Self.quarantine)
        #expect(try Self.extract(folders.archive, into: folders.out) == 0)
        for item in [
            "", "locked", "locked/inside.txt", "locked/deeper", "locked/deeper/leaf.txt", "plain.txt", "made",
            "made/on", "made/on/the", "made/on/the/way.txt",
        ] {
            #expect(
                ArchiveOperationsTests.attribute("\(folders.out)/\(item)", "com.apple.quarantine") == Self.quarantine,
                "\(item)")
        }
        #expect(try Self.mode("\(folders.out)/locked") == 0o555)
        #expect(try Self.mode("\(folders.out)/locked/inside.txt") == 0o444)
        #expect(try Self.mode("\(folders.out)/locked/deeper") == 0o500)
        #expect(try Self.mode("\(folders.out)/locked/deeper/leaf.txt") == 0o400)
        #expect(try Self.mode("\(folders.out)/plain.txt") == 0o444)
    }

    @Test func foldersGetTheirDatesAfterTheirContents() throws {
        let folders = try Folders()
        defer { folders.directory.remove() }
        var tar = TarBuilder()
        tar.add("old/", .folder, mode: 0o755, modified: 1_500_000_000)
        tar.add("old/file.txt", contents: "x", modified: 1_600_000_000)
        tar.add("old/sub/", .folder, mode: 0o755, modified: 1_400_000_000)
        try tar.write(to: folders.archive)
        try Self.extract(folders.archive, into: folders.out)
        #expect(try Self.status("\(folders.out)/old").st_mtimespec.tv_sec == 1_500_000_000)
        #expect(try Self.status("\(folders.out)/old/file.txt").st_mtimespec.tv_sec == 1_600_000_000)
        #expect(try Self.status("\(folders.out)/old/sub").st_mtimespec.tv_sec == 1_400_000_000)
    }

    @Test func setuidBitsAreTakenOff() throws {
        let folders = try Folders()
        defer { folders.directory.remove() }
        var tar = TarBuilder()
        tar.add("tool", mode: 0o6755, contents: "#!/bin/sh\n")
        tar.add("shared/", .folder, mode: 0o1777)
        try tar.write(to: folders.archive)
        try Self.extract(folders.archive, into: folders.out)
        #expect(try Self.mode("\(folders.out)/tool") == 0o755)
        // Nor is anything left writable by anyone but its owner.
        #expect(try Self.mode("\(folders.out)/shared") == 0o755)
    }

    // MARK: Access rules

    /// An archive whose items deny writing their attributes (bin's rule inherited by what is made in it) would keep
    /// them from being quarantined, and one that denies deleting them would keep a stop or Undo from clearing them
    /// away: no access rule comes out of an archive.
    @Test(arguments: ["zip", "tar"]) func accessRulesDontComeOutSoTheQuarantineStaysOn(kind: String) throws {
        let folders = try Folders()
        defer { folders.directory.remove() }
        let archive =
            kind == "zip" ? try AccessRuleArchive.zip(in: folders.root) : try AccessRuleArchive.tar(in: folders.root)
        ArchiveOperationsTests.setAttribute(archive, "com.apple.quarantine", Self.quarantine)
        #expect(try Self.extract(archive, into: folders.out) == 0)
        for item in AccessRuleArchive.items(in: folders.out) {
            #expect(ArchiveOperationsTests.attribute(item, "com.apple.quarantine") == Self.quarantine, "\(item)")
            #expect(!AccessRuleArchive.hasAccessRules(item), "\(item)")
            #expect(ArchiveOperationsTests.attribute(item, "com.apple.acl.text") == nil, "\(item)")
        }
        #expect(try String(contentsOfFile: "\(folders.out)/Evil/bin/tool", encoding: .utf8) == "#!/bin/sh\n")
        try NativeRemoval.rm(folders.out, recursive: true, force: true, unlockingFolders: true)
        #expect(!FileManager.default.fileExists(atPath: folders.out))
    }

    /// The folder extracted into has a rule that denies writing attributes to what is made in it: the first item made
    /// can't be quarantined, and the archive fails.
    @Test func anItemThatRefusesTheQuarantineFailsTheArchive() throws {
        let folders = try Folders()
        defer {
            _ = try? ArchiveOperationsTests.run("/bin/chmod", ["-R", "-N", folders.root])
            folders.directory.remove()
        }
        var tar = TarBuilder()
        tar.add("first.txt", contents: "first")
        tar.add("second.txt", contents: "second")
        try tar.write(to: folders.archive)
        ArchiveOperationsTests.setAttribute(folders.archive, "com.apple.quarantine", Self.quarantine)
        // The items refuse it, and then the folder itself too.
        let refusing = "\(folders.root)/refusing"
        try FileManager.default.createDirectory(atPath: refusing, withIntermediateDirectories: false)
        let rule = "everyone deny writeextattr,file_inherit,directory_inherit"
        try ArchiveOperationsTests.run("/bin/chmod", ["+a", rule + ",only_inherit", folders.out])
        try ArchiveOperationsTests.run("/bin/chmod", ["+a", rule, refusing])
        for folder in [folders.out, refusing] {
            let error = #expect(throws: ArchiveError.self) { try Self.extract(folders.archive, into: folder) }
            #expect(error?.reason == .notQuarantined, "\(folder)")
            #expect(error?.message.contains("couldn\u{2019}t be marked as downloaded") == true)
        }
        #expect(try Self.names(refusing).isEmpty)
        // Without a quarantine on the archive, nothing is asked of the items.
        try ArchiveOperationsTests.run("/usr/bin/xattr", ["-d", "com.apple.quarantine", folders.archive])
        let plain = "\(folders.root)/plain"
        try FileManager.default.createDirectory(atPath: plain, withIntermediateDirectories: false)
        try ArchiveOperationsTests.run("/bin/chmod", ["+a", rule + ",only_inherit", plain])
        #expect(try Self.extract(folders.archive, into: plain) == 0)
        #expect(try Self.names(plain) == ["first.txt", "second.txt"])
    }

    /// A disk that keeps no extended attributes at all: what comes out goes without the quarantine, as nothing on it
    /// can have one, rather than not at all.
    @Test func onADiskThatKeepsNoAttributesItemsComeOutWithoutTheQuarantine() throws {
        let folders = try Folders()
        defer { folders.directory.remove() }
        var tar = TarBuilder()
        tar.add("first.txt", contents: "first")
        tar.add("sub/second.txt", contents: "second")
        try tar.write(to: folders.archive)
        ArchiveOperationsTests.setAttribute(folders.archive, "com.apple.quarantine", Self.quarantine)
        let control = NativeArchive.Control()
        control.takeDiskAsKeepingNoAttributes()
        try NativeArchive.extract(folders.archive, into: folders.out, rawName: nil, quarantine: true, control: control)
        #expect(try Self.names(folders.out) == ["first.txt", "sub"])
        for item in ["", "first.txt", "sub", "sub/second.txt"] {
            let path = "\(folders.out)/\(item)"
            #expect(ArchiveOperationsTests.attribute(path, "com.apple.quarantine") == nil, "\(item)")
        }
    }

    /// A downloaded zip that holds a "._a.txt" of its own, taken apart on a disk that keeps attributes in "._name"
    /// files (exFAT, FAT32): the system takes a file of that name for the attributes of the item beside it and gives
    /// it none of its own, the quarantine neither. It is left out and counted, whichever of the two comes first, and
    /// the item comes out quarantined. Only a release runs it: it mounts an image of each.
    @Test(
        .tags(.diskImage), .diskImages, .enabled(if: ReleaseTests.enabled), arguments: [DiskImage.Kind.exfat, .fat32])
    func aZipsOwnAttributesFileIsLeftOutOnADiskThatKeepsAttributesInFiles(kind: DiskImage.Kind) async throws {
        try await DiskImage.withVolume(kind) { volume in
            let folders = try Folders()
            defer { folders.directory.remove() }
            let zipPath = "\(folders.root)/photos.zip"
            for (index, names) in [["._a.txt", "a.txt"], ["a.txt", "._a.txt"]].enumerated() {
                var zip = ZipBuilder()
                for name in names {
                    zip.add(name: Array(name.utf8), contents: name == "a.txt" ? "a" : "bytes of the zip\u{2019}s own")
                }
                try zip.write(to: zipPath)
                ArchiveOperationsTests.setAttribute(zipPath, "com.apple.quarantine", Self.quarantine)
                let out = "\(volume.path)/out\(index)"
                try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: false)
                #expect(try Self.extract(zipPath, into: out) == 1, "\(names)")
                #expect(try String(contentsOfFile: "\(out)/a.txt", encoding: .utf8) == "a")
                #expect(ArchiveOperationsTests.attribute("\(out)/a.txt", "com.apple.quarantine") == Self.quarantine)
                // What is beside it is the file the disk keeps its quarantine in, not the zip's.
                #expect(try NativeWriteFileSystem().readdir(out).sorted() == ["._a.txt", "a.txt"])
                #expect(NativeFS.isAppleDoubleOnItsVolume("\(out)/._a.txt"))
            }
        }
    }

    /// A quarantine longer than a kilobyte is read whole, and put on every item.
    @Test func aLongQuarantineIsKeptWhole() throws {
        let folders = try Folders()
        defer { folders.directory.remove() }
        var tar = TarBuilder()
        tar.add("folder/", .folder, mode: 0o755)
        tar.add("folder/file.txt", contents: "x")
        try tar.write(to: folders.archive)
        let long = "0083;6734a1b2;\(String(repeating: "Agent", count: 400));"
        ArchiveOperationsTests.setAttribute(folders.archive, "com.apple.quarantine", long)
        #expect(ArchiveOperationsTests.attribute(folders.archive, "com.apple.quarantine") == long)
        try Self.extract(folders.archive, into: folders.out)
        for item in ["", "folder", "folder/file.txt"] {
            let path = "\(folders.out)/\(item)"
            #expect(ArchiveOperationsTests.attribute(path, "com.apple.quarantine") == long, "\(item)")
        }
    }

    // MARK: The umask

    /// Extracting on one thread while others make folders: each of those must come out with the permissions the
    /// umask gives, which extracting must never clear, not even for a moment.
    @Test func extractingLeavesTheUmaskAloneForOtherThreads() throws {
        let folders = try Folders()
        defer { folders.directory.remove() }
        // Many small items: the umask would be cleared once for each. A few hundred in all are enough to be seen, as
        // extracting no longer goes near the umask; the other threads spin while it runs.
        var tar = TarBuilder()
        for index in 0..<100 { tar.add("folder\(index)/", .folder, mode: 0o755) }
        try tar.write(to: folders.archive)
        let probe = "\(folders.root)/probe"
        #expect(mkdir(probe, 0o777) == 0)
        let expected = try Self.mode(probe)

        let extracting = DispatchGroup()
        DispatchQueue.global().async(group: extracting) {
            for round in 0..<2 {
                let out = "\(folders.root)/round\(round)"
                guard mkdir(out, 0o755) == 0, (try? Self.extract(folders.archive, into: out)) != nil else { return }
            }
        }
        let wrong = Mutex<[mode_t]>([])
        let made = Mutex(0)
        DispatchQueue.concurrentPerform(iterations: 3) { thread in
            let scratch = "\(folders.root)/scratch\(thread)"
            var count = 0
            while extracting.wait(timeout: .now()) == .timedOut, mkdir(scratch, 0o777) == 0 {
                count += 1
                if let mode = try? Self.mode(scratch), mode != expected { wrong.withLock { $0.append(mode) } }
                rmdir(scratch)
            }
            made.withLock { $0 += count }
        }
        let all = wrong.withLock { $0 }
        #expect(all.isEmpty, "\(all.count) of \(made.withLock { $0 }) folders came out with other permissions")
        #expect(try Self.names("\(folders.root)/round1").count == 100)
    }

    // MARK: Names

    @Test func anItemThroughALinkAnEarlierItemMadeIsLeftOut() throws {
        let folders = try Folders()
        defer { folders.directory.remove() }
        let outside = "\(folders.root)/outside"
        try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: false)
        var tar = TarBuilder()
        tar.add("way", .symlink, link: "../outside")
        tar.add("way/planted.txt", contents: "planted")
        tar.add("way/deeper/planted.txt", contents: "planted")
        tar.add("fine.txt", contents: "fine")
        try tar.write(to: folders.archive)
        #expect(try Self.extract(folders.archive, into: folders.out) == 2)
        #expect(try Self.names(outside).isEmpty)
        #expect(try Self.names(folders.out) == ["fine.txt", "way"])
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: "\(folders.out)/way") == "../outside")
    }

    @Test func aHardLinkToALinkThatPointsOutsideIsLeftOut() throws {
        let folders = try Folders()
        defer { folders.directory.remove() }
        let secret = "\(folders.root)/secret.txt"
        try Data("secret".utf8).write(to: URL(fileURLWithPath: secret))
        #expect(chmod(secret, 0o600) == 0)
        var tar = TarBuilder()
        tar.add("way", .symlink, link: "../secret.txt")
        tar.add("second", .hardLink, mode: 0o777, link: "way")
        tar.add("second", mode: 0o777, contents: "replaced")
        tar.add("real.txt", contents: "real")
        tar.add("twin.txt", .hardLink, link: "real.txt")
        tar.add("climbing", .hardLink, link: "../secret.txt")
        try tar.write(to: folders.archive)
        // The two hard links that aren't to a file of the archive; the file "second" is then free to be written.
        #expect(try Self.extract(folders.archive, into: folders.out) == 2)
        #expect(try String(contentsOfFile: secret, encoding: .utf8) == "secret")
        #expect(try Self.status(secret).st_nlink == 1)
        #expect(try Self.mode(secret) == 0o600)
        #expect(try String(contentsOfFile: "\(folders.out)/second", encoding: .utf8) == "replaced")
        #expect(try Self.status("\(folders.out)/twin.txt").st_ino == Self.status("\(folders.out)/real.txt").st_ino)
        #expect(try Self.names(folders.out) == ["real.txt", "second", "twin.txt", "way"])
    }

    @Test func aTarOfAFolderItselfLeavesNothingOut() throws {
        let folders = try Folders()
        defer { folders.directory.remove() }
        let source = "\(folders.root)/source"
        try FileManager.default.createDirectory(atPath: "\(source)/sub", withIntermediateDirectories: true)
        try Data("a".utf8).write(to: URL(fileURLWithPath: "\(source)/a.txt"))
        try Data("b".utf8).write(to: URL(fileURLWithPath: "\(source)/sub/b.txt"))
        // Its first item is "./", the folder itself.
        try ArchiveOperationsTests.run("/usr/bin/tar", ["-cf", folders.archive, "-C", source, "."])
        #expect(try Self.extract(folders.archive, into: folders.out) == 0)
        #expect(try Self.names(folders.out) == ["a.txt", "sub"])
    }

    @Test func aSecondItemOfANameLeavesTheFirstAsItWas() throws {
        let folders = try Folders()
        defer { folders.directory.remove() }
        var tar = TarBuilder()
        tar.add("a.txt", mode: 0o600, contents: "first", modified: 1_500_000_000)
        tar.add("a.txt", mode: 0o755, contents: "second, and longer", modified: 1_600_000_000)
        tar.add("sub/", .folder, mode: 0o700, modified: 1_500_000_000)
        tar.add("sub/", .folder, mode: 0o755, modified: 1_600_000_000)
        tar.add("a.txt", .symlink, link: "/etc/hosts")
        try tar.write(to: folders.archive)
        #expect(try Self.extract(folders.archive, into: folders.out) == 3)
        #expect(try String(contentsOfFile: "\(folders.out)/a.txt", encoding: .utf8) == "first")
        #expect(try Self.mode("\(folders.out)/a.txt") == 0o600)
        #expect(try Self.status("\(folders.out)/a.txt").st_mtimespec.tv_sec == 1_500_000_000)
        #expect(try Self.mode("\(folders.out)/sub") == 0o700)
        #expect(try Self.status("\(folders.out)/sub").st_mtimespec.tv_sec == 1_500_000_000)
    }

    @Test func namesThatDifferOnlyInCaseKeepTheFirstWhereTheDiskIgnoresCase() throws {
        let folders = try Folders()
        defer { folders.directory.remove() }
        var tar = TarBuilder()
        tar.add("Readme.txt", contents: "first")
        tar.add("README.TXT", contents: "second")
        try tar.write(to: folders.archive)
        let skipped = try Self.extract(folders.archive, into: folders.out)
        let values = try folders.directory.url.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
        if values.volumeSupportsCaseSensitiveNames == true {
            #expect(skipped == 0)
            #expect(try Self.names(folders.out) == ["README.TXT", "Readme.txt"])
        } else {
            #expect(skipped == 1)
            #expect(try Self.names(folders.out) == ["Readme.txt"])
            #expect(try String(contentsOfFile: "\(folders.out)/Readme.txt", encoding: .utf8) == "first")
        }
    }

    @Test func aFolderNamedAfterItsContentsTakesItsPermissions() throws {
        let folders = try Folders()
        defer { folders.directory.remove() }
        var tar = TarBuilder()
        tar.add("late/file.txt", contents: "x")
        tar.add("late/", .folder, mode: 0o750, modified: 1_500_000_000)
        try tar.write(to: folders.archive)
        #expect(try Self.extract(folders.archive, into: folders.out) == 0)
        #expect(try Self.mode("\(folders.out)/late") == 0o750)
        #expect(try Self.status("\(folders.out)/late").st_mtimespec.tv_sec == 1_500_000_000)
    }

    @Test func devicesAndPipesAreLeftOutAndTheRestComesOut() throws {
        let folders = try Folders()
        defer { folders.directory.remove() }
        var tar = TarBuilder()
        tar.add("dev/", .folder, mode: 0o755)
        tar.add("dev/null", .characterDevice, mode: 0o666)
        tar.add("dev/pipe", .pipe)
        tar.add("etc/hostname", contents: "box\n")
        try tar.write(to: folders.archive)
        #expect(try Self.extract(folders.archive, into: folders.out) == 2)
        #expect(try Self.names(folders.out) == ["dev", "etc"])
        #expect(try Self.names("\(folders.out)/dev").isEmpty)
        #expect(try String(contentsOfFile: "\(folders.out)/etc/hostname", encoding: .utf8) == "box\n")
    }

    // MARK: Names that aren't UTF-8

    /// A zip made where names aren't UTF-8 doesn't say what they are written in: they are read in the encoding they
    /// fit, all of them, also a name that is UTF-8 as it stands. One that encoding can't read is left out.
    @Test func aZipWhoseNamesAreShiftJISComesOutWithTheNamesRead() throws {
        let folders = try Folders()
        defer { folders.directory.remove() }
        let zipPath = "\(folders.root)/names.zip"
        var zip = ZipBuilder()
        zip.add(name: Array("plain.txt".utf8), contents: "before")
        // "テスト.txt" in Shift-JIS.
        zip.add(name: [0x83, 0x65, 0x83, 0x58, 0x83, 0x67] + Array(".txt".utf8), contents: "shift-jis")
        // "日本.txt" in UTF-8 (E6 97 A5, E6 9C AC), which the zip doesn't mark: read in Shift-JIS as the zip's other
        // names are, it is "譌･譛ｬ.txt".
        zip.add(name: Array("日本.txt".utf8), contents: "utf-8")
        // "日本/ğüş.txt" in UTF-8 is no name in Shift-JIS ("ş." is C5, then 9F 2E, and no pair ends in 2E): left out.
        zip.add(name: Array("日本/ğüş.txt".utf8), contents: "no name")
        // "資料/表計算ソフト.txt": 表 and ソ end in the byte of a backslash, 0x5C.
        let folder: [UInt8] = [0x8E, 0x91, 0x97, 0xBF]
        let sheet: [UInt8] = [0x95, 0x5C, 0x8C, 0x76, 0x8E, 0x5A, 0x83, 0x5C, 0x83, 0x74, 0x83, 0x67]
        zip.add(name: folder + [0x2F] + sheet + Array(".txt".utf8), contents: "sheet")
        // "ガ.txt": comes out as one character, not "カ" and its mark.
        zip.add(name: [0x83, 0x4B] + Array(".txt".utf8), contents: "composed")
        try zip.write(to: zipPath)
        #expect(try Self.extract(zipPath, into: folders.out) == 1)
        #expect(try Self.names(folders.out) == ["plain.txt", "ガ.txt", "テスト.txt", "譌･譛ｬ.txt", "資料"].sorted())
        #expect(try Self.names(folders.out).contains { $0.unicodeScalars.elementsEqual("ガ.txt".unicodeScalars) })
        #expect(try String(contentsOfFile: "\(folders.out)/テスト.txt", encoding: .utf8) == "shift-jis")
        #expect(try String(contentsOfFile: "\(folders.out)/譌･譛ｬ.txt", encoding: .utf8) == "utf-8")
        #expect(try String(contentsOfFile: "\(folders.out)/資料/表計算ソフト.txt", encoding: .utf8) == "sheet")
        #expect(try String(contentsOfFile: "\(folders.out)/plain.txt", encoding: .utf8) == "before")
    }

    /// A name in the zip's encoding whose bytes are UTF-8 as they stand is read in that encoding like the zip's other
    /// names, wherever it comes: "目录" in GBK (C4 BF, C2 BC) is "Ŀ¼" in UTF-8, and taken for that it would be a
    /// second folder beside the one the zip's other items go into.
    @Test func aNameThatIsUTF8AsItStandsIsReadInTheZipsEncoding() throws {
        let folders = try Folders()
        defer { folders.directory.remove() }
        let zipPath = "\(folders.root)/names.zip"
        var zip = ZipBuilder()
        let folder: [UInt8] = [0xC4, 0xBF, 0xC2, 0xBC]
        // "目录/目录.txt" first, before any name that isn't UTF-8; then "目录/照片.txt" and "说明文档.txt".
        zip.add(name: folder + [0x2F] + folder + Array(".txt".utf8), contents: "list")
        zip.add(name: folder + [0x2F, 0xD5, 0xD5, 0xC6, 0xAC] + Array(".txt".utf8), contents: "photo")
        zip.add(name: [0xCB, 0xB5, 0xC3, 0xF7, 0xCE, 0xC4, 0xB5, 0xB5] + Array(".txt".utf8), contents: "notes")
        try zip.write(to: zipPath)
        let control = NativeArchive.Control()
        try NativeArchive.extract(zipPath, into: folders.out, rawName: nil, quarantine: true, control: control)
        #expect(control.skipped == 0)
        #expect(control.nameEncodingsAsked == 1)
        #expect(try Self.names(folders.out) == ["目录", "说明文档.txt"].sorted())
        #expect(try Self.names("\(folders.out)/目录") == ["照片.txt", "目录.txt"].sorted())
        #expect(try String(contentsOfFile: "\(folders.out)/目录/目录.txt", encoding: .utf8) == "list")
        #expect(try String(contentsOfFile: "\(folders.out)/目录/照片.txt", encoding: .utf8) == "photo")
    }

    @Test func aZipWhoseNamesAreGBKComesOutWithTheNamesRead() throws {
        let folders = try Folders()
        defer { folders.directory.remove() }
        let zipPath = "\(folders.root)/names.zip"
        var zip = ZipBuilder()
        // "中文文件夹/说明文档.txt" and "中文文件夹/照片.txt" in GBK.
        let folder: [UInt8] = [0xD6, 0xD0, 0xCE, 0xC4, 0xCE, 0xC4, 0xBC, 0xFE, 0xBC, 0xD0, 0x2F]
        let notes: [UInt8] = [0xCB, 0xB5, 0xC3, 0xF7, 0xCE, 0xC4, 0xB5, 0xB5]
        zip.add(name: folder + notes + Array(".txt".utf8), contents: "notes")
        zip.add(name: folder + [0xD5, 0xD5, 0xC6, 0xAC] + Array(".txt".utf8), contents: "photo")
        try zip.write(to: zipPath)
        #expect(try Self.extract(zipPath, into: folders.out) == 0)
        #expect(try Self.names(folders.out) == ["中文文件夹"])
        #expect(try Self.names("\(folders.out)/中文文件夹") == ["照片.txt", "说明文档.txt"].sorted())
        #expect(try String(contentsOfFile: "\(folders.out)/中文文件夹/说明文档.txt", encoding: .utf8) == "notes")
    }

    /// The names are checked as they are read in their encoding: one that climbs out or starts at the root is left
    /// out, as in any archive.
    @Test func namesReadInAnEncodingAreStillKeptInsideTheFolder() throws {
        let folders = try Folders()
        defer { folders.directory.remove() }
        let zipPath = "\(folders.root)/names.zip"
        // "テスト" in Shift-JIS.
        let test: [UInt8] = [0x83, 0x65, 0x83, 0x58, 0x83, 0x67]
        var zip = ZipBuilder()
        zip.add(name: Array("../".utf8) + test + Array(".txt".utf8), contents: "out")
        zip.add(name: test + Array("/../../up.txt".utf8), contents: "out")
        zip.add(name: Array("/tmp/".utf8) + test, contents: "out")
        zip.add(name: test + Array("/./in.txt".utf8), contents: "in")
        try zip.write(to: zipPath)
        #expect(try Self.extract(zipPath, into: folders.out) == 3)
        #expect(try Self.names(folders.out) == ["テスト"])
        #expect(try Self.names("\(folders.out)/テスト") == ["in.txt"])
        #expect(try Self.names(folders.root).sorted() == ["names.zip", "out"])
    }

    /// Names in UTF-8 need no guess, marked as UTF-8 or not: no encoding is asked for, and its names are as they were.
    @Test func aZipWhoseNamesAreUTF8IsReadAsItIs() throws {
        let folders = try Folders()
        defer { folders.directory.remove() }
        let zipPath = "\(folders.root)/names.zip"
        var zip = ZipBuilder()
        zip.add(name: Array("日本/ğüş.txt".utf8), contents: "utf-8")
        zip.add(name: Array("Café.txt".utf8), contents: "latin")
        try zip.write(to: zipPath)
        let control = NativeArchive.Control()
        try NativeArchive.extract(zipPath, into: folders.out, rawName: nil, quarantine: true, control: control)
        #expect(control.nameEncodingsAsked == 0)
        #expect(try Self.names(folders.out) == ["Café.txt", "日本"])
        #expect(try String(contentsOfFile: "\(folders.out)/日本/ğüş.txt", encoding: .utf8) == "utf-8")

        // One with such a name is asked about once, however many it has.
        var other = ZipBuilder()
        other.add(name: [0x83, 0x65] + Array(".txt".utf8), contents: "a")
        other.add(name: [0x83, 0x58] + Array(".txt".utf8), contents: "b")
        try other.write(to: zipPath)
        let out = "\(folders.root)/out2"
        try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: false)
        let second = NativeArchive.Control()
        try NativeArchive.extract(zipPath, into: out, rawName: nil, quarantine: true, control: second)
        #expect(second.nameEncodingsAsked == 1)
        #expect(try Self.names(out) == ["ス.txt", "テ.txt"])
    }

    /// Names no encoding tried reads whole are read as the zip format's own default, MS-DOS's.
    @Test func namesThatFitNoEncodingTriedAreReadAsCP437() throws {
        let folders = try Folders()
        defer { folders.directory.remove() }
        let zipPath = "\(folders.root)/names.zip"
        var zip = ZipBuilder()
        // "Café/über.txt" in CP437: 0x81 is no character in Windows-1252, and 0x82 0x2F no pair in the others.
        zip.add(name: [0x43, 0x61, 0x66, 0x82, 0x2F, 0x81] + Array("ber.txt".utf8), contents: "dos")
        try zip.write(to: zipPath)
        #expect(try Self.extract(zipPath, into: folders.out) == 0)
        #expect(try Self.names(folders.out) == ["Café"])
        #expect(try String(contentsOfFile: "\(folders.out)/Café/über.txt", encoding: .utf8) == "dos")
    }

    @Test func theEncodingsOfTheUsersLanguagesAreTriedFirst() {
        func order(_ languages: [String]) -> [String] {
            ArchiveNameEncoding.candidates(preferredLanguages: languages).map(\.charset)
        }
        #expect(order(["en-US"]) == ["CP932", "GB18030", "BIG5", "CP949", "CP1252"])
        #expect(order(["ko-KR", "en-US"]) == ["CP949", "CP932", "GB18030", "BIG5", "CP1252"])
        #expect(order(["en", "zh-Hant-TW", "zh-Hans-CN"]) == ["BIG5", "GB18030", "CP932", "CP949", "CP1252"])
        #expect(order(["zh-TW", "ja"]) == ["BIG5", "CP932", "GB18030", "CP949", "CP1252"])

        func charset(_ text: String, _ encoding: CFStringEncodings, languages: [String] = ["en"]) -> String {
            let ns = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(encoding.rawValue))
            let names = (text as NSString).data(using: ns) ?? Data()
            return ArchiveNameEncoding.charset(forNames: names, preferredLanguages: languages)
        }
        #expect(charset("資料.txt\n", .dosJapanese) == "CP932")
        #expect(charset("照片.txt\n", .GB_18030_2000, languages: ["ja"]) == "GB18030")
        #expect(charset("繁體中文/說明文件.txt\n", .big5) == "BIG5")
        #expect(charset("한국어/문서.txt\n", .dosKorean) == "CP949")
        let latin = Data("Café/Übergröße.txt\n".unicodeScalars.map { UInt8($0.value) })
        #expect(ArchiveNameEncoding.charset(forNames: latin, preferredLanguages: ["en"]) == "CP1252")
        #expect(ArchiveNameEncoding.charset(forNames: Data([0x43, 0x82, 0x2F, 0x81, 0x0A])) == "CP437")
    }

    @Test func aStopLeavesFoldersTheirOwnersToClearAway() throws {
        let folders = try Folders()
        defer { folders.directory.remove() }
        var tar = TarBuilder()
        tar.add("locked/", .folder, mode: 0o555)
        tar.add("locked/inside.txt", mode: 0o444, contents: "inside")
        try tar.write(to: folders.archive)
        // Cut off after the two items: what was written is left, with the folder not yet read-only.
        let whole = try Data(contentsOf: URL(fileURLWithPath: folders.archive))
        try whole.prefix(1536 + 100).write(to: URL(fileURLWithPath: folders.archive))
        #expect(throws: ArchiveError.self) { try Self.extract(folders.archive, into: folders.out) }
        #expect(try Self.mode("\(folders.out)/locked") == 0o700)
        let control = NativeArchive.Control()
        control.stop()
        #expect(throws: StopError.self) {
            try NativeArchive.extract(
                folders.archive, into: "\(folders.root)", rawName: nil, quarantine: true, control: control)
        }
        #expect(try Self.names(folders.root) == ["out", "test.tar"])
    }

    // MARK: Stop

    /// A tar.gz whose first item is left out (its name climbs out of the folder): passing over its data means
    /// reading it through, and a Stop pressed meanwhile is seen there, not only once all of it is read.
    @Test func aStopIsSeenWhileTheDataOfAnItemLeftOutIsPassedOver() throws {
        let folders = try Folders()
        defer { folders.directory.remove() }
        let source = "\(folders.root)/source"
        try FileManager.default.createDirectory(atPath: source, withIntermediateDirectories: false)
        try ArchivePipe.noise(2_000_000).write(to: URL(fileURLWithPath: "\(source)/big.bin"))
        try Data("small".utf8).write(to: URL(fileURLWithPath: "\(source)/small.txt"))
        let made = "\(folders.root)/made.tar.gz"
        try ArchiveOperationsTests.run(
            "/usr/bin/tar", ["-czf", made, "-P", "-s", ",^big.bin$,../big.bin,", "big.bin", "small.txt"], in: source)
        let archive = try Data(contentsOf: URL(fileURLWithPath: made))
        let pipe = "\(folders.root)/piped.tar.gz"
        let control = NativeArchive.Control()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        try ArchivePipe.feed(pipe, archive, first: 256 << 10, second: 256 << 10, release: release) { control.stop() }
        let outcome = Mutex<Result<Void, any Error>?>(nil)
        let extracting = DispatchGroup()
        DispatchQueue.global().async(group: extracting) {
            let result = Result {
                try NativeArchive.extract(pipe, into: folders.out, rawName: nil, quarantine: true, control: control)
            }
            outcome.withLock { $0 = result }
        }
        // The rest of the archive is held back: only a Stop seen in the middle of the data ends this.
        #expect(extracting.wait(timeout: .now() + 30) == .success)
        release.signal()
        extracting.wait()
        #expect(throws: StopError.self) { try outcome.withLock { $0 }?.get() }
        #expect(try Self.names(folders.out).isEmpty)
    }

    /// A Stop pressed in the middle of a large file's data stops the zip there.
    @Test func aStopInTheMiddleOfCompressingEndsIt() throws {
        let folders = try Folders()
        defer { folders.directory.remove() }
        try FileManager.default.createDirectory(atPath: "\(folders.root)/Big", withIntermediateDirectories: false)
        // A gigabyte with nothing in it: no room taken on the disk, and long to read.
        let big = "\(folders.root)/Big/zeros.bin"
        #expect(FileManager.default.createFile(atPath: big, contents: nil))
        #expect(truncate(big, 1 << 30) == 0)
        let control = NativeArchive.Control()
        let compressing = DispatchGroup()
        let outcome = Mutex<Result<Void, any Error>?>(nil)
        DispatchQueue.global().async(group: compressing) {
            let result = Result {
                try NativeArchive.compressZip(
                    ["Big"], in: folders.root, to: "\(folders.root)/Big.zip", control: control)
            }
            outcome.withLock { $0 = result }
        }
        let deadline = ContinuousClock.now + .seconds(30)
        while control.done == 0, ContinuousClock.now < deadline { usleep(1000) }
        control.stop()
        compressing.wait()
        #expect(throws: StopError.self) { try outcome.withLock { $0 }?.get() }
        #expect(control.done < control.total)
    }

    /// A Stop pressed before the items are counted stops the count, and no zip is begun.
    @Test func aStopBeforeTheCountMakesNoZip() throws {
        let folders = try Folders()
        defer { folders.directory.remove() }
        try FileManager.default.createDirectory(atPath: "\(folders.root)/Box", withIntermediateDirectories: false)
        try Data("x".utf8).write(to: URL(fileURLWithPath: "\(folders.root)/Box/x.txt"))
        let control = NativeArchive.Control()
        control.stop()
        #expect(throws: StopError.self) {
            try NativeArchive.compressZip(["Box"], in: folders.root, to: "\(folders.root)/Box.zip", control: control)
        }
        #expect(!FileManager.default.fileExists(atPath: "\(folders.root)/Box.zip"))
    }

    // MARK: Compress

    @Test func aFolderGivenWithASlashAtItsEndNamesItsItemsTheSame() throws {
        let folders = try Folders()
        defer { folders.directory.remove() }
        try FileManager.default.createDirectory(atPath: "\(folders.root)/Photos", withIntermediateDirectories: false)
        try Data("a".utf8).write(to: URL(fileURLWithPath: "\(folders.root)/Photos/a.txt"))
        ArchiveOperationsTests.setAttribute("\(folders.root)/Photos/a.txt", "com.example.tag", "kept")
        for (index, base) in [folders.root, folders.root + "/", folders.root + "//"].enumerated() {
            let zip = "\(folders.root)/made\(index).zip"
            try NativeArchive.compressZip(["Photos"], in: base, to: zip, control: NativeArchive.Control())
            // The folder may carry attributes of the system's own, which then have a `._Photos` too.
            let listed = try ArchiveOperationsTests.run("/usr/bin/zipinfo", ["-1", zip])
                .split(separator: "\n").map(String.init).filter { $0 != "__MACOSX/._Photos" }.sorted()
            #expect(listed == ["Photos/", "Photos/a.txt", "__MACOSX/Photos/._a.txt"])
        }
        #expect(throws: (any Error).self) {
            try NativeArchive.compressZip(
                ["Photos"], in: "", to: "\(folders.root)/none.zip", control: NativeArchive.Control())
        }
    }

    /// A file named "._a.txt" beside "a.txt" that begins as the attribute files of a USB stick do: on a disk that
    /// keeps attributes itself (APFS, here) it is someone's file, and goes into the zip with what it holds.
    @Test func aFileNamedAsAnAttributesFileGoesInOnADiskThatKeepsAttributesItself() throws {
        let folders = try Folders()
        defer { folders.directory.remove() }
        try FileManager.default.createDirectory(atPath: "\(folders.root)/Photos", withIntermediateDirectories: false)
        try Data("a".utf8).write(to: URL(fileURLWithPath: "\(folders.root)/Photos/a.txt"))
        let double = Data([0x00, 0x05, 0x16, 0x07, 0x00, 0x02, 0x00, 0x00]) + Data("kept by hand".utf8)
        try double.write(to: URL(fileURLWithPath: "\(folders.root)/Photos/._a.txt"))
        try Data("alone".utf8).write(to: URL(fileURLWithPath: "\(folders.root)/Photos/._alone"))
        let zip = "\(folders.root)/made.zip"
        try NativeArchive.compressZip(["Photos"], in: folders.root, to: zip, control: NativeArchive.Control())
        let listed = try ArchiveOperationsTests.run("/usr/bin/zipinfo", ["-1", zip])
            .split(separator: "\n").map(String.init).filter { !$0.hasPrefix("__MACOSX/") }.sorted()
        #expect(listed == ["Photos/", "Photos/._a.txt", "Photos/._alone", "Photos/a.txt"])
        _ = try Self.extract(zip, into: folders.out)
        #expect(try Data(contentsOf: URL(fileURLWithPath: "\(folders.out)/Photos/._a.txt")) == double)
    }

    /// On a disk that keeps attributes in "._name" files (exFAT, FAT32) those files are no items: what they hold is
    /// in __MACOSX with their item. A "._name" with no item beside it, or that doesn't begin as one, is a file.
    /// Only a release runs it: it mounts an image of each.
    @Test(
        .tags(.diskImage), .diskImages, .enabled(if: ReleaseTests.enabled), arguments: [DiskImage.Kind.exfat, .fat32])
    func anAttributesFileStaysOutOnADiskThatKeepsAttributesInFiles(kind: DiskImage.Kind) async throws {
        try await DiskImage.withVolume(kind) { volume in
            let root = volume.path
            try FileManager.default.createDirectory(atPath: "\(root)/Photos", withIntermediateDirectories: false)
            try Data("a".utf8).write(to: URL(fileURLWithPath: "\(root)/Photos/a.txt"))
            ArchiveOperationsTests.setAttribute("\(root)/Photos/a.txt", "com.example.tag", "kept")
            #expect(FileManager.default.fileExists(atPath: "\(root)/Photos/._a.txt"))
            try Data("alone".utf8).write(to: URL(fileURLWithPath: "\(root)/Photos/._alone"))
            try Data("b".utf8).write(to: URL(fileURLWithPath: "\(root)/Photos/b.txt"))
            try Data("plain".utf8).write(to: URL(fileURLWithPath: "\(root)/Photos/._b.txt"))
            let folders = try Folders()
            defer { folders.directory.remove() }
            let zip = "\(folders.root)/made.zip"
            try NativeArchive.compressZip(["Photos"], in: root, to: zip, control: NativeArchive.Control())
            let listed = try ArchiveOperationsTests.run("/usr/bin/zipinfo", ["-1", zip])
                .split(separator: "\n").map(String.init)
            #expect(
                listed.filter { !$0.hasPrefix("__MACOSX/") }.sorted()
                    == ["Photos/", "Photos/._alone", "Photos/._b.txt", "Photos/a.txt", "Photos/b.txt"])
            #expect(listed.contains("__MACOSX/Photos/._a.txt"))
        }
    }

    /// Compressing on one thread while another looks at the process's working directory: it must never be seen
    /// anywhere else, as a relative path used meanwhile would then mean another file.
    @Test func compressingLeavesTheWorkingDirectoryAlone() throws {
        let folders = try Folders()
        defer { folders.directory.remove() }
        for folder in 0..<8 {
            try FileManager.default.createDirectory(
                atPath: "\(folders.root)/Photos/sub\(folder)", withIntermediateDirectories: true)
            for file in 0..<8 {
                let path = "\(folders.root)/Photos/sub\(folder)/\(file).txt"
                try Data("x".utf8).write(to: URL(fileURLWithPath: path))
                ArchiveOperationsTests.setAttribute(path, "com.example.tag", "kept")
            }
        }
        let start = FileManager.default.currentDirectoryPath
        let compressing = DispatchGroup()
        DispatchQueue.global().async(group: compressing) {
            for round in 0..<2 {
                try? NativeArchive.compressZip(
                    ["Photos"], in: folders.root, to: "\(folders.root)/made\(round).zip",
                    control: NativeArchive.Control())
            }
        }
        var moved = 0
        var looks = 0
        while compressing.wait(timeout: .now()) == .timedOut {
            looks += 1
            if FileManager.default.currentDirectoryPath != start { moved += 1 }
        }
        #expect(moved == 0, "the working directory was elsewhere in \(moved) of \(looks) looks")
        let listed = try ArchiveOperationsTests.run("/usr/bin/zipinfo", ["-1", "\(folders.root)/made1.zip"])
            .split(separator: "\n")
        #expect(listed.filter { $0.hasPrefix("__MACOSX/Photos/sub") }.count == 64)
        #expect(listed.filter { $0.hasPrefix("Photos/sub") && $0.hasSuffix(".txt") }.count == 64)
    }

    // MARK: Clearing away

    @Test func whatWasExtractedIsClearedAwayWithItsReadOnlyFolders() throws {
        let folders = try Folders()
        defer { folders.directory.remove() }
        var tar = TarBuilder()
        tar.add("locked/", .folder, mode: 0o555)
        tar.add("locked/inside.txt", mode: 0o444, contents: "inside")
        tar.add("locked/hidden/", .folder, mode: 0o000)
        try tar.write(to: folders.archive)
        let staging = try Staging(near: folders.out, NativeWriteFileSystem())
        try Self.extract(folders.archive, into: staging.work)
        #expect(try Self.mode("\(staging.work)/locked") == 0o555)
        staging.remove()
        #expect(!FileManager.default.fileExists(atPath: staging.root))
        #expect(try Self.names(folders.out).isEmpty)
    }

    @Test func aDeleteSomeoneAskedForStopsAtAFolderThatCantBeChanged() throws {
        let folders = try Folders()
        defer { folders.directory.remove() }
        try FileManager.default.createDirectory(atPath: "\(folders.out)/locked", withIntermediateDirectories: false)
        try Data("x".utf8).write(to: URL(fileURLWithPath: "\(folders.out)/locked/x.txt"))
        #expect(chmod("\(folders.out)/locked", 0o555) == 0)
        #expect(throws: (any Error).self) { try NativeRemoval.rm(folders.out, recursive: true, force: true) }
        #expect(FileManager.default.fileExists(atPath: "\(folders.out)/locked/x.txt"))
        try NativeRemoval.rm(folders.out, recursive: true, force: true, unlockingFolders: true)
        #expect(!FileManager.default.fileExists(atPath: folders.out))
    }
}
