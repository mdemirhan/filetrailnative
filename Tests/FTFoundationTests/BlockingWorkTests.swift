// Work that blocks runs out of Swift's shared pool: more of it than the pool has threads, all blocked at once, leave
// the pool free for every other task; and only so much of it runs at once, so that it can't take every thread macOS
// gives the app's dispatch queues either
import Foundation
import Testing
import os

@testable import FTFoundation

struct BlockingWorkTests {
    /// Waits until `condition`, 20 s at most: false when it never came.
    private func reached(_ condition: @Sendable () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(20)
        while !condition() {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    @Test func blockedWorkLeavesSwiftsThreadsFree() async {
        // More than the pool's threads, one for each core.
        let count = ProcessInfo.processInfo.activeProcessorCount + 4
        let started = OSAllocatedUnfairLock(initialState: 0)
        let release = DispatchSemaphore(value: 0)
        let blocked = Task {
            await withTaskGroup(of: Int.self) { group in
                for index in 0..<count {
                    group.addTask {
                        await BlockingWork.run {
                            started.withLock { $0 += 1 }
                            release.wait()
                            return index
                        }
                    }
                }
                return await group.reduce(0, +)
            }
        }
        let all = await reached { started.withLock { $0 } == count }
        #expect(all)
        // Every one is blocked, as on a disk that stopped answering, and a task of the pool still runs.
        #expect(await Task.detached { 42 }.value == 42)
        for _ in 0..<count { release.signal() }
        #expect(await blocked.value == (0..<count).reduce(0, +))
    }

    // A folder of thousands on a disk that stopped answering asks for the details of its rows over and over, each
    // read never coming back. Only so many hold a thread; the rest wait without one, so that the threads macOS gives
    // the app's dispatch queues (some 64 to 80, for every priority together) are still there for an eject, a file
    // operation or a read asked for now, which is not behind them.
    @Test func workThatMayWaitNeverTakesTheThreadsTheRestOfTheAppNeeds() async {
        let count = 300
        let limit = BlockingWork.limit(for: .utility)
        #expect(limit < 64)
        let started = OSAllocatedUnfairLock(initialState: 0)
        let ended = OSAllocatedUnfairLock(initialState: 0)
        let release = DispatchSemaphore(value: 0)
        for _ in 0..<count {
            Task {
                await BlockingWork.run(qos: .utility) {
                    started.withLock { $0 += 1 }
                    release.wait()
                    ended.withLock { $0 += 1 }
                }
            }
        }
        let full = await reached { started.withLock { $0 } == limit }
        #expect(full)
        try? await Task.sleep(for: .milliseconds(200))
        // No more than the limit run, however many were asked for.
        #expect(started.withLock { $0 } == limit)

        // What the app puts on a dispatch queue itself still starts: an eject, a file operation.
        let onAQueue = OSAllocatedUnfairLock(initialState: false)
        DispatchQueue.global(qos: .userInitiated).async { onAQueue.withLock { $0 = true } }
        let ran = await reached { onAQueue.withLock { $0 } }
        #expect(ran)
        // And so does a read asked for now.
        #expect(await BlockingWork.run { 7 } == 7)

        // Let go, every one of them runs, in turn.
        for _ in 0..<count { release.signal() }
        let all = await reached { ended.withLock { $0 } == count }
        #expect(all)
    }

    // What is thrown comes back to the caller as it was thrown.
    @Test func whatTheWorkThrowsIsThrownToTheCaller() async {
        struct Refused: Error, Equatable {}
        await #expect(throws: Refused.self) {
            try await BlockingWork.run { () throws(Refused) -> Int in throw Refused() }
        }
        #expect(await BlockingWork.run(qos: .utility) { 3 } == 3)
    }
}
