// The search syntax beyond words and conditions: a size to its last digit, permissions, and `!` for not, as read, as
// worded, and as the list under the field offers them.
import FTFoundation
import Foundation
import Testing

@Suite struct SearchSyntaxTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func query(_ text: String) -> SearchQuery { SearchQuery(text, calendar: calendar) }

    private func rule(_ text: String) -> SearchSizeRule? {
        guard case .size(let rule)? = query("size:" + text).conditions.first else { return nil }
        return rule
    }

    /// Whether a file of `size` bytes meets the rule `text` reads as.
    private func holds(_ text: String, _ size: Int64) -> Bool {
        guard let bounds = rule(text)?.bounds else { return false }
        return (bounds.above.map { size > $0 } ?? true) && (bounds.below.map { size < $0 } ?? true)
    }

    /// The sizes from `from` up to `upTo` meet `text`, and the byte on either side doesn't.
    private func expectRange(
        _ text: String, from: Int64, upTo: Int64, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(!holds(text, from - 1), "\(text) at \(from - 1)", sourceLocation: sourceLocation)
        #expect(holds(text, from), "\(text) at \(from)", sourceLocation: sourceLocation)
        #expect(holds(text, upTo - 1), "\(text) at \(upTo - 1)", sourceLocation: sourceLocation)
        #expect(!holds(text, upTo), "\(text) at \(upTo)", sourceLocation: sourceLocation)
    }

    // MARK: A size alone

    // A size alone is that size to its last digit: from it, up to one more of that digit.
    @Test func aSizeAloneIsItsLastDigit() {
        expectRange("1mb", from: 1_000_000, upTo: 2_000_000)
        expectRange("1.5mb", from: 1_500_000, upTo: 1_600_000)
        expectRange("2.11kb", from: 2110, upTo: 2120)
        expectRange("1000b", from: 1000, upTo: 1001)
        expectRange("1b", from: 1, upTo: 2)
        expectRange("10mb", from: 10_000_000, upTo: 11_000_000)
        expectRange("0.5mb", from: 500_000, upTo: 600_000)
        expectRange("1.25gb", from: 1_250_000_000, upTo: 1_260_000_000)
        expectRange("1k", from: 1000, upTo: 2000)
        expectRange("3m", from: 3_000_000, upTo: 4_000_000)
        expectRange("2g", from: 2_000_000_000, upTo: 3_000_000_000)
    }

    // Digits typed after the point count, zeros too, though the number alone loses them.
    @Test func trailingZerosKeepTheirPlaces() {
        expectRange("2.10kb", from: 2100, upTo: 2110)
        expectRange("2.1kb", from: 2100, upTo: 2200)
        expectRange("1.50mb", from: 1_500_000, upTo: 1_510_000)
        expectRange("1.0mb", from: 1_000_000, upTo: 1_100_000)
        #expect(rule("2.10kb")?.places == 2)
        #expect(rule("2.1kb")?.places == nil)
        #expect(rule("1.0mb")?.places == 1)
    }

    // Decimals a computer can't hold exactly still count whole bytes: 2.11 × 1000 is 2110.0000000000002.
    @Test func decimalsAreCountedInWholeBytes() {
        expectRange("3.3mb", from: 3_300_000, upTo: 3_400_000)
        expectRange("0.1kb", from: 100, upTo: 200)
        expectRange("0.7kb", from: 700, upTo: 800)
        expectRange("4.35mb", from: 4_350_000, upTo: 4_360_000)
        expectRange("9.99kb", from: 9990, upTo: 10_000)
        expectRange("1.001mb", from: 1_001_000, upTo: 1_002_000)
    }

    @Test func largerSmallerAndBetweenAreAsTyped() {
        #expect(!holds(">1mb", 1_000_000))
        #expect(holds(">1mb", 1_000_001))
        #expect(holds("<1mb", 999_999))
        #expect(!holds("<1mb", 1_000_000))
        // Between takes both ends.
        #expect(holds("1mb..2mb", 1_000_000))
        #expect(holds("1mb..2mb", 2_000_000))
        #expect(!holds("1mb..2mb", 2_000_001))
        #expect(!holds("1mb..2mb", 999_999))
        #expect(holds("500kb..2mb", 500_000))
        #expect(holds("2mb..500kb", 1_000_000))
        #expect(rule(">1mb")?.comparison == .larger)
        #expect(rule("<1mb")?.comparison == .smaller)
        #expect(rule("1mb")?.comparison == .equal)
        #expect(rule("1mb..2mb")?.comparison == .between)
    }

    // Two sizes are both asked for: larger than one and smaller than the other is between them.
    @Test func twoSizesAreBothAskedFor() {
        let both = query("size:>1mb size:<2mb").conditions
        #expect(both.count == 2)
        #expect(query("size:1mb size:1.5mb").conditions.count == 2)
    }

    @Test func sizesThatCantBeRead() {
        for text in [
            "size:0mb", "size:0", "size:>0b", "size:-1mb", "size:>-1mb", "size:1tb", "size:mb", "size:1.mb.",
            "size:1mb..", "size:..1mb", "size:1mb..2", "size:1 mb", "size:1.2.3mb", "size:>", "size:<", "size:><1mb",
            "size:1mbb", "size:1kib", "size:one",
        ] {
            #expect(query(text).hasUnfinished, "\(text)")
            #expect(query(text).conditions.isEmpty, "\(text)")
        }
    }

    @Test func sizesSayWhatTheyMean() {
        func words(_ text: String) -> String? {
            query("size:" + text).conditions.first.map { SearchConditionText.chip($0) }
        }
        #expect(words("1mb") == "Size is 1 MB to under 2 MB")
        #expect(words("1.5mb") == "Size is 1.5 MB to under 1.6 MB")
        #expect(words("2.11kb") == "Size is 2.11 KB to under 2.12 KB")
        #expect(words("1000b") == "Size is 1,000 bytes")
        #expect(words("1b") == "Size is 1 byte")
        #expect(words(">1b") == "Size is larger than 1 byte")
        #expect(words("<5b") == "Size is smaller than 5 bytes")
        #expect(words(">10mb") == "Size is larger than 10 MB")
        #expect(words("1mb..10mb") == "Size is between 1 and 10 MB")
    }

    // MARK: Permissions

    @Test func permissionsAreDigitsOrLetters() {
        let modes: [(String, UInt16)] = [
            ("755", 0o755), ("0755", 0o755), ("644", 0o644), ("0644", 0o644), ("4755", 0o4755), ("2755", 0o2755),
            ("1777", 0o1777), ("7777", 0o7777), ("000", 0), ("777", 0o777), ("rwxr-xr-x", 0o755),
            ("rw-r--r--", 0o644), ("-rw-r--r--", 0o644), ("drwxr-xr-x", 0o755), ("rwsr-xr-x", 0o4755),
            ("rwSr--r--", 0o4644), ("rwxr-sr-x", 0o2755), ("rwxr-Sr-x", 0o2745), ("rwxrwxrwt", 0o1777),
            ("rw-rw-rwT", 0o1666), ("---------", 0), ("r-xr-xr-x", 0o555),
        ]
        for (text, mode) in modes { #expect(SearchPermissions.mode(text) == mode, "\(text)") }
        for text in [
            "800", "75", "7", "77777", "abc", "", "rwx", "rwxr-xr-", "rwxr-xr-xx", "rwxr-xr-y", "wrx------",
            "rwsr-xr-s", "rwtr-xr-x", "RWXR-XR-X", "rwx r-x r-x", "0o755", "-755", "7a5",
        ] {
            #expect(SearchPermissions.mode(text) == nil, "\(text)")
        }
    }

    @Test func permissionsAreWrittenAsLsWritesThem() {
        #expect(SearchPermissions.letters(0o755) == "rwxr-xr-x")
        #expect(SearchPermissions.letters(0o644) == "rw-r--r--")
        #expect(SearchPermissions.letters(0o4755) == "rwsr-xr-x")
        #expect(SearchPermissions.letters(0o4644) == "rwSr--r--")
        #expect(SearchPermissions.letters(0o2755) == "rwxr-sr-x")
        #expect(SearchPermissions.letters(0o1777) == "rwxrwxrwt")
        #expect(SearchPermissions.letters(0o1666) == "rw-rw-rwT")
        #expect(SearchPermissions.octal(0o755) == "755")
        #expect(SearchPermissions.octal(0o4755) == "4755")
        #expect(SearchPermissions.octal(0o7) == "007")
        #expect(SearchPermissions.octal(0) == "000")
        #expect(SearchPermissions.words(0o644) == "644 (rw-r--r--)")
    }

    // A mode written either way reads back as itself.
    @Test func modesReadBackAsThemselves() {
        for mode in modes {
            #expect(SearchPermissions.mode(SearchPermissions.letters(mode)) == mode, "\(mode)")
            #expect(SearchPermissions.octal(mode).flatMap(SearchPermissions.mode) == mode, "\(mode)")
        }
    }

    // MARK: Permissions with `?`, against every mode

    /// A mode's four octal digits, as `stat -f %Mp%Lp` shows them: "0755", "4755".
    private func octalDigits(_ mode: UInt16) -> [Character] { Array(String(format: "%04o", Int(mode))) }

    /// Whether digits typed as `pattern` say `mode`, digit by digit: each typed digit is the mode's or `?`. Three
    /// digits leave the fourth unsaid: any when one of them is `?`, 0 when none is (`755` is one mode, 0755).
    private func digitsSay(_ pattern: String, _ mode: UInt16) -> Bool {
        var typed = Array(pattern)
        if typed.count == 3 { typed.insert(typed.contains("?") ? "?" : "0", at: 0) }
        return zip(typed, octalDigits(mode)).allSatisfy { $0 == "?" || $0 == $1 }
    }

    /// The letters `ls -l` shows for a mode, written here from `ls`'s own rules rather than the app's.
    private func lsLetters(_ mode: UInt16) -> [Character] {
        func has(_ bit: UInt16) -> Bool { mode & bit != 0 }
        let owner: [Character] = [
            has(0o400) ? "r" : "-", has(0o200) ? "w" : "-",
            has(0o4000) ? (has(0o100) ? "s" : "S") : (has(0o100) ? "x" : "-"),
        ]
        let group: [Character] = [
            has(0o40) ? "r" : "-", has(0o20) ? "w" : "-",
            has(0o2000) ? (has(0o10) ? "s" : "S") : (has(0o10) ? "x" : "-"),
        ]
        let others: [Character] = [
            has(0o4) ? "r" : "-", has(0o2) ? "w" : "-",
            has(0o1000) ? (has(0o1) ? "t" : "T") : (has(0o1) ? "x" : "-"),
        ]
        return owner + group + others
    }

    /// Whether letters typed as `pattern` say `mode`, letter by letter: each is the mode's or `?`.
    private func lettersSay(_ pattern: String, _ mode: UInt16) -> Bool {
        var typed = Array(pattern)
        if typed.count == 10 { typed.removeFirst() }
        return zip(typed, lsLetters(mode)).allSatisfy { $0 == "?" || $0 == $1 }
    }

    /// Modes worth telling apart: none, the usual ones, and each special bit.
    private let modes: [UInt16] = [
        0o000, 0o600, 0o640, 0o644, 0o700, 0o750, 0o751, 0o755, 0o775, 0o777, 0o1777, 0o2755, 0o4755, 0o6755,
    ]

    // Each pattern finds exactly the modes its own characters say: digits by the mode's octal digits, letters by the
    // letters `ls` shows.
    @Test func patternsFindWhatTheirCharactersSay() throws {
        let digitPatterns = [
            "755", "644", "000", "?5?", "?4?", "??5", "5??", "7??", "??7", "?55", "7?5", "???", "0?5?", "?755", "4???",
            "2?5?", "?7??", "4755", "6755", "1777",
        ]
        for pattern in digitPatterns {
            let permission = try #require(SearchPermissions.permission(pattern), "\(pattern)")
            for mode in modes {
                #expect(permission.holds(mode) == digitsSay(pattern, mode), "\(pattern) and \(String(mode, radix: 8))")
            }
        }
        let letterPatterns = [
            "rwxr-xr-x", "-rw-r--r--", "???r-x???", "???r-s???", "rwx??????", "rws??????", "??????rwx", "??????rwt",
            "r????????", "?????????",
        ]
        for pattern in letterPatterns {
            let permission = try #require(SearchPermissions.permission(pattern), "\(pattern)")
            for mode in modes {
                #expect(permission.holds(mode) == lettersSay(pattern, mode), "\(pattern) and \(String(mode, radix: 8))")
            }
        }
    }

    // The cases worth naming, each said both ways where both can say it.
    @Test func wildcardPermissionsNamed() throws {
        let groupFive = try #require(SearchPermissions.permission("?5?"))
        for mode: UInt16 in [0o755, 0o750, 0o751, 0o4755, 0o2755, 0o1757, 0o7757, 0o057] {
            #expect(groupFive.holds(mode), "?5? and \(String(mode, radix: 8))")
        }
        for mode: UInt16 in [0o644, 0o640, 0o600, 0o745, 0o775, 0o705, 0o777, 0o000, 0o7777] {
            #expect(!groupFive.holds(mode), "?5? and \(String(mode, radix: 8))")
        }
        // In letters, `x` is not `s`: a set-group 2755 shows `r-s`.
        let groupReadRun = try #require(SearchPermissions.permission("???r-x???"))
        #expect(groupReadRun.holds(0o755) && groupReadRun.holds(0o4755) && !groupReadRun.holds(0o2755))
        #expect(try #require(SearchPermissions.permission("???r-s???")).holds(0o2755))
        // A fourth digit says the special digit: `0?5?` has none of them.
        let noSpecial = try #require(SearchPermissions.permission("0?5?"))
        #expect(noSpecial.holds(0o755) && !noSpecial.holds(0o4755) && !noSpecial.holds(0o2755))
        #expect(try #require(SearchPermissions.permission("?755")).holds(0o4755))
        // Three digits without `?` are one mode.
        let exact = try #require(SearchPermissions.permission("755"))
        #expect(modes.filter(exact.holds) == [0o755])
        #expect(modes.filter(try #require(SearchPermissions.permission("4755")).holds) == [0o4755])
        #expect(modes.filter(try #require(SearchPermissions.permission("rwxr-xr-x")).holds) == [0o755])
        // All `?`: anything.
        #expect(modes.allSatisfy(try #require(SearchPermissions.permission("???")).holds))
        #expect(modes.allSatisfy(try #require(SearchPermissions.permission("?????????")).holds))
        for text in ["?", "??", "?????", "7?a", "?8?", "rwx?", "r?x??????x", "*5*", "?5", "x5x", ".5."] {
            #expect(SearchPermissions.permission(text) == nil, "\(text)")
        }
        #expect(SearchPermissions.mode("?5?") == nil)
    }

    @Test func wildcardPermissionsAreWrittenBackAsTyped() {
        func words(_ text: String) -> String? { SearchPermissions.permission(text).map(SearchPermissions.words) }
        #expect(words("?5?") == "?5?")
        #expect(words("7??") == "7??")
        #expect(words("0?5?") == "0?5?")
        #expect(words("?755") == "?755")
        #expect(words("755") == "755 (rwxr-xr-x)")
        #expect(words("4755") == "4755 (rwsr-xr-x)")
        // Letters that no digits say stay letters.
        #expect(words("???r-x???") == "???r-x???")
        #expect(words("r????????") == "r????????")
        #expect(words("rw-r--r-?") == "rw-r--r-?")
    }

    // What is written back reads back as the same permissions.
    @Test func writtenPermissionsReadBack() throws {
        for text in ["755", "4755", "?5?", "0?5?", "7??", "?755", "???r-x???", "r????????", "rw-r--r-?", "rwSr--r--"] {
            let permission = try #require(SearchPermissions.permission(text), "\(text)")
            #expect(
                SearchPermissions.permission(SearchPermissions.letters(permission.mode, mask: permission.mask))
                    == permission || SearchPermissions.octal(permission.mode, mask: permission.mask) != nil, "\(text)")
            if let octal = SearchPermissions.octal(permission.mode, mask: permission.mask) {
                #expect(SearchPermissions.permission(octal) == permission, "\(text) as \(octal)")
            }
        }
    }

    @Test func permissionWords() {
        #expect(query("perm:755").conditions == [.permissions([0o755])])
        #expect(query("perm:?5?").conditions == [.permissions([SearchPermission(mode: 0o050, mask: 0o070)])])
        #expect(query("perm:!?5?").conditions == [.not(.permissions([SearchPermission(mode: 0o050, mask: 0o070)]))])
        #expect(query("perm:?5?,?4?").conditions.count == 1)
        #expect(query("perm:755,644").conditions == [.permissions([0o755, 0o644])])
        #expect(query("perm:rwxr-xr-x").conditions == [.permissions([0o755])])
        // Letters as typed: `S` isn't `s`.
        #expect(query("perm:rwSr--r--").conditions == [.permissions([0o4644])])
        #expect(query("PERM:644").conditions == [.permissions([0o644])])
        #expect(query("perm:755 perm:644").conditions == [.permissions([0o755]), .permissions([0o644])])
        for text in ["perm:", "perm:8", "perm:75", "perm:755,8", "perm:rwx", "perm:,"] {
            #expect(query(text).hasUnfinished, "\(text)")
        }
        #expect(query("perm:755,").conditions == [.permissions([0o755])])
        #expect(
            SearchConditionText.chip(.permissions([0o755, 0o644]))
                == "Permissions are 755 (rwxr-xr-x) or 644 (rw-r--r--)")
    }

    // MARK: Not

    @Test func anExclamationMarkAsksForWhatItDoesntSay() {
        #expect(query("kind:!pdf").conditions == [.not(.kind([.pdf]))])
        #expect(query("kind:!pdf,picture").conditions == [.not(.kind([.pdf, .picture]))])
        #expect(query("ext:!tmp").conditions == [.not(.fileExtension(["tmp"]))])
        #expect(query("ext:!.tmp,log").conditions == [.not(.fileExtension(["tmp", "log"]))])
        #expect(query("tag:!red").conditions == [.not(.tags(["red"], all: false))])
        #expect(query("perm:!777").conditions == [.not(.permissions([0o777]))])
        #expect(query("perm:!rwxrwxrwx").conditions == [.not(.permissions([0o777]))])
    }

    // Before the word, the same as before its value.
    @Test func anExclamationMarkBeforeTheWord() {
        #expect(query("!kind:pdf").conditions == query("kind:!pdf").conditions)
        #expect(query("!tag:Red,blue").conditions == [.not(.tags(["Red", "blue"], all: false))])
        #expect(query("!ext:tmp").conditions == [.not(.fileExtension(["tmp"]))])
        #expect(query("!perm:777").conditions == [.not(.permissions([0o777]))])
        #expect(query("!KIND:PDF").conditions == [.not(.kind([.pdf]))])
        let words = SearchQuery.words("!kind:pdf", calendar: calendar)
        #expect(words.first?.keyLength == 6)
        #expect(words.first?.key == .kind)
    }

    // An attribute's not is its other side: `is:!hidden` is `not:hidden`.
    @Test func anAttributesNotIsItsOtherSide() {
        #expect(query("is:!hidden").conditions == [.attribute(.hidden, is: false)])
        #expect(query("not:!hidden").conditions == [.attribute(.hidden, is: true)])
        #expect(query("!is:locked").conditions == [.attribute(.locked, is: false)])
        #expect(query("!not:locked").conditions == [.attribute(.locked, is: true)])
        #expect(query("is:!hidden").conditions == query("not:hidden").conditions)
    }

    // A skipped folder is already left out; two marks are one too many.
    @Test func notWhereItHasNoMeaning() {
        for text in [
            "skip:!build", "!skip:build", "kind:!!pdf", "!kind:!pdf",
            "!!kind:pdf",
            "kind:!", "kind:!,", "tag:!", "!kind:", "kind:!nothing", "perm:!8", "is:!nothing", "size:!!1mb",
            "!size:!1mb", "modified:!!today", "size:!", "modified:!",
        ] {
            #expect(query(text).hasUnfinished, "\(text)")
            #expect(query(text).conditions.isEmpty, "\(text)")
        }
    }

    // MARK: At least and at most

    // `>=` and `<=` include the size itself, as typed, to the byte; `=>` and `=<` are read the same.
    @Test func atLeastAndAtMostIncludeTheSize() {
        #expect(rule(">=1mb") == SearchSizeRule(comparison: .atLeast, value: 1, unit: .megabytes))
        #expect(rule("<=1mb") == SearchSizeRule(comparison: .atMost, value: 1, unit: .megabytes))
        #expect(rule("=>1mb") == rule(">=1mb"))
        #expect(rule("=<1mb") == rule("<=1mb"))
        #expect(rule(">=1MB") == rule(">=1mb"))
        let edges: [(String, Int64, Bool)] = [
            (">=1mb", 999_999, false), (">=1mb", 1_000_000, true), (">=1mb", 5_000_000_000, true),
            ("<=1mb", 1_000_000, true), ("<=1mb", 1_000_001, false), ("<=1mb", 0, true),
            (">=1000b", 999, false), (">=1000b", 1000, true), ("<=1000b", 1000, true), ("<=1000b", 1001, false),
            (">=2.11kb", 2109, false), (">=2.11kb", 2110, true), ("<=2.11kb", 2110, true), ("<=2.11kb", 2111, false),
            // Part of a byte: at least 1234.5 is 1235 on; at most is to 1234.
            (">=1.2345kb", 1234, false), (">=1.2345kb", 1235, true), ("<=1.2345kb", 1234, true),
            ("<=1.2345kb", 1235, false),
            // `>` and `<` leave the size itself out.
            (">1mb", 1_000_000, false), (">1mb", 1_000_001, true), ("<1mb", 1_000_000, false), ("<1mb", 999_999, true),
        ]
        for (text, size, meets) in edges { #expect(holds(text, size) == meets, "\(text) at \(size)") }
        func words(_ text: String) -> String? { query(text).conditions.first.map { SearchConditionText.chip($0) } }
        #expect(words("size:>=1mb") == "Size is at least 1 MB")
        #expect(words("size:<=500kb") == "Size is at most 500 KB")
        #expect(words("size:!>=1mb") == "Size is not at least 1 MB")
        // A sign, then a range, or two signs, or `=` alone: none of them reads.
        for text in [
            "size:>=1mb..2mb", "size:>=>1mb", "size:==1mb", "size:=1mb", "size:>==1mb", "size:<>1mb", "size:>=",
            "modified:=7d", "modified:<=7d",
            "modified:>=2026-03..2026-04",
        ] {
            #expect(query(text).hasUnfinished, "\(text)")
            #expect(query(text).conditions.isEmpty, "\(text)")
        }
    }

    // A day or a month: `>=` from its first day on, `<=` to the end of its last; a count is more than so long ago.
    @Test func atLeastAndAtMostForDates() throws {
        func day(_ year: Int, _ month: Int, _ day: Int) throws -> Date {
            try #require(calendar.date(from: DateComponents(year: year, month: month, day: day)))
        }
        #expect(query("modified:>=2026-03").conditions == [.date(.modified, .onOrAfter(try day(2026, 3, 1)))])
        #expect(query("modified:<=2026-03").conditions == [.date(.modified, .onOrBefore(try day(2026, 3, 31)))])
        #expect(query("modified:>=2026-03-15").conditions == [.date(.modified, .onOrAfter(try day(2026, 3, 15)))])
        #expect(query("modified:=<2026-03-15").conditions == [.date(.modified, .onOrBefore(try day(2026, 3, 15)))])
        #expect(query("created:>=1y").conditions == [.date(.created, .moreThanAgo(1, .years))])
        #expect(query("added:!>=2026-03").conditions == [.not(.date(.added, .onOrAfter(try day(2026, 3, 1))))])
        let now = try day(2026, 6, 1)
        let from = SearchDateRule.onOrAfter(try day(2026, 3, 1)).span(now: now, calendar: calendar)
        #expect(from == SearchDateSpan(start: try day(2026, 3, 1), end: nil))
        let to = SearchDateRule.onOrBefore(try day(2026, 3, 31)).span(now: now, calendar: calendar)
        #expect(to == SearchDateSpan(start: nil, end: try day(2026, 4, 1)))
        // `>` is after the month's last day; `>=` takes it in.
        let after = SearchDateRule.after(try day(2026, 3, 31)).span(now: now, calendar: calendar)
        #expect(after == SearchDateSpan(start: try day(2026, 4, 1), end: nil))
        // Never opened counts as long ago: to a day, not from one.
        #expect(SearchDateRule.onOrBefore(now).takesNoDate)
        #expect(!SearchDateRule.onOrAfter(now).takesNoDate)
        let words = query("modified:>=2026-03").conditions.first.map { SearchConditionText.chip($0) }
        #expect(words?.contains("on or after") == true)
        #expect(
            query("modified:<=2026-03").conditions.first.map { SearchConditionText.chip($0) }?.contains("on or before")
                == true)
    }

    // Sizes and dates take `!` too: anything but that size, or that day, span or range.
    @Test func notOnSizesAndDates() {
        let oneMegabyte = SearchSizeRule(comparison: .equal, value: 1, unit: .megabytes)
        #expect(query("size:!1mb").conditions == [.not(.size(oneMegabyte))])
        #expect(
            query("size:!>10mb").conditions == [
                .not(.size(SearchSizeRule(comparison: .larger, value: 10, unit: .megabytes)))
            ])
        #expect(
            query("size:!1mb..2mb").conditions.first.map { if case .not(.size) = $0 { true } else { false } } == true)
        #expect(query("modified:!today").conditions == [.not(.date(.modified, .today))])
        #expect(query("opened:!7d").conditions == [.not(.date(.lastOpened, .withinLast(7, .days)))])
        #expect(query("created:!>1y").conditions == [.not(.date(.created, .moreThanAgo(1, .years)))])
        #expect(query("added:!2026-03").conditions.count == 1)
        func words(_ text: String) -> String? { query(text).conditions.first.map { SearchConditionText.chip($0) } }
        #expect(words("size:!1mb") == "Size is not 1 MB to under 2 MB")
        #expect(words("size:!>10mb") == "Size is not larger than 10 MB")
        #expect(words("modified:!today") == "Not modified today")
        #expect(words("opened:!7d")?.hasPrefix("Not last opened") == true)
    }

    // `!` before the word is `!` before its value, for every word that takes it.
    @Test func notBeforeTheWordIsNotBeforeItsValue() {
        let pairs = [
            ("kind", "pdf"), ("ext", "tmp"), ("tag", "red"), ("perm", "?5?"), ("size", "1mb"), ("size", ">5k"),
            ("modified", "today"), ("created", "7d"), ("added", "2026-03"), ("opened", ">1y"),
            ("is", "hidden"), ("not", "locked"),
        ]
        for (key, value) in pairs {
            let before = query("!\(key):\(value)").conditions
            #expect(!before.isEmpty, "!\(key):\(value)")
            #expect(before == query("\(key):!\(value)").conditions, "!\(key):\(value)")
        }
    }

    @Test func notIsWorded() {
        func words(_ text: String) -> String? { query(text).conditions.first.map { SearchConditionText.chip($0) } }
        #expect(words("kind:!pdf") == "Kind is not PDF")
        #expect(
            words("kind:!pdf,picture") == "Kind is not Picture or PDF"
                || words("kind:!pdf,picture") == "Kind is not PDF or Picture")
        #expect(words("ext:!tmp,log") == "Extension is not tmp or log")
        #expect(words("tag:!red") == "Not tagged red")
        #expect(words("perm:!777") == "Permissions are not 777 (rwxrwxrwx)")
        #expect(words("is:!locked") == words("not:locked"))
    }

    // A name word after `!` is one a name must not hold; in quotes, `!` is text.
    @Test func aNameWordLeftOut() {
        let read = query("report !draft kind:pdf")
        #expect(read.names == ["report"])
        #expect(read.leftOutNames == ["draft"])
        #expect(read.conditions == [.kind([.pdf])])
        #expect(query("!draft").names.isEmpty)
        #expect(query("!draft").leftOutNames == ["draft"])
        #expect(query("\"!draft\"").names == ["!draft"])
        #expect(query("\"!draft\"").leftOutNames.isEmpty)
        #expect(query("!\"old copy\"").leftOutNames == ["old copy"])
        // A condition inside a left-out phrase stays text.
        let phrase = query("!\"a kind:pdf b\"")
        #expect(phrase.conditions.isEmpty)
        #expect(phrase.leftOutNames == ["a kind:pdf b"])
        // A word that isn't a condition's, after `!`, is a name left out.
        #expect(query("!note:draft").leftOutNames == ["note:draft"])
        #expect(query("!").names == ["!"])
        #expect(query("a!b").names == ["a!b"])
        #expect(query("!!draft").leftOutNames == ["!draft"])
        #expect(query("! draft").names == ["!", "draft"])
    }

    // MARK: Suggestions

    private func suggest(
        _ text: String, caret: Int? = nil, newWord: Bool = false, conditionWords: Bool = true
    ) -> SearchQuerySuggestions? {
        SearchQuerySuggestions.make(
            query: text, caret: caret ?? text.utf16.count, tags: ["Red", "Work"], folders: ["node_modules"],
            listsWordsForNewWord: newWord, offersConditionWords: conditionWords,
            now: calendar.date(from: DateComponents(year: 2026, month: 11, day: 24))!, calendar: calendar)
    }

    // A size that reads as it is is offered as itself, said, and nothing is chosen for Return to take instead: the
    // same in every unit.
    @Test func aWholeSizeIsKeptAsTyped() throws {
        for (typed, title) in [
            ("1mb", "1 MB to under 2 MB"), ("1kb", "1 KB to under 2 KB"), ("1gb", "1 GB to under 2 GB"),
            ("1000b", "1,000 bytes"), (">1kb", "Larger than 1 KB"), ("<5mb", "Smaller than 5 MB"),
            ("1mb..10mb", "Between 1 and 10 MB"),
        ] {
            let list = try #require(suggest("size:" + typed), "\(typed)")
            #expect(list.rows.map(\.hint) == [typed], "\(typed)")
            #expect(list.rows.first?.title == title, "\(typed)")
            #expect(!list.highlightsFirst, "\(typed)")
            #expect(list.typedIsComplete, "\(typed)")
        }
    }

    // A range is offered only once `..` is typed, from what is before it, ends only above it.
    @Test func rangesComeAfterTwoDots() throws {
        #expect(try #require(suggest("size:1mb..")).rows.map(\.hint) == ["1mb..10mb", "1mb..100mb"])
        #expect(try #require(suggest("size:1kb..")).rows.map(\.hint) == ["1kb..10kb", "1kb..100kb"])
        #expect(try #require(suggest("size:1mb..5")).rows.map(\.hint) == ["1mb..5mb", "1mb..5gb"])
        #expect(try #require(suggest("size:500kb..2")).rows.map(\.hint) == ["500kb..2mb", "500kb..2gb"])
        // A range has no sign, and starts with a size: the list says so.
        #expect(suggest("size:..")?.rows.first?.tone == .problem)
        #expect(suggest("size:>1mb..")?.rows.first?.tone == .problem)
        for typed in ["1", "1m", "1mb", "1kb", ">1", "<2"] {
            let list = suggest("size:" + typed)
            #expect(list?.rows.contains { $0.hint.contains("..") } != true, "\(typed)")
        }
    }

    @Test func aNumberIsOfferedInEachUnit() throws {
        let equal = try #require(suggest("size:1"))
        #expect(equal.rows.map(\.hint) == ["1kb", "1mb", "1gb", "1b"])
        #expect(equal.rows.first?.title == "1 KB to under 2 KB")
        #expect(equal.highlightsFirst)
        #expect(!equal.typedIsComplete)
        let larger = try #require(suggest("size:>2.5"))
        #expect(larger.rows.map(\.hint) == [">2.5kb", ">2.5mb", ">2.5gb", ">2.5b"])
        #expect(try #require(suggest("size:<7")).rows.first?.title == "Smaller than 7 KB")
    }

    @Test func theExamplesShowEachKindOfSize() throws {
        let list = try #require(suggest("size:"))
        #expect(list.rows.map(\.hint) == [">10mb", ">100mb", ">1gb", "<1mb", "1mb", "1mb..10mb"])
        // Typing narrows them, never to a range.
        #expect(try #require(suggest("size:>1")).rows.map(\.hint) == [">1kb", ">1mb", ">1gb", ">1b"])
    }

    @Test func notIsOfferedAsTyped() throws {
        let kinds = try #require(suggest("kind:!pd"))
        #expect(kinds.rows.first == SearchQuerySuggestion(title: "Not PDF", hint: "!pdf", replacement: "kind:!pdf "))
        let before = try #require(suggest("!kind:pd"))
        #expect(before.rows.first?.replacement == "!kind:pdf ")
        let tags = try #require(suggest("tag:!r"))
        #expect(tags.rows.first?.replacement == "tag:!Red ")
        let after = try #require(suggest("kind:!pdf,pic"))
        #expect(after.rows.first?.replacement == "kind:!pdf,picture ")
        // Sizes and dates take it, their rows said as a sentence goes on.
        let sizes = try #require(suggest("size:!1"))
        #expect(sizes.rows.first?.hint == "!1kb")
        #expect(sizes.rows.first?.title == "Not 1 KB to under 2 KB")
        #expect(sizes.rows.first?.replacement == "size:!1kb ")
        let days = try #require(suggest("modified:!7"))
        #expect(days.rows.first?.hint == "!7d")
        #expect(days.rows.first?.title == "Not within the last 7 days")
        #expect(try #require(suggest("kind:!pd")).rows.first?.title == "Not PDF")
        // Where `!` means nothing, the list says so.
        #expect(suggest("skip:!x")?.rows.first?.tone == .problem)
    }

    @Test func permissionsAreOffered() throws {
        let all = try #require(suggest("perm:"))
        #expect(all.rows.map(\.hint) == ["755", "644", "700", "600", "750", "640", "777", "666", "444"])
        #expect(all.rows.first?.title == "rwxr-xr-x")
        #expect(try #require(suggest("perm:7")).rows.map(\.hint) == ["755", "700", "750", "777"])
        #expect(try #require(suggest("perm:rwx")).rows.map(\.hint) == ["755", "700", "750", "777"])
        let typed = try #require(suggest("perm:751"))
        #expect(typed.rows.first?.hint == "751")
        #expect(typed.typedIsComplete)
        #expect(try #require(suggest("perm:!6")).rows.first?.title == "Not rw-r--r--")
    }

    // A value that reads as it is isn't replaced by one nobody chose; one being typed is completed.
    @Test func whatIsCompleteIsKept() throws {
        #expect(try #require(suggest("kind:pdf")).typedIsComplete)
        #expect(try !#require(suggest("kind:pdf")).highlightsFirst)
        #expect(try #require(suggest("kind:pd")).highlightsFirst)
        #expect(try !#require(suggest("kind:pdf,pic")).typedIsComplete)
        #expect(try #require(suggest("modified:7d")).typedIsComplete)
        #expect(try !#require(suggest("modified:7")).typedIsComplete)
        // A tag or a folder, free names, is whole only as one listed.
        #expect(try #require(suggest("tag:red")).typedIsComplete)
        #expect(try !#require(suggest("tag:r")).typedIsComplete)
        #expect(try #require(suggest("skip:node_modules")).typedIsComplete)
    }

    // The box lists the words below its text: it offers only a condition's values.
    @Test func theBoxOffersOnlyValues() throws {
        #expect(suggest("", newWord: false, conditionWords: false) == nil)
        #expect(suggest("pdf", conditionWords: false) == nil)
        #expect(suggest("d", conditionWords: false) == nil)
        #expect(suggest("kind:pdf ", conditionWords: false) == nil)
        #expect(try #require(suggest("kind:pd", conditionWords: false)).rows.first?.hint == "pdf")
        #expect(try #require(suggest("size:1", conditionWords: false)).rows.count == 4)
    }

    // Every row's end is what it types: Help is the link at the list's foot, not a row.
    @Test func everyRowTypesWhatItsEndSays() throws {
        let words = try #require(suggest("", newWord: true))
        #expect(words.rows.allSatisfy { !$0.opensHelp && $0.replacement == $0.hint })
        #expect(words.rows.map(\.hint).last == "skip:")
        #expect(words.rows.map(\.hint).contains("perm:"))
        #expect(try #require(suggest("kind:")).rows.allSatisfy { !$0.opensHelp })
    }

    // A name left out offers nothing: it is a name.
    @Test func aNameLeftOutOffersNothing() {
        #expect(suggest("!d") == nil)
        #expect(suggest("!pdf") == nil)
        #expect(suggest("report !draft ", newWord: true) == nil)
    }

    // MARK: What typing can't break

    // Numbers past any size or count are words that can't be read, and nothing made of one traps.
    @Test func numbersPastAnySizeAreNotRead() {
        for text in [
            "size:>9999999999gb", "size:99999999999999999999b", "size:1kb..99999999999999999999gb",
            "size:9999999999999999999999999999999999kb", "modified:>9223372036854775807y", "modified:10000d",
            "modified:99999w", "perm:1\u{301}55", "perm:1\u{FE0F}\u{20E3}55", "modified:+123-01", "size:١mb",
            "modified:٢٠٢٦-٠٣",
        ] {
            #expect(query(text).hasUnfinished, "\(text)")
            #expect(query(text).conditions.isEmpty, "\(text)")
            _ = SearchQuerySuggestions.make(query: text, caret: text.utf16.count)
            _ = SearchQuery.problems(text, caret: text.utf16.count, whileTyping: true)
        }
        // The largest size read is still a number of bytes, and its bounds are too.
        let largest = rule(">1000000000gb")
        #expect(largest?.bounds.above == 1_000_000_000_000_000_000)
        // A rule made by hand past what is counted has bounds, and finds nothing.
        let huge = SearchSizeRule(comparison: .between, value: 1e30, upper: 1e300, unit: .gigabytes)
        #expect(huge.bounds.above.map { $0 > 0 } == true)
        #expect(SearchSizeRule(comparison: .equal, value: .infinity, unit: .gigabytes).bounds.above != nil)
        // The list builds a range's other end from any number typed.
        #expect(suggest("size:1kb..99999999999999999999")?.rows.contains { $0.canBeChosen } != true)
        #expect(
            suggest("size:1kb..99999999999999")?.rows.map(\.hint) == ["1kb..99999999999999kb", "1kb..99999999999999b"])
    }

    // A size alone is to its last digit: one finer than a byte is no size; with a sign it still compares.
    @Test func aSizeAloneIsWholeBytes() {
        for text in ["size:1.5b", "size:0.0001kb", "size:1.2345kb", "size:1.mb", "size:>1.mb"] {
            #expect(query(text).hasUnfinished, "\(text)")
        }
        #expect(rule("1.234kb")?.bounds.above == 1233)
        #expect(rule(">1.2345kb") != nil)
    }

    // A range of days typed the later one first is the same days.
    @Test func aRangeOfDaysTypedBackwardsIsTheSameDays() {
        #expect(query("modified:2026-03..2026-01").conditions == query("modified:2026-01..2026-03").conditions)
        #expect(
            query("modified:2026-03-10..2026-03-01").conditions == query("modified:2026-03-01..2026-03-10").conditions)
        #expect(
            query("modified:2026-03..2026-01").conditions.first.map { SearchConditionText.chip($0) }
                == "Modified between Jan 1, 2026 and Mar 31, 2026")
    }

    // A day to its own month is in order: from the day to the month's end.
    @Test func aDayToItsOwnMonthRunsToTheMonthsEnd() {
        #expect(
            query("modified:2026-03-15..2026-03").conditions == query("modified:2026-03-15..2026-03-31").conditions)
        #expect(
            query("modified:2026-03..2026-03-15").conditions == query("modified:2026-03-01..2026-03-15").conditions)
        #expect(
            query("modified:2026-03-20..2026-02").conditions == query("modified:2026-02-01..2026-03-20").conditions)
    }

    // A day is read as it is written, whatever calendar the Mac counts its years in.
    @Test func daysAreReadInTheCalendarTheyAreWrittenIn() throws {
        for identifier in [Calendar.Identifier.buddhist, .japanese, .persian, .islamicUmmAlQura] {
            var other = Calendar(identifier: identifier)
            other.timeZone = calendar.timeZone
            #expect(
                SearchQuery("modified:2026-03-15", calendar: other).conditions
                    == query("modified:2026-03-15").conditions,
                "\(identifier)")
            // The row of two days types days that are read.
            let list = try #require(
                SearchQuerySuggestions.make(query: "modified:", caret: 9, tags: [], folders: [], calendar: other))
            for row in list.rows {
                let typed = try #require(row.replacement)
                #expect(!SearchQuery(typed, calendar: other).hasUnfinished, "\(identifier) \(typed)")
            }
        }
    }

    // Larger and smaller than a part of a byte: the whole bytes on that side.
    @Test func aPartOfAByteIsComparedByWholeBytes() {
        #expect(holds(">1.5b", 2))
        #expect(!holds(">1.5b", 1))
        #expect(holds("<1.4b", 1))
        #expect(!holds("<1.4b", 2))
        #expect(holds(">1.2345kb", 1235))
        #expect(!holds(">1.2345kb", 1234))
        #expect(!holds(">2.3kb", 2300))
        #expect(holds(">2.3kb", 2301))
        #expect(holds("<2.3kb", 2299))
        #expect(!holds("<2.3kb", 2300))
    }

    // A size says every digit typed, and a range the smaller first.
    @Test func aSizeIsSaidAsTyped() {
        func said(_ text: String) -> String? {
            query(text).conditions.first.map { SearchConditionText.chip($0, locale: Locale(identifier: "en_US")) }
        }
        #expect(said("size:1.234kb") == "Size is 1.234 KB to under 1.235 KB")
        #expect(said("size:1.005gb") == "Size is 1.005 GB to under 1.006 GB")
        #expect(said("size:0.001kb") == "Size is 0.001 KB to under 0.002 KB")
        #expect(said("size:>1.234kb") == "Size is larger than 1.234 KB")
        #expect(said("size:1.1234567gb") == "Size is 1.1234567 GB to under 1.1234568 GB")
        #expect(said("size:1mb..500kb") == said("size:500kb..1mb"))
        #expect(said("size:2mb..1mb") == "Size is between 1 and 2 MB")
    }

    // A range's rows type the number as someone would.
    @Test func aRangesRowsTypePlainNumbers() throws {
        #expect(try #require(suggest("size:1.1mb..")).rows.map(\.hint) == ["1.1mb..11mb", "1.1mb..110mb"])
        #expect(try #require(suggest("size:2.11mb..")).rows.map(\.hint) == ["2.11mb..21.1mb", "2.11mb..211mb"])
    }

    // Permissions pasted from `ls -l`, which ends them with `@` or `+` for an item with more to say.
    @Test func permissionsPastedFromLsAreRead() {
        #expect(query("perm:-rw-r--r--@").conditions == query("perm:644").conditions)
        #expect(query("perm:drwxr-xr-x+").conditions == query("perm:755").conditions)
        #expect(query("perm:rw-r--r--@").conditions == query("perm:644").conditions)
        #expect(query("perm:755@").hasUnfinished)
    }

    // A tag or a folder of one's own may start as a listed one does: Return searches for it, Tab completes it.
    @Test func aNameThatReadsIsNotReplaced() throws {
        let typed = try #require(suggest("tag:r"))
        #expect(!typed.highlightsFirst)
        #expect(!typed.typedIsComplete)
        #expect(try !#require(suggest("tag:red,")).highlightsFirst)
        #expect(try !#require(suggest("skip:node")).highlightsFirst)
    }

    // A size of many gigabytes is compared to the byte, whatever a decimal leaves over when multiplied.
    @Test func largeSizesAreComparedToTheByte() {
        #expect(!holds(">32.3gb", 32_300_000_000))
        #expect(holds(">32.3gb", 32_300_000_001))
        #expect(!holds("<32.2gb", 32_200_000_000))
        #expect(holds("<32.2gb", 32_199_999_999))
        #expect(holds(">=32.2gb", 32_200_000_000))
        #expect(!holds(">=32.2gb", 32_199_999_999))
        #expect(!holds("17.1gb", 17_200_000_000))
        #expect(holds("17.1gb", 17_199_999_999))
        #expect(holds("17.1gb", 17_100_000_000))
        // Tenths of a gigabyte up to 2,000 GB, against whole-number arithmetic.
        for tenths in stride(from: 1, through: 20_000, by: 7) {
            let bytes = Int64(tenths) * 100_000_000
            let text = "\(tenths / 10).\(tenths % 10)gb"
            #expect(!holds(">" + text, bytes) && holds(">" + text, bytes + 1), "\(text)")
            #expect(!holds("<" + text, bytes) && holds("<" + text, bytes - 1), "\(text)")
            #expect(holds(">=" + text, bytes) && !holds(">=" + text, bytes - 1), "\(text)")
            #expect(holds("<=" + text, bytes) && !holds("<=" + text, bytes + 1), "\(text)")
            #expect(holds(text, bytes) && !holds(text, bytes - 1), "\(text)")
            #expect(holds(text, bytes + 99_999_999) && !holds(text, bytes + 100_000_000), "\(text)")
        }
    }

    // A range with a part of a byte at its ends is the whole bytes between them.
    @Test func aRangeOfPartsOfABYteIsTheWholeBytesBetween() {
        #expect(!holds("1.5b..2.5b", 1))
        #expect(holds("1.5b..2.5b", 2))
        #expect(!holds("1.5b..2.5b", 3))
        #expect(holds("1.2345kb..2.0005kb", 2000))
        #expect(!holds("1.2345kb..2.0005kb", 2001))
        #expect(!holds("1.2345kb..2.0005kb", 1234))
        #expect(holds("1mb..10mb", 1_000_000) && holds("1mb..10mb", 10_000_000))
    }

    // A day on which the clock skips midnight ends where the next starts.
    @Test func aDayWithoutAMidnightEndsAtTheNext() throws {
        var cairo = Calendar(identifier: .gregorian)
        cairo.timeZone = try #require(TimeZone(identifier: "Africa/Cairo"))
        let now = try #require(cairo.date(from: DateComponents(year: 2026, month: 6, day: 1)))
        let next = try #require(cairo.date(from: DateComponents(year: 2026, month: 4, day: 25)))
        for text in ["modified:2026-04-24", "modified:<=2026-04-24", "modified:2026-04-20..2026-04-24"] {
            guard case .date(_, let rule)? = SearchQuery(text, calendar: cairo).conditions.first else {
                Issue.record("\(text) is no date")
                continue
            }
            #expect(rule.span(now: now, calendar: cairo).end == next, "\(text)")
        }
        guard case .date(_, let after)? = SearchQuery("modified:>2026-04-24", calendar: cairo).conditions.first
        else {
            Issue.record("no date")
            return
        }
        #expect(after.span(now: now, calendar: cairo).start == next)
    }

    // The month's row says the month it types, whatever the Mac's calendar; a year alone is offered as its months.
    @Test func dateRowsSayWhatTheyType() throws {
        var persian = Calendar(identifier: .persian)
        persian.timeZone = calendar.timeZone
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 24)))
        let list = try #require(
            SearchQuerySuggestions.make(
                query: "modified:", caret: 9, tags: [], folders: [], now: now, calendar: persian))
        #expect(list.rows.contains { $0.title == "In October 2026" && $0.hint == "2026-10" })
        let year = try #require(suggest("modified:2026"))
        #expect(year.rows.first?.title == "In 2026")
        #expect(year.rows.first?.hint == "2026-01..2026-12")
        #expect(!query("modified:2026-01..2026-12").hasUnfinished)
        #expect(try #require(suggest("modified:30")).rows.first?.hint == "30d")
    }

    // A name in quotes typed before other words is the name up to the caret: the words after it stay.
    @Test func aQuotedNameTypedMidTextEndsAtTheCaret() throws {
        let text = "tag:\"W kind:pdf"
        let list = try #require(suggest(text, caret: 6))
        #expect(list.range == NSRange(location: 0, length: 6))
        #expect(list.rows.map(\.hint) == ["Work"])
        #expect(list.rows.first?.replacement == "tag:Work ")
    }

    // MARK: Names with a space

    // A tag or a folder with a space in its name is typed in quotes, after the colon, a comma or the `!`.
    @Test func namesInQuotesAreTakenWhole() {
        #expect(query("tag:\"To Do\"").conditions == [.tags(["To Do"], all: false)])
        #expect(query("tag:red,\"To Do\",blue").conditions == [.tags(["red", "To Do", "blue"], all: false)])
        #expect(query("tag:!\"To Do\"").conditions == [.not(.tags(["To Do"], all: false))])
        #expect(query("!tag:\"To Do\"").conditions == query("tag:!\"To Do\"").conditions)
        #expect(
            query("skip:\"Application Support\",build").conditions == [
                .skipFolders(["Application Support", "build"])
            ])
        #expect(query("TAG:\"a,b\"").conditions == [.tags(["a,b"], all: false)])
        // The words around it stay the name to find.
        let mixed = query("annual tag:\"To Do\" report")
        #expect(mixed.text == "annual report")
        #expect(mixed.conditions == [.tags(["To Do"], all: false)])
        #expect(!mixed.hasUnfinished)
        // A quote elsewhere in a value is a character, and quotes after other words are too.
        #expect(query("tag:a\"b").conditions == [.tags(["a\"b"], all: false)])
        #expect(query("kind:\"pdf\"").hasUnfinished)
        // Left open, the name runs to the end of the text and is still being typed: nothing is searched for it.
        let open = query("tag:\"To Do report")
        #expect(open.hasUnfinished && open.conditions.isEmpty && open.text.isEmpty)
        #expect(SearchQuery.words("tag:\"To Do report").count == 1)
        #expect(SearchQuery.problems("tag:\"To Do", caret: 10, whileTyping: true).isEmpty)
        #expect(SearchQuery.problems("tag:\"To Do").first?.detail == "Close the quote: tag:\"a name\"")
        // Something after the closing quote that isn't a comma can't be read.
        #expect(query("tag:\"To Do\"x").hasUnfinished)
        #expect(SearchQuery.words("tag:\"To Do\"x").first?.canStillBeRead == false)
    }

    // One `!` before the first name is for all of them; one before a later name says nothing.
    @Test func notBeforeALaterNameIsNotRead() {
        for text in ["tag:red,!blue", "tag:!red,!blue", "skip:a,!b"] {
            #expect(query(text).hasUnfinished, "\(text)")
            #expect(SearchQuery.words(text).first?.canStillBeRead == false, "\(text)")
        }
        #expect(SearchQuery.problems("tag:red,!blue").first?.detail.hasPrefix("One ! before the first tag") == true)
        // In quotes it is a name.
        #expect(query("tag:red,\"!blue\"").conditions == [.tags(["red", "!blue"], all: false)])
    }

    // A comma in an attribute's value is a choice: any of them after `is:`, none of them after `not:`, the `!`
    // before the first for all of them.
    @Test func attributesTakeAComma() {
        #expect(query("is:link,alias").conditions == [.attributes([.symbolicLink, .alias], is: true)])
        #expect(query("not:hidden,locked").conditions == [.attributes([.hidden, .locked], is: false)])
        #expect(query("is:!hidden,locked").conditions == [.attributes([.hidden, .locked], is: false)])
        #expect(query("!is:hidden,locked").conditions == query("not:hidden,locked").conditions)
        #expect(query("not:!file,folder").conditions == [.attributes([.file, .folder], is: true)])
        // Each once, in the order typed.
        #expect(query("is:alias,link,alias").conditions == [.attributes([.alias, .symbolicLink], is: true)])
        #expect(query("is:link,").conditions == [.attribute(.symbolicLink, is: true)])
        for text in ["is:hidden,", "is:hidden,lo", "not:hidden,"] {
            #expect(SearchQuery.words(text).first?.canStillBeRead == true, "\(text)")
        }
        for text in ["is:hidden,!locked", "is:hidden,nope"] {
            #expect(query(text).hasUnfinished, "\(text)")
            #expect(SearchQuery.words(text).first?.canStillBeRead == false, "\(text)")
        }
        #expect(
            SearchQuery.problems("is:hidden,!locked").first?.detail
                == "One ! before the first is for all of them: is:!hidden,locked is neither")
        #expect(
            SearchQuery.problems("not:hidden,!locked").first?.detail
                == "One ! before the first is for all of them: not:!hidden,locked is either")
    }

    // After a comma the list offers the attributes not yet typed, and a row types the whole list.
    @Test func anAttributeListOffersTheRest() throws {
        let rows = try #require(suggest("is:link,")?.rows)
        #expect(!rows.contains { $0.hint == "link" })
        let alias = try #require(rows.first { $0.hint == "alias" })
        #expect(alias.replacement == "is:link,alias ")
        #expect(suggest("is:link,al")?.rows.first?.hint == "alias")
    }

    @Test func fileFolderAndTaggedAreAttributes() {
        #expect(query("is:file").conditions == [.attribute(.file, is: true)])
        #expect(query("is:folder").conditions == [.attribute(.folder, is: true)])
        #expect(query("is:tagged").conditions == [.attribute(.tagged, is: true)])
        #expect(query("not:tagged").conditions == [.attribute(.tagged, is: false)])
        #expect(SearchConditionText.chip(.attributes([.symbolicLink, .alias], is: true)) == "Symbolic link or alias")
        #expect(SearchConditionText.chip(.attributes([.hidden, .locked], is: false)) == "Not hidden and not locked")
        #expect(SearchConditionText.chip(.attribute(.tagged, is: false)) == "Not tagged")
    }

    @Test func cloudDownloadedAndBrokenAreAttributes() {
        #expect(query("is:cloud").conditions == [.attribute(.cloud, is: true)])
        #expect(query("not:downloaded").conditions == [.attribute(.downloaded, is: false)])
        #expect(query("is:broken,alias").conditions == [.attributes([.broken, .alias], is: true)])
        #expect(SearchConditionText.chip(.attribute(.cloud, is: true)) == "Only in the cloud")
        #expect(SearchConditionText.chip(.attribute(.broken, is: false)) == "Not a broken link or alias")
    }

    // A name without an extension is `ext:none`; the extension "none" is `ext:.none`.
    @Test func noExtensionIsNone() {
        #expect(query("ext:none").conditions == [.fileExtension([""])])
        #expect(query("ext:pdf,none").conditions == [.fileExtension(["pdf", ""])])
        #expect(query("ext:.none").conditions == [.fileExtension(["none"])])
        #expect(query("ext:!none").conditions == [.not(.fileExtension([""]))])
        #expect(SearchConditionText.chip(.fileExtension(["pdf", ""])) == "Extension is pdf, none")
    }

    // A tag's color, whatever its name; grey is gray.
    @Test func aColorIsATagsColor() {
        #expect(query("color:red").conditions == [.tagColors([.red])])
        #expect(query("color:Red,grey,red").conditions == [.tagColors([.red, .gray])])
        #expect(query("color:!blue").conditions == [.not(.tagColors([.blue]))])
        #expect(query("color:pink").hasUnfinished)
        #expect(SearchQuery.words("color:re").first?.canStillBeRead == true)
        #expect(SearchQuery.words("color:x").first?.canStillBeRead == false)
        #expect(SearchConditionText.chip(.tagColors([.red, .blue])) == "Has a red or blue tag")
        #expect(SearchConditionText.chip(.not(.tagColors([.red]))) == "Has no red tag")
    }

    // An owner is me, a user's name or a number; a name no user has can't be read once the caret leaves it.
    @Test func anOwnerIsAUserOfThisMac() {
        #expect(query("owner:me").conditions == [.owners(["me"])])
        #expect(query("owner:root,0").conditions == [.owners(["root", "0"])])
        #expect(query("owner:!root").conditions == [.not(.owners(["root"]))])
        #expect(SearchQuery.ownerID("me") == getuid())
        #expect(SearchQuery.ownerID("root") == 0)
        #expect(SearchQuery.ownerID("no-such-user-7f72e9") == nil)
        #expect(query("owner:no-such-user-7f72e9").hasUnfinished)
        #expect(SearchQuery.words("owner:no-such-user-7f72e9").first?.canStillBeRead == true)
        #expect(SearchQuery.problems("owner:no-such-user-7f72e9").first?.detail.hasPrefix("Not a user") == true)
        #expect(SearchConditionText.chip(.owners(["root", "me"])) == "Owned by root or me")
    }

    // Where from is any part of an address, in quotes when it has a space or a comma.
    @Test func fromIsPartOfAnAddress() {
        #expect(query("from:github.com").conditions == [.downloadedFrom(["github.com"])])
        #expect(query("from:github.com,\"a,b\"").conditions == [.downloadedFrom(["github.com", "a,b"])])
        #expect(query("from:!example.com").conditions == [.not(.downloadedFrom(["example.com"]))])
        #expect(query("from:a,!b").hasUnfinished)
        #expect(SearchConditionText.chip(.downloadedFrom(["github.com"])) == "Downloaded from github.com")
    }

    // The new words' lists: every color and attribute, me and root among the owners, none among the extensions.
    @Test func theNewWordsOfferTheirValues() throws {
        let colors = try #require(suggest("color:")?.rows.map(\.hint))
        #expect(colors == SearchTagColor.allCases.map(\.rawValue))
        #expect(try #require(suggest("color:red,")?.rows.map(\.hint)).contains("red") == false)
        let owners = try #require(suggest("owner:")?.rows.map(\.hint))
        #expect(owners.prefix(2) == ["me", "root"])
        #expect(try #require(suggest("ext:no")?.rows.first?.hint) == "none")
        let attributes = try #require(suggest("is:")?.rows.map(\.hint))
        #expect(attributes.count == SearchAttribute.allCases.count)
        #expect(try #require(suggest("from:git")?.rows.first?.hint) == "git")
    }

    // A word has one `!` or one `not:` that turns it: more can't be read.
    @Test func doubleNegativesAreOneTurn() {
        #expect(query("!not:executable").conditions == [.attribute(.executable, is: true)])
        #expect(query("not:!executable").conditions == [.attribute(.executable, is: true)])
        for text in ["!not:!executable", "!is:!executable", "not:not:!executable", "not:!!executable"] {
            #expect(query(text).hasUnfinished, "\(text)")
        }
        #expect(SearchQuery.problems("!not:!executable").first?.detail == "One ! is enough")
    }

    // `!` before the word and `!` before its value are one too many, and say so.
    @Test func twoMarksSaySo() {
        for text in ["!kind:!pdf", "!size:!1mb", "!!kind:pdf", "kind:!!pdf"] {
            #expect(SearchQuery.problems(text).first?.detail == "One ! is enough", "\(text)")
        }
    }

    // MARK: What a row says is what it types

    // Every row that can be taken types a word that reads, and says what that word asks for: its title is the
    // condition's own words, "Not" and all, wherever the `!` was typed.
    @Test func eachRowTypesWhatItSays() throws {
        let tags = ["Red", "To Do", "a,b", "Work"]
        let folders = ["node_modules", "Application Support", "build"]
        let typed = [
            "kind:", "kind:pd", "kind:!pd", "!kind:pd", "kind:pdf,pic", "!kind:pdf,pic", "ext:", "ext:!do", "!ext:do",
            "size:", "size:1", "size:!1", "!size:1", "size:>2", "!size:>2", "size:1mb..", "modified:", "modified:7",
            "modified:!7", "!modified:7", "!modified:to", "opened:!ye", "tag:", "tag:r", "tag:!r", "!tag:r", "tag:to",
            "tag:\"To", "tag:red,to", "!tag:red,\"To", "tag:a", "is:", "is:lo", "is:!lo", "!is:lo", "not:lo",
            "!not:lo", "not:!lo", "perm:", "perm:7", "perm:!7", "!perm:7", "skip:", "skip:app", "skip:build,\"App",
            "to", "re", "app", "doc", "pdf",
        ]
        for text in typed {
            let list = try #require(
                SearchQuerySuggestions.make(
                    query: text, caret: text.utf16.count, tags: tags, folders: folders,
                    now: calendar.date(from: DateComponents(year: 2026, month: 11, day: 24))!, calendar: calendar),
                "\(text)")
            for row in list.rows where row.canBeChosen && !row.keepsListOpen {
                let replacement = try #require(row.replacement, "\(text): \(row.title)")
                let read = SearchQuery(replacement, calendar: calendar)
                #expect(!read.hasUnfinished && read.text.isEmpty, "\(text) types \(replacement)")
                let condition = try #require(read.conditions.first, "\(text) types \(replacement)")
                #expect(read.conditions.count == 1, "\(text) types \(replacement)")
                // Negated, the row says so; and it never says so of what isn't.
                let isNot: Bool
                switch condition {
                case .not: isNot = true
                case .attributes(_, let isSo): isNot = !isSo
                default: isNot = false
                }
                let saysNot = row.title.hasPrefix("Not ") || row.title.contains(" not ") || row.title.hasPrefix("Can't")
                #expect(saysNot == isNot, "\(text): “\(row.title)” types \(replacement)")
                // A name row names every name the word then asks for last.
                if case .tags(let names, _) = condition, text.contains("tag:") {
                    #expect(names.last.map { row.title.hasSuffix($0) } == true, "\(text): \(row.title)")
                }
                if case .skipFolders(let names) = condition {
                    #expect(names.last.map { row.title.hasSuffix($0) } == true, "\(text): \(row.title)")
                }
            }
        }
    }
}
