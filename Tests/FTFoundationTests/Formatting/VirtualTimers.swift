// A clock and timers that only move when a test says so (the original's tests use vitest's fake timers).
import Foundation

@testable import FTFoundation

@MainActor
final class VirtualTimers: TimerScheduling {
    // Cancelling comes from a token that is not on the main actor, so the table has its own lock.
    private final class Table: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [Int: (fireAt: Date, delay: TimeInterval, action: @MainActor () -> Void)] = [:]
        private var nextID = 0

        func add(fireAt: Date, delay: TimeInterval, action: @escaping @MainActor () -> Void) -> Int {
            lock.withLock {
                nextID += 1
                entries[nextID] = (fireAt, delay, action)
                return nextID
            }
        }

        func remove(_ id: Int) {
            lock.withLock { _ = entries.removeValue(forKey: id) }
        }

        /// The next timer due by `limit`, taken out of the table.
        func popDue(by limit: Date) -> (fireAt: Date, action: @MainActor () -> Void)? {
            lock.withLock {
                guard let next = entries.min(by: { $0.value.fireAt < $1.value.fireAt }), next.value.fireAt <= limit
                else {
                    return nil
                }
                entries.removeValue(forKey: next.key)
                return (next.value.fireAt, next.value.action)
            }
        }

        var delays: [TimeInterval] {
            lock.withLock { entries.values.map(\.delay).sorted() }
        }
    }

    private let table = Table()
    private(set) var now: Date

    init(start: Date) {
        now = start
    }

    /// How many timers are waiting.
    var count: Int { table.delays.count }

    /// The delays the waiting timers were asked for, in seconds.
    var pendingDelays: [TimeInterval] { table.delays }

    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> TimerToken {
        let id = table.add(fireAt: now.addingTimeInterval(delay), delay: delay, action: action)
        let table = table
        return TimerToken { table.remove(id) }
    }

    /// Moves time on, running the timers that fall due on the way, in order.
    func advance(by seconds: TimeInterval) {
        let target = now.addingTimeInterval(seconds)
        while let due = table.popDue(by: target) {
            now = due.fireAt
            due.action()
        }
        now = target
    }
}
