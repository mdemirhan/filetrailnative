// Timing checks that hold up when the machine is busy: they count the CPU time the work used, not the wall
// time it took, so a test is not failed by waiting for a turn behind other builds.
import Darwin

public enum CPUTime {
    /// The CPU time the calling thread has used, in seconds. For work that runs without suspending.
    public static func thread() -> Double { read(CLOCK_THREAD_CPUTIME_ID) }

    /// The CPU time all threads of the process have used, in seconds. For work that may hop between threads;
    /// tests running alongside add to it, so bound it loosely.
    public static func process() -> Double { read(CLOCK_PROCESS_CPUTIME_ID) }

    /// The CPU seconds `work` used on this thread.
    public static func measureThread<T>(_ work: () throws -> T) rethrows -> (value: T, seconds: Double) {
        let start = thread()
        let value = try work()
        return (value, thread() - start)
    }

    /// The CPU seconds the process used while `work` ran.
    public static func measureProcess<T>(_ work: () async throws -> T) async rethrows -> (value: T, seconds: Double) {
        let start = process()
        let value = try await work()
        return (value, process() - start)
    }

    private static func read(_ clock: clockid_t) -> Double {
        var spec = timespec()
        guard clock_gettime(clock, &spec) == 0 else { return 0 }
        return Double(spec.tv_sec) + Double(spec.tv_nsec) / 1e9
    }
}
