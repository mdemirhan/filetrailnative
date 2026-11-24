// What a search can ask of an item besides its name: its kind, extension, size, size in pixels, dates, tags and
// attributes, and folders it leaves out. Each condition is a chip under the search bar, kept as it was set ("within the
// last 2 weeks"), and made into what the walk checks when the search runs.
import Foundation

/// The kinds of item a condition can ask for, each by its extensions; a folder by being one.
public enum SearchKind: String, CaseIterable, Codable, Sendable, Hashable {
    case pdf, picture, video, audio, document, spreadsheet, presentation, archive, code, text, folder, application

    /// The extensions of the kind, lowercase and without the dot; none for a folder, which is told by being one.
    public var extensions: Set<String> {
        switch self {
        case .pdf: ["pdf"]
        case .picture:
            [
                "jpg", "jpeg", "png", "heic", "heif", "gif", "tif", "tiff", "bmp", "webp", "avif", "raw", "dng", "cr2",
                "cr3", "nef", "arw", "orf", "rw2", "svg", "psd",
            ]
        case .video: ["mov", "mp4", "m4v", "avi", "mkv", "webm", "mpg", "mpeg", "3gp", "wmv"]
        case .audio: ["mp3", "m4a", "aac", "wav", "aif", "aiff", "flac", "ogg", "opus", "caf"]
        case .document: ["doc", "docx", "pages", "rtf", "rtfd", "odt", "epub"]
        case .spreadsheet: ["xls", "xlsx", "numbers", "csv", "tsv", "ods"]
        case .presentation: ["ppt", "pptx", "key", "odp"]
        case .archive: ["zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "dmg", "xar", "zst"]
        case .code:
            [
                "swift", "c", "h", "m", "mm", "cpp", "hpp", "cc", "cs", "java", "kt", "go", "rs", "py", "rb", "js",
                "jsx", "ts", "tsx", "php", "sh", "zsh", "html", "css", "scss", "json", "yaml", "yml", "toml", "xml",
                "sql", "lua", "pl", "r", "dart", "vue",
            ]
        case .text: ["txt", "md", "markdown", "log"]
        case .folder: []
        case .application: ["app"]
        }
    }

    /// As the editor and a chip name it.
    public var label: String {
        switch self {
        case .pdf: "PDF"
        case .picture: "Picture"
        case .video: "Video"
        case .audio: "Audio"
        case .document: "Document"
        case .spreadsheet: "Spreadsheet"
        case .presentation: "Presentation"
        case .archive: "Archive"
        case .code: "Code"
        case .text: "Text"
        case .folder: "Folder"
        case .application: "Application"
        }
    }
}

/// Which of an item's dates a condition is about.
public enum SearchDateField: String, CaseIterable, Codable, Sendable, Hashable {
    case modified, created, added, lastOpened, taken

    /// As the Add a Condition menu names it.
    public var menuLabel: String {
        switch self {
        case .modified: "Date Modified"
        case .created: "Date Created"
        case .added: "Date Added"
        case .lastOpened: "Date Last Opened"
        case .taken: "Date Taken"
        }
    }

    /// As a chip starts: "Modified within the last 2 weeks".
    public var chipLabel: String {
        switch self {
        case .modified: "Modified"
        case .created: "Created"
        case .added: "Added"
        case .lastOpened: "Last opened"
        case .taken: "Taken"
        }
    }
}

/// What about an item a condition can ask, beyond its name, kind, size and dates.
public enum SearchAttribute: String, CaseIterable, Codable, Sendable, Hashable {
    case hidden, executable, readOnly, locked, empty, alias, symbolicLink

    /// As the Attribute menu names it.
    public var label: String {
        switch self {
        case .hidden: "Hidden"
        case .executable: "Can Be Run"
        case .readOnly: "Read-only"
        case .locked: "Locked"
        case .empty: "Empty"
        case .alias: "Alias"
        case .symbolicLink: "Symbolic Link"
        }
    }

    /// As a chip says it, or says it isn't.
    public func chip(is value: Bool) -> String {
        switch (self, value) {
        case (.hidden, true): "Hidden"
        case (.hidden, false): "Not hidden"
        case (.executable, true): "Can be run"
        case (.executable, false): "Can't be run"
        case (.readOnly, true): "Read-only"
        case (.readOnly, false): "Not read-only"
        case (.locked, true): "Locked"
        case (.locked, false): "Not locked"
        case (.empty, true): "Empty"
        case (.empty, false): "Not empty"
        case (.alias, true): "Alias"
        case (.alias, false): "Not an alias"
        case (.symbolicLink, true): "Symbolic link"
        case (.symbolicLink, false): "Not a symbolic link"
        }
    }
}

/// How a size compares.
public enum SearchComparison: String, CaseIterable, Codable, Sendable, Hashable {
    /// `equal`: the size as typed, to the last digit typed (`SearchSizeRule.bounds`). `atLeast` and `atMost` include
    /// the size itself, as typed (`>=1mb` is 1,000,000 bytes or more).
    case larger, smaller, between, equal, atLeast, atMost

    public var label: String {
        switch self {
        case .larger: "is larger than"
        case .smaller: "is smaller than"
        case .between: "is between"
        case .equal: "is"
        case .atLeast: "is at least"
        case .atMost: "is at most"
        }
    }
}

/// A unit of size, as Finder counts them: a thousand bytes to a kilobyte.
public enum SearchSizeUnit: String, CaseIterable, Codable, Sendable, Hashable {
    case bytes, kilobytes, megabytes, gigabytes

    public var label: String {
        switch self {
        case .bytes: "bytes"
        case .kilobytes: "KB"
        case .megabytes: "MB"
        case .gigabytes: "GB"
        }
    }

    /// The unit after `value`: "1 byte", "2 bytes", "1 KB".
    public func label(_ value: Double) -> String { self == .bytes && value == 1 ? "byte" : label }

    public var bytes: Double {
        switch self {
        case .bytes: 1
        case .kilobytes: 1e3
        case .megabytes: 1e6
        case .gigabytes: 1e9
        }
    }
}

/// A size as set: a number and its unit, a second number for "between".
public struct SearchSizeRule: Equatable, Codable, Sendable, Hashable {
    public var comparison: SearchComparison
    public var value: Double
    /// The top of "between".
    public var upper: Double
    public var unit: SearchSizeUnit
    /// The digits typed after the point, where `value` doesn't say them: `2.10kb` is 2.1 to two places. Nil for as
    /// many as `value` has.
    public var places: Int?

    public init(
        comparison: SearchComparison, value: Double, upper: Double = 0, unit: SearchSizeUnit, places: Int? = nil
    ) {
        self.comparison = comparison
        self.value = value
        self.upper = upper
        self.unit = unit
        self.places = places
    }

    /// The bytes an item's size must be over (excluded) and under (excluded), either open. A size that is equal is so
    /// to the last digit typed, as the Size column starts: `1mb` is 1 MB up to 2 MB (what shows as 1.x MB), `1.5mb`
    /// 1.5 up to 1.6 MB, `1000b` 1,000 bytes and no other.
    public var bounds: (above: Int64?, below: Int64?) {
        let low = Int64((value * unit.bytes).rounded())
        switch comparison {
        case .larger: return (low, nil)
        case .smaller: return (nil, low)
        case .atLeast: return (Int64((value * unit.bytes - 1e-6).rounded(.up)) - 1, nil)
        case .atMost: return (nil, Int64((value * unit.bytes + 1e-6).rounded(.down)) + 1)
        case .between:
            let high = Int64((upper * unit.bytes).rounded())
            return (min(low, high) - 1, max(low, high) + 1)
        case .equal:
            // Up to a whole byte, past what a decimal leaves over (2.11 × 1000 is 2110.0000000000002).
            func whole(_ bytes: Double) -> Int64 { Int64((bytes - 1e-6).rounded(.up)) }
            return (whole(value * unit.bytes) - 1, whole(upTo * unit.bytes))
        }
    }

    /// Where an equal size ends, not included: one more of its last digit (2 for 1, 1.6 for 1.5).
    public var upTo: Double { value + 1 / pow(10, Double(places ?? Self.decimals(value))) }

    /// The digits typed after the point: 0 for 1, 1 for 1.5, 2 for 1.25 (up to 6).
    public static func decimals(_ value: Double) -> Int {
        var places = 0
        var scaled = value
        while places < 6, abs(scaled - scaled.rounded()) > 1e-9 {
            scaled *= 10
            places += 1
        }
        return places
    }
}

/// A picture's longer side as set.
public struct SearchPixelRule: Equatable, Codable, Sendable, Hashable {
    /// Larger, smaller, at least, at most, or exactly (a size alone, as a file's size alone is that size); "between"
    /// isn't offered.
    public var comparison: SearchComparison
    public var pixels: Int

    public init(comparison: SearchComparison, pixels: Int) {
        self.comparison = comparison
        self.pixels = pixels
    }

    public init(larger: Bool, pixels: Int) { self.init(comparison: larger ? .larger : .smaller, pixels: pixels) }

    public var larger: Bool { comparison == .larger }

    /// Whether a picture whose longer side is `side` pixels meets it. Pixels are whole: exactly is exactly.
    public func holds(_ side: Int) -> Bool {
        switch comparison {
        case .larger: side > pixels
        case .smaller: side < pixels
        case .equal: side == pixels
        case .atLeast: side >= pixels
        case .atMost: side <= pixels
        case .between: false
        }
    }
}

/// Days, weeks, months or years, for "within the last 2 weeks".
public enum SearchTimeUnit: String, CaseIterable, Codable, Sendable, Hashable {
    case days, weeks, months, years

    public func label(_ count: Int) -> String {
        let one: String
        switch self {
        case .days: one = "day"
        case .weeks: one = "week"
        case .months: one = "month"
        case .years: one = "year"
        }
        return count == 1 ? one : one + "s"
    }

    var component: Calendar.Component {
        switch self {
        case .days: .day
        case .weeks: .weekOfYear
        case .months: .month
        case .years: .year
        }
    }
}

/// When a date must be, as set: kept as words ("within the last 2 weeks") and made a span of time when the search runs,
/// so a search run tomorrow means tomorrow's two weeks.
public enum SearchDateRule: Equatable, Codable, Sendable, Hashable {
    case today, yesterday, thisWeek, thisMonth, thisYear
    case withinLast(Int, SearchTimeUnit)
    case moreThanAgo(Int, SearchTimeUnit)
    /// Before the start of that day.
    case before(Date)
    /// After the end of that day.
    case after(Date)
    /// From the start of that day on.
    case onOrAfter(Date)
    /// To the end of that day.
    case onOrBefore(Date)
    /// From the start of the first day to the end of the second.
    case between(Date, Date)

    /// What the editor's first menu names, in its order.
    public enum Kind: String, CaseIterable, Sendable {
        case today, yesterday, thisWeek, thisMonth, thisYear, withinLast, moreThanAgo, before, after, onOrAfter,
            onOrBefore, between

        public var label: String {
            switch self {
            case .today: "is today"
            case .yesterday: "is yesterday"
            case .thisWeek: "is this week"
            case .thisMonth: "is this month"
            case .thisYear: "is this year"
            case .withinLast: "is within the last"
            case .moreThanAgo: "is more than"
            case .before: "is before"
            case .after: "is after"
            case .onOrAfter: "is on or after"
            case .onOrBefore: "is on or before"
            case .between: "is between"
            }
        }
    }

    public var kind: Kind {
        switch self {
        case .today: .today
        case .yesterday: .yesterday
        case .thisWeek: .thisWeek
        case .thisMonth: .thisMonth
        case .thisYear: .thisYear
        case .withinLast: .withinLast
        case .moreThanAgo: .moreThanAgo
        case .before: .before
        case .after: .after
        case .onOrAfter: .onOrAfter
        case .onOrBefore: .onOrBefore
        case .between: .between
        }
    }

    /// The span it means at `now`: from `start` (included) to `end` (excluded), either open.
    public func span(now: Date, calendar: Calendar = .current) -> SearchDateSpan {
        func period(_ component: Calendar.Component, back: Int = 0) -> SearchDateSpan {
            let base = calendar.date(byAdding: component, value: -back, to: now) ?? now
            guard let interval = calendar.dateInterval(of: component, for: base) else { return SearchDateSpan() }
            return SearchDateSpan(start: interval.start, end: interval.end)
        }
        let today = calendar.startOfDay(for: now)
        switch self {
        case .today: return period(.day)
        case .yesterday: return period(.day, back: 1)
        case .thisWeek: return period(.weekOfYear)
        case .thisMonth: return period(.month)
        case .thisYear: return period(.year)
        case .withinLast(let count, let unit):
            // The days counted whole: "the last 2 days" is yesterday and today.
            let start = calendar.date(byAdding: unit.component, value: -count, to: today)
            return SearchDateSpan(
                start: unit == .days ? start.flatMap { calendar.date(byAdding: .day, value: 1, to: $0) } : start)
        case .moreThanAgo(let count, let unit):
            return SearchDateSpan(end: calendar.date(byAdding: unit.component, value: -count, to: now))
        case .before(let day):
            return SearchDateSpan(end: calendar.startOfDay(for: day))
        case .after(let day):
            return SearchDateSpan(start: calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day)))
        case .onOrAfter(let day):
            return SearchDateSpan(start: calendar.startOfDay(for: day))
        case .onOrBefore(let day):
            return SearchDateSpan(end: calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day)))
        case .between(let first, let second):
            let (from, to) = first <= second ? (first, second) : (second, first)
            return SearchDateSpan(
                start: calendar.startOfDay(for: from),
                end: calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: to)))
        }
    }

    /// An item that has no such date (never opened, no date taken) meets only a rule of "long ago".
    public var takesNoDate: Bool {
        switch self {
        case .moreThanAgo, .before, .onOrBefore: true
        default: false
        }
    }
}

/// A span of time: from `start` (included) to `end` (excluded), either open.
public struct SearchDateSpan: Equatable, Sendable, Hashable {
    public var start: Date?
    public var end: Date?

    public init(start: Date? = nil, end: Date? = nil) {
        self.start = start
        self.end = end
    }

    public func contains(_ date: Date) -> Bool {
        if let start, date < start { return false }
        if let end, date >= end { return false }
        return true
    }
}

/// One condition: a chip under the search bar.
public enum SearchCondition: Equatable, Codable, Sendable, Hashable {
    /// Any of these kinds; none chosen asks for nothing.
    case kind(Set<SearchKind>)
    /// Any of these extensions, lowercase, without the dot; none asks for nothing.
    case fileExtension([String])
    case size(SearchSizeRule)
    case pictureSize(SearchPixelRule)
    case date(SearchDateField, SearchDateRule)
    /// Tags by name; with `all`, every one of them, else any.
    case tags([String], all: Bool)
    case attribute(SearchAttribute, is: Bool)
    /// Folders of these names, wherever they are, aren't gone into.
    case skipFolders([String])
    /// An item's permissions are any of these modes (`0o7777`: the read, write and run bits of its owner, its group and
    /// everyone, with set-user, set-group and sticky).
    case permissions([SearchPermission])
    /// What the condition asks for, not: for a kind, an extension, tags, permissions, a size, a picture's size and a
    /// date (`kind:!pdf`, `size:!1mb`, `picture:!1920`, `modified:!today`).
    indirect case not(SearchCondition)

    /// What the Add a Condition menu offers, in its order, with what each starts as.
    public static let kindDefault = SearchCondition.kind([.pdf])
    public static let extensionDefault = SearchCondition.fileExtension([])
    public static let sizeDefault = SearchCondition.size(
        SearchSizeRule(comparison: .larger, value: 10, unit: .megabytes))
    public static let pictureSizeDefault = SearchCondition.pictureSize(SearchPixelRule(larger: true, pixels: 1920))
    public static func dateDefault(_ field: SearchDateField) -> SearchCondition { .date(field, .withinLast(7, .days)) }
    public static let tagsDefault = SearchCondition.tags([], all: false)
    public static func attributeDefault(_ attribute: SearchAttribute) -> SearchCondition {
        .attribute(attribute, is: true)
    }
    public static let skipFoldersDefault = SearchCondition.skipFolders([])

    /// Whether it asks for anything yet: a chip whose list is still empty asks for nothing.
    public var asksForSomething: Bool {
        switch self {
        case .kind(let kinds): !kinds.isEmpty
        case .fileExtension(let extensions): !extensions.isEmpty
        case .tags(let tags, _): !tags.isEmpty
        case .skipFolders(let names): !names.isEmpty
        case .permissions(let modes): !modes.isEmpty
        case .not(let condition): condition.asksForSomething
        default: true
        }
    }

    /// Whether checking it reads more of an item than its folder lists: its attributes, tags or contents.
    public var readsEachItem: Bool {
        switch self {
        case .kind, .fileExtension, .skipFolders: false
        case .attribute(.hidden, _), .attribute(.symbolicLink, _): false
        case .not(let condition): condition.readsEachItem
        default: true
        }
    }
}

/// What a condition's chip says.
public enum SearchConditionText {
    public static let addTitle = "Add a Condition"
    public static let clearAll = "Clear All"
    public static let addButtonName = "Add a condition"

    /// "Kind is PDF, Picture", "Size is larger than 10 MB", "Modified within the last 2 weeks", "Not locked".
    public static func chip(_ condition: SearchCondition, locale: Locale = FormatLocale.current) -> String {
        switch condition {
        case .kind(let kinds):
            let names = SearchKind.allCases.filter(kinds.contains).map(\.label)
            return names.isEmpty ? "Kind is any" : "Kind is " + names.joined(separator: ", ")
        case .fileExtension(let extensions):
            return extensions.isEmpty ? "Extension is any" : "Extension is " + extensions.joined(separator: ", ")
        case .size(let rule):
            switch rule.comparison {
            case .larger: return "Size is larger than \(number(rule.value, locale)) \(rule.unit.label(rule.value))"
            case .smaller: return "Size is smaller than \(number(rule.value, locale)) \(rule.unit.label(rule.value))"
            case .atLeast: return "Size is at least \(number(rule.value, locale)) \(rule.unit.label(rule.value))"
            case .atMost: return "Size is at most \(number(rule.value, locale)) \(rule.unit.label(rule.value))"
            case .equal:
                // Bytes are counted; other units go to the next of the last digit typed.
                if rule.unit == .bytes { return "Size is \(number(rule.value, locale)) \(rule.unit.label(rule.value))" }
                return
                    "Size is \(number(rule.value, locale)) \(rule.unit.label) to under \(number(rule.upTo, locale)) \(rule.unit.label)"
            case .between:
                return
                    "Size is between \(number(rule.value, locale)) and \(number(rule.upper, locale)) \(rule.unit.label(rule.upper))"
            }
        case .pictureSize(let rule):
            let pixels = FormatLocale.count(rule.pixels, locale: locale)
            switch rule.comparison {
            case .larger: return "Picture is larger than \(pixels) px"
            case .smaller: return "Picture is smaller than \(pixels) px"
            case .atLeast: return "Picture is at least \(pixels) px"
            case .atMost: return "Picture is at most \(pixels) px"
            case .equal, .between: return "Picture is \(pixels) px"
            }
        case .date(let field, let rule):
            return field.chipLabel + " " + dateWords(rule, locale: locale)
        case .tags(let tags, let all):
            return tags.isEmpty ? "Tagged with any tag" : "Tagged " + tags.joined(separator: all ? " and " : " or ")
        case .attribute(let attribute, let value):
            return attribute.chip(is: value)
        case .skipFolders(let names):
            return names.isEmpty ? "Skipping no folders" : "Skipping " + names.joined(separator: ", ")
        case .permissions(let modes):
            return "Permissions are " + modes.map(SearchPermissions.words).joined(separator: " or ")
        case .not(let condition):
            return negated(condition, locale: locale)
        }
    }

    /// "Kind is not PDF or Picture", "Not tagged red", "Permissions are not 777 (rwxrwxrwx)".
    private static func negated(_ condition: SearchCondition, locale: Locale) -> String {
        switch condition {
        case .kind(let kinds):
            return "Kind is not " + SearchKind.allCases.filter(kinds.contains).map(\.label).joined(separator: " or ")
        case .fileExtension(let extensions):
            return "Extension is not " + extensions.joined(separator: " or ")
        case .tags(let tags, _):
            return "Not tagged " + tags.joined(separator: " or ")
        case .permissions(let modes):
            return "Permissions are not " + modes.map(SearchPermissions.words).joined(separator: " or ")
        case .pictureSize:
            // "Picture is not 1,920 px", "Picture is not larger than 3,840 px".
            let said = chip(condition, locale: locale)
            return said.hasPrefix("Picture is ") ? "Picture is not " + said.dropFirst("Picture is ".count) : said
        case .size:
            // "Size is not 1 MB to under 2 MB", "Size is not larger than 10 MB".
            let said = chip(condition, locale: locale)
            return said.hasPrefix("Size is ") ? "Size is not " + said.dropFirst("Size is ".count) : "Not: " + said
        case .date:
            // "Not modified today", "Not last opened within the last 7 days".
            let said = chip(condition, locale: locale)
            return "Not " + said.prefix(1).lowercased() + said.dropFirst()
        case .attribute(let attribute, let value):
            return attribute.chip(is: !value)
        default:
            return "Not: " + chip(condition, locale: locale)
        }
    }

    /// What a chip says of when: "within the last 2 weeks", "today", "before Nov 1, 2026".
    public static func dateWords(_ rule: SearchDateRule, locale: Locale = FormatLocale.current) -> String {
        switch rule {
        case .today: return "today"
        case .yesterday: return "yesterday"
        case .thisWeek: return "this week"
        case .thisMonth: return "this month"
        case .thisYear: return "this year"
        case .withinLast(let count, let unit): return "within the last \(count) \(unit.label(count))"
        case .moreThanAgo(let count, let unit): return "more than \(count) \(unit.label(count)) ago"
        case .before(let day): return "before \(dayText(day, locale))"
        case .after(let day): return "after \(dayText(day, locale))"
        case .onOrAfter(let day): return "on or after \(dayText(day, locale))"
        case .onOrBefore(let day): return "on or before \(dayText(day, locale))"
        case .between(let first, let second): return "between \(dayText(first, locale)) and \(dayText(second, locale))"
        }
    }

    static func number(_ value: Double, _ locale: Locale) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    static func dayText(_ day: Date, _ locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: day)
    }
}

/// Permissions an item's must have: the bits of `mode` where `mask` has them, any elsewhere. Exact, the mask is every
/// bit (`0o7777`), so `755` is 0755 and not 4755; `?5?` asks for the group's bits alone.
public struct SearchPermission: Equatable, Codable, Sendable, Hashable, ExpressibleByIntegerLiteral {
    public var mode: UInt16
    public var mask: UInt16

    public init(mode: UInt16, mask: UInt16 = 0o7777) {
        self.mask = mask & 0o7777
        self.mode = mode & self.mask
    }

    public init(integerLiteral value: UInt16) { self.init(mode: value) }

    /// Whether an item whose mode is `mode` has these permissions.
    public func holds(_ mode: UInt16) -> Bool { mode & mask == self.mode }
}

/// Permissions as typed and shown: three or four octal digits (`755`, `0644`, `4755`) or the letters `ls` shows
/// (`rwxr-xr-x`, `-rw-r--r--`, with `s`, `S`, `t` and `T` for set-user, set-group and sticky); `?` for a digit or a
/// letter that can be anything (`?5?`, `???r-x???`).
public enum SearchPermissions {
    /// The bits each letter stands for, owner first.
    private static let bits: [UInt16] = [0o400, 0o200, 0o100, 0o40, 0o20, 0o10, 0o4, 0o2, 0o1]

    /// The exact mode `text` is, or nil (for a wildcard too).
    public static func mode(_ text: String) -> UInt16? {
        guard let permission = permission(text), permission.mask == 0o7777 else { return nil }
        return permission.mode
    }

    /// The permissions `text` asks for, or nil.
    public static func permission(_ text: String) -> SearchPermission? {
        if (3...4).contains(text.count), text.allSatisfy({ ("0"..."7").contains($0) || $0 == "?" }) {
            var mode: UInt16 = 0
            var mask: UInt16 = 0o7777
            // Digits say digits: from the last, others, group, owner, then the digit of set-user, set-group and sticky.
            // A `?` is any digit there. Three digits with a `?` leave the fourth unsaid, so any (`?5?` is a group
            // of 5, whatever else); three without are one mode, the fourth 0 (`755` is 0755, not 4755).
            if text.count == 3, text.contains("?") { mask &= ~0o7000 }
            for (place, digit) in text.reversed().enumerated() {
                let shift = UInt16(3 * place)
                if digit == "?" {
                    mask &= ~(0o7 << shift)
                } else {
                    mode |= UInt16(String(digit), radix: 8)! << shift
                }
            }
            return SearchPermission(mode: mode, mask: mask)
        }
        var letters = Array(text)
        if letters.count == 10 { letters.removeFirst() }
        guard letters.count == 9 else { return nil }
        var mode: UInt16 = 0
        var mask: UInt16 = 0o7777
        for (index, letter) in letters.enumerated() {
            let expected: Character = ["r", "w", "x"][index % 3]
            // The set-user, set-group and sticky bit each letter's place shares, if any.
            let special: UInt16 = index == 2 ? 0o4000 : index == 5 ? 0o2000 : index == 8 ? 0o1000 : 0
            switch letter {
            case expected: mode |= bits[index]
            case "-": break
            case "?": mask &= ~(bits[index] | special)
            case "s" where index == 2 || index == 5, "t" where index == 8: mode |= bits[index] | special
            case "S" where index == 2 || index == 5, "T" where index == 8: mode |= special
            default: return nil
            }
        }
        return SearchPermission(mode: mode, mask: mask)
    }

    /// `rwxr-xr-x` for 0o755, with `s`, `S`, `t` and `T` as `ls` writes them, and `?` where any will do.
    public static func letters(_ mode: UInt16, mask: UInt16 = 0o7777) -> String {
        var text = ""
        for (index, bit) in bits.enumerated() {
            let special: UInt16 = index == 2 ? 0o4000 : index == 5 ? 0o2000 : index == 8 ? 0o1000 : 0
            let on = mode & bit != 0
            if mask & bit == 0 {
                text += "?"
            } else if special != 0, mode & special != 0 {
                text += index == 8 ? (on ? "t" : "T") : (on ? "s" : "S")
            } else {
                text += on ? String(["r", "w", "x"][index % 3]) : "-"
            }
        }
        return text
    }

    /// `755` for 0o755, `4755` with a bit above, `?5?` where a digit can be anything: the fewest digits that read back
    /// as these permissions (`permission`); nil where no digits do (`r-?` is no one digit).
    public static func octal(_ mode: UInt16, mask: UInt16 = 0o7777) -> String? {
        var digits: [String] = []
        for place in 0..<4 {
            let shift = UInt16(3 * place)
            switch mask >> shift & 0o7 {
            case 0o7: digits.insert(String(mode >> shift & 0o7), at: 0)
            case 0: digits.insert("?", at: 0)
            default:
                // The special digit is told from the other three when they read back the same.
                guard place == 3 else { return nil }
                digits.insert("", at: 0)
            }
        }
        let wanted = SearchPermission(mode: mode, mask: mask)
        let three = digits.dropFirst().joined()
        if permission(three) == wanted { return three }
        let four = digits.joined()
        return four.count == 4 && permission(four) == wanted ? four : nil
    }

    /// "755 (rwxr-xr-x)": the digits, and the letters where they say the same (`?5?` has none, as `???r-x???` says
    /// set-group is off); the letters alone where no digits say it (`r????????`).
    public static func words(_ permission: SearchPermission) -> String {
        let letters = letters(permission.mode, mask: permission.mask)
        guard let octal = octal(permission.mode, mask: permission.mask) else { return letters }
        return SearchPermissions.permission(letters) == permission ? "\(octal) (\(letters))" : octal
    }

}
