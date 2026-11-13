// Timing checks that hold up when the machine is busy: they count the CPU time the work used, not the wall
// time it took, so a test is not failed by waiting for a turn behind other builds.
import Darwin
import Testing

public enum CPUTime {
    /// The CPU time the calling thread has used, in seconds. For work that runs without suspending.
    public static func thread() -> Double { read(CLOCK_THREAD_CPUTIME_ID) }

    /// The CPU seconds `work` used on this thread.
    public static func measureThread<T>(_ work: () throws -> T) rethrows -> (value: T, seconds: Double) {
        let start = thread()
        let value = try work()
        return (value, thread() - start)
    }

    /// A clock that can't be read fails the test, and gives NaN, which no bound is met by: 0 would meet every one.
    private static func read(_ clock: clockid_t) -> Double {
        var spec = timespec()
        guard clock_gettime(clock, &spec) == 0 else {
            Issue.record("the CPU clock \(clock) couldn't be read: errno \(errno)")
            return .nan
        }
        return Double(spec.tv_sec) + Double(spec.tv_nsec) / 1e9
    }
}
