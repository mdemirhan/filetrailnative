// Port of apps/desktop/src/renderer/lib/formatting.ts (the date functions)
import Foundation

/// Dates as the original's lists and tooltips write them, in the system's time zone and the locale Chromium gives
/// `Intl.DateTimeFormat(undefined, …)`: the app's language alone, not the system's region (`InfoLocale.original`), so
/// the list, the Info Row and the Info panel agree. Tests pass their own.
///
/// The original runs on Chromium, whose English date patterns join a medium date and a time with a
/// comma and a plain space ("Oct 5, 2026, 4:45 PM") where macOS writes "at" and a narrow no-break
/// space, so those two are put back to Chromium's.
public final class DateText: @unchecked Sendable {
    public static let shared = DateText()

    // A clock a little ahead of this one still reads as now; further ahead gets the full date.
    private static let minute = 60_000.0
    private static let hour = 60 * minute
    private static let futureTolerance = minute

    /// The locale the dates are written in.
    public let locale: Locale
    private let calendar: Calendar
    private let time: DateFormatter
    private let weekday: DateFormatter
    private let day: DateFormatter
    private let dayYear: DateFormatter
    private let full: DateFormatter
    private let exact: DateFormatter
    private let short: DateFormatter

    public init(locale: Locale = InfoLocale.original, timeZone: TimeZone = .autoupdatingCurrent) {
        self.locale = locale
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.locale = locale
        self.calendar = calendar

        func make(template: String) -> DateFormatter {
            let pattern = DateFormatter.dateFormat(fromTemplate: template, options: 0, locale: locale) ?? template
            return Self.formatter(pattern: pattern, locale: locale, timeZone: timeZone, commaGlue: true)
        }
        func make(dateStyle: DateFormatter.Style, timeStyle: DateFormatter.Style, commaGlue: Bool) -> DateFormatter {
            let styled = DateFormatter()
            styled.locale = locale
            styled.dateStyle = dateStyle
            styled.timeStyle = timeStyle
            return Self.formatter(
                pattern: styled.dateFormat ?? "", locale: locale, timeZone: timeZone, commaGlue: commaGlue)
        }
        time = make(template: "jmm")
        weekday = make(template: "EEE")
        day = make(template: "MMMd")
        dayYear = make(template: "MMMdy")
        full = make(dateStyle: .medium, timeStyle: .short, commaGlue: true)
        exact = make(dateStyle: .full, timeStyle: .medium, commaGlue: false)
        short = make(template: "MMMdHHmmss")
    }

    // `commaGlue`: the short and medium forms join date and time with a comma where macOS says "at"
    // (the long and full forms say "at" in Chromium too).
    private static func formatter(pattern: String, locale: Locale, timeZone: TimeZone, commaGlue: Bool) -> DateFormatter
    {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        var adjusted = pattern.replacingOccurrences(of: "\u{202F}", with: " ")
        if commaGlue {
            adjusted = adjusted.replacingOccurrences(of: " 'at' ", with: ", ")
        }
        formatter.dateFormat = adjusted
        return formatter
    }

    // MARK: - Dates

    /// A date from the metadata (an ISO 8601 text), or "Not available".
    public func dateTime(iso value: String?) -> String {
        guard let value, !value.isEmpty, let date = Self.parse(value) else { return "Not available" }
        return full.string(from: date)
    }

    /// Whether a date reads as minutes ("24 min ago"), and so changes from one minute to the next.
    public func isWithinLastHour(_ date: Date, now: Date) -> Bool {
        let ms = date.epochMilliseconds
        let nowMs = now.epochMilliseconds
        return ms <= nowMs + Self.futureTolerance && nowMs - ms < Self.hour
    }

    /// A date for a list, said the way it would be said aloud: the closer it is, the more relative it
    /// reads, and the year or the time is left out where it adds nothing.
    ///   "Just now", "24 min ago", "Today, 9:12 AM", "Yesterday, 6:03 PM", "Mon, 4:05 PM",
    ///   "Jun 12, 8:30 AM", "Mar 3, 2024"
    /// A date in the future (a wrong clock somewhere) is shown in full rather than as "Just now".
    public func relative(_ date: Date, now: Date) -> String {
        let ms = date.epochMilliseconds
        let nowMs = now.epochMilliseconds
        if ms > nowMs + Self.futureTolerance {
            return full.string(from: date)
        }
        let age = max(0, nowMs - ms)
        if age < Self.minute {
            return "Just now"
        }
        if age < Self.hour {
            return "\(Int((age / Self.minute).rounded(.down))) min ago"
        }
        // Calendar days, not 24-hour steps: days around a daylight saving change are 23 or 25 hours.
        let startOfToday = calendar.startOfDay(for: now)
        func startOfDay(daysAgo: Int) -> Double {
            (calendar.date(byAdding: .day, value: -daysAgo, to: startOfToday) ?? startOfToday).epochMilliseconds
        }
        let clock = time.string(from: date)
        if ms >= startOfDay(daysAgo: 0) {
            return "Today, \(clock)"
        }
        if ms >= startOfDay(daysAgo: 1) {
            return "Yesterday, \(clock)"
        }
        // The six days before today: a week back would name today's own weekday.
        if ms >= startOfDay(daysAgo: 6) {
            return "\(weekday.string(from: date)), \(clock)"
        }
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            return "\(day.string(from: date)), \(clock)"
        }
        return dayYear.string(from: date)
    }

    /// The whole date, to the second, for the tooltip of a relative one.
    public func exactDateTime(_ date: Date) -> String {
        exact.string(from: date)
    }

    public func shortDateTime(_ date: Date) -> String {
        short.string(from: date)
    }

    // `new Date(text)` for the ISO 8601 forms the metadata uses: a date alone is UTC, a time without
    // a zone is local.
    private static func parse(_ text: String) -> Date? {
        let internet = ISO8601DateFormatter()
        internet.formatOptions = [.withInternetDateTime]
        if let date = internet.date(from: text) { return date }
        internet.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = internet.date(from: text) { return date }
        internet.formatOptions = [.withFullDate]
        if let date = internet.date(from: text) { return date }
        return AppClock.parse(text)
    }
}
