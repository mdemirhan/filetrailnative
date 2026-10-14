// Port of packages/core/src/fs/stoppableCopy.ts
import Dispatch
import Foundation
import os

// The native copy (copyfile(3)) checks a stop flag between chunks, so Stop takes effect part way through a large
// file instead of once it has been copied in full. It also counts the bytes copied so far next to the flag, so a
// large file shows progress as it goes.

/// Calls `tick` every `interval` until cancelled; cancelling waits for a tick under way, so none runs after.
public protocol ProgressTicker: Sendable {
    func start(every interval: Duration, _ tick: @escaping @Sendable () -> Void) -> any ProgressTicking
}

public protocol ProgressTicking: Sendable {
    func cancel()
}

/// Ticks on a dispatch timer of its own.
public struct DispatchProgressTicker: ProgressTicker {
    public init() {}

    public func start(every interval: Duration, _ tick: @escaping @Sendable () -> Void) -> any ProgressTicking {
        let queue = DispatchQueue(label: "filetrail.copy-progress", qos: .utility)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let nanoseconds = Int((interval / .nanoseconds(1)).rounded())
        timer.schedule(deadline: .now() + .nanoseconds(nanoseconds), repeating: .nanoseconds(nanoseconds))
        timer.setEventHandler(handler: tick)
        timer.resume()
        return Ticking(timer: timer, queue: queue)
    }

    private final class Ticking: ProgressTicking, @unchecked Sendable {
        // Only cancelled, which DispatchSource allows from any thread.
        let timer: any DispatchSourceTimer
        let queue: DispatchQueue

        init(timer: any DispatchSourceTimer, queue: DispatchQueue) {
            self.timer = timer
            self.queue = queue
        }

        func cancel() {
            timer.cancel()
            // A tick already running finishes before this returns.
            queue.sync {}
        }
    }
}

/// `createStoppableCopyFile`: the native copy, stopped by a `StopSignal`, with its progress.
public struct StoppableCopy: Sendable {
    /// The native copy: `NativeFS.copyFile`, given a control when the copy can be stopped or reports progress.
    public typealias NativeCopy = @Sendable (_ source: String, _ destination: String, _ control: CopyControl?) throws
        -> Void

    /// How often the bytes copied so far are read while a file is being copied (`COPY_PROGRESS_INTERVAL_MS`).
    public static let progressInterval: Duration = .milliseconds(250)

    private let copy: NativeCopy
    private let ticker: any ProgressTicker

    public init(
        copy: @escaping NativeCopy = { try NativeFS.copyFile($0, $1, control: $2) },
        ticker: any ProgressTicker = DispatchProgressTicker()
    ) {
        self.copy = copy
        self.ticker = ticker
    }

    /// Copies `source` to `destination` on this thread (never the main thread: a large file takes a while).
    /// A stopped copy throws `StopError` and leaves no partial file. `onProgress` is told the bytes of the file
    /// copied so far, at most every `progressInterval` and only when it grew, and never after this returns.
    public func copyFile(
        _ source: String, to destination: String, stop: StopSignal? = nil,
        onProgress: (@Sendable (Int64) -> Void)? = nil
    ) throws {
        if stop == nil && onProgress == nil {
            try copy(source, destination, nil)
            return
        }
        try stop?.throwIfStopped()
        let control = CopyControl()
        let token = stop?.onStop { control.stop() }
        let ticking = onProgress.map { onProgress in
            let reported = OSAllocatedUnfairLock(initialState: Int64(0))
            return ticker.start(every: Self.progressInterval) {
                let bytes = control.copiedBytes
                let grew = reported.withLock { reported in
                    guard bytes > reported else { return false }
                    reported = bytes
                    return true
                }
                if grew {
                    onProgress(bytes)
                }
            }
        }
        defer {
            ticking?.cancel()
            stop?.removeHandler(token)
        }
        do {
            try copy(source, destination, control)
        } catch {
            if stop?.isStopped == true && errorCode(error) == "ECANCELED" {
                throw StopError()
            }
            throw error
        }
    }
}
