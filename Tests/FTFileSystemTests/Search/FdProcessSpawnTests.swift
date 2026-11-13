// An fd that can't be started: the search hears why, once, as an error, and nothing else
import Foundation
import Testing
import os

@testable import FTFileSystem

struct FdProcessSpawnTests {
    /// What a spawn reported, once it has said it couldn't start (or after 5 s).
    private func spawn(_ file: String, cwd: String) async -> (errors: [String], closes: Int, output: Int) {
        let told = OSAllocatedUnfairLock(initialState: (errors: [String](), closes: 0, output: 0))
        let events = SearchProcessEvents(
            onStdout: { _ in told.withLock { $0.output += 1 } }, onStderr: { _ in told.withLock { $0.output += 1 } },
            onError: { message in told.withLock { $0.errors.append(message) } },
            onClose: { _, _ in told.withLock { $0.closes += 1 } })
        _ = FdProcess.spawn(file, ["--version"], cwd, events)
        let deadline = ContinuousClock.now + .seconds(5)
        while told.withLock({ $0.errors.isEmpty }), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return told.withLock { $0 }
    }

    @Test func aProgramThatIsntThereIsAnError() async {
        let told = await spawn("/nonexistent/fd", cwd: NSTemporaryDirectory())
        #expect(told.errors == ["spawn /nonexistent/fd ENOENT"])
        #expect(told.closes == 0 && told.output == 0)
    }

    @Test func aFolderToSearchThatIsntThereIsAnError() async {
        let told = await spawn("/usr/bin/true", cwd: "/nonexistent-filetrail-folder")
        #expect(told.errors == ["spawn /usr/bin/true ENOENT"])
        #expect(told.closes == 0 && told.output == 0)
    }
}
