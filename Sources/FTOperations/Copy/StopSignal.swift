// The AbortSignal and AbortError the original's engine stops with (packages/core/src/fs/stoppableCopy.ts and its callers)
import Foundation
import os

/// Stops an operation from any thread: what the original's `AbortController` signal does.
public final class StopSignal: Sendable {
    private struct State {
        var stopped = false
        var nextHandler = 0
        var handlers: [Int: @Sendable () -> Void] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {}

    public var isStopped: Bool { state.withLock { $0.stopped } }

    /// Stops: runs each handler once, on this thread. Stopping again does nothing.
    public func stop() {
        let handlers = state.withLock { state -> [@Sendable () -> Void] in
            guard !state.stopped else { return [] }
            state.stopped = true
            let handlers = state.handlers.sorted { $0.key < $1.key }.map(\.value)
            state.handlers = [:]
            return handlers
        }
        for handler in handlers {
            handler()
        }
    }

    /// `throwIfAborted()`.
    public func throwIfStopped() throws {
        if isStopped {
            throw StopError()
        }
    }

    /// Runs `handler` once when the signal stops (`addEventListener("abort", …, { once: true })`). Returns a token
    /// for `removeHandler`, or nil when already stopped (the handler then doesn't run).
    @discardableResult
    public func onStop(_ handler: @escaping @Sendable () -> Void) -> Int? {
        state.withLock { state in
            guard !state.stopped else { return nil }
            let token = state.nextHandler
            state.nextHandler += 1
            state.handlers[token] = handler
            return token
        }
    }

    public func removeHandler(_ token: Int?) {
        guard let token else { return }
        _ = state.withLock { $0.handlers.removeValue(forKey: token) }
    }
}

/// What a stopped operation throws: the signal's `AbortError` ("This operation was aborted"), which has no
/// string `code`.
public struct StopError: CodedError, Equatable, Sendable, CustomStringConvertible {
    public init() {}

    public var code: String? { nil }
    public var name: String { "AbortError" }
    public var message: String { "This operation was aborted" }
    public var description: String { message }
}
