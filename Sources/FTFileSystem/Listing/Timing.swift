// Port of withTiming (apps/desktop/src/main/bootstrap/responseCache.ts)
import Foundation

/// Runs `load` and reports it through `log` when it took long: slow-path logging is enough for production
/// debugging without flooding the log.
public func withTiming<T>(
    _ label: String, path: String, slowMilliseconds: Double = 120, always: Bool = false,
    now: () -> Double = { ProcessInfo.processInfo.systemUptime * 1000 }, log: (String) -> Void,
    load: () async throws -> T
) async rethrows -> T {
    let start = now()
    let value = try await load()
    let elapsed = now() - start
    if always || elapsed >= slowMilliseconds {
        log("[filetrail] \(label) \(path) \(Int(elapsed.rounded()))ms")
    }
    return value
}
