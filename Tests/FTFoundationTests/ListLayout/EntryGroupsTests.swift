import FTTestSupport
import Foundation
import Testing

@testable import FTFoundation

struct EntryGroupsTests {
    static func calendar(_ zone: String = "Europe/Istanbul") -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    static func ms(_ text: String, zone: String = "Europe/Istanbul") -> Int64 {
        AppClock.parse(text, timeZone: TimeZone(identifier: zone)!)!.epochMilliseconds64
    }

    // Friday 20 November 2026, 3:40 PM.
    static let now = AppClock.parse("2026-11-20T15:40", timeZone: TimeZone(identifier: "Europe/Istanbul")!)!
    static let dates = DateGroups(now: now, calendar: calendar())

    static func title(_ text: String) -> String {
        dates.key(milliseconds: ms(text), missing: "No Date").group.title
    }

    // MARK: Dates

    @Test func datesFallInFindersGroupsCountedFromMidnight() {
        #expect(Self.title("2026-11-21T00:00") == "Future")
        #expect(Self.title("2026-11-20T23:59") == "Today")
        #expect(Self.title("2026-11-20T00:00") == "Today")
        #expect(Self.title("2026-11-19T23:59") == "Yesterday")
        #expect(Self.title("2026-11-19T00:00") == "Yesterday")
        #expect(Self.title("2026-11-18T23:59") == "Previous 7 Days")
        #expect(Self.title("2026-11-13T00:00") == "Previous 7 Days")
        #expect(Self.title("2026-11-12T23:59") == "Previous 30 Days")
        #expect(Self.title("2026-10-21T00:00") == "Previous 30 Days")
        #expect(Self.title("2026-10-20T23:59") == "October")
        #expect(Self.title("2026-10-01T00:00") == "October")
        #expect(Self.title("2026-01-01T00:00") == "January")
        #expect(Self.title("2025-12-31T23:59") == "2025")
        #expect(Self.title("1999-06-01T12:00") == "1999")
    }

    @Test func theTwoRelativeGroupsSayTheirDays() {
        let week = Self.dates.key(milliseconds: Self.ms("2026-11-15T10:00"), missing: "")
        #expect(week.group.detail == "Nov 13–18")
        let month = Self.dates.key(milliseconds: Self.ms("2026-11-01T10:00"), missing: "")
        #expect(month.group.detail == "Oct 21 – Nov 12")
        #expect(Self.dates.key(milliseconds: Self.ms("2026-11-20T10:00"), missing: "").group.detail == nil)
    }

    @Test func anItemWithoutTheDateIsInTheMissingGroupLast() {
        let key = Self.dates.key(milliseconds: nil, missing: "Never Opened")
        #expect(key.group.title == "Never Opened")
        #expect(key.isLast)
    }

    // On 5 January the thirty days reach into December, and the rest of December is under the year before.
    @Test func earlyInTheYearThereAreNoMonths() {
        let now = AppClock.parse("2027-01-05T09:00", timeZone: TimeZone(identifier: "Europe/Istanbul")!)!
        let dates = DateGroups(now: now, calendar: Self.calendar())
        func title(_ text: String) -> String { dates.key(milliseconds: Self.ms(text), missing: "").group.title }
        #expect(title("2027-01-01T08:00") == "Previous 7 Days")
        #expect(title("2026-12-20T08:00") == "Previous 30 Days")
        #expect(title("2026-12-05T23:59") == "2026")
        #expect(dates.key(milliseconds: Self.ms("2026-12-29T08:00"), missing: "").group.detail == "Dec 29 – Jan 3")
    }

    // The day after the clocks go back is 25 hours long: midnight is still where Yesterday starts.
    @Test func daysAroundADaylightSavingChangeStartAtMidnight() {
        let zone = "America/New_York"
        let now = AppClock.parse("2026-11-02T08:00", timeZone: TimeZone(identifier: zone)!)!
        let dates = DateGroups(now: now, calendar: Self.calendar(zone))
        func title(_ text: String) -> String {
            dates.key(milliseconds: Self.ms(text, zone: zone), missing: "").group.title
        }
        #expect(title("2026-11-01T00:00") == "Yesterday")
        #expect(title("2026-10-31T23:59") == "Previous 7 Days")
        #expect(title("2026-11-02T00:00") == "Today")
    }

    // MARK: Order

    static func keys(_ titles: [String]) -> [EntryGroupKey] {
        titles.map { Self.dates.key(milliseconds: Self.ms($0), missing: "No Date") }
    }

    static func titles(_ spans: [EntryGroupSpan]) -> [String] { spans.map(\.group.title) }

    @Test func datesComeNewestFirstAndKeepTheListsOrderInside() {
        let keys = Self.keys(["2025-03-01", "2026-11-20T09:00", "2026-11-19", "2026-11-20T08:00", "2026-10-02"])
        let spans = EntryGroups.make(
            keys: keys, groupBy: .modified, foldersFirst: true)
        #expect(Self.titles(spans) == ["Today", "Yesterday", "October", "2025"])
        #expect(spans[0].positions == [1, 3])
    }

    // The groups' order is the grouping's own: Sort By orders the items inside each group, not the groups.
    @Test func dateGroupsComeNewestFirstWithoutTheDateLast() {
        var keys = Self.keys(["2025-03-01", "2026-11-20T09:00", "2026-11-19"])
        keys.append(Self.dates.key(milliseconds: nil, missing: "Never Opened"))
        let spans = EntryGroups.make(keys: keys, groupBy: .modified, foldersFirst: true)
        #expect(Self.titles(spans) == ["Today", "Yesterday", "2025", "Never Opened"])
    }

    @Test func foldersFirstPutsTheFoldersGroupFirst() {
        let keys = [KindGroup.images.key, KindGroup.folders.key, KindGroup.applications.key, KindGroup.other.key]
        let first = EntryGroups.make(keys: keys, groupBy: .kind, foldersFirst: true)
        #expect(Self.titles(first) == ["Folders", "Applications", "Images", "Other"])
        let mixed = EntryGroups.make(keys: keys, groupBy: .kind, foldersFirst: false)
        #expect(Self.titles(mixed) == ["Applications", "Folders", "Images", "Other"])
    }

    // MARK: Sizes, names, kinds, tags

    @Test func sizesFallInBandsOfAThousand() {
        func title(_ bytes: Int64?) -> String { SizeGroups.key(bytes: bytes).group.title }
        #expect(title(0) == "Zero bytes")
        #expect(title(1) == "Under 100 KB")
        #expect(title(99_999) == "Under 100 KB")
        #expect(title(100_000) == "100 KB to 1 MB")
        #expect(title(999_999) == "100 KB to 1 MB")
        #expect(title(1_000_000) == "1 to 10 MB")
        #expect(title(640_000_000) == "100 MB to 1 GB")
        #expect(title(3_400_000_000) == "1 to 10 GB")
        #expect(title(10_000_000_000) == "Over 10 GB")
        #expect(title(nil) == "Not Measured")
        #expect(SizeGroups.key(bytes: nil).isLast)
        let spans = EntryGroups.make(
            keys: [1, 2_000_000, nil, 0, 5_000_000_000].map { SizeGroups.key(bytes: $0) }, groupBy: .size,
            foldersFirst: true)
        #expect(Self.titles(spans) == ["Zero bytes", "Under 100 KB", "1 to 10 MB", "1 to 10 GB", "Not Measured"])
    }

    @Test func namesGroupByTheirFirstLetterWithoutCaseOrAccents() {
        let english = Locale(identifier: "en_US")
        func title(_ name: String) -> String { NameGroups.key(name: name, locale: english).group.title }
        #expect(title("Élan.txt") == "E")
        #expect(title("eagle") == "E")
        #expect(title("2026 taxes") == "0–9")
        #expect(title("_build") == "#")
        #expect(title(".hidden") == "#")
        let spans = EntryGroups.make(
            keys: ["zeta", "_x", "alpha", "9lives", "Beta"].map { NameGroups.key(name: $0, locale: english) },
            groupBy: .name, foldersFirst: true)
        #expect(Self.titles(spans) == ["0–9", "A", "B", "Z", "#"])
    }

    @Test func kindsComeFromTheExtensionsType() {
        func kind(_ ext: String, folder: Bool = false) -> KindGroup {
            KindGroup.of(fileExtension: ext, isFolder: folder)
        }
        #expect(kind("pdf") == .pdfs)
        #expect(kind("JPG") == .images)
        #expect(kind("heic") == .images)
        #expect(kind("mov") == .movies)
        #expect(kind("m4a") == .music)
        #expect(kind("key") == .presentations)
        #expect(kind("numbers") == .spreadsheets)
        #expect(kind("swift") == .sourceCode)
        #expect(kind("zip") == .archives)
        #expect(kind("dmg") == .diskImages)
        #expect(kind("app") == .applications)
        #expect(kind("txt") == .documents)
        #expect(kind("docx") == .documents)
        #expect(kind("") == .other)
        #expect(kind("qqqzz") == .other)
        #expect(kind("anything", folder: true) == .folders)
    }

    @Test func tagsGroupByTheFirstTagNoTagsLast() {
        let spans = EntryGroups.make(
            keys: ["Work", nil, "Home", "Work"].map { TagGroups.key(firstTag: $0) }, groupBy: .tags,
            foldersFirst: true)
        #expect(Self.titles(spans) == ["Home", "Work", "No Tags"])
        #expect(spans[1].positions == [0, 3])
    }

    // Grouping a large folder is one pass over its items: the keys are made once each and compared as numbers.
    @Test func groupsAHundredAndFiftyThousandItemsQuickly() {
        let count = 150_000
        let start = Self.ms("2020-01-01T00:00")
        let step = (Self.now.epochMilliseconds64 - start) / Int64(count)
        let (spans, seconds) = CPUTime.measureThread {
            let keys = (0..<count).map { Self.dates.key(milliseconds: start + Int64($0) * step, missing: "") }
            return EntryGroups.make(keys: keys, groupBy: .modified, foldersFirst: true)
        }
        #expect(spans.reduce(0) { $0 + $1.positions.count } == count)
        #expect(spans.first?.group.title == "Today")
        #expect(seconds < 1)
    }

    // MARK: The setting

    @Test func eachFieldIsAnItemOfViewGroupBy() {
        for field in GroupByPreference.allCases {
            #expect(GroupByPreference(command: field.command) == field)
        }
        #expect(GroupByPreference(command: .sortByName) == nil)
        #expect(
            GroupByPreference.menuOrder.map(\.title) == [
                "Name", "Date Modified", "Date Created", "Date Last Opened", "Date Added", "Size", "Kind", "Tags",
            ])
        #expect(GroupByPreference.searchMenuOrder == [.name, .folder, .kind])
        #expect(GroupByPreference.allCases.filter(\.isDate) == [.modified, .created, .lastOpened, .added])
        #expect(!GroupByPreference.folder.isForFolders && GroupByPreference.folder.isForSearch)
        #expect(!GroupByPreference.size.isForSearch && GroupByPreference.none.isForSearch)
        #expect(GroupByPreference.saved(.folder, search: false) == nil)
        #expect(GroupByPreference.saved(.size, search: true) == nil)
        #expect(GroupByPreference.saved(.size, search: false) == .size)
        #expect(GroupByPreference.saved(GroupByPreference.none, search: false) == nil)
    }

    // A search result's group is the folder it is in, the folder searched first, the others A to Z.
    @Test func searchResultsGroupByTheirFolderTheSearchedOneFirst() {
        let keys = [
            FolderGroups.key(label: "Taxes", parent: "/r/Taxes", isSearchedFolder: false),
            FolderGroups.key(label: "Documents", parent: "/r", isSearchedFolder: true),
            FolderGroups.key(label: "Archive", parent: "/r/Archive", isSearchedFolder: false),
            FolderGroups.key(label: "Taxes", parent: "/r/Taxes", isSearchedFolder: false),
        ]
        let spans = EntryGroups.make(keys: keys, groupBy: .folder, foldersFirst: false)
        #expect(Self.titles(spans) == ["Documents", "Archive", "Taxes"])
        #expect(spans[2].positions == [0, 3])
    }

    // Each extension's kind is looked up once in a run; a folder is a folder whatever its name.
    @Test func kindsAreLookedUpOncePerExtension() {
        var cache = KindGroupCache()
        #expect(cache.group(fileExtension: "pdf", isFolder: false) == .pdfs)
        #expect(cache.group(fileExtension: "pdf", isFolder: false) == .pdfs)
        #expect(cache.group(fileExtension: "pdf", isFolder: true) == .folders)
        #expect(KindGroup.allCases.allSatisfy { !$0.title.isEmpty })
        #expect(KindGroup.other.key.isLast && KindGroup.folders.key.isFolders)
    }

    // More than a hundred years back is still its own year.
    @Test func aVeryOldDateIsInItsYear() {
        #expect(Self.title("1850-03-01T12:00") == "1850")
    }

    // The command palette shows Group By's items with the toolbar's Group symbol.
    @Test func thePaletteShowsGroupBysItemsWithItsSymbol() {
        for field in GroupByPreference.allCases {
            let id = ShortcutCommandID(rawValue: field.command.rawValue)
            #expect(id.flatMap(CommandPalette.icon) == .groupBy, "\(field)")
        }
    }
}
