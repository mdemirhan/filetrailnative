import Foundation
import Testing

@testable import FTOperations

struct CopyPasteFingerprintTests {
    @Test func capturesFileFingerprintsWithMetadata() {
        let fileSystem = MockIdentityFileSystem([
            ("/workspace/file.txt", .file(size: 42, mode: 0o755, mtimeMs: 1234, ino: 7, dev: 2))
        ])

        #expect(
            captureFingerprint(fileSystem, "/workspace/file.txt")
                == NodeFingerprint(
                    exists: true, kind: .file, size: 42, mtimeMs: 1234, mode: 0o755, ino: 7, dev: 2,
                    symlinkTarget: nil))
    }

    @Test func capturesSymlinkFingerprintsAndReadsTheLinkTarget() throws {
        let fileSystem = MockIdentityFileSystem([
            ("/workspace/alias", .symlink("actual.txt", mode: 0o777, mtimeMs: 5000))
        ])

        let fingerprint = captureFingerprint(fileSystem, "/workspace/alias")

        #expect(fingerprint.kind == .symlink)
        #expect(fingerprint.symlinkTarget == "actual.txt")
        #expect(detectKind(try fileSystem.lstat("/workspace/alias")) == .symlink)
    }

    @Test func treatsUnreadableSymlinkTargetsAsNull() {
        let fileSystem = MockIdentityFileSystem([("/workspace/alias", .symlink("actual.txt"))])
        fileSystem.readlinkImpl = { _ in throw OperationError("readlink failed") }

        #expect(captureFingerprint(fileSystem, "/workspace/alias").symlinkTarget == nil)
    }

    @Test func returnsAMissingFingerprintForAbsentPaths() {
        let fileSystem = MockIdentityFileSystem()

        #expect(
            captureFingerprint(fileSystem, "/missing")
                == NodeFingerprint(
                    exists: false, kind: .missing, size: nil, mtimeMs: nil, mode: nil, ino: nil, dev: nil,
                    symlinkTarget: nil))
    }

    @Test func treatsNullInodeAndDeviceValuesAsFallbackCompatible() {
        #expect(
            fingerprintsEqual(
                NodeFingerprint(exists: true, kind: .file, size: 1, mtimeMs: 10, mode: 0o644, ino: nil, dev: nil),
                NodeFingerprint(exists: true, kind: .file, size: 1, mtimeMs: 10, mode: 0o644, ino: 99, dev: 1)))
    }

    @Test func detectsMeaningfulMetadataChanges() {
        let base = NodeFingerprint(exists: true, kind: .file, size: 5, mtimeMs: 100, mode: 0o644, ino: 1, dev: 1)
        func with(_ change: (inout NodeFingerprint) -> Void) -> NodeFingerprint {
            var copy = base
            change(&copy)
            return copy
        }

        #expect(!fingerprintsEqual(base, with { $0.size = 6 }))
        #expect(!fingerprintsEqual(base, with { $0.mtimeMs = 101 }))
        #expect(
            !fingerprintsEqual(
                with {
                    $0.kind = .symlink
                    $0.symlinkTarget = "a"
                },
                with {
                    $0.kind = .symlink
                    $0.symlinkTarget = "b"
                }))
        #expect(!fingerprintsEqual(base, with { $0.ino = 2 }))
        #expect(!fingerprintsEqual(base, with { $0.dev = 2 }))
        // Targets compare scalar for scalar.
        #expect(
            !fingerprintsEqual(
                with { $0.symlinkTarget = "caf\u{e9}" }, with { $0.symlinkTarget = "cafe\u{301}" }))
    }
}

struct FileIdOfTests {
    @Test func keepsAFileIdANumberCanHoldExactly() {
        #expect(fileIdOf(447403) == 447403)
        #expect(fileIdOf(9_007_199_254_740_991) == 9_007_199_254_740_991)
    }

    // FAT and exFAT empty files, and the system volume's folders, have ids near 2^64 that round to the same
    // number as a Double.
    @Test func treatsAnIdTooLargeToCompareAsUnknown() {
        #expect(fileIdOf(18_446_744_073_709_551_602) == nil)
        #expect(fileIdOf(1_152_921_500_311_879_682) == nil)
        #expect(fileIdOf(nil) == nil)
        #expect(fileIdOf(1 << 53) == nil)
    }
}

struct PastedItemsTests {
    // Home reached by its firmlinked spelling: the same folders, by identity, under two paths that real paths keep
    // apart.
    func firmlinkedHome() -> MockIdentityFileSystem {
        let data = "/System/Volumes/Data"
        return MockIdentityFileSystem([
            ("/Users/me", .directory(ino: 99, dev: 1)),
            ("\(data)/Users/me", .directory(ino: 99, dev: 1)),
            ("/Users/me/d", .directory(ino: 100, dev: 1)),
            ("/Users/me/d/keep.txt", .file(ino: 101, dev: 1)),
            ("/Users/me/a.txt", .file(ino: 102, dev: 1)),
            ("/Users/me/b.txt", .file(ino: 103, dev: 1)),
            ("\(data)/Users/me/d", .directory(ino: 100, dev: 1)),
            ("\(data)/Users/me/d/keep.txt", .file(ino: 101, dev: 1)),
            ("\(data)/Users/me/a.txt", .file(ino: 102, dev: 1)),
        ])
    }

    @Test func findsAnItemPastedInsideAFolderReachedByAnotherSpelling() {
        let fileSystem = firmlinkedHome()
        let pasted = ["/System/Volumes/Data/Users/me/d/keep.txt"]
        let items = PastedItems(realPaths: pasted)

        #expect(holdsAnyOf(fileSystem, "/Users/me/d", items))
        #expect(holdsAnyOf(fileSystem, "/Users/me", items))
        // Moved out already (earlier in the same move): no longer at risk.
        fileSystem.delete("/System/Volumes/Data/Users/me/d/keep.txt")
        #expect(!holdsAnyOf(fileSystem, "/Users/me/d", PastedItems(realPaths: pasted)))
    }

    @Test func findsAnItemThatIsItselfPastedByAnotherSpelling() {
        let fileSystem = firmlinkedHome()
        let items = PastedItems(realPaths: ["/System/Volumes/Data/Users/me/a.txt"])

        #expect(isAnyOf(fileSystem, "/Users/me/a.txt", items))
        #expect(!isAnyOf(fileSystem, "/Users/me/b.txt", items))
    }

    // FAT and exFAT give no identities (for empty files), and don't tell case apart.
    @Test func comparesPathsIgnoringCaseOnADiskThatGivesNoIdentities() {
        let noId: UInt64 = 18_446_744_073_709_551_602
        let fileSystem = MockIdentityFileSystem([
            ("/v", .directory(ino: noId)),
            ("/v/a.txt", .file(ino: noId)),
            ("/v/sub", .directory(ino: noId)),
            ("/v/sub/x.txt", .file(ino: noId)),
        ])

        #expect(isAnyOf(fileSystem, "/v/A.txt", PastedItems(realPaths: ["/v/a.txt"])))
        #expect(holdsAnyOf(fileSystem, "/v/SUB", PastedItems(realPaths: ["/v/sub/x.txt"])))
        // Moved away already (earlier in the same move): no longer at risk.
        fileSystem.delete("/v/a.txt")
        #expect(!isAnyOf(fileSystem, "/v/A.txt", PastedItems(realPaths: ["/v/a.txt"])))
    }

    @Test func findsAHardLinkToAnItemPasted() {
        let fileSystem = MockIdentityFileSystem([
            ("/x/a.txt", .file(ino: 50, dev: 1)),
            ("/d/link.txt", .file(ino: 50, dev: 1)),
            ("/d/other.txt", .file(ino: 51, dev: 1)),
        ])
        let items = PastedItems(realPaths: ["/x/a.txt"])

        #expect(isAnyOf(fileSystem, "/d/link.txt", items))
        #expect(!isAnyOf(fileSystem, "/d/other.txt", items))
    }

    // On a disk that tells case apart, "a.txt" and "A.txt" are two items.
    @Test func tellsNamesApartByCaseOnACaseSensitiveDisk() {
        let fileSystem = MockIdentityFileSystem()
        fileSystem.caseSensitive = true
        fileSystem.addDirectory("/d")
        fileSystem.addFile("/d/a.txt")
        fileSystem.addFile("/d/A.txt")
        fileSystem.addDirectory("/d/sub")
        fileSystem.addDirectory("/d/Sub")
        fileSystem.addFile("/d/Sub/x.txt")

        #expect(!isAnyOf(fileSystem, "/d/a.txt", PastedItems(realPaths: ["/d/A.txt"])))
        #expect(isAnyOf(fileSystem, "/d/A.txt", PastedItems(realPaths: ["/d/A.txt"])))
        #expect(!holdsAnyOf(fileSystem, "/d/sub", PastedItems(realPaths: ["/d/Sub/x.txt"])))
        #expect(holdsAnyOf(fileSystem, "/d/Sub", PastedItems(realPaths: ["/d/Sub/x.txt"])))
    }

    // Asked once for each item in the way: each answer looks at that one item, not at every item pasted again
    // (2,000 items took 4 million looks).
    @Test func readsEachItemOnceHoweverManyItemsAreAskedAbout() {
        let count = 300
        let fileSystem = MockIdentityFileSystem([("/src", .directory())])
        fileSystem.addDirectory("/dst")
        var pasted: [String] = []
        for index in 0..<count {
            fileSystem.addFile("/src/item-\(index).txt")
            fileSystem.addDirectory("/dst/item-\(index)")
            pasted.append("/src/item-\(index).txt")
        }
        let items = PastedItems(realPaths: pasted)
        let before = fileSystem.lstatCount

        for index in 0..<count {
            #expect(!isAnyOf(fileSystem, "/dst/item-\(index)", items))
            #expect(!holdsAnyOf(fileSystem, "/dst/item-\(index)", items))
        }

        #expect(fileSystem.lstatCount - before < 5 * count)
    }

    // A pasted item that can't be read just now (a disk error, a network disk not answering) may still be there:
    // it is still at risk, never taken for one moved out already.
    @Test func takesAnItemInsideThatCantBeReadForOneStillThere() {
        let disk = MockWriteServiceFileSystem([("/d/sub/x.txt", .file(ino: 60, dev: 1))])
        let fileSystem = TestFileSystem(disk)
        let items = PastedItems(realPaths: ["/d/sub/x.txt"])
        #expect(holdsAnyOf(fileSystem, "/d/sub", items))

        fileSystem.lstatImpl = { path in
            if path == "/d/sub/x.txt" {
                throw MockWriteServiceFileSystem.error(EIO, path)
            }
            return try disk.lstat(path)
        }

        #expect(holdsAnyOf(fileSystem, "/d/sub", items))
    }

    @Test func takesAnItemThatCantBeReadForOneStillBeingPasted() {
        let disk = MockWriteServiceFileSystem([("/d/a.txt", .file(ino: 61, dev: 1))])
        let fileSystem = TestFileSystem(disk)
        let items = PastedItems(realPaths: ["/d/a.txt"])
        #expect(isAnyOf(fileSystem, "/d/a.txt", items))

        fileSystem.lstatImpl = { path in
            if path == "/d/a.txt" {
                throw MockWriteServiceFileSystem.error(EIO, path)
            }
            return try disk.lstat(path)
        }

        #expect(isAnyOf(fileSystem, "/d/a.txt", items))
    }
}

struct SourceRelationTests {
    @Test func tellsTheSameItemAndAFolderHoldingIt() {
        let fileSystem = MockIdentityFileSystem([
            ("/a", .directory(ino: 20, dev: 1)),
            ("/a/b", .directory(ino: 21, dev: 1)),
            ("/a/b/c.txt", .file(ino: 22, dev: 1)),
            ("/other", .directory(ino: 23, dev: 1)),
        ])
        let folder = captureFingerprint(fileSystem, "/a")

        #expect(findSourceRelation(fileSystem, sourcePath: "/a", destinationPath: "/a", destination: folder) == .same)
        #expect(
            findSourceRelation(fileSystem, sourcePath: "/a/b/c.txt", destinationPath: "/a", destination: folder)
                == .contains)
        // Another letter case of the same folder, by identity.
        #expect(
            findSourceRelation(fileSystem, sourcePath: "/A/b/c.txt", destinationPath: "/a", destination: folder)
                == .contains)
        #expect(
            findSourceRelation(
                fileSystem, sourcePath: "/other", destinationPath: "/a", destination: folder) == nil)
    }

    @Test func followsAFolderGivenByALink() {
        let fileSystem = MockIdentityFileSystem([
            ("/real", .directory(ino: 30, dev: 1)),
            ("/link", .symlink("/real")),
        ])

        let followed = captureFolderFingerprint(fileSystem, "/link")

        #expect(followed.kind == .directory)
        #expect(followed.ino == 30)
        #expect(captureFingerprint(fileSystem, "/link").kind == .symlink)
    }
}
