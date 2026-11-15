import FTTestSupport
import Foundation
import Testing
import os

@testable import FTFileSystem

@Suite struct DecodeGateTests {
    /// Work the test lets go of by hand, counting how many pieces run at once.
    private final class Held: Sendable {
        private struct State {
            var running = 0
            var most = 0
            var begun = 0
        }
        private let state = OSAllocatedUnfairLock(initialState: State())
        private let go = DispatchSemaphore(value: 0)

        var running: Int { state.withLock { $0.running } }
        var most: Int { state.withLock { $0.most } }
        var begun: Int { state.withLock { $0.begun } }

        func work() -> Int? {
            state.withLock {
                $0.running += 1
                $0.begun += 1
                $0.most = max($0.most, $0.running)
            }
            go.wait()
            state.withLock { $0.running -= 1 }
            return 1
        }

        func release(_ count: Int) {
            for _ in 0..<count { go.signal() }
        }
    }

    @Test func onlySoManyRunAtOnce() async {
        let gate = DecodeGate(limit: 2)
        let held = Held()
        let tasks = (0..<6).map { _ in Task { await gate.run { held.work() } } }
        await pollUntil { held.running == 2 && gate.waitingCount == 4 }
        held.release(6)
        var done = 0
        for task in tasks { done += await task.value ?? 0 }
        #expect(done == 6)
        #expect(held.most == 2)
    }

    // A picture scrolled past while it waits its turn is never decoded, and no longer holds up those behind it.
    @Test func oneNoLongerWantedLeavesTheLineWithoutRunning() async {
        let gate = DecodeGate(limit: 1)
        let held = Held()
        let first = Task { await gate.run { held.work() } }
        await pollUntil { held.running == 1 }
        let passed = Task { await gate.run { held.work() } }
        await pollUntil { gate.waitingCount == 1 }
        passed.cancel()
        #expect(await passed.value == nil)
        #expect(gate.waitingCount == 0)
        let wanted = Task { await gate.run { held.work() } }
        await pollUntil { gate.waitingCount == 1 }
        held.release(2)
        #expect(await first.value == 1)
        #expect(await wanted.value == 1)
        #expect(held.begun == 2)
    }

    @Test func oneCancelledBeforeItAsksDoesNotRun() async {
        let gate = DecodeGate(limit: 1)
        let held = Held()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await gate.run { held.work() }
        }
        #expect(await task.value == nil)
        #expect(held.begun == 0)
    }
}
