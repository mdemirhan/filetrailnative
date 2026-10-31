import Foundation
import Testing

@testable import FTFileSystem

// first_search_results_ms (tools/bench/budgets.json, budget 150 ms): the time from starting a recursive
// name search of the Home folder with the bundled fd to the first results being polled, as the search bar
// does. Run by tools/bench/listing.sh in a release build; skipped otherwise. It opens no window.
struct SearchBenchTests {
    static var enabled: Bool { ProcessInfo.processInfo.environment["FILETRAIL_BENCH"] == "1" }

    private func firstResultsMs(_ runtime: FdSearchRuntime, root: String) throws -> Double {
        let start = ContinuousClock.now
        let started = runtime.startSearch(SearchRequest(rootPath: root, query: "a"))
        defer { runtime.cancelSearch(jobId: started.jobId) }
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            let update = try runtime.getUpdate(jobId: started.jobId, cursor: 0)
            if !update.items.isEmpty || update.done {
                let elapsed = start.duration(to: .now)
                return Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
            }
            Thread.sleep(forTimeInterval: 0.001)
        }
        throw CocoaError(.fileReadUnknown)
    }

    @Test("first search results within budget", .enabled(if: enabled && FdBinary.currentArchitecture == "arm64"))
    func firstResultsAreWithinBudget() throws {
        let runtime = FdSearchRuntime(fdBinaryPath: try FdBinary.resolveBundledPath())
        defer { runtime.close() }
        let home = NSHomeDirectory()
        // The first search warms the disk cache, as a search after the window opened would find it.
        _ = try firstResultsMs(runtime, root: home)
        var times: [Double] = []
        for _ in 0..<7 { times.append(try firstResultsMs(runtime, root: home)) }
        times.sort()
        let median = times[times.count / 2]
        print("BENCH {\"metric\":\"first_search_results_ms\",\"medianMs\":\(median),\"bestMs\":\(times[0])}")
        #if !DEBUG
            #expect(median <= 150, "first results after \(median) ms of 150")
        #endif
    }
}
