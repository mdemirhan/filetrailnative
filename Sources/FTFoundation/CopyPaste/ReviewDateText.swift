// Port of formatReviewDate, formatCount and pluralize (apps/desktop/src/renderer/lib/copyPasteReview.ts)
import Foundation

/// The dates of the review rows and the conflict cards (`formatReviewDate`), in the system's time zone and the locale
/// Chromium gives `Intl.DateTimeFormat(undefined, …)` (`InfoLocale.original`), with Chromium's comma and plain space
/// where macOS writes "at" and a narrow no-break space. Tests pass their own locale and zone.
public final class ReviewDateText: @unchecked Sendable {
    public static let shared = ReviewDateText()

    /// `FUTURE_TOLERANCE_MS`: a clock a little ahead of this one is still "today".
    private static let futureTolerance = 60_000.0

    private let calendar: Calendar
    private let time: DateFormatter
    private let full: DateFormatter
    private let day: DateFormatter
    private let dayYear: DateFormatter

    public init(locale: Locale = InfoLocale.original, timeZone: TimeZone = .autoupdatingCurrent) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.locale = locale
        self.calendar = calendar
        func make(_ pattern: String) -> DateFormatter {
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.timeZone = timeZone
            formatter.dateFormat = pattern.replacingOccurrences(of: "\u{202F}", with: " ")
                .replacingOccurrences(of: " 'at' ", with: ", ")
            return formatter
        }
        func template(_ template: String) -> DateFormatter {
            make(DateFormatter.dateFormat(fromTemplate: template, options: 0, locale: locale) ?? template)
        }
        time = template("jmm")
        day = template("MMMd")
        dayYear = template("MMMdy")
        let styled = DateFormatter()
        styled.locale = locale
        styled.dateStyle = .medium
        styled.timeStyle = .short
        full = make(styled.dateFormat ?? "")
    }

    /// "today, 13:59", "yesterday, 09:12", "Jan 1", or "Jan 1, 2025" for another year. A date in the future (a wrong
    /// clock somewhere) is shown in full rather than as "today".
    public func format(_ ms: Double, now: Double) -> String {
        let date = Date(epochMilliseconds: ms)
        if ms > now + Self.futureTolerance { return full.string(from: date) }
        let today = Date(epochMilliseconds: now)
        // Calendar days, not 24-hour steps: days around a daylight saving change are 23 or 25 hours.
        let startOfToday = calendar.startOfDay(for: today)
        let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday) ?? startOfToday
        if ms >= startOfToday.epochMilliseconds { return "today, \(time.string(from: date))" }
        if ms >= startOfYesterday.epochMilliseconds { return "yesterday, \(time.string(from: date))" }
        return calendar.component(.year, from: date) == calendar.component(.year, from: today)
            ? day.string(from: date) : dayYear.string(from: date)
    }
}

/// The counts the copy and paste dialogs write.
public enum ReviewCount {
    /// `formatCount`: "1,200", as `toLocaleString()` writes it.
    public static func format(_ count: Int) -> String {
        ContextMenuRules.groupedCount(count)
    }

    /// `pluralize`: "1 item", "1,500 items".
    public static func pluralize(_ count: Int, _ noun: String) -> String {
        "\(format(count)) \(noun)\(count == 1 ? "" : "s")"
    }
}
