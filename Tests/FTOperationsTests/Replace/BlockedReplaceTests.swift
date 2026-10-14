// Port of the case of packages/core/src/fs/copyPasteBlockedReplace.test.ts where the paste itself refuses a Replace
// planned over another item being pasted (the review cases are in Policy/BlockedReplaceReviewTests.swift)
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTOperations

struct BlockedReplaceTests {
    // T-b743943a F-338 F-490
    @Test func isRefusedByThePasteItselfWhenThePlanSaysReplace() async throws {
        // Search results from two folders, pasted into one of them: "/d/a.txt" is pasted too, and "/x/a.txt" would
        // land on it.
        let fileSystem = MockWriteServiceFileSystem([
            ("/x", .directory()), ("/x/a.txt", .file(size: 3)), ("/d", .directory()), ("/d/a.txt", .file(size: 7)),
        ])
        fileSystem.enableTrash()
        var report = try buildCopyPasteAnalysisReport(
            analysisId: "analysis-1",
            request: CopyPasteAnalysisRequest(
                mode: .copy, sourcePaths: ["/x/a.txt", "/d/a.txt"], destinationDirectoryPath: "/d"),
            fileSystem: fileSystem,
            thresholds: CopyPasteThresholds(largeBatchItemThreshold: 100, largeBatchByteThreshold: 1000))
        // A plan made without the review's note (or a runtime answer of Replace).
        for index in report.nodes.indices {
            report.nodes[index].replaceBlockedReason = nil
        }
        let resolvedNodes = try resolveAnalysisWithPolicy(
            report: report, policy: NativePaste.replaceAll, fileSystem: fileSystem)

        let events = await execute(
            fileSystem, (report, resolvedNodes), operationId: "op-1", policy: NativePaste.replaceAll)

        let result = try #require(events.last?.result)
        #expect(fileSystem.trashed == [])
        #expect(fileSystem.readNode("/d/a.txt")?.size == 7)
        let refused = itemFor(result, "/x/a.txt")
        #expect(refused?.status == .failed)
        #expect(refused?.error == "Can't replace \u{201C}a.txt\u{201D} because it is another item being pasted.")
    }
}
