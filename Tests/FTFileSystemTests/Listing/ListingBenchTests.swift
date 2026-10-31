import Foundation
import Testing

// Listing budgets (tools/bench/budgets.json, ) on fixtures/bench: 3,000 items read and sorted in 25 ms or
// less, 100,000 in 400 ms or less. Run by tools/bench/listing.sh in a release build; skipped otherwise, as a
// debug build says nothing about speed.
@testable import FTFileSystem

struct ListingBenchTests {
    static var enabled: Bool { ProcessInfo.processInfo.environment["FILETRAIL_BENCH"] == "1" }

    struct Measurement: Codable {
        var folder: String
        var items: Int
        var medianMs: Double
        var bestMs: Double
        var budgetMs: Double
        /// Of the median, what reading the folder took.
        var readMs: Double
    }

    private func measure(folder: String, budgetMs: Double, runs: Int) async throws -> Measurement {
        let path = Fixtures.root + "/bench/" + folder
        var times: [Double] = []
        var items = 0
        // The first read warms the disk cache, as the window opening the folder after the sidebar did.
        for run in 0...runs {
            // A service of its own each time: nothing is cached.
            let service = DirectoryService(cache: ResponseCache(), kinds: KindLabeler(describer: nil))
            let start = ContinuousClock.now
            let snapshot = try await service.snapshot(path: path)
            let elapsed = start.duration(to: .now)
            items = snapshot.entries.count
            if run > 0 {
                times.append(Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15)
            }
        }
        times.sort()
        var reads: [Double] = []
        for _ in 0..<5 {
            let start = ContinuousClock.now
            _ = try NativeFileSystem().readDirectory(path)
            let elapsed = start.duration(to: .now)
            reads.append(Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15)
        }
        reads.sort()
        return Measurement(
            folder: folder, items: items, medianMs: times[times.count / 2], bestMs: times[0], budgetMs: budgetMs,
            readMs: reads[reads.count / 2])
    }

    @Test("listing read and sorted within budget", .enabled(if: enabled && Fixtures.available))
    func listingIsWithinBudget() async throws {
        let results = [
            try await measure(folder: "files-3000", budgetMs: 25, runs: 15),
            try await measure(folder: "files-100000", budgetMs: 400, runs: 7),
        ]
        for result in results {
            let data = try JSONEncoder().encode(result)
            print("BENCH " + String(decoding: data, as: UTF8.self))
        }
        #expect(results[0].items == 3_000)
        #expect(results[1].items == 100_000)
        #if !DEBUG
            for result in results {
                #expect(
                    result.medianMs <= result.budgetMs, "\(result.folder): \(result.medianMs) ms of \(result.budgetMs)")
            }
        #endif
    }
}
