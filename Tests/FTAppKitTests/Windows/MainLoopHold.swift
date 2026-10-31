import AppKit
import Testing

/// Keeps a test process alive through a stop of the main run loop. The entry point `swift test` builds ends in the
/// runtime's `CFRunLoopRun(); exit(0)`, and AppKit stops the main loop whenever an event is posted (`-[NSEvent
/// _postAtStart:]`, which a system menu does as it closes): the process would end there with status 0, no test failed
/// and no summary, and the rest of the run never happens. So the tests run in a loop of ours inside that one, which a
/// stop only sends round again. The process still ends as it should: the entry point calls `exit` when the tests finish.
@MainActor
enum MainLoopHold {
    private static var started: Task<Void, Never>?

    /// Returns once the loop runs. The run loop runs the blocks it has at one time in order, and this one never ends: a
    /// block asked for before it had started would wait behind it for good.
    static func begin() async {
        let start =
            started
            ?? Task {
                await withCheckedContinuation { (running: CheckedContinuation<Void, Never>) in
                    // Not from this task: inside a block of the main queue, the nested loop wouldn't run the main queue.
                    RunLoop.main.perform(inModes: [.common]) {
                        running.resume()
                        while true { _ = CFRunLoopRunInMode(.defaultMode, 1_000_000, false) }
                    }
                }
            }
        started = start
        await start.value
    }
}

struct MainLoopHoldTrait: TestTrait, SuiteTrait, TestScoping {
    var isRecursive: Bool { true }

    func scopeProvider(for test: Test, testCase: Test.Case?) -> Self? {
        test.isSuite || testCase == nil ? nil : self
    }

    func provideScope(
        for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void
    ) async throws {
        await MainLoopHold.begin()
        try await function()
    }
}

extension Trait where Self == MainLoopHoldTrait {
    /// For a test that shows a window or a menu, or posts an event: a stop of the main loop doesn't end the process.
    static var holdsMainLoop: Self { MainLoopHoldTrait() }
}

@MainActor
@Suite(.holdsMainLoop)
struct MainLoopHoldTests {
    // A process without the hold ends here with status 0: this test never finishes, and the summary never comes.
    // The first test held would otherwise lose what it asks of the run loop at once: a batch of blocks runs in order, and
    // the hold's block in it never ends. A system menu of that test never came up.
    @Test func aBlockAskedOfTheRunLoopAfterTheHoldRuns() async {
        var ran = false
        RunLoop.main.perform(inModes: [.common]) { MainActor.assumeIsolated { ran = true } }
        #expect(await waitUntil { ran })
    }

    @Test func aPostedEventLeavesTheProcessRunning() async throws {
        _ = NSApplication.shared
        let event = try #require(
            NSEvent.otherEvent(
                with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                context: nil, subtype: 0, data1: 0, data2: 0))
        NSApp.postEvent(event, atStart: true)
        try await Task.sleep(for: .milliseconds(100))
        NSApp.discardEvents(matching: .applicationDefined, before: nil)
    }
}
