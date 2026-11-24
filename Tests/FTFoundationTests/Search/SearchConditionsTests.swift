// A search's conditions: what each chip says, the span of time a date rule means when the search runs, and the bytes a
// size means.
import Foundation
import Testing

@testable import FTFoundation

@Suite struct SearchConditionsTests {
    private let locale = Locale(identifier: "en_US")

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 1
        return calendar
    }

    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    @Test func eachChipSaysWhatItAsksInASentence() {
        let chip = { SearchConditionText.chip($0, locale: locale) }
        #expect(chip(.kind([.picture, .pdf])) == "Kind is PDF, Picture")
        #expect(chip(.kind([])) == "Kind is any")
        #expect(chip(.fileExtension(["swift", "md"])) == "Extension is swift, md")
        #expect(chip(SearchCondition.sizeDefault) == "Size is larger than 10 MB")
        #expect(
            chip(.size(SearchSizeRule(comparison: .between, value: 1, upper: 5, unit: .gigabytes)))
                == "Size is between 1 and 5 GB")
        #expect(
            chip(.size(SearchSizeRule(comparison: .smaller, value: 1.5, unit: .kilobytes)))
                == "Size is smaller than 1.5 KB")
        #expect(chip(.pictureSize(SearchPixelRule(larger: true, pixels: 3840))) == "Picture is larger than 3,840 px")
        #expect(chip(.pictureSize(SearchPixelRule(larger: false, pixels: 100))) == "Picture is smaller than 100 px")
        #expect(chip(.pictureSize(SearchPixelRule(comparison: .equal, pixels: 1920))) == "Picture is 1,920 px")
        #expect(
            chip(.not(.pictureSize(SearchPixelRule(comparison: .equal, pixels: 1920)))) == "Picture is not 1,920 px")
        #expect(
            chip(.not(.pictureSize(SearchPixelRule(larger: true, pixels: 3840))))
                == "Picture is not larger than 3,840 px")
        // Pixels are whole: exactly is exactly.
        let exactly = SearchPixelRule(comparison: .equal, pixels: 300)
        #expect(exactly.holds(300) && !exactly.holds(299) && !exactly.holds(301))
        #expect(
            SearchPixelRule(larger: true, pixels: 300).holds(301)
                && !SearchPixelRule(larger: true, pixels: 300).holds(300))
        #expect(chip(.date(.modified, .withinLast(2, .weeks))) == "Modified within the last 2 weeks")
        #expect(chip(.date(.lastOpened, .moreThanAgo(1, .years))) == "Last opened more than 1 year ago")
        #expect(chip(.date(.created, .thisMonth)) == "Created this month")
        #expect(chip(.date(.added, .before(date("2026-11-01T12:00:00Z")))).hasPrefix("Added before Nov 1, 2026"))
        #expect(chip(.tags(["Red", "Work"], all: false)) == "Tagged Red or Work")
        #expect(chip(.tags(["Red", "Work"], all: true)) == "Tagged Red and Work")
        #expect(chip(.attribute(.locked, is: false)) == "Not locked")
        #expect(chip(.attribute(.executable, is: true)) == "Can be run")
        #expect(chip(.skipFolders(["node_modules", ".build"])) == "Skipping node_modules, .build")
    }

    // A rule is kept as words and made a span when the search runs, so "within the last 7 days" moves with the day.
    @Test func aDateRuleIsASpanOfTimeAtTheMomentItRuns() {
        let now = date("2026-11-24T15:00:00Z")
        let span = { (rule: SearchDateRule) in rule.span(now: now, calendar: calendar) }
        #expect(span(.today) == SearchDateSpan(start: date("2026-11-24T00:00:00Z"), end: date("2026-11-25T00:00:00Z")))
        #expect(
            span(.yesterday) == SearchDateSpan(start: date("2026-11-23T00:00:00Z"), end: date("2026-11-24T00:00:00Z")))
        #expect(
            span(.thisMonth) == SearchDateSpan(start: date("2026-11-01T00:00:00Z"), end: date("2026-12-01T00:00:00Z")))
        // The days counted whole: the last 2 days are yesterday and today.
        #expect(span(.withinLast(2, .days)) == SearchDateSpan(start: date("2026-11-23T00:00:00Z")))
        #expect(span(.withinLast(1, .months)) == SearchDateSpan(start: date("2026-10-24T00:00:00Z")))
        #expect(span(.moreThanAgo(1, .years)) == SearchDateSpan(end: date("2025-11-24T15:00:00Z")))
        let first = date("2026-11-01T10:00:00Z")
        let last = date("2026-11-03T18:00:00Z")
        #expect(span(.before(first)) == SearchDateSpan(end: date("2026-11-01T00:00:00Z")))
        #expect(span(.after(first)) == SearchDateSpan(start: date("2026-11-02T00:00:00Z")))
        #expect(
            span(.between(last, first))
                == SearchDateSpan(start: date("2026-11-01T00:00:00Z"), end: date("2026-11-04T00:00:00Z")))
        // An item with no such date (never opened) meets only a rule of long ago.
        #expect(SearchDateRule.moreThanAgo(1, .years).takesNoDate && SearchDateRule.before(first).takesNoDate)
        #expect(!SearchDateRule.withinLast(1, .years).takesNoDate && !SearchDateRule.today.takesNoDate)
    }

    @Test func aSizeIsCountedInThousandsOfBytesAndBetweenTakesItsEnds() {
        #expect(SearchSizeRule(comparison: .larger, value: 10, unit: .megabytes).bounds == (10_000_000, nil))
        #expect(SearchSizeRule(comparison: .smaller, value: 1.5, unit: .kilobytes).bounds == (nil, 1_500))
        let between = SearchSizeRule(comparison: .between, value: 5, upper: 1, unit: .gigabytes).bounds
        #expect(between == (999_999_999, 5_000_000_001))
    }

    @Test func aChipWithAnEmptyListAsksForNothing() {
        #expect(!SearchCondition.extensionDefault.asksForSomething)
        #expect(!SearchCondition.tagsDefault.asksForSomething)
        #expect(!SearchCondition.skipFoldersDefault.asksForSomething)
        #expect(SearchCondition.kindDefault.asksForSomething)
        #expect(!SearchCondition.kind([.pdf]).readsEachItem)
        #expect(SearchCondition.sizeDefault.readsEachItem)
        #expect(!SearchCondition.attribute(.hidden, is: true).readsEachItem)
    }
}
