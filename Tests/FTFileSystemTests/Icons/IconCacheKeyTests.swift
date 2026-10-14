import Testing

@testable import FTFileSystem

// F-225
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

    // T-308244dc F-225
    @Test func filesWithoutAnExtensionShareOneIconOfTwoKinds() {
        #expect(key("/usr/bin/ls", name: "ls", executable: true) == "kind:executable")
        #expect(key("/usr/bin/zip", name: "zip", executable: true) == "kind:executable")
        #expect(key("/usr/bin/hosts", name: "hosts", executable: false) == "kind:file")
        #expect(key("/usr/bin/Makefile", name: "Makefile", executable: false) == "kind:file")
    }

    @Test func aFileWithoutAnExtensionOfUnknownModeIsAskedForByPath() {
        #expect(key("/found/Makefile", name: "Makefile") == "path:/found/Makefile")
    }

    // T-41333069 F-225
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

    @Test func volumeRoots() {
        #expect(IconCacheKey.volumeRootPath(of: "/Volumes/Backup/a/b") == "/Volumes/Backup")
        #expect(IconCacheKey.volumeRootPath(of: "/Volumes/") == "/")
        #expect(IconCacheKey.volumeRootPath(of: "/Users/me") == "/")
        #expect(IconCacheKey.isVolumeRootPath("/"))
        #expect(!IconCacheKey.isVolumeRootPath("/Volumes/Backup/a"))
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

    @Test func theStoresKeepAsManyAsTheOriginal() {
        #expect(FileIconStore.maxEntries == 2048)
        #expect(ThumbnailStore.maxEntries == 500)
        #expect(ThumbnailStore.pixelSize == 128)
        #expect(ThumbnailLoadQueue.maxConcurrentLoads == 4)
    }
}
