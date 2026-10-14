// Port of the review cases of packages/core/src/fs/copyPasteBlockedReplace.test.ts: Replace for all, over another item
// being pasted, is made the safe choice before anything is pasted. What the paste then writes (and that it refuses a
// Replace planned anyway) is checked with the engine (P3-03, P3-04).
import FTFoundation
import Foundation
import Testing

@testable import FTOperations

private let replaceAll = CopyPastePolicy(file: .overwrite, directory: .overwrite, mismatch: .overwrite)

private func analyze(_ fileSystem: MockAnalysisFileSystem, _ mode: CopyPasteMode, _ sources: [String], into destination: String)
    throws -> CopyPasteAnalysisReport
{
    try buildCopyPasteAnalysisReport(
        analysisId: "analysis-1",
        request: CopyPasteAnalysisRequest(mode: mode, sourcePaths: sources, destinationDirectoryPath: destination),
        fileSystem: fileSystem, thresholds: .init(largeBatchItemThreshold: 100, largeBatchByteThreshold: 1000))
}

struct BlockedReplaceReviewTests {
    // Search results from two folders, pasted into one of them: "/d/a.txt" is pasted too, and "/x/a.txt" would
    // land on it.
    // T-a0bdac5b F-446 F-318
    @Test func replaceForAllOverAnotherItemBeingPastedKeepsBothAsTheReviewSheetSays() throws {
        let fileSystem = MockAnalysisFileSystem([
            ("/x", .directory()), ("/x/a.txt", .file(size: 3)), ("/d", .directory()), ("/d/a.txt", .file(size: 7)),
        ])
        let report = try analyze(fileSystem, .copy, ["/x/a.txt", "/d/a.txt"], into: "/d")
        let blocked = try #require(report.nodes.first { $0.sourcePath == "/x/a.txt" })
        #expect(blocked.replaceBlockedReason == "It is another item being pasted.")

        let resolved = try resolveAnalysisWithPolicy(report: report, policy: replaceAll, fileSystem: fileSystem)

        let kept = try #require(resolved.first { $0.node.sourcePath == "/x/a.txt" })
        #expect(kept.action == .keepBoth)
        #expect(kept.destinationPath != "/d/a.txt")
        // "/d/a.txt" pasted into its own folder is "/d/a copy.txt": the kept copy takes the next name.
        #expect(kept.destinationPath == "/d/a copy 2.txt")
    }

    // "/data/d" is "/d" by another spelling (a firmlink): the same folder, by identity.
    // T-6d3f7e31 F-446 F-318
    @Test func neverReplacesAFolderHoldingAnotherItemBeingPastedReachedByAnotherSpelling() throws {
        let fileSystem = MockAnalysisFileSystem([
            ("/x", .directory(dev: 2)), ("/x/a", .directory(dev: 2)), ("/x/a/new.txt", .file(size: 3, dev: 2)),
            ("/d/a", .directory(ino: 500)), ("/d/a/keep.txt", .file(size: 4, ino: 501)),
            ("/data/d/a", .directory(ino: 500)), ("/data/d/a/keep.txt", .file(size: 4, ino: 501)),
        ])
        let report = try analyze(fileSystem, .cut, ["/x/a", "/data/d/a/keep.txt"], into: "/d")
        let folder = try #require(report.nodes.first { $0.sourcePath == "/x/a" })
        #expect(folder.conflictClass == .directoryConflict)
        #expect(folder.replaceBlockedReason == "It contains another item being pasted.")

        let resolved = try resolveAnalysisWithPolicy(report: report, policy: replaceAll, fileSystem: fileSystem)

        #expect(resolved.first { $0.node.sourcePath == "/x/a" }?.action == .merge)
    }
}
