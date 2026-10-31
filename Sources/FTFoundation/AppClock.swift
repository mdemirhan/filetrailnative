// Port of the original's frozen clock for UI captures (Playwright `page.clock`); no TypeScript source.
import Foundation

/// The app's notion of "now". Normally the system clock. With `FILETRAIL_NOW=<ISO-8601 local time>`
/// in the environment, time starts at that instant when the app launches and runs on from there, so
/// that dates shown relative to today ("Today at 14:38") are the same in every capture.
public enum AppClock {
    public static var now: Date {
        guard let frozen = base.frozen else { return Date() }
        return frozen.addingTimeInterval(ProcessInfo.processInfo.systemUptime - base.uptime)
    }

    /// Whether `FILETRAIL_NOW` is set (and could be read).
    public static var isFrozen: Bool { base.frozen != nil }

    /// Fixes the start instant. Called at launch so that elapsed time counts from then.
    public static func start() { _ = base }

    private static let base: (frozen: Date?, uptime: TimeInterval) = (
        ProcessInfo.processInfo.environment["FILETRAIL_NOW"].flatMap { parse($0) },
        ProcessInfo.processInfo.systemUptime
    )

    /// Reads `2026-10-13T14:38:00` as local time; a time with a zone (`Z`, `+02:00`) keeps its zone.
    /// Fractional seconds and a missing seconds field are accepted.
    public static func parse(_ text: String, timeZone: TimeZone = .current) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let withZone = ISO8601DateFormatter()
        withZone.formatOptions = [.withInternetDateTime]
        if let date = withZone.date(from: trimmed) { return date }
        withZone.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withZone.date(from: trimmed) { return date }

        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.calendar = Calendar(identifier: .gregorian)
        local.timeZone = timeZone
        for format in ["yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd"] {
            local.dateFormat = format
            if let date = local.date(from: trimmed) { return date }
        }
        return nil
    }
}
