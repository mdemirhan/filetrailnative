// Compress and Extract: zips made as Finder makes them, archives taken apart next to themselves, and their Undo
import Darwin
import FTFileSystem
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTOperations

@MainActor
@Suite(.localOperationHang) struct ArchiveOperationsTests {
    /// What is in the folder, the test's Trash left out.
    nonisolated static func names(_ folder: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder).filter { $0 != ".Trash" }.sorted()
    }

    /// Runs one of the system's tools, which must succeed; its output.
    @discardableResult
    nonisolated static func run(_ tool: String, _ arguments: [String], in folder: String? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        if let folder { process.currentDirectoryURL = URL(fileURLWithPath: folder) }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw OperationError("\(tool) \(arguments.joined(separator: " ")) failed")
        }
        return String(decoding: data, as: UTF8.self)
    }

    nonisolated static func attribute(_ path: String, _ name: String) -> String? {
        let length = getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard length >= 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: length)
        _ = getxattr(path, name, &bytes, length, 0, XATTR_NOFOLLOW)
        return String(decoding: bytes, as: UTF8.self)
    }

    nonisolated static func setAttribute(_ path: String, _ name: String, _ value: String) {
        _ = value.withCString { setxattr(path, name, $0, strlen($0), 0, XATTR_NOFOLLOW) }
    }

    nonisolated static func text(_ path: String) throws -> String { try String(contentsOfFile: path, encoding: .utf8) }

    /// "Photos.zip" in `root`, as Finder's Compress makes it, of a folder "Photos" holding a.txt (with an extended
    /// attribute) and sub/b.txt; the folder itself is made elsewhere and gone.
    static func finderZip(in root: String) throws -> String {
        let maker = try TemporaryDirectory(prefix: "filetrail-zip-maker")
        defer { maker.remove() }
        try FileManager.default.createDirectory(
            atPath: "\(maker.path)/Photos/sub", withIntermediateDirectories: true)
        try UndoDisk.write("\(maker.path)/Photos/a.txt", "a")
        try UndoDisk.write("\(maker.path)/Photos/sub/b.txt", "b")
        setAttribute("\(maker.path)/Photos/a.txt", "com.example.tag", "kept")
        try run(
            "/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", "Photos", "\(root)/Photos.zip"],
            in: maker.path)
        return "\(root)/Photos.zip"
    }

    @discardableResult
    static func extract(_ t: UndoTest, _ paths: [String], into folder: String? = nil) async throws
        -> WriteOperationEvent
    {
        try await t.finish(t.coordinator.extractArchives(paths, into: folder, window: t.window))
    }

    @discardableResult
    static func compress(_ t: UndoTest, _ paths: [String]) async throws -> WriteOperationEvent {
        try await t.finish(t.coordinator.compress(paths, window: t.window))
    }

    // MARK: Extract

    @Test func aZipHoldingOneFolderGivesThatFolderWithItsAttributes() async throws {
        try await withUndoFolder { root, trashDir in
            let zip = try Self.finderZip(in: root)
            let t = UndoTest(root: root, trashDir: trashDir)
            let end = try await Self.extract(t, [zip])
            #expect(end.action == .extract)
            #expect(end.status == .completed)
            #expect(end.result?.targetPath == root)
            #expect(end.result?.items.map(\.destinationPath) == ["\(root)/Photos"])
            #expect(try Self.names(root) == ["Photos", "Photos.zip"])
            #expect(try Self.names("\(root)/Photos") == ["a.txt", "sub"])
            #expect(try Self.text("\(root)/Photos/sub/b.txt") == "b")
            // What Finder kept in __MACOSX is back on its item, and __MACOSX itself isn't there.
            #expect(Self.attribute("\(root)/Photos/a.txt", "com.example.tag") == "kept")
            await t.shutDown()
        }
    }

    /// Opening a link to an archive extracts it where the link is, not where the archive it leads to is.
    @Test func aLinkToAnArchiveGivesItsItemsBesideTheLink() async throws {
        try await withUndoFolder { root, trashDir in
            try FileManager.default.createDirectory(atPath: "\(root)/elsewhere", withIntermediateDirectories: true)
            try FileManager.default.createDirectory(atPath: "\(root)/here", withIntermediateDirectories: true)
            let zip = try Self.finderZip(in: "\(root)/elsewhere")
            let link = "\(root)/here/Photos.zip"
            try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: zip)
            let t = UndoTest(root: root, trashDir: trashDir)
            let end = try await Self.extract(t, [link])
            #expect(end.status == .completed)
            #expect(try Self.names("\(root)/here") == ["Photos", "Photos.zip"])
            #expect(try Self.names("\(root)/elsewhere") == ["Photos.zip"])
            #expect(try Self.text("\(root)/here/Photos/sub/b.txt") == "b")
            await t.shutDown()
        }
    }

    @Test func severalItemsAtTheTopGoIntoAFolderNamedAfterTheArchive() async throws {
        try await withUndoFolder { root, trashDir in
            try UndoDisk.write("\(root)/one.txt", "1")
            try UndoDisk.write("\(root)/two.txt", "2")
            try Self.run("/usr/bin/tar", ["-czf", "\(root)/pair.tar.gz", "one.txt", "two.txt"], in: root)
            let t = UndoTest(root: root, trashDir: trashDir)
            let end = try await Self.extract(t, ["\(root)/pair.tar.gz"])
            #expect(end.status == .completed)
            #expect(try Self.names("\(root)/pair") == ["one.txt", "two.txt"])
            #expect(try Self.text("\(root)/pair/two.txt") == "2")
            await t.shutDown()
        }
    }

    @Test func aNameTakenGetsTheNextNumberAndNothingIsReplaced() async throws {
        try await withUndoFolder { root, trashDir in
            let zip = try Self.finderZip(in: root)
            try FileManager.default.createDirectory(atPath: "\(root)/Photos", withIntermediateDirectories: false)
            try UndoDisk.write("\(root)/Photos/mine.txt", "mine")
            let t = UndoTest(root: root, trashDir: trashDir)
            let end = try await Self.extract(t, [zip])
            #expect(end.result?.items.map(\.destinationPath) == ["\(root)/Photos 2"])
            #expect(try Self.names("\(root)/Photos") == ["mine.txt"])
            #expect(try Self.names("\(root)/Photos 2") == ["a.txt", "sub"])
            await t.shutDown()
        }
    }

    @Test func aSingleCompressedFileBecomesTheFileUnderItsOwnName() async throws {
        try await withUndoFolder { root, trashDir in
            try UndoDisk.write("\(root)/notes.txt", "hello")
            try Self.run("/usr/bin/gzip", ["notes.txt"], in: root)
            let t = UndoTest(root: root, trashDir: trashDir)
            let end = try await Self.extract(t, ["\(root)/notes.txt.gz"])
            #expect(end.status == .completed)
            #expect(try Self.names(root) == ["notes.txt", "notes.txt.gz"])
            #expect(try Self.text("\(root)/notes.txt") == "hello")
            await t.shutDown()
        }
    }

    @Test func namesReachingOutsideTheFolderAreLeftOutAndSaidSo() async throws {
        try await withUndoFolder { root, trashDir in
            try FileManager.default.createDirectory(atPath: "\(root)/inner", withIntermediateDirectories: false)
            try UndoDisk.write("\(root)/inner/ok.txt", "ok")
            // "../escape.txt", then "ok.txt".
            try Self.run(
                "/usr/bin/tar", ["-cf", "\(root)/inner/evil.tar", "-P", "-s", ",^ok.txt$,../escape.txt,", "ok.txt"],
                in: "\(root)/inner")
            try Self.run("/usr/bin/tar", ["-rf", "\(root)/inner/evil.tar", "ok.txt"], in: "\(root)/inner")
            try FileManager.default.removeItem(atPath: "\(root)/inner/ok.txt")
            let t = UndoTest(root: root, trashDir: trashDir)
            let end = try await Self.extract(t, ["\(root)/inner/evil.tar"])
            #expect(end.status == .completed)
            let item = try #require(end.result?.items.first)
            #expect(item.destinationPath == "\(root)/inner/ok.txt")
            #expect(item.note)
            #expect(item.error?.hasPrefix("1 item was left out") == true)
            #expect(try Self.names(root) == ["inner"])
            #expect(try Self.names("\(root)/inner") == ["evil.tar", "ok.txt"])
            await t.shutDown()
        }
    }

    @Test func whatComesFromADownloadedArchiveKeepsItsQuarantine() async throws {
        try await withUndoFolder { root, trashDir in
            let zip = try Self.finderZip(in: root)
            let quarantine = "0083;6734a1b2;Safari;"
            Self.setAttribute(zip, "com.apple.quarantine", quarantine)
            let t = UndoTest(root: root, trashDir: trashDir)
            try await Self.extract(t, [zip])
            #expect(Self.attribute("\(root)/Photos", "com.apple.quarantine") == quarantine)
            #expect(Self.attribute("\(root)/Photos/sub/b.txt", "com.apple.quarantine") == quarantine)
            await t.shutDown()
        }
    }

    /// Its items' access rules would deny writing their attributes and deleting them: they come out without them,
    /// quarantined, and Undo can move them to the Trash.
    @Test func anArchiveWithAccessRulesComesOutWithoutThemAndUndoTakesItAway() async throws {
        try await withUndoFolder { root, trashDir in
            let zip = try AccessRuleArchive.zip(in: root)
            let quarantine = "0083;6734a1b2;Safari;"
            Self.setAttribute(zip, "com.apple.quarantine", quarantine)
            let t = UndoTest(root: root, trashDir: trashDir)
            let end = try await Self.extract(t, [zip])
            #expect(end.status == .completed)
            #expect(end.result?.items.map(\.destinationPath) == ["\(root)/Evil"])
            for item in AccessRuleArchive.items(in: root).dropFirst() {
                #expect(Self.attribute(item, "com.apple.quarantine") == quarantine, "\(item)")
                #expect(!AccessRuleArchive.hasAccessRules(item), "\(item)")
            }
            try await t.undo()
            #expect(try Self.names(root) == ["evil.zip"])
            #expect(t.inTrash() == ["1-Evil"])
            await t.shutDown()
        }
    }

    /// The archive's quarantine can't be read: nothing of it comes out, as what did would be run unchecked.
    @Test func anArchiveWhoseQuarantineCantBeReadIsRefusedAndLeavesNothing() async throws {
        try await withUndoFolder { root, trashDir in
            let zip = try Self.finderZip(in: root)
            Self.setAttribute(zip, "com.apple.quarantine", "0083;6734a1b2;Safari;")
            try Self.run("/bin/chmod", ["+a", "everyone deny readextattr", zip])
            defer { _ = try? Self.run("/bin/chmod", ["-N", zip]) }
            let t = UndoTest(root: root, trashDir: trashDir)
            let end = try await Self.extract(t, [zip])
            #expect(end.status == .failed)
            #expect(end.result?.error?.contains("couldn\u{2019}t be marked as downloaded") == true)
            #expect(try Self.names(root) == ["Photos.zip"])
            await t.shutDown()
        }
    }

    @Test func aProtectedArchiveIsRefusedAndLeavesNothing() async throws {
        try await withUndoFolder { root, trashDir in
            try UndoDisk.write("\(root)/secret.txt", "secret")
            try Self.run("/usr/bin/zip", ["-q", "-P", "pass", "locked.zip", "secret.txt"], in: root)
            try FileManager.default.removeItem(atPath: "\(root)/secret.txt")
            let t = UndoTest(root: root, trashDir: trashDir)
            let end = try await Self.extract(t, ["\(root)/locked.zip"])
            #expect(end.status == .failed)
            #expect(end.result?.error?.contains("is protected with a password") == true)
            #expect(try Self.names(root) == ["locked.zip"])
            await t.shutDown()
        }
    }

    @Test func aFileThatIsntAnArchiveFailsWithoutStoppingTheOthers() async throws {
        try await withUndoFolder { root, trashDir in
            try UndoDisk.write("\(root)/broken.zip", "not a zip at all")
            let zip = try Self.finderZip(in: root)
            let t = UndoTest(root: root, trashDir: trashDir)
            let end = try await Self.extract(t, ["\(root)/broken.zip", zip])
            #expect(end.status == .partial)
            let items = try #require(end.result?.items)
            #expect(items.map(\.status) == [.failed, .completed])
            #expect(items[0].error?.contains("can\u{2019}t be read") == true)
            #expect(try Self.names(root) == ["Photos", "Photos.zip", "broken.zip"])
            await t.shutDown()
        }
    }

    @Test func extractToPutsItInTheFolderChosen() async throws {
        try await withUndoFolder { root, trashDir in
            let zip = try Self.finderZip(in: root)
            try FileManager.default.createDirectory(atPath: "\(root)/out", withIntermediateDirectories: false)
            let t = UndoTest(root: root, trashDir: trashDir)
            let end = try await Self.extract(t, [zip], into: "\(root)/out")
            #expect(end.result?.targetPath == "\(root)/out")
            #expect(try Self.names("\(root)/out") == ["Photos"])
            await t.shutDown()
        }
    }

    @Test func nothingIsExtractedIntoTheTrash() async throws {
        try await withUndoFolder { root, trashDir in
            let zip = try Self.finderZip(in: root)
            let t = UndoTest(root: root, trashDir: trashDir)
            await #expect(throws: (any Error).self) {
                try await t.coordinator.extractArchives([zip], into: trashDir, window: t.window)
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: trashDir).isEmpty)
            await t.shutDown()
        }
    }

    @Test func undoMovesWhatWasExtractedToTheTrash() async throws {
        try await withUndoFolder { root, trashDir in
            let zip = try Self.finderZip(in: root)
            let t = UndoTest(root: root, trashDir: trashDir)
            try await Self.extract(t, [zip])
            #expect(t.history.menu().undo == "Extract")
            try await t.undo()
            #expect(try Self.names(root) == ["Photos.zip"])
            #expect(t.inTrash() == ["1-Photos"])
            await t.shutDown()
        }
    }

    // MARK: Compress

    @Test func compressMakesAFinderZipThatDittoTakesApartWithItsAttributes() async throws {
        try await withUndoFolder { root, trashDir in
            try FileManager.default.createDirectory(atPath: "\(root)/Photos/sub", withIntermediateDirectories: true)
            try UndoDisk.write("\(root)/Photos/a.txt", "a")
            try UndoDisk.write("\(root)/Photos/sub/b.txt", "b")
            try FileManager.default.createSymbolicLink(atPath: "\(root)/Photos/link", withDestinationPath: "a.txt")
            Self.setAttribute("\(root)/Photos/a.txt", "com.example.tag", "kept")
            let t = UndoTest(root: root, trashDir: trashDir)
            let end = try await Self.compress(t, ["\(root)/Photos"])
            #expect(end.action == .compress)
            #expect(end.status == .completed)
            #expect(end.result?.items.map(\.destinationPath) == ["\(root)/Photos.zip"])
            #expect(try Self.names(root) == ["Photos", "Photos.zip"])
            let listed = try Self.run("/usr/bin/zipinfo", ["-1", "\(root)/Photos.zip"])
                .split(separator: "\n").map(String.init)
            #expect(listed.contains("Photos/sub/b.txt"))
            #expect(listed.contains("__MACOSX/Photos/._a.txt"))
            let out = try TemporaryDirectory(prefix: "filetrail-zip-out")
            defer { out.remove() }
            try Self.run("/usr/bin/ditto", ["-x", "-k", "\(root)/Photos.zip", out.path])
            #expect(try Self.text("\(out.path)/Photos/sub/b.txt") == "b")
            #expect(Self.attribute("\(out.path)/Photos/a.txt", "com.example.tag") == "kept")
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: "\(out.path)/Photos/link") == "a.txt")
            await t.shutDown()
        }
    }

    @Test func severalItemsMakeArchiveZipAndThenTheNextNumber() async throws {
        try await withUndoFolder { root, trashDir in
            try UndoDisk.write("\(root)/one.txt", "1")
            try UndoDisk.write("\(root)/two.txt", "2")
            let t = UndoTest(root: root, trashDir: trashDir)
            try await Self.compress(t, ["\(root)/one.txt", "\(root)/two.txt"])
            let again = try await Self.compress(t, ["\(root)/one.txt", "\(root)/two.txt"])
            #expect(again.result?.items.map(\.destinationPath) == ["\(root)/Archive 2.zip"])
            let listed = try Self.run("/usr/bin/zipinfo", ["-1", "\(root)/Archive.zip"]).split(separator: "\n")
            #expect(listed.contains("one.txt") && listed.contains("two.txt"))
            #expect(try Self.names(root) == ["Archive 2.zip", "Archive.zip", "one.txt", "two.txt"])
            await t.shutDown()
        }
    }

    @Test func aZipCompressMadeComesBackWhole() async throws {
        try await withUndoFolder { root, trashDir in
            try FileManager.default.createDirectory(atPath: "\(root)/Résumé ğüş", withIntermediateDirectories: true)
            try UndoDisk.write("\(root)/Résumé ğüş/日本.txt", "kanji")
            let t = UndoTest(root: root, trashDir: trashDir)
            try await Self.compress(t, ["\(root)/Résumé ğüş"])
            try FileManager.default.removeItem(atPath: "\(root)/Résumé ğüş")
            try await Self.extract(t, ["\(root)/Résumé ğüş.zip"])
            #expect(try Self.text("\(root)/Résumé ğüş/日本.txt") == "kanji")
            await t.shutDown()
        }
    }

    @Test func itemsOfSeveralFoldersAreRefused() async throws {
        try await withUndoFolder { root, trashDir in
            try FileManager.default.createDirectory(atPath: "\(root)/a", withIntermediateDirectories: false)
            try UndoDisk.write("\(root)/a/x.txt", "x")
            try UndoDisk.write("\(root)/y.txt", "y")
            let t = UndoTest(root: root, trashDir: trashDir)
            await #expect(throws: (any Error).self) {
                try await t.coordinator.compress(["\(root)/a/x.txt", "\(root)/y.txt"], window: t.window)
            }
            await t.shutDown()
        }
    }

    @Test func undoMovesTheZipToTheTrash() async throws {
        try await withUndoFolder { root, trashDir in
            try UndoDisk.write("\(root)/one.txt", "1")
            let t = UndoTest(root: root, trashDir: trashDir)
            try await Self.compress(t, ["\(root)/one.txt"])
            #expect(t.history.menu().undo == "Compress")
            try await t.undo()
            #expect(try Self.names(root) == ["one.txt"])
            #expect(t.inTrash() == ["1-one.txt.zip"])
            await t.shutDown()
        }
    }

    @Test func aPipeIsLeftOutOfTheZipAndSaidSo() async throws {
        try await withUndoFolder { root, trashDir in
            try FileManager.default.createDirectory(atPath: "\(root)/Box", withIntermediateDirectories: false)
            try UndoDisk.write("\(root)/Box/kept.txt", "kept")
            #expect(mkfifo("\(root)/Box/pipe", 0o644) == 0)
            let t = UndoTest(root: root, trashDir: trashDir)
            let end = try await Self.compress(t, ["\(root)/Box"])
            #expect(end.status == .completed)
            let item = try #require(end.result?.items.first)
            #expect(item.note)
            #expect(item.error?.hasPrefix("1 item was left out") == true)
            let listed = try Self.run("/usr/bin/zipinfo", ["-1", "\(root)/Box.zip"]).split(separator: "\n")
            #expect(listed.contains("Box/kept.txt"))
            #expect(!listed.contains { $0.hasSuffix("pipe") })
            await t.shutDown()
        }
    }

    @Test func namesOutsideASCIIGoIntoTheZipAsDittoReadsThem() async throws {
        try await withUndoFolder { root, trashDir in
            try FileManager.default.createDirectory(atPath: "\(root)/Résumé ğüş", withIntermediateDirectories: true)
            try UndoDisk.write("\(root)/Résumé ğüş/日本 😀.txt", "kanji")
            let t = UndoTest(root: root, trashDir: trashDir)
            try await Self.compress(t, ["\(root)/Résumé ğüş"])
            let out = try TemporaryDirectory(prefix: "filetrail-zip-out")
            defer { out.remove() }
            try Self.run("/usr/bin/ditto", ["-x", "-k", "\(root)/Résumé ğüş.zip", out.path])
            #expect(try Self.text("\(out.path)/Résumé ğüş/日本 😀.txt") == "kanji")
            await t.shutDown()
        }
    }

    // MARK: What an archive may hold

    @Test func aProtectedItemAfterPlainOnesLeavesNothing() async throws {
        try await withUndoFolder { root, trashDir in
            try UndoDisk.write("\(root)/plain.txt", "plain")
            try UndoDisk.write("\(root)/secret.txt", "secret")
            try Self.run("/usr/bin/zip", ["-q", "mixed.zip", "plain.txt"], in: root)
            try Self.run("/usr/bin/zip", ["-q", "-P", "pass", "mixed.zip", "secret.txt"], in: root)
            try FileManager.default.removeItem(atPath: "\(root)/plain.txt")
            try FileManager.default.removeItem(atPath: "\(root)/secret.txt")
            let t = UndoTest(root: root, trashDir: trashDir)
            let end = try await Self.extract(t, ["\(root)/mixed.zip"])
            #expect(end.status == .failed)
            #expect(end.result?.error?.contains("is protected with a password") == true)
            #expect(try Self.names(root) == ["mixed.zip"])
            await t.shutDown()
        }
    }

    @Test func aDamagedArchiveWithReadOnlyFoldersLeavesNothing() async throws {
        try await withUndoFolder { root, trashDir in
            var tar = TarBuilder()
            tar.add("locked/", .folder, mode: 0o555)
            tar.add("locked/inside.txt", mode: 0o444, contents: "inside")
            tar.add("locked/deeper/", .folder, mode: 0o500)
            tar.add("locked/deeper/leaf.txt", mode: 0o400, contents: String(repeating: "leaf", count: 4096))
            try tar.write(to: "\(root)/whole.tar")
            // Cut off in the middle of the last file.
            let whole = try Data(contentsOf: URL(fileURLWithPath: "\(root)/whole.tar"))
            try whole.prefix(whole.count - 1024 - 8192).write(to: URL(fileURLWithPath: "\(root)/cut.tar"))
            try FileManager.default.removeItem(atPath: "\(root)/whole.tar")
            let t = UndoTest(root: root, trashDir: trashDir)
            let end = try await Self.extract(t, ["\(root)/cut.tar"])
            #expect(end.status == .failed)
            #expect(end.result?.error?.contains("can\u{2019}t be read") == true)
            #expect(try FileManager.default.contentsOfDirectory(atPath: root).sorted() == [".Trash", "cut.tar"])
            await t.shutDown()
        }
    }

    @Test func anArchiveWithReadOnlyFoldersComesOutAndUndoTakesItAway() async throws {
        try await withUndoFolder { root, trashDir in
            var tar = TarBuilder()
            tar.add("locked/", .folder, mode: 0o555)
            tar.add("locked/inside.txt", mode: 0o444, contents: "inside")
            try tar.write(to: "\(root)/ro.tar")
            Self.setAttribute("\(root)/ro.tar", "com.apple.quarantine", "0083;6734a1b2;Safari;")
            let t = UndoTest(root: root, trashDir: trashDir)
            let end = try await Self.extract(t, ["\(root)/ro.tar"])
            #expect(end.status == .completed)
            #expect(end.result?.items.first?.note == false)
            #expect(try NativeArchiveTests.mode("\(root)/locked") == 0o555)
            #expect(Self.attribute("\(root)/locked", "com.apple.quarantine") == "0083;6734a1b2;Safari;")
            #expect(Self.attribute("\(root)/locked/inside.txt", "com.apple.quarantine") == "0083;6734a1b2;Safari;")
            try await t.undo()
            #expect(try Self.names(root) == ["ro.tar"])
            await t.shutDown()
        }
    }

    @Test func aRootFileSystemWithDevicesComesOutWithoutThem() async throws {
        try await withUndoFolder { root, trashDir in
            var tar = TarBuilder()
            tar.add("./", .folder, mode: 0o755)
            tar.add("./dev/", .folder, mode: 0o755)
            tar.add("./dev/null", .characterDevice, mode: 0o666)
            tar.add("./etc/", .folder, mode: 0o755)
            tar.add("./etc/hostname", contents: "box\n")
            try tar.write(to: "\(root)/rootfs.tar")
            let t = UndoTest(root: root, trashDir: trashDir)
            let end = try await Self.extract(t, ["\(root)/rootfs.tar"])
            #expect(end.status == .completed)
            let item = try #require(end.result?.items.first)
            #expect(item.destinationPath == "\(root)/rootfs")
            // Only the device is counted, not the "./" the tar starts with.
            #expect(item.error?.hasPrefix("1 item was left out") == true)
            #expect(try Self.text("\(root)/rootfs/etc/hostname") == "box\n")
            #expect(try Self.names("\(root)/rootfs/dev").isEmpty)
            await t.shutDown()
        }
    }
}
