import Foundation
import Testing

@testable import FTFileSystem

@Suite struct IconCacheKeyTests {
    private func key(
        _ path: String, name: String = "", extension fileExtension: String = "", kind: IconEntryKind = .file,
        executable: Bool? = nil
    ) -> String {
        IconCacheKey.key(
            for: IconEntry(path: path, name: name, extension: fileExtension, kind: kind, isExecutable: executable))
    }

    @Test func filesShareOneIconPerExtensionIgnoringCase() {
        #expect(key("/a/one.txt", extension: "txt") == "ext:txt")
        #expect(key("/a/ONE.TXT", extension: "TXT") == "ext:txt")
        // The extension wins over whether the file is executable.
        #expect(key("/a/run.sh", extension: "sh", executable: true) == "ext:sh")
    }

    @Test func aFileWithoutAnExtensionOfUnknownModeIsAskedForByPath() {
        #expect(key("/found/Makefile", name: "Makefile") == "path:/found/Makefile")
    }

    @Test func symlinksBundlesAndOtherItemsAreAskedForByPath() {
        #expect(key("/a/link.txt", extension: "txt", kind: .symlinkFile) == "path:/a/link.txt")
        #expect(key("/a/link", kind: .symlinkDirectory) == "path:/a/link")
        #expect(key("/Applications/Safari.app", extension: "app", kind: .bundle) == "path:/Applications/Safari.app")
        #expect(key("/dev/null", kind: .other) == "path:/dev/null")
    }

    @Test func ordinaryFoldersShareOneIconAndSpecialOnesHaveTheirOwn() {
        #expect(key("/a/Projects", name: "Projects", kind: .directory) == "kind:directory")
        #expect(key("/Users/me/Documents", name: "Documents", kind: .directory) == "path:/Users/me/Documents")
        #expect(key("/Users/me/Library", name: "Library", kind: .directory) == "path:/Users/me/Library")
        #expect(key("/Applications", name: "Applications", kind: .directory) == "path:/Applications")
        // Names are matched exactly.
        #expect(key("/a/documents", name: "documents", kind: .directory) == "kind:directory")
    }

    @Test func aFolderWithoutANameTakesItFromItsPath() {
        #expect(key("/Users/me/Downloads/", kind: .directory) == "path:/Users/me/Downloads/")
        #expect(key("/a/plain/", kind: .directory) == "kind:directory")
    }

    @Test func aDisksTopFolderIsDrawnAsTheDisk() {
        #expect(key("/", kind: .directory) == "path:/")
        #expect(key("/Volumes/Backup", name: "Backup", kind: .directory) == "path:/Volumes/Backup")
        #expect(key("/Volumes/Backup/Stuff", name: "Stuff", kind: .directory) == "kind:directory")
        #expect(key("/Volumes", name: "Volumes", kind: .directory) == "kind:directory")
    }

    @Test func requestsForGenericKeysAreDrawnFromSamples() {
        let folder = IconRequest(entry: IconEntry(path: "/a/Plain", name: "Plain", kind: .directory))
        #expect(folder.generic == .folder)
        let executable = IconRequest(entry: IconEntry(path: "/bin/ls", name: "ls", isExecutable: true))
        #expect(executable.generic == .executable)
        let text = IconRequest(entry: IconEntry(path: "/a/one.txt", name: "one.txt", extension: "txt"))
        #expect(text.generic == nil)
        #expect(text.path == "/a/one.txt")
        #expect(IconRequest.app(path: "/Applications/Mail.app").cacheKey == "app:/Applications/Mail.app")
    }
}

@Suite struct LRUCacheTests {
    @Test func dropsTheLeastRecentlyUsedEntryWhenFull() {
        var cache = LRUCache<String, Int>(capacity: 3)
        cache.write(1, for: "a")
        cache.write(2, for: "b")
        cache.write(3, for: "c")
        // Reading makes "a" the most recently used.
        #expect(cache.read("a") == 1)
        cache.write(4, for: "d")
        #expect(!cache.contains("b"))
        #expect(cache.contains("a") && cache.contains("c") && cache.contains("d"))
        #expect(cache.count == 3)
    }

    @Test func writingAnExistingKeyReplacesItWithoutEvicting() {
        var cache = LRUCache<String, Int>(capacity: 2)
        cache.write(1, for: "a")
        cache.write(2, for: "b")
        cache.write(3, for: "a")
        #expect(cache.count == 2)
        #expect(cache.peek("a") == 3 && cache.peek("b") == 2)
        // "a" was written last, so "b" goes first.
        cache.write(4, for: "c")
        #expect(!cache.contains("b"))
    }
}

@Suite struct CustomFolderIconTests {
    @Test func aCustomizedFolderHasItsOwnKeyAndOthersShareOne() {
        let plain = IconEntry(path: "/a/b", name: "b", kind: .directory)
        let custom = IconEntry(path: "/a/c", name: "c", kind: .directory, hasCustomIcon: true)
        #expect(IconCacheKey.key(for: plain) == GenericIconKind.folder.cacheKey)
        #expect(IconCacheKey.key(for: custom) == "path:/a/c")
    }

    @Test func foldersOfATagColorShareAKeyAndACustomOneKeepsItsOwn() {
        let red = IconRequest(entry: IconEntry(path: "/a/b", name: "b", kind: .directory, tagColor: .red))
        #expect(red.tint == .red)
        #expect(red.generic == nil)
        #expect(red == IconRequest(cacheKey: red.cacheKey, path: "/a/b", tint: .red))
        let other = IconRequest(entry: IconEntry(path: "/a/c", name: "c", kind: .directory, tagColor: .red))
        #expect(other.cacheKey == red.cacheKey)
        let custom = IconRequest(
            entry: IconEntry(path: "/a/d", name: "d", kind: .directory, hasCustomIcon: true, tagColor: .red))
        #expect(custom.cacheKey == "path:/a/d")
        #expect(custom.tint == nil)
        // A special folder keeps the system's picture.
        let special = IconRequest(
            entry: IconEntry(path: "/a/Documents", name: "Documents", kind: .directory, tagColor: .red))
        #expect(special.tint == nil)
    }

    @Test func foldersHoldingNothingHaveTheirOwnKeysAndOneNotKnownToIsDrawnAsHoldingSomething() {
        let folder = IconRequest(entry: IconEntry(path: "/a/b", name: "b", kind: .directory))
        #expect(folder.generic == .folder)
        let empty = IconRequest(entry: IconEntry(path: "/a/c", name: "c", kind: .directory, isEmptyFolder: true))
        #expect(empty.generic == .emptyFolder)
        let redFull = IconRequest(entry: IconEntry(path: "/a/d", name: "d", kind: .directory, tagColor: .red))
        let redEmpty = IconRequest(
            entry: IconEntry(path: "/a/e", name: "e", kind: .directory, tagColor: .red, isEmptyFolder: true))
        #expect(redFull.cacheKey != redEmpty.cacheKey)
        #expect(redEmpty.tint == .red)
        #expect(redEmpty.isEmptyFolder)
        #expect(!redFull.isEmptyFolder)
        // A folder with its own picture is drawn again when that changes.
        let custom = IconRequest(
            entry: IconEntry(path: "/a/f", name: "f", kind: .directory, hasCustomIcon: true, isEmptyFolder: true))
        #expect(custom.cacheKey == "path:/a/f:empty")
        #expect(custom.isFolder)
    }

    /// Quick Look looks inside a folder to draw it, which makes macOS ask for Desktop, Documents and Downloads.
    @Test func specialFoldersAndDisksAreNotDrawnByQuickLook() {
        for name in ["Desktop", "Documents", "Downloads"] {
            let special = IconRequest(entry: IconEntry(path: "/Users/u/\(name)", name: name, kind: .directory))
            #expect(special.cacheKey == "path:/Users/u/\(name)")
            #expect(!special.isFolder)
            let customized = IconRequest(
                entry: IconEntry(path: "/Users/u/\(name)", name: name, kind: .directory, hasCustomIcon: true))
            #expect(!customized.isFolder)
        }
        let disk = IconRequest(entry: IconEntry(path: "/Volumes/Backup", name: "Backup", kind: .directory))
        #expect(disk.cacheKey == "path:/Volumes/Backup")
        #expect(!disk.isFolder)
    }

    @Test func quickLookDrawsTheSampleFoldersAsFinderDoes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let samples = IconSamples(root: root)
        let source = WorkspaceIconSource()
        func picture(_ path: String) async -> Data? { await source.folderIcon(atPath: path)?.tiffRepresentation }
        let plain = await picture(try samples.path(for: .folder))
        let empty = await picture(try samples.path(for: .emptyFolder))
        let red = await picture(try samples.path(forTint: .red))
        let redEmpty = await picture(try samples.path(forTint: .red, isEmpty: true))
        let blue = await picture(try samples.path(forTint: .blue))
        #expect(plain != nil)
        #expect(plain != empty)
        #expect(red != plain)
        #expect(red != redEmpty)
        #expect(red != blue)
    }

    @Test func theDiskReadSaysWhichFoldersHoldNothing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = FileManager.default
        for name in ["empty", "full", "hidden"] {
            try files.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try Data().write(to: root.appendingPathComponent("full/item"))
        try Data().write(to: root.appendingPathComponent("hidden/.DS_Store"))
        try Data().write(to: root.appendingPathComponent("file"))
        let records = try NativeFileSystem().readDirectory(root.path)
        func isEmpty(_ name: String) -> Bool? { records.first { $0.name == name }?.isEmptyFolder }
        #expect(isEmpty("empty") == true)
        #expect(isEmpty("full") == false)
        // The count is all that is read: a hidden item counts.
        #expect(isEmpty("hidden") == false)
        #expect(isEmpty("file") == false)
        // What comes after the count in a record is still read right.
        #expect(records.first { $0.name == "file" }?.lstat?.size == 0)
        #expect(records.first { $0.name == "empty" }?.lstat?.type == .directory)
    }

    @Test func theDiskReadSaysTheLabelOfATaggedFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("tagged")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FinderTags.write(
            [FinderTag(name: "Blue", color: .blue), FinderTag(name: "Yellow", color: .yellow)], to: folder.path)
        #expect(try NativeFileSystem().readDirectory(root.path).first?.tagColor == .yellow)
    }

    @Test func theDiskReadSaysWhichFoldersFinderCustomized() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["custom", "plain"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        var finderInfo = [UInt8](repeating: 0, count: 32)
        finderInfo[8] = 0x04
        let custom = root.appendingPathComponent("custom").path
        #expect(setxattr(custom, "com.apple.FinderInfo", &finderInfo, 32, 0, 0) == 0)
        let records = try NativeFileSystem().readDirectory(root.path)
        #expect(records.first { $0.name == "custom" }?.hasCustomIcon == true)
        #expect(records.first { $0.name == "plain" }?.hasCustomIcon == false)
    }
}
