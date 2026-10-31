// Port of packages/core/src/fs/copyPasteExecution.ts (createOperationResult's top-level count)
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTOperations

struct ReviewTopLevelCountPerfTests {
    @Test func resultForManySameLengthPickedItemsIsLinear() async throws {
        try await withTemporaryDirectory(prefix: "toplevel") { root in
            try Disk.write(root.path + "/src/IMG_00000.JPG", "x")
            try Disk.makeDirectories(root.path + "/dst")
            let fileSystem = NativeWriteFileSystem()
            var (report, _) = try realOperation(
                fileSystem, mode: .copy, sources: [root.path + "/src/IMG_00000.JPG"], into: root.path + "/dst")
            let template = report.nodes[0]
            let count = 4_000
            let paths = (0..<count).map { i -> String in
                let d = String(i)
                return root.path + "/src/IMG_" + String(repeating: "0", count: 5 - d.count) + d + ".JPG"
            }
            report.nodes = paths.map {
                var n = template
                n.sourcePath = $0
                return n
            }
            let items = paths.map {
                CopyPasteItemResult(
                    sourcePath: $0, destinationPath: $0, sourceKind: .file, status: .completed, error: nil)
            }
            // CPU time of this thread, not wall time, so a busy machine does not fail it.
            let (result, seconds) = CPUTime.measureThread {
                createOperationResult(
                    operationId: "op", report: report, mode: .copy, startedAt: Date(), finishedAt: Date(),
                    completedByteCount: 0, totalBytes: 0, items: items, status: .completed, error: nil)
            }
            print("createOperationResult \(count) same-length picked items: \(seconds) s")
            #expect(result.summary.topLevelItemCount == count)
            #expect(seconds < 1)
        }
    }
}
