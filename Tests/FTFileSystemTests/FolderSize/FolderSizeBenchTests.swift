// Times the walker on the deep fixture tree (200,000 files): no slower than the reference's native walker, within 10%.
import Foundation
import Testing

@testable import FTFileSystem

private let deepTree: String = {
    let cache =
        ProcessInfo.processInfo.environment["FILETRAIL_PORT_CACHE"]
        ?? NSHomeDirectory() + "/Library/Caches/filetrail-port"
    return cache + "/fixtures/bench/deep"
}()

/// Off by default: it takes a few seconds and only means something in a release build:
///   FILETRAIL_BENCH=1 [FILETRAIL_BENCH_REFERENCE_MS=<reference median>] swift test -c release -Xswiftc -enable-testing --filter FolderSizeBench
/// The reference is timed the same way with the addon (`nativeFolderSize` on the same folder, median of the warm runs).
extension RealWalks {
    @MainActor @Suite struct FolderSizeBenchTests {
        // F-179
        @Test(
            .enabled(
                if: ProcessInfo.processInfo.environment["FILETRAIL_BENCH"] == "1"
                    && FileManager.default.fileExists(atPath: deepTree),
                "needs FILETRAIL_BENCH=1 and the deep fixture tree"
            ))
        func walksTheDeepTreeNoSlowerThanTheReference() async throws {
            let native = NativeFolderSize()
            var milliseconds: [Double] = []
            var files = 0
            for run in 0..<12 {
                let started = ContinuousClock.now
                let walk = try await measure(native, deepTree)
                let elapsed = ContinuousClock.now - started
                milliseconds.append(
                    Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15)
                if run == 0 { files = walk.result.fileCount }
            }
            #expect(files == 200_000)
            let warm = milliseconds.dropFirst(2).sorted()
            let median = warm[warm.count / 2]
            print(
                "BENCH port ms:", milliseconds.map { Int($0.rounded()) }, "median", Int(median.rounded()), "min",
                Int((warm.first ?? 0).rounded()))
            if let reference = ProcessInfo.processInfo.environment["FILETRAIL_BENCH_REFERENCE_MS"].flatMap(Double.init)
            {
                #expect(median <= reference * 1.10, "median \(median) ms against the reference's \(reference) ms")
            }
        }
    }
}
