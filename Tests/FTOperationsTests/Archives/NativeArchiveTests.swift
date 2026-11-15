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

    @Test func aZipWhoseNamesArentUTF8ComesOutWithThoseBytesEscaped() throws {
        let folders = try Folders()
        defer { folders.directory.remove() }
        let zipPath = "\(folders.root)/names.zip"
        var zip = ZipBuilder()
        // "テスト.txt" in Shift-JIS, and a folder and file in UTF-8 that stay as they are.
        zip.add(name: [0x83, 0x65, 0x83, 0x58, 0x83, 0x67] + Array(".txt".utf8), contents: "shift-jis")
        zip.add(name: Array("日本/ğüş.txt".utf8), contents: "utf-8")
        try zip.write(to: zipPath)
        #expect(try Self.extract(zipPath, into: folders.out) == 0)
        #expect(try Self.names(folders.out) == ["%83e%83X%83g.txt", "日本"])
        #expect(try String(contentsOfFile: "\(folders.out)/%83e%83X%83g.txt", encoding: .utf8) == "shift-jis")
        #expect(try String(contentsOfFile: "\(folders.out)/日本/ğüş.txt", encoding: .utf8) == "utf-8")
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
