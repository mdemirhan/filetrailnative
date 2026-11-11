import FTTestSupport
import Foundation
import Testing

@testable import FTFoundation

struct DateTextTests {
    struct Input: Codable, Sendable {
        let now: Double
        let ms: Double
        let timeZone: String
    }

    struct Output: Codable, Equatable, Sendable {
        let relative: String
        let exact: String
        let withinLastHour: Bool
    }

    static let zone = TimeZone(identifier: "America/Los_Angeles") ?? .gmt
    static let locale = Locale(identifier: "en_US")
    let text = DateText(locale: Self.locale, timeZone: Self.zone)

    // Local wall time in the fixed zone, so the cases do not depend on the machine's.
    static func local(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0)
        -> Date
    {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.date(
            from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))
            ?? .distantPast
    }

    // The list writes its dates in the locale the Info panel uses, the app's language alone, not the machine's region.
    @Test func listDatesUseTheAppsLocale() {
        #expect(DateText.shared.locale == InfoLocale.original)
        #expect(DateText().locale == InfoLocale.original)
        let now = Self.local(2026, 10, 19, 12)
        let date = Self.local(2026, 10, 5, 16, 12)
        let language = DateText(locale: Locale(identifier: "en"), timeZone: Self.zone)
        #expect(language.relative(date, now: now) == "Oct 5, 4:12 PM")
        // A region's own patterns are what the list showed before: day first, 24-hour.
        let region = DateText(locale: Locale(identifier: "en_GB"), timeZone: Self.zone)
        #expect(region.relative(date, now: now) != language.relative(date, now: now))
    }

    @Test func formatsInvalidDatesDefensively() {
        #expect(text.dateTime(iso: "bad-date") == "Not available")
        #expect(text.dateTime(iso: nil) == "Not available")
        #expect(text.dateTime(iso: "") == "Not available")
        #expect(text.dateTime(iso: "2026-10-05T17:12:30Z") == "Oct 5, 2026, 10:12 AM")
    }

    // A Thursday afternoon.
    let now = DateTextTests.local(2026, 10, 1, 14, 45)
    func at(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int, year: Int = 2026) -> String {
        text.relative(Self.local(year, month, day, hour, minute), now: now)
    }

    @Test func countsInMinutesWithinTheHour() {
        #expect(text.relative(now.addingTimeInterval(-20), now: now) == "Just now")
        #expect(text.relative(now.addingTimeInterval(-60), now: now) == "1 min ago")
        #expect(at(10, 1, 14, 21) == "24 min ago")
        #expect(text.relative(now.addingTimeInterval(-59 * 60 - 59), now: now) == "59 min ago")
        #expect(text.relative(now.addingTimeInterval(-60 * 60), now: now) == "Today, 1:45 PM")
    }

    @Test func keepsCountingMinutesAcrossMidnight() {
        let justAfterMidnight = Self.local(2026, 10, 2, 0, 10)
        #expect(text.relative(Self.local(2026, 10, 1, 23, 50), now: justAfterMidnight) == "20 min ago")
    }

    @Test func namesTodayYesterdayAndTheWeekdaysBeforeThem() {
        #expect(at(10, 1, 9, 12) == "Today, 9:12 AM")
        #expect(at(10, 1, 0, 0) == "Today, 12:00 AM")
        #expect(at(9, 30, 18, 3) == "Yesterday, 6:03 PM")
        #expect(at(9, 28, 16, 5) == "Mon, 4:05 PM")
        // Six days back is the last with a weekday; a week back would name today's own.
        #expect(at(9, 25, 0, 0) == "Fri, 12:00 AM")
        #expect(at(9, 24, 23, 59) == "Sep 24, 11:59 PM")
    }

    @Test func dropsTheYearForThisYearAndTheTimeForOlderOnes() {
        #expect(at(6, 12, 8, 30) == "Jun 12, 8:30 AM")
        #expect(at(12, 31, 22, 0, year: 2025) == "Dec 31, 2025")
        #expect(at(3, 3, 11, 15, year: 2024) == "Mar 3, 2024")
    }

    @Test func countsDaysOnTheCalendarAcrossDaylightSavingChanges() {
        let afterFallBack = Self.local(2026, 11, 2, 10, 0)
        #expect(text.relative(Self.local(2026, 11, 1, 0, 30), now: afterFallBack) == "Yesterday, 12:30 AM")
        #expect(text.relative(Self.local(2026, 10, 31, 23, 30), now: afterFallBack) == "Sat, 11:30 PM")
    }

    @Test func showsADateInTheFutureInFull() {
        #expect(text.relative(now.addingTimeInterval(30), now: now) == "Just now")
        #expect(text.relative(now.addingTimeInterval(2 * 3600), now: now) == "Oct 1, 2026, 4:45 PM")
    }

    @Test func givesTheWholeDateForTheTooltip() {
        #expect(text.exactDateTime(Self.local(2026, 10, 1, 14, 44, 7)) == "Thursday, October 1, 2026 at 2:44:07 PM")
    }

    @Test func relativeDatesMatchTheGoldenFile() throws {
        let cases: [GoldenCase<Input, Output>] = try Golden.load(suite: "relative-dates")
        #expect(cases.count >= 500)
        Golden.expectMatches(cases) { input in
            // The golden says which zone it was recorded in; the test sets the same.
            let zone = TimeZone(identifier: input.timeZone) ?? .gmt
            let text = DateText(locale: Self.locale, timeZone: zone)
            let date = Date(epochMilliseconds: input.ms)
            let now = Date(epochMilliseconds: input.now)
            return Output(
                relative: text.relative(date, now: now),
                exact: text.exactDateTime(date),
                withinLastHour: text.isWithinLastHour(date, now: now))
        }
    }
}
