// The groups a folder's items are shown in (View ▸ Group By): which group each item is in, and the groups' order
import Foundation
import UniformTypeIdentifiers

/// One group as the views show it: its header and the items under it.
public struct EntryGroup: Equatable, Sendable {
    /// Stays the same while the group means the same items ("today", "month-2026-10", "kind-images"): what a
    /// collapsed group is remembered by.
    public var id: String
    /// The header's name: "Today", "October", "1 to 10 MB", "E".
    public var title: String
    /// What the header adds faintly: the days of Previous 7 Days and Previous 30 Days ("Nov 13–18").
    public var detail: String?

    public init(id: String, title: String, detail: String? = nil) {
        self.id = id
        self.title = title
        self.detail = detail
    }
}

/// The group an item is in, and where the group comes among the others.
public struct EntryGroupKey: Equatable, Sendable {
    public enum Rank: Equatable, Sendable {
        /// A date's or a size's: groups are compared by it.
        case number(Int64)
        /// A name's, a kind's, a tag's or a folder's: compared as words.
        case text(String)
    }

    public var group: EntryGroup
    public var rank: Rank
    /// The group of the items without the value (Never Opened, Not Measured, No Tags): last in either direction.
    public var isLast = false
    /// The Folders group, which Folders First puts first.
    public var isFolders = false

    public init(group: EntryGroup, rank: Rank, isLast: Bool = false, isFolders: Bool = false) {
        self.group = group
        self.rank = rank
        self.isLast = isLast
        self.isFolders = isFolders
    }
}

/// A group with the positions of its items in the list it was made from, in that list's order.
public struct EntryGroupSpan: Equatable, Sendable {
    public var group: EntryGroup
    public var positions: [Int]

    public init(group: EntryGroup, positions: [Int]) {
        self.group = group
        self.positions = positions
    }
}

public enum EntryGroups {
    /// The groups of a list already in its order (sorted, Folders First applied): each item goes into its key's group,
    /// keeping the list's order inside it, so Sort By orders the items within each group. The groups themselves come
    /// in their field's own fixed order, whatever the sort: dates the newest first, sizes the smallest first, words A
    /// to Z; the groups without a value last, and with Folders First the Folders group first.
    public static func make(
        keys: [EntryGroupKey], groupBy: GroupByPreference, foldersFirst: Bool, order: NameOrder = .current
    ) -> [EntryGroupSpan] {
        var spans: [EntryGroupSpan] = []
        var keyOf: [EntryGroupKey] = []
        var indexOf: [String: Int] = [:]
        for (position, key) in keys.enumerated() {
            if let index = indexOf[key.group.id] {
                spans[index].positions.append(position)
            } else {
                indexOf[key.group.id] = spans.count
                spans.append(EntryGroupSpan(group: key.group, positions: [position]))
                keyOf.append(key)
            }
        }
        let ascending = ascends(groupBy)
        let ordered = spans.indices.sorted { left, right in
            let l = keyOf[left]
            let r = keyOf[right]
            if l.isLast != r.isLast { return r.isLast }
            if foldersFirst, l.isFolders != r.isFolders { return l.isFolders }
            var compared = 0
            switch (l.rank, r.rank) {
            case (.number(let a), .number(let b)): compared = a == b ? 0 : (a < b ? -1 : 1)
            case (.text(let a), .text(let b)): compared = order.compareWords(a, b)
            case (.number, .text): compared = -1
            case (.text, .number): compared = 1
            }
            if !ascending { compared = -compared }
            return compared != 0 ? compared < 0 : left < right
        }
        return ordered.map { spans[$0] }
    }

    /// Dates come the newest first; sizes the smallest first; names, kinds, tags and folders A to Z.
    static func ascends(_ groupBy: GroupByPreference) -> Bool {
        switch groupBy {
        case .modified, .created, .lastOpened, .added: false
        case .none, .name, .size, .kind, .tags, .folder: true
        }
    }
}

// MARK: - Dates

/// The groups of a date: Today, Yesterday, Previous 7 Days, Previous 30 Days, each earlier month of this year by name,
/// each earlier year, and Future for a date after today. The days start at midnight in the calendar's time zone,
/// worked out once, so placing an item is a comparison of numbers.
public struct DateGroups: Sendable {
    private let tomorrow: Int64
    private let today: Int64
    private let yesterday: Int64
    private let week: Int64
    private let month: Int64
    private let year: Int64
    private let calendar: Calendar
    /// Where each month of this year starts, January first.
    private let monthStarts: [Int64]
    /// Where each of the hundred years before this one starts, the latest first, with its number.
    private let yearStarts: [(year: Int, start: Int64)]
    private let weekDetail: String
    private let monthDetail: String

    public static let monthNames = [
        "January", "February", "March", "April", "May", "June", "July", "August", "September", "October",
        "November", "December",
    ]
    static let shortMonthNames = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    public init(now: Date, calendar: Calendar = .autoupdatingCurrent) {
        self.calendar = calendar
        let startOfToday = calendar.startOfDay(for: now)
        // Calendar days, not 24-hour steps: days around a daylight saving change are 23 or 25 hours.
        func daysFromToday(_ days: Int) -> Date {
            calendar.date(byAdding: .day, value: days, to: startOfToday) ?? startOfToday
        }
        let startOfYear = calendar.dateInterval(of: .year, for: now)?.start ?? startOfToday
        tomorrow = daysFromToday(1).epochMilliseconds64
        today = startOfToday.epochMilliseconds64
        yesterday = daysFromToday(-1).epochMilliseconds64
        week = daysFromToday(-7).epochMilliseconds64
        month = daysFromToday(-30).epochMilliseconds64
        year = startOfYear.epochMilliseconds64
        let thisYear = calendar.component(.year, from: now)
        monthStarts = (1...12).map {
            (calendar.date(from: DateComponents(year: thisYear, month: $0)) ?? startOfYear).epochMilliseconds64
        }
        yearStarts = (1...100).compactMap { back in
            calendar.date(from: DateComponents(year: thisYear - back)).map { (thisYear - back, $0.epochMilliseconds64) }
        }
        weekDetail = Self.range(daysFromToday(-7), daysFromToday(-2), calendar: calendar)
        monthDetail = Self.range(daysFromToday(-30), daysFromToday(-8), calendar: calendar)
    }

    /// The group of a date in milliseconds since 1970; nil goes in the group of items without it, named `missing`
    /// ("Never Opened", "No Date Added").
    public func key(milliseconds: Int64?, missing: String) -> EntryGroupKey {
        guard let ms = milliseconds else {
            return EntryGroupKey(group: EntryGroup(id: "date-none", title: missing), rank: .number(0), isLast: true)
        }
        if ms >= tomorrow {
            return EntryGroupKey(group: EntryGroup(id: "future", title: "Future"), rank: .number(.max))
        }
        if ms >= today { return EntryGroupKey(group: EntryGroup(id: "today", title: "Today"), rank: .number(today)) }
        if ms >= yesterday {
            return EntryGroupKey(group: EntryGroup(id: "yesterday", title: "Yesterday"), rank: .number(yesterday))
        }
        if ms >= week {
            return EntryGroupKey(
                group: EntryGroup(id: "previous-7", title: "Previous 7 Days", detail: weekDetail), rank: .number(week))
        }
        if ms >= month {
            return EntryGroupKey(
                group: EntryGroup(id: "previous-30", title: "Previous 30 Days", detail: monthDetail),
                rank: .number(month))
        }
        if ms >= year {
            let month = monthStarts.lastIndex { $0 <= ms } ?? 0
            return EntryGroupKey(
                group: EntryGroup(id: "month-\(month + 1)", title: Self.monthNames[month]),
                rank: .number(monthStarts[month]))
        }
        if let found = yearStarts.first(where: { $0.start <= ms }) {
            return EntryGroupKey(
                group: EntryGroup(id: "year-\(found.year)", title: String(found.year)), rank: .number(found.start))
        }
        // More than a hundred years back.
        let date = Date(timeIntervalSince1970: Double(ms) / 1000)
        let yearNumber = calendar.component(.year, from: date)
        let start = calendar.date(from: DateComponents(year: yearNumber)) ?? date
        return EntryGroupKey(
            group: EntryGroup(id: "year-\(yearNumber)", title: String(yearNumber)),
            rank: .number(start.epochMilliseconds64))
    }

    /// "Nov 13–18", or "Oct 21 – Nov 12" across two months.
    static func range(_ first: Date, _ last: Date, calendar: Calendar) -> String {
        let a = calendar.dateComponents([.month, .day], from: first)
        let b = calendar.dateComponents([.month, .day], from: last)
        let firstMonth = shortMonthNames[max(1, min(12, a.month ?? 1)) - 1]
        let lastMonth = shortMonthNames[max(1, min(12, b.month ?? 1)) - 1]
        if a.month == b.month { return "\(firstMonth) \(a.day ?? 1)–\(b.day ?? 1)" }
        return "\(firstMonth) \(a.day ?? 1) – \(lastMonth) \(b.day ?? 1)"
    }
}

extension Date {
    /// Milliseconds since 1970, whole.
    var epochMilliseconds64: Int64 { Int64((timeIntervalSince1970 * 1000).rounded(.down)) }
}

// MARK: - Sizes

/// The groups of a size, in steps of 1,000 as sizes are shown: Zero bytes, Under 100 KB, 100 KB to 1 MB, 1 to 10 MB,
/// 10 to 100 MB, 100 MB to 1 GB, 1 to 10 GB, Over 10 GB; Not Measured for a folder whose size isn't known yet.
public enum SizeGroups {
    static let bands: [(below: Int64, id: String, title: String)] = [
        (100_000, "size-1", "Under 100 KB"),
        (1_000_000, "size-2", "100 KB to 1 MB"),
        (10_000_000, "size-3", "1 to 10 MB"),
        (100_000_000, "size-4", "10 to 100 MB"),
        (1_000_000_000, "size-5", "100 MB to 1 GB"),
        (10_000_000_000, "size-6", "1 to 10 GB"),
    ]

    public static func key(bytes: Int64?) -> EntryGroupKey {
        guard let bytes else {
            return EntryGroupKey(
                group: EntryGroup(id: "size-none", title: "Not Measured"), rank: .number(0), isLast: true)
        }
        if bytes <= 0 { return EntryGroupKey(group: EntryGroup(id: "size-0", title: "Zero bytes"), rank: .number(0)) }
        for (rank, band) in bands.enumerated() where bytes < band.below {
            return EntryGroupKey(group: EntryGroup(id: band.id, title: band.title), rank: .number(Int64(rank + 1)))
        }
        return EntryGroupKey(
            group: EntryGroup(id: "size-7", title: "Over 10 GB"), rank: .number(Int64(bands.count + 1)))
    }
}

// MARK: - Names

/// The group of a name: its first letter without case or accents ("É" under "E"), 0–9 for a digit, # for anything else.
public enum NameGroups {
    public static func key(name: String, locale: Locale = .current) -> EntryGroupKey {
        guard let first = name.first else { return other }
        if first.isNumber, first.isASCII { return digits }
        guard first.isLetter else { return other }
        let letter = String(first).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
            .uppercased(with: locale)
        return EntryGroupKey(group: EntryGroup(id: "name-\(letter)", title: letter), rank: .text(letter))
    }

    // Digits before the letters, as names sort; anything else after them in either direction.
    private static let digits = EntryGroupKey(group: EntryGroup(id: "name-digits", title: "0–9"), rank: .text(""))
    private static let other = EntryGroupKey(
        group: EntryGroup(id: "name-other", title: "#"), rank: .text(""), isLast: true)
}

// MARK: - Kinds

/// The broad kinds items are grouped by: an item's type, from its extension, put in one of a few groups.
public enum KindGroup: String, CaseIterable, Sendable {
    case applications, archives, diskImages, documents, folders, images, movies, music, pdfs, presentations
    case sourceCode, spreadsheets, other

    public var title: String {
        switch self {
        case .applications: "Applications"
        case .archives: "Archives"
        case .diskImages: "Disk Images"
        case .documents: "Documents"
        case .folders: "Folders"
        case .images: "Images"
        case .movies: "Movies"
        case .music: "Music"
        case .pdfs: "PDFs"
        case .presentations: "Presentations"
        case .sourceCode: "Source Code"
        case .spreadsheets: "Spreadsheets"
        case .other: "Other"
        }
    }

    public var key: EntryGroupKey {
        EntryGroupKey(
            group: EntryGroup(id: "kind-\(rawValue)", title: title), rank: .text(title), isLast: self == .other,
            isFolders: self == .folders)
    }

    /// The kind of an item: a folder (or a link to one), else by its extension's type.
    public static func of(fileExtension: String, isFolder: Bool) -> KindGroup {
        if isFolder { return .folders }
        let lowered = fileExtension.lowercased()
        if lowered == "app" { return .applications }
        guard !lowered.isEmpty, let type = UTType(filenameExtension: lowered) else { return .other }
        let checks: [(UTType, KindGroup)] = [
            (.application, .applications), (.applicationBundle, .applications), (.pdf, .pdfs),
            (.diskImage, .diskImages), (.archive, .archives), (.image, .images), (.movie, .movies),
            (.audio, .music), (.presentation, .presentations), (.spreadsheet, .spreadsheets),
            (.sourceCode, .sourceCode), (.script, .sourceCode), (.text, .documents),
            (.compositeContent, .documents),
        ]
        for (parent, group) in checks where type.conforms(to: parent) { return group }
        return .other
    }
}

/// Each extension's kind, looked up once for a run of grouping.
public struct KindGroupCache {
    private var known: [String: KindGroup] = [:]

    public init() {}

    public mutating func group(fileExtension: String, isFolder: Bool) -> KindGroup {
        if isFolder { return .folders }
        if let group = known[fileExtension] { return group }
        let group = KindGroup.of(fileExtension: fileExtension, isFolder: false)
        known[fileExtension] = group
        return group
    }
}

// MARK: - Tags and folders

public enum TagGroups {
    /// The group of an item's first tag; No Tags last.
    public static func key(firstTag: String?) -> EntryGroupKey {
        guard let tag = firstTag, !tag.isEmpty else {
            return EntryGroupKey(group: EntryGroup(id: "tag-none", title: "No Tags"), rank: .text(""), isLast: true)
        }
        return EntryGroupKey(group: EntryGroup(id: "tag-\(tag)", title: tag), rank: .text(tag))
    }
}

public enum FolderGroups {
    /// The group of a search result: the folder it is in, named as the Folder column names it ("Taxes › 2025"), and
    /// `parent`, its path, telling folders apart. The folder searched comes first.
    public static func key(label: String, parent: String, isSearchedFolder: Bool) -> EntryGroupKey {
        EntryGroupKey(
            group: EntryGroup(id: "folder-\(parent)", title: label), rank: .text(isSearchedFolder ? "" : label))
    }
}
