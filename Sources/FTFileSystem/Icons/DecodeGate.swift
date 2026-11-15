import FTFoundation
import Foundation
import os

/// Lets a few pictures be decoded at once, the rest waiting in line without a thread.
///
/// Decoding a very large picture takes hundreds of megabytes and every core for a while, and can't be stopped once
/// begun. One scrolled past is told to stop, and its place in the load queue goes to the next after a moment whether
/// it has or not: without the gate, a folder of such pictures scrolled through fast had as many decodes going as
/// places were given up. One no longer wanted when its turn comes, or while it waits, is not begun at all.
final class DecodeGate: Sendable {
    private struct State {
        var free: Int
        var nextID = 0
        var waiting: [(id: Int, go: CheckedContinuation<Bool, Never>)] = []
    }

    private let state: OSAllocatedUnfairLock<State>

    init(limit: Int) {
        state = OSAllocatedUnfairLock(initialState: State(free: limit))
    }

    /// How many wait in line, for a test.
    var waitingCount: Int { state.withLock { $0.waiting.count } }

    /// Runs `work` off the caller once it is its turn; nil, without running it, when the task is cancelled by then.
    func run<T: Sendable>(_ work: @escaping @Sendable () -> T?) async -> T? {
        guard await enter() else { return nil }
        let result = await BlockingWork.run { work() }
        leave()
        return result
    }

    private func enter() async -> Bool {
        let id = state.withLock { state -> Int in
            state.nextID += 1
            return state.nextID
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let cancelled = Task.isCancelled
                let answer: Bool? = state.withLock { state in
                    if cancelled { return false }
                    if state.free > 0 {
                        state.free -= 1
                        return true
                    }
                    state.waiting.append((id, continuation))
                    return nil
                }
                if let answer { continuation.resume(returning: answer) }
            }
        } onCancel: {
            let waiter = state.withLock { state -> CheckedContinuation<Bool, Never>? in
                guard let index = state.waiting.firstIndex(where: { $0.id == id }) else { return nil }
                return state.waiting.remove(at: index).go
            }
            waiter?.resume(returning: false)
        }
    }

    private func leave() {
        let next = state.withLock { state -> CheckedContinuation<Bool, Never>? in
            if state.waiting.isEmpty {
                state.free += 1
                return nil
            }
            return state.waiting.removeFirst().go
        }
        next?.resume(returning: true)
    }
}
