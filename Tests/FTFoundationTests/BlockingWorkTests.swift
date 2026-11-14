// Work that blocks runs out of Swift's shared pool: more of it than the pool has threads, all blocked at once, leave
// the pool free for every other task
import Foundation
import Testing
import os

@testable import FTFoundation

struct BlockingWorkTests {
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
        while started.withLock({ $0 }) < count { await Task.yield() }
        // Every one is blocked, as on a disk that stopped answering, and a task of the pool still runs.
        #expect(await Task.detached { 42 }.value == 42)
        for _ in 0..<count { release.signal() }
        #expect(await blocked.value == (0..<count).reduce(0, +))
    }
}
