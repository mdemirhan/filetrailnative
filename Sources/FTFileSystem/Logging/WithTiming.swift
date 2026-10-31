// Port of withTiming of apps/desktop/src/main/bootstrap/responseCache.ts
import Foundation

public enum Timing {
    /// A call this slow is logged even without `FILETRAIL_DEBUG_TIMINGS`.
    public static let slowThresholdMilliseconds = 120.0

    /// `debugTimingsEnabled`: `FILETRAIL_DEBUG_TIMINGS` is `1`.
    public static func timingsEnabled(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environment["FILETRAIL_DEBUG_TIMINGS"] == "1"
    }

    /// `[filetrail] <label> <path> <ms>ms`, the milliseconds rounded as `Math.round` does.
    public static func line(label: String, path: String, elapsedMilliseconds: Double) -> String {
        "[filetrail] \(label) \(path) \(Int((elapsedMilliseconds + 0.5).rounded(.down)))ms"
    }
}

/// Runs `load` and logs how long it took at debug level: when it took 120 ms or more, or always with the timings flag.
/// Slow-path logging is enough for production debugging without flooding the log.
public func withTiming<T>(
    _ label: String, _ path: String, logger: AppLogger, timingsEnabled: Bool = Timing.timingsEnabled(),
    clock: @Sendable () -> Double = { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000 },
    _ load: () async throws -> T
) async rethrows -> T {
    let start = clock()
    let value = try await load()
    let elapsed = clock() - start
    if timingsEnabled || elapsed >= Timing.slowThresholdMilliseconds {
        logger.debug(.text(Timing.line(label: label, path: path, elapsedMilliseconds: elapsed)))
    }
    return value
}
