// Port of packages/core/src/fs/copyPasteAnalysis.test.ts
import FTFoundation
import Foundation
import Testing

@testable import FTOperations

private func analyze(
    _ fileSystem: MockAnalysisFileSystem, _ sourcePaths: [String], into destination: String, items: Int = 100,
    bytes: Int64 = 1000, signal: StopSignal? = nil
) throws -> CopyPasteAnalysisReport {
    try analyze(fileSystem, .copy, sourcePaths, into: destination, items: items, bytes: bytes, signal: signal)
}

private func analyze(
    _ fileSystem: MockAnalysisFileSystem, _ mode: CopyPasteMode, _ sourcePaths: [String],
    into destination: String, items: Int = 100, bytes: Int64 = 1000, signal: StopSignal? = nil
) throws -> CopyPasteAnalysisReport {
    try buildCopyPasteAnalysisReport(
        analysisId: "analysis-1",
        request: CopyPasteAnalysisRequest(mode: mode, sourcePaths: sourcePaths, destinationDirectoryPath: destination),
        fileSystem: fileSystem, thresholds: .init(largeBatchItemThreshold: items, largeBatchByteThreshold: bytes),
        signal: signal)
}

private func findChild(_ node: CopyPasteAnalysisNode?, endingWith suffix: String) -> CopyPasteAnalysisNode? {
    node?.children.first { $0.sourcePath.hasSuffix(suffix) }
}

struct CopyPasteAnalysisTests {
    // T-899e0083 F-418
    @Test func normalizesSourceAndDestinationPaths() {
        #expect(
            normalizeCopyPasteAnalysisRequest(
                CopyPasteAnalysisRequest(
                    mode: .copy,
                    sourcePaths: ["/workspace/file.txt/", "/workspace/file.txt", "/workspace/../workspace/a"],
                    destinationDirectoryPath: "/target/../target"))
                == CopyPasteAnalysisRequest(
                    mode: .copy, sourcePaths: ["/workspace/file.txt", "/workspace/a"],
                    destinationDirectoryPath: "/target"))
    }

    // T-dddfa761 F-418 F-241
    @Test func analyzesANewFileCopyIntoAnEmptyDestination() throws {
        let fileSystem = MockAnalysisFileSystem([
            ("/workspace", .directory()), ("/workspace/file.txt", .file(size: 5)), ("/target", .directory()),
        ])

        let report = try analyze(fileSystem, ["/workspace/file.txt"], into: "/target")

        #expect(report.issues.isEmpty)
        #expect(report.summary.totalNodeCount == 1)
        #expect(report.summary.fileConflictCount == 0)
        #expect(report.summary.directoryConflictCount == 0)
        #expect(report.summary.mismatchConflictCount == 0)
        #expect(report.summary.totalBytes == 5)
        let node = try #require(report.nodes.first)
        #expect(node.sourcePath == "/workspace/file.txt")
        #expect(node.destinationPath == "/target/file.txt")
        #expect(node.conflictClass == nil)
        #expect(node.disposition == .new)
    }

    // T-fe65bc63 F-419 F-256
    @Test func resolvesSameDirectoryCopyToAKeepBothDestinationName() throws {
        let fileSystem = MockAnalysisFileSystem([
            ("/workspace", .directory()), ("/workspace/file.txt", .file(size: 5)),
            ("/workspace/file copy.txt", .file(size: 5)),
        ])

        let report = try analyze(fileSystem, ["/workspace/file.txt"], into: "/workspace")

        #expect(report.nodes.first?.destinationPath == "/workspace/file copy 2.txt")
        #expect(report.issues.isEmpty)
    }

    // T-88b2ff73 F-419 F-288
    @Test func blocksSameDirectoryCutAsASelfTarget() throws {
        let fileSystem = MockAnalysisFileSystem([("/workspace", .directory()), ("/workspace/file.txt", .file(size: 5))])

        let report = try analyze(fileSystem, .cut, ["/workspace/file.txt"], into: "/workspace")

        #expect(report.issues.map(\.code) == [.samePath])
    }

    // T-aa3a458d F-420 F-314
    @Test func flagsTopLevelAndNestedConflictsRecursivelyForFolders() throws {
        let fileSystem = MockAnalysisFileSystem([
            ("/source", .directory()), ("/source/Photos", .directory()), ("/source/Photos/logo.png", .file(size: 10)),
            ("/source/Photos/icons", .directory()), ("/source/Photos/icons/a.svg", .file(size: 4)),
            ("/target", .directory()), ("/target/Photos", .directory()), ("/target/Photos/logo.png", .file(size: 8)),
            ("/target/Photos/icons", .directory()), ("/target/Photos/icons/a.svg", .directory()),
        ])

        let report = try analyze(fileSystem, ["/source/Photos"], into: "/target")

        let topLevel = report.nodes.first
        #expect(topLevel?.conflictClass == .directoryConflict)
        #expect(report.summary.directoryConflictCount == 2)
        #expect(report.summary.fileConflictCount == 1)
        #expect(report.summary.mismatchConflictCount == 1)
        #expect(findChild(topLevel, endingWith: "logo.png")?.conflictClass == .fileConflict)
        #expect(
            findChild(findChild(topLevel, endingWith: "/icons"), endingWith: "a.svg")?.conflictClass == .typeMismatch)
    }

    // T-0d6c67b0 F-420 F-309
    @Test func detectsDestinationAndSourceIssues() throws {
        let fileSystem = MockAnalysisFileSystem([
            ("/workspace", .directory()), ("/workspace/file.txt", .file(size: 3)), ("/not-a-dir", .file(size: 1)),
        ])

        #expect(try analyze(fileSystem, ["/workspace/file.txt"], into: "/missing").issues.map(\.code) == [.destinationMissing])
        #expect(
            try analyze(fileSystem, ["/workspace/file.txt"], into: "/not-a-dir").issues.map(\.code)
                == [.destinationNotDirectory])
        #expect(
            try analyze(fileSystem, ["/workspace/file.txt", "/workspace/missing.txt"], into: "/workspace").issues.map(
                \.code) == [.sourceMissing])
    }

    // T-7c7cd228 F-421 F-310
    @Test func rejectsCopyingADirectoryIntoItsOwnDescendant() throws {
        let fileSystem = MockAnalysisFileSystem([
            ("/workspace", .directory()), ("/workspace/folder", .directory()), ("/workspace/folder/child", .directory()),
        ])
        fileSystem.setRealpath("/workspace/folder", "/workspace/folder")
        fileSystem.setRealpath("/workspace/folder/child", "/workspace/folder/child")

        let report = try analyze(fileSystem, ["/workspace/folder"], into: "/workspace/folder/child")

        #expect(report.issues.map(\.code) == [.parentIntoChild])
    }

    // A firmlink: "/Users/me/A" and "/System/Volumes/Data/Users/me/A" are one folder, and each keeps its own real
    // path.
    // T-70baa7f0 F-421 F-310
    @Test func blocksPastingAFolderIntoItsOwnInsideReachedByAnotherSpelling() throws {
        let fileSystem = MockAnalysisFileSystem([
            ("/Users", .directory(ino: 900, dev: 1)), ("/Users/me", .directory(ino: 901, dev: 1)),
            ("/Users/me/A", .directory(ino: 902, dev: 1)), ("/Users/me/B", .directory(ino: 903, dev: 1)),
            ("/System/Volumes/Data/Users", .directory(ino: 900, dev: 1)),
            ("/System/Volumes/Data/Users/me", .directory(ino: 901, dev: 1)),
            ("/System/Volumes/Data/Users/me/A", .directory(ino: 902, dev: 1)),
            ("/System/Volumes/Data/Users/me/A/sub", .directory(ino: 904, dev: 1)),
        ])

        let intoItself = try analyze(fileSystem, ["/Users/me/A"], into: "/System/Volumes/Data/Users/me/A/sub")
        #expect(intoItself.issues.map(\.code) == [.parentIntoChild])
        #expect(intoItself.issues.map(\.sourcePath) == ["/Users/me/A"])
        #expect(intoItself.nodes.isEmpty)
        // Its holder too; a folder beside it is pasted.
        let intoHolder = try analyze(
            fileSystem, ["/Users/me", "/Users/me/B"], into: "/System/Volumes/Data/Users/me/A/sub")
        #expect(intoHolder.issues.map(\.code) == [.parentIntoChild])
        #expect(intoHolder.issues.map(\.sourcePath) == ["/Users/me"])
        #expect(intoHolder.nodes.map(\.sourcePath) == ["/Users/me/B"])
    }

    // T-be429cac F-422 F-318
    @Test func cantReplaceAnItemPastedTooUnderAnotherSpellingOfItsPath() throws {
        let fileSystem = MockAnalysisFileSystem([
            ("/x", .directory()), ("/x/a.txt", .file(size: 1)), ("/d", .directory(ino: 910, dev: 1)),
            ("/d/a.txt", .file(size: 2, ino: 911, dev: 1)), ("/System/Volumes/Data/d", .directory(ino: 910, dev: 1)),
            ("/System/Volumes/Data/d/a.txt", .file(size: 2, ino: 911, dev: 1)),
        ])

        let report = try analyze(fileSystem, ["/x/a.txt", "/System/Volumes/Data/d/a.txt"], into: "/d")

        let node = try #require(report.nodes.first { $0.sourcePath == "/x/a.txt" })
        #expect(node.conflictClass == .fileConflict)
        #expect(node.replaceBlockedReason == "It is another item being pasted.")
    }

    // T-48e82758 F-423 F-311
    @Test func blocksSourcesFromDifferentFoldersThatWouldLandOnTheSameDestinationName() throws {
        let fileSystem = MockAnalysisFileSystem([
            ("/a", .directory()), ("/a/report.pdf", .file(size: 5)), ("/b", .directory()),
            ("/b/Report.pdf", .file(size: 7)), ("/b/notes.txt", .file(size: 1)), ("/target", .directory()),
        ])

        let report = try analyze(fileSystem, .cut, ["/a/report.pdf", "/b/Report.pdf", "/b/notes.txt"], into: "/target")

        #expect(report.issues.count == 1)
        #expect(report.issues.first?.code == .duplicateDestinationName)
        #expect(report.issues.first?.sourcePath == "/b/Report.pdf")
        #expect(report.issues.first?.destinationPath == "/target/Report.pdf")
    }

    // T-622ce2f9 F-424
    @Test func fallsBackToASourceMissingIssueWhenParentChildRealpathChecksFail() throws {
        let fileSystem = MockAnalysisFileSystem([
            ("/workspace", .directory()), ("/workspace/folder", .directory()), ("/workspace/folder/child", .directory()),
            ("/target", .directory()),
        ])
        fileSystem.realpathImpl = { path in
            if path == "/workspace/folder" {
                throw OperationError("realpath failed")
            }
            return path
        }

        let report = try analyze(fileSystem, ["/workspace/folder"], into: "/workspace/folder/child")

        #expect(report.issues.map(\.code) == [.sourceMissing])
    }

    // MARK: A folder moved on its own disk

    private static func folderToMove(_ extra: [(String, MockAnalysisFileSystem.Seed)] = []) -> (
        MockAnalysisFileSystem, ReadLog
    ) {
        let fileSystem = MockAnalysisFileSystem(
            [
                ("/source", .directory()), ("/source/Project", .directory()),
                ("/source/Project/a.txt", .file(size: 5)), ("/source/Project/lib/b.txt", .file(size: 7)),
                ("/target", .directory()),
            ] + extra)
        let read = ReadLog()
        let base = fileSystem.base
        fileSystem.readdirImpl = { path in
            read.paths.append(path)
            return try base.readdir(path)
        }
        return (fileSystem, read)
    }

    final class ReadLog: @unchecked Sendable {
        var paths: [String] = []
    }

    // T-1b2630a3 F-425 F-281
    @Test func aFolderMovedOnItsOwnDiskIsRenamedWholeWithoutReadingWhatIsInIt() throws {
        let (fileSystem, read) = Self.folderToMove()

        let report = try analyze(fileSystem, .cut, ["/source/Project"], into: "/target")

        #expect(report.nodes.count == 1)
        #expect(report.nodes.first?.renameOnly == true)
        #expect(report.nodes.first?.children.isEmpty == true)
        #expect(report.nodes.first?.totalNodeCount == 1)
        #expect(report.summary.totalNodeCount == 1)
        #expect(report.summary.totalBytes == nil)
        #expect(read.paths.filter { $0.hasPrefix("/source/Project") }.isEmpty)
    }

    enum ReadThrough: String, CaseIterable {
        case toATakenName = "to a name that is taken"
        case toAnotherDisk = "to another disk"
        case whenCopied = "when copied"
    }

    // T-0b446690 F-425 F-281
    @Test(arguments: ReadThrough.allCases)
    func aFolderMovedOnItsOwnDiskIsReadThrough(_ variant: ReadThrough) throws {
        let (mode, extra): (CopyPasteMode, [(String, MockAnalysisFileSystem.Seed)]) =
            switch variant {
            case .toATakenName: (.cut, [("/target/Project", .directory())])
            case .toAnotherDisk: (.cut, [("/target", .directory(dev: 2))])
            case .whenCopied: (.copy, [])
            }
        let (fileSystem, read) = Self.folderToMove(extra)

        let report = try analyze(fileSystem, mode, ["/source/Project"], into: "/target")

        #expect(report.nodes.first?.renameOnly == false)
        #expect(report.nodes.first?.totalNodeCount == 4)
        #expect(read.paths.contains("/source/Project/lib"))
    }

    // T-f5015ebd F-426 F-320
    @Test func includesLargeBatchAndCutWarnings() throws {
        // On another disk, so the folder is read through rather than renamed whole.
        let fileSystem = MockAnalysisFileSystem([
            ("/workspace", .directory(dev: 2)), ("/workspace/folder", .directory()),
            ("/workspace/folder/a.txt", .file(size: 5)), ("/workspace/folder/b.txt", .file(size: 7)),
            ("/target", .directory()),
        ])

        let report = try analyze(fileSystem, .cut, ["/workspace/folder"], into: "/target", items: 2, bytes: 4)

        let codes = report.warnings.map(\.code)
        #expect(codes.contains(.largeBatch))
        #expect(codes.contains(.cutRequiresDelete))
    }

    // MARK: destinationTotalNodeCount

    // T-001a2232 F-427 F-317
    @Test func countsDestinationItemsRecursivelyForADirectoryConflict() throws {
        let fileSystem = MockAnalysisFileSystem([
            ("/source", .directory()), ("/source/Photos", .directory()), ("/source/Photos/a.png", .file(size: 10)),
            ("/target", .directory()), ("/target/Photos", .directory()), ("/target/Photos/x.png", .file(size: 5)),
            ("/target/Photos/y.png", .file(size: 5)), ("/target/Photos/sub", .directory()),
            ("/target/Photos/sub/z.png", .file(size: 5)),
        ])

        let report = try analyze(fileSystem, ["/source/Photos"], into: "/target", bytes: 10000)

        #expect(report.nodes.first?.conflictClass == .directoryConflict)
        // x.png, y.png, sub, sub/z.png
        #expect(report.nodes.first?.destinationTotalNodeCount == 4)
    }

    // T-ef2ab173 F-427
    @Test func countsHiddenDotfilesInTheDestinationDirectory() throws {
        let fileSystem = MockAnalysisFileSystem([
            ("/source", .directory()), ("/source/folder", .directory()), ("/source/folder/file.txt", .file(size: 1)),
            ("/target", .directory()), ("/target/folder", .directory()), ("/target/folder/.hidden", .file(size: 1)),
            ("/target/folder/.config", .directory()), ("/target/folder/.config/settings", .file(size: 1)),
        ])

        let report = try analyze(fileSystem, ["/source/folder"], into: "/target", bytes: 10000)

        // .hidden, .config, .config/settings
        #expect(report.nodes.first?.destinationTotalNodeCount == 3)
    }

    // T-1525cf75 F-427
    @Test func returnsZeroForAnEmptyDestinationDirectory() throws {
        let fileSystem = MockAnalysisFileSystem([
            ("/source", .directory()), ("/source/folder", .directory()), ("/source/folder/file.txt", .file(size: 1)),
            ("/target", .directory()), ("/target/folder", .directory()),
        ])

        let report = try analyze(fileSystem, ["/source/folder"], into: "/target", bytes: 10000)

        #expect(report.nodes.first?.destinationTotalNodeCount == 0)
    }

    // T-28c543bb F-427
    @Test func countsSymlinksAsItemsInTheDestination() throws {
        let fileSystem = MockAnalysisFileSystem([
            ("/source", .directory()), ("/source/folder", .directory()), ("/source/folder/f.txt", .file(size: 1)),
            ("/target", .directory()), ("/target/folder", .directory()), ("/target/folder/link", .symlink("/elsewhere")),
        ])

        let report = try analyze(fileSystem, ["/source/folder"], into: "/target", bytes: 10000)

        #expect(report.nodes.first?.destinationTotalNodeCount == 1)
    }

    // T-ddbc07b6 F-427
    @Test func returnsNullForFileConflictNodes() throws {
        let fileSystem = MockAnalysisFileSystem([
            ("/source", .directory()), ("/source/file.txt", .file(size: 5)), ("/target", .directory()),
            ("/target/file.txt", .file(size: 10)),
        ])

        let report = try analyze(fileSystem, ["/source/file.txt"], into: "/target", bytes: 10000)

        #expect(report.nodes.first?.conflictClass == .fileConflict)
        #expect(report.nodes.first?.destinationTotalNodeCount == nil)
    }

    // T-789848b4 F-427 F-317
    @Test func countsTheExistingFolderOfATypeMismatch() throws {
        let fileSystem = MockAnalysisFileSystem([
            ("/source", .directory()), ("/source/item", .file(size: 5)), ("/target", .directory()),
            ("/target/item", .directory()),
        ])

        let report = try analyze(fileSystem, ["/source/item"], into: "/target", bytes: 10000)

        #expect(report.nodes.first?.conflictClass == .typeMismatch)
        // The existing (empty) folder would be lost to Replace, so it is counted too.
        #expect(report.nodes.first?.destinationTotalNodeCount == 0)
        #expect(report.nodes.first?.destinationOnly == CopyPasteDestinationOnlySummary(count: 0, samplePaths: []))
    }

    // T-22b17976 F-427
    @Test func returnsNullForNewItemsWithNoConflict() throws {
        let fileSystem = MockAnalysisFileSystem([
            ("/source", .directory()), ("/source/file.txt", .file(size: 5)), ("/target", .directory()),
        ])

        let report = try analyze(fileSystem, ["/source/file.txt"], into: "/target", bytes: 10000)

        #expect(report.nodes.first?.conflictClass == nil)
        #expect(report.nodes.first?.destinationTotalNodeCount == nil)
    }

    // T-0b4507a2 F-427
    @Test func returnsNullWhenDestinationReaddirFails() throws {
        let fileSystem = MockAnalysisFileSystem([
            ("/source", .directory()), ("/source/folder", .directory()), ("/source/folder/f.txt", .file(size: 1)),
            ("/target", .directory()), ("/target/folder", .directory()), ("/target/folder/a.txt", .file(size: 1)),
        ])
        let base = fileSystem.base
        fileSystem.readdirImpl = { path in
            if path == "/target/folder" {
                throw codedError("EACCES", "EACCES: permission denied")
            }
            return try base.readdir(path)
        }

        let report = try analyze(fileSystem, ["/source/folder"], into: "/target", bytes: 10000)

        #expect(report.nodes.first?.conflictClass == .directoryConflict)
        #expect(report.nodes.first?.destinationTotalNodeCount == nil)
    }

    // T-88d14058 F-427
    @Test func handlesDeeplyNestedDestinationTrees() throws {
        let fileSystem = MockAnalysisFileSystem([
            ("/source", .directory()), ("/source/root", .directory()), ("/source/root/f.txt", .file(size: 1)),
            ("/target", .directory()), ("/target/root", .directory()), ("/target/root/a", .directory()),
            ("/target/root/a/b", .directory()), ("/target/root/a/b/c", .directory()),
            ("/target/root/a/b/c/deep.txt", .file(size: 1)), ("/target/root/sibling.txt", .file(size: 1)),
        ])

        let report = try analyze(fileSystem, ["/source/root"], into: "/target", bytes: 10000)

        // a, a/b, a/b/c, a/b/c/deep.txt, sibling.txt
        #expect(report.nodes.first?.destinationTotalNodeCount == 5)
    }

    // T-96ce005a F-427
    @Test func countsMixedFileTypesCorrectlyInDestination() throws {
        let fileSystem = MockAnalysisFileSystem([
            ("/source", .directory()), ("/source/dir", .directory()), ("/source/dir/x.txt", .file(size: 1)),
            ("/target", .directory()), ("/target/dir", .directory()), ("/target/dir/file.txt", .file(size: 1)),
            ("/target/dir/sub", .directory()), ("/target/dir/link", .symlink("/elsewhere")),
        ])

        let report = try analyze(fileSystem, ["/source/dir"], into: "/target", bytes: 10000)

        // file.txt, sub, link
        #expect(report.nodes.first?.destinationTotalNodeCount == 3)
    }

    // T-7b971083 F-427
    @Test func reusesCachedCountsForNestedDestinationConflicts() throws {
        let fileSystem = MockAnalysisFileSystem([
            ("/source", .directory()), ("/source/root", .directory()), ("/source/root/sub", .directory()),
            ("/source/root/sub/file.txt", .file(size: 1)), ("/target", .directory()), ("/target/root", .directory()),
            ("/target/root/sub", .directory()), ("/target/root/sub/existing.txt", .file(size: 1)),
        ])
        let reads = ReadLog()
        let base = fileSystem.base
        fileSystem.readdirImpl = { path in
            if path.hasPrefix("/target/") {
                reads.paths.append(path)
            }
            return try base.readdir(path)
        }

        let report = try analyze(fileSystem, ["/source/root"], into: "/target", bytes: 10000)

        #expect(report.nodes.first?.destinationTotalNodeCount == 2)
        #expect(report.nodes.first?.children.first?.destinationTotalNodeCount == 1)
        #expect(reads.paths.filter { $0 == "/target/root" }.count == 1)
        #expect(reads.paths.filter { $0 == "/target/root/sub" }.count == 1)
    }

    // T-50c57947 F-427
    @Test func propagatesAbortsWhileCountingDestinationItems() {
        let fileSystem = MockAnalysisFileSystem([
            ("/source", .directory()), ("/source/folder", .directory()), ("/source/folder/file.txt", .file(size: 1)),
            ("/target", .directory()), ("/target/folder", .directory()), ("/target/folder/existing.txt", .file(size: 1)),
        ])
        let signal = StopSignal()
        signal.stop()

        #expect(throws: StopError.self) {
            try analyze(fileSystem, ["/source/folder"], into: "/target", bytes: 10000, signal: signal)
        }
    }

    // T-ad772b7c F-314
    @Test func handlesSymlinkSourcesAsFirstClassNodes() throws {
        let fileSystem = MockAnalysisFileSystem([
            ("/source", .directory()), ("/source/alias", .symlink("actual.txt")), ("/target", .directory()),
            ("/target/alias", .file(size: 5)),
        ])

        let report = try analyze(fileSystem, ["/source/alias"], into: "/target")

        #expect(report.nodes.first?.sourceKind == .symlink)
        #expect(report.nodes.first?.destinationKind == .file)
        #expect(report.nodes.first?.conflictClass == .typeMismatch)
    }

    // MARK: On a case-sensitive volume

    // T-e9ca5d72 F-428 F-311
    @Test func onACaseSensitiveVolumeNamesThatDifferOnlyByCaseLandSideBySide() throws {
        let seed: [(String, MockAnalysisFileSystem.Seed)] = [
            ("/a/report.pdf", .file(size: 5)), ("/b/Report.pdf", .file(size: 7)), ("/target", .directory()),
        ]
        let insensitive = MockAnalysisFileSystem(seed)
        let sensitive = MockAnalysisFileSystem(seed)
        sensitive.caseSensitive = true

        #expect(
            try analyze(insensitive, ["/a/report.pdf", "/b/Report.pdf"], into: "/target").issues.map(\.code) == [
                .duplicateDestinationName
            ])
        let report = try analyze(sensitive, ["/a/report.pdf", "/b/Report.pdf"], into: "/target")
        #expect(report.issues.isEmpty)
        #expect(report.destinationCaseSensitive)
    }

    // T-7849033d F-428 F-319
    @Test func onACaseSensitiveVolumeKeepBothNamesAreReservedByExactCase() throws {
        let seed: [(String, MockAnalysisFileSystem.Seed)] = [
            ("/source/notes.txt", .file(size: 5)), ("/source/Notes copy.txt", .file(size: 5)),
            ("/target/notes.txt", .file(size: 1)),
        ]
        let insensitive = MockAnalysisFileSystem(seed)
        let sensitive = MockAnalysisFileSystem(seed)
        sensitive.caseSensitive = true
        let sources = ["/source/notes.txt", "/source/Notes copy.txt"]

        #expect(
            try analyze(insensitive, sources, into: "/target").nodes.first?.keepBothDestinationPath
                == "/target/notes copy 2.txt")
        #expect(
            try analyze(sensitive, sources, into: "/target").nodes.first?.keepBothDestinationPath
                == "/target/notes copy.txt")
    }

    // T-21536dfd F-428 F-309
    @Test func onACaseSensitiveVolumeTheVolumeIsAskedOncePerAnalysis() throws {
        let fileSystem = MockAnalysisFileSystem([
            ("/source/a.txt", .file(size: 5)), ("/source/b.txt", .file(size: 5)), ("/target/a.txt", .file(size: 1)),
            ("/target/b.txt", .file(size: 1)),
        ])
        let asked = ReadLog()
        fileSystem.isCaseSensitiveImpl = { path in
            asked.paths.append(path)
            return true
        }

        _ = try analyze(fileSystem, ["/source/a.txt", "/source/b.txt"], into: "/target")

        #expect(asked.paths == ["/target"])
    }

    // Each item in the way is checked against the others pasted by a lookup, not by reading every item pasted
    // again: 2,000 items in the way took 4 million reads.
    // T-88e17c92 F-428
    @Test func readsTheDiskInProportionToTheItemsPasted() throws {
        func readsFor(_ count: Int) throws -> Int {
            let fileSystem = MockAnalysisFileSystem([("/src", .directory()), ("/dst", .directory())])
            var sourcePaths: [String] = []
            for index in 0..<count {
                fileSystem.addFile("/src/item-\(index).txt", size: 1)
                fileSystem.addFile("/dst/item-\(index).txt", size: 2)
                sourcePaths.append("/src/item-\(index).txt")
            }
            let report = try analyze(fileSystem, sourcePaths, into: "/dst", items: 100_000, bytes: 1_000_000)
            #expect(report.summary.fileConflictCount == count)
            return fileSystem.lstatCount
        }

        #expect(Double(try readsFor(300)) < 2.5 * Double(try readsFor(150)))
    }

    // MARK: A disk mounted inside a folder

    private static func withMountedDisk(_ seed: [(String, MockAnalysisFileSystem.Seed)] = []) -> MockAnalysisFileSystem {
        MockAnalysisFileSystem(
            [
                ("/Users/me/project", .directory(dev: 1)), ("/Users/me/project/notes.txt", .file(size: 1)),
                ("/Users/me/project/mnt", .directory(dev: 7)), ("/Users/me/project/mnt/disk-file.txt", .file(size: 1)),
                ("/Users/me/target", .directory(dev: 1)), ("/Volumes/Other", .directory(dev: 3)),
            ] + seed)
    }

    // A move to another disk copies the folder and then removes it, the mounted disk's items with it.
    // T-1d226fa8 F-429 F-287
    @Test func aDiskMountedInsideAFolderRefusesToMoveTheFolderToAnotherDisk() throws {
        let report = try analyze(Self.withMountedDisk(), .cut, ["/Users/me/project"], into: "/Volumes/Other")

        #expect(
            report.issues == [
                CopyPasteAnalysisIssue(
                    code: .sourceUnreadable,
                    message: "\u{201C}project\u{201D} can't be moved because a disk is mounted inside it (\u{201C}mnt\u{201D}).",
                    sourcePath: "/Users/me/project", destinationPath: "/Volumes/Other/project")
            ])
        #expect(report.nodes.isEmpty)
    }

    // T-4b9c30b7 F-429
    @Test func aDiskMountedInsideAFolderIsCopiedDiskAndAll() throws {
        let report = try analyze(Self.withMountedDisk(), .copy, ["/Users/me/project"], into: "/Volumes/Other")

        #expect(report.issues.isEmpty)
        #expect(report.summary.totalNodeCount == 4)
    }

    // On the same disk the folder is renamed whole, and the disk stays mounted in it.
    // T-9a10332f F-429
    @Test func aDiskMountedInsideAFolderMovesTheFolderOnItsOwnDisk() throws {
        let report = try analyze(Self.withMountedDisk(), .cut, ["/Users/me/project"], into: "/Users/me/target")

        #expect(report.issues.isEmpty)
    }

    // Merged into a folder of the same name, its items are moved one by one: the mounted disk's would be copied
    // and removed.
    // T-624982bf F-429 F-287
    @Test func aDiskMountedInsideAFolderRefusesToMergeTheFolderIntoAnotherOnItsOwnDisk() throws {
        let report = try analyze(
            Self.withMountedDisk([("/Users/me/target/project", .directory(dev: 1))]), .cut, ["/Users/me/project"],
            into: "/Users/me/target")

        #expect(report.issues.map(\.code) == [.sourceUnreadable])
    }
}
