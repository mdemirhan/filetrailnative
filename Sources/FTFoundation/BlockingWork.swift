import Foundation
import os

/// Work that can block for long, run off the caller: reading a file on a disk that stopped answering (a network share,
/// a USB drive), or the system's clipboard while the app that copied makes what it promised. It runs on a global
/// dispatch queue, which starts more threads while some are blocked, rather than in Swift's shared pool, whose few
/// threads every task waits on: a blocked one stays blocked until the disk gives up, even once its result is no longer
/// wanted.
///
/// The queues' threads are many but not endless: macOS gives an app some 64 to 80 of them, shared by every priority
/// and by everything else the app puts on a dispatch queue, an eject and the file operations among them. So only so
/// many pieces of work run at once here (`limit`), the rest waiting their turn without a thread: a disk that never
/// answers keeps at most that many threads, and what waits behind it is more of the same, not the rest of the app.
/// What may wait behind the rest (`.utility`: the details and tags of the rows on screen) has a smaller share of its
/// own, so that a folder of thousands on such a disk can't keep a listing or a clipboard read from starting. The work
/// is handed over once, whole, so a long walk pays one hop.
public enum BlockingWork {
    /// `qos` is the priority the work runs at: `.utility` for what may wait behind the rest.
    public static func run<T: Sendable, Failure: Error>(
        qos: DispatchQoS.QoSClass = .userInitiated, _ work: @escaping @Sendable () throws(Failure) -> T
    ) async throws(Failure) -> T {
        let lane = lane(for: qos)
        let result: Result<T, Failure> = await withCheckedContinuation { continuation in
            lane.run(qos: qos) {
                continuation.resume(returning: Result { () throws(Failure) -> T in try work() })
            }
        }
        return try result.get()
    }

    /// How many pieces of work of the priority run at once.
    public static func limit(for qos: DispatchQoS.QoSClass) -> Int { lane(for: qos).limit }

    /// Those asked for now run at once up to the cores and a few more, or 32; those that may wait, 16.
    private static let now = Lane(limit: max(32, ProcessInfo.processInfo.activeProcessorCount + 8))
    private static let later = Lane(limit: 16)

    private static func lane(for qos: DispatchQoS.QoSClass) -> Lane {
        switch qos {
        case .userInteractive, .userInitiated: now
        default: later
        }
    }

    /// Runs up to `limit` pieces of work at once, each on a thread of a global queue; the others wait in the order
    /// they came, holding no thread.
    private final class Lane: Sendable {
        let limit: Int
        private struct State {
            var running = 0
            var waiting: [(qos: DispatchQoS.QoSClass, work: @Sendable () -> Void)] = []
            var next = 0
        }
        private let state = OSAllocatedUnfairLock(initialState: State())

        init(limit: Int) {
            self.limit = limit
        }

        func run(qos: DispatchQoS.QoSClass, _ work: @escaping @Sendable () -> Void) {
            let starts = state.withLock { state -> Bool in
                if state.running < limit {
                    state.running += 1
                    return true
                }
                state.waiting.append((qos, work))
                return false
            }
            if starts { start(qos: qos, work) }
        }

        private func start(qos: DispatchQoS.QoSClass, _ work: @escaping @Sendable () -> Void) {
            DispatchQueue.global(qos: qos).async {
                work()
                self.finished()
            }
        }

        /// One ended: the first of those waiting takes its place.
        private func finished() {
            let next = state.withLock { state -> (qos: DispatchQoS.QoSClass, work: @Sendable () -> Void)? in
                guard state.next < state.waiting.count else {
                    state.running -= 1
                    state.waiting.removeAll(keepingCapacity: false)
                    state.next = 0
                    return nil
                }
                let next = state.waiting[state.next]
                state.next += 1
                // The ones that left are let go of once they are half of what is kept.
                if state.next > 64, state.next * 2 > state.waiting.count {
                    state.waiting.removeFirst(state.next)
                    state.next = 0
                }
                return next
            }
            if let next { start(qos: next.qos, next.work) }
        }
    }
}
