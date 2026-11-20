// A time limit on work done on the calling thread, counted in the thread's own CPU time
import Darwin
import Dispatch

/// How long work on this thread may go on, counted in the CPU time the thread uses: time spent waiting for a core
/// behind other work, or asleep, doesn't count. A wall-clock limit is spent by a busy Mac alone, so a pattern any name
/// is through with in microseconds would be taken for one that never ends.
struct ThreadTimeBudget {
    private let end: UInt64

    /// A budget of `interval` from now, on the calling thread; read it on that thread only.
    init(_ interval: DispatchTimeInterval) {
        self.init(nanoseconds: Self.nanoseconds(interval), from: Self.now())
    }

    /// A budget of `nanoseconds` from `start`, a reading of `now()` on the calling thread.
    init(nanoseconds: UInt64, from start: UInt64) {
        let (sum, overflow) = start.addingReportingOverflow(nanoseconds)
        end = overflow ? .max : sum
    }

    /// The thread has used more than the budget since it was made.
    var isSpent: Bool { Self.now() > end }

    /// The CPU time the calling thread has used, in nanoseconds.
    static func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) }

    static func nanoseconds(_ interval: DispatchTimeInterval) -> UInt64 {
        switch interval {
        case .seconds(let value): UInt64(max(value, 0)) * 1_000_000_000
        case .milliseconds(let value): UInt64(max(value, 0)) * 1_000_000
        case .microseconds(let value): UInt64(max(value, 0)) * 1_000
        case .nanoseconds(let value): UInt64(max(value, 0))
        case .never: .max
        @unknown default: .max
        }
    }
}
