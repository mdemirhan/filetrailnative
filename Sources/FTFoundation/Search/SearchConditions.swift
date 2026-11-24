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
    case larger, smaller, between

    public var label: String {
        switch self {
        case .larger: "is larger than"
        case .smaller: "is smaller than"
        case .between: "is between"
        }
    }
}

/// A unit of size, as Finder counts them: a thousand bytes to a kilobyte.
public enum SearchSizeUnit: String, CaseIterable, Codable, Sendable, Hashable {
    case kilobytes, megabytes, gigabytes

    public var label: String {
        switch self {
        case .kilobytes: "KB"
        case .megabytes: "MB"
        case .gigabytes: "GB"
        }
    }

    public var bytes: Double {
        switch self {
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

    public init(comparison: SearchComparison, value: Double, upper: Double = 0, unit: SearchSizeUnit) {
        self.comparison = comparison
        self.value = value
        self.upper = upper
        self.unit = unit
    }

    /// The bytes an item's size must be over (excluded) and under (excluded), either open.
    public var bounds: (above: Int64?, below: Int64?) {
        let low = Int64((value * unit.bytes).rounded())
        switch comparison {
        case .larger: return (low, nil)
        case .smaller: return (nil, low)
        case .between:
            let high = Int64((upper * unit.bytes).rounded())
            return (min(low, high) - 1, max(low, high) + 1)
        }
    }
}

/// A picture's longer side as set.
public struct SearchPixelRule: Equatable, Codable, Sendable, Hashable {
    /// Larger or smaller; "between" isn't offered.
    public var larger: Bool
    public var pixels: Int

    public init(larger: Bool, pixels: Int) {
        self.larger = larger
        self.pixels = pixels
    }

    public func holds(_ side: Int) -> Bool { larger ? side > pixels : side < pixels }
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
    /// From the start of the first day to the end of the second.
    case between(Date, Date)

    /// What the editor's first menu names, in its order.
    public enum Kind: String, CaseIterable, Sendable {
        case today, yesterday, thisWeek, thisMonth, thisYear, withinLast, moreThanAgo, before, after, between

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
        case .moreThanAgo, .before: true
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
        default: true
        }
    }

    /// Whether checking it reads more of an item than its folder lists: its attributes, tags or contents.
    public var readsEachItem: Bool {
        switch self {
        case .kind, .fileExtension, .skipFolders: false
        case .attribute(.hidden, _), .attribute(.symbolicLink, _): false
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
            case .larger: return "Size is larger than \(number(rule.value, locale)) \(rule.unit.label)"
            case .smaller: return "Size is smaller than \(number(rule.value, locale)) \(rule.unit.label)"
            case .between:
                return
                    "Size is between \(number(rule.value, locale)) and \(number(rule.upper, locale)) \(rule.unit.label)"
            }
        case .pictureSize(let rule):
            return
                "Picture is \(rule.larger ? "larger" : "smaller") than \(FormatLocale.count(rule.pixels, locale: locale)) px"
        case .date(let field, let rule):
            return field.chipLabel + " " + dateWords(rule, locale: locale)
        case .tags(let tags, let all):
            return tags.isEmpty ? "Tagged with any tag" : "Tagged " + tags.joined(separator: all ? " and " : " or ")
        case .attribute(let attribute, let value):
            return attribute.chip(is: value)
        case .skipFolders(let names):
            return names.isEmpty ? "Skipping no folders" : "Skipping " + names.joined(separator: ", ")
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
