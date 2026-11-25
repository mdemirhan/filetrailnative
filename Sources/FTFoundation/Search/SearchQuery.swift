// The search field's text read as a search: the words that are conditions ("kind:pdf", "size:>10mb", "modified:7d"),
// and the rest, the text names are matched against. A word whose value can't be read is left out of both until it can.
import Darwin
import Foundation

/// A condition's word, as typed before its colon.
public enum SearchQueryKey: String, CaseIterable, Sendable {
    case kind, ext, size, modified, created, added, opened, tag, color, `is`, not, owner, perm, from, skip

    /// The word as typed, with its colon.
    public var word: String { rawValue + ":" }

    /// What the field's menu and the suggestions call it.
    public var title: String {
        switch self {
        case .kind: "Kind"
        case .ext: "Extension"
        case .size: "Size"
        case .tag: "Tags"
        case .color: "Tag Color"
        case .owner: "Owner"
        case .from: "Downloaded From"
        case .is: "Attribute"
        case .not: "Attribute Is Not"
        case .perm: "Permissions"
        case .skip: "Skip a Folder"
        default: dateField?.menuLabel ?? rawValue
        }
    }

    /// The date a date word asks about.
    public var dateField: SearchDateField? {
        switch self {
        case .modified: .modified
        case .created: .created
        case .added: .added
        case .opened: .lastOpened
        default: nil
        }
    }

    /// The words the field's menu lists, in its order: `not:` after `is:`, as its other side.
    public static let menuOrder: [SearchQueryKey] = [
        .kind, .ext, .size, .modified, .created, .added, .opened, .tag, .color, .is, .not, .owner, .perm, .from,
        .skip,
    ]

    /// Whether its values are names, any text, a name with a space or a comma in quotes: tags, places downloaded
    /// from, folders skipped.
    public var takesNames: Bool { self == .tag || self == .from || self == .skip }

    /// Whether `!` before its value, or before the word, asks for what it doesn't say: `kind:!pdf`, `!tag:red`,
    /// `size:!1mb`, `modified:!today`. A folder skipped is already left out.
    public var takesNot: Bool { self != .skip }
}

/// One word of the field's text: text to find, a condition, or a condition's word whose value can't be read yet.
public struct SearchQueryWord: Equatable, Sendable {
    public enum Role: Equatable, Sendable {
        case text
        case condition(SearchCondition)
        case unfinished
    }

    /// Where it is in the text, in UTF-16 units, as AppKit counts.
    public var range: NSRange
    public var text: String
    public var key: SearchQueryKey?
    public var role: Role

    /// The length of the word and its colon, as typed.
    public var keyLength: Int {
        guard key != nil, let colon = text.firstIndex(of: ":") else { return 0 }
        return text[..<colon].utf16.count + 1
    }

    /// What follows the colon.
    public var value: String {
        guard key != nil, let colon = text.firstIndex(of: ":") else { return "" }
        return String(text[text.index(after: colon)...])
    }
}

/// The field's text read as a search.
public struct SearchQuery: Equatable, Sendable {
    /// The text names are matched against: the words that aren't conditions, as typed.
    public var text: String
    public var conditions: [SearchCondition]
    /// A condition's word whose value can't be read yet: it is searched for once it can.
    public var hasUnfinished: Bool

    public init(_ query: String, calendar: Calendar = .current) {
        let words = Self.words(query, calendar: calendar)
        let source = query as NSString
        var text = ""
        var lastKept: Int?
        var removedSince = false
        for word in words {
            guard word.role == .text else {
                removedSince = true
                continue
            }
            if let lastKept {
                text +=
                    removedSince
                    ? " " : source.substring(with: NSRange(location: lastKept, length: word.range.location - lastKept))
            }
            text += word.text
            lastKept = NSMaxRange(word.range)
            removedSince = false
        }
        self.text = text
        conditions = words.compactMap { word in
            if case .condition(let condition) = word.role { return condition }
            return nil
        }
        hasUnfinished = words.contains { $0.role == .unfinished }
    }

    /// The words of the name to find (`NameTerms.words`): none for text with no word in it, such as `""`.
    public var names: [String] { NameTerms.words(text) }

    /// The words a name must not hold (`!draft`).
    public var leftOutNames: [String] { NameTerms.leftOut(text) }

    /// The words of `query`, separated by white space, each with what it is. A word that starts with a double quote
    /// runs to the quote that closes it, white space and all, and is text, never a condition (`"kind:pdf notes"`);
    /// without a closing quote the quote is an ordinary character (`NameTerms.words`). A name after `tag:` or `skip:`
    /// takes quotes too (`tag:"To Do"`, `skip:build,"My Builds"`), as a tag or a folder may have a space in its
    /// name; there a quote left open runs to the end of the text, the word being one still typed.
    public static func words(_ query: String, calendar: Calendar = .current) -> [SearchQueryWord] {
        let source = query as NSString
        var words: [SearchQueryWord] = []
        var location = 0
        let length = source.length
        let spaces = CharacterSet.whitespacesAndNewlines
        func isSpace(_ unit: unichar) -> Bool {
            Unicode.Scalar(unit).map { spaces.contains($0) } ?? false
        }
        while location < length {
            while location < length, isSpace(source.character(at: location)) { location += 1 }
            let start = location
            let quote = unichar(UInt8(ascii: "\""))
            // `"…"` and `!"…"` run to their closing quote.
            let bang = unichar(UInt8(ascii: "!"))
            let opening =
                location < length && source.character(at: location) == quote
                ? location
                : location + 1 < length && source.character(at: location) == bang
                    && source.character(at: location + 1) == quote ? location + 1 : nil
            if let opening {
                let rest = NSRange(location: opening + 1, length: length - opening - 1)
                let close = source.range(of: "\"", options: .literal, range: rest)
                if close.location != NSNotFound { location = NSMaxRange(close) }
            }
            while location < length, !isSpace(source.character(at: location)) {
                if source.character(at: location) == quote, location > start,
                    opensName(source, wordStart: start, at: location)
                {
                    let rest = NSRange(location: location + 1, length: length - location - 1)
                    let close = source.range(of: "\"", options: .literal, range: rest)
                    location = close.location == NSNotFound ? length : NSMaxRange(close)
                    continue
                }
                location += 1
            }
            guard location > start else { break }
            let range = NSRange(location: start, length: location - start)
            let text = source.substring(with: range)
            words.append(word(text, range: range, calendar: calendar))
        }
        return words
    }

    /// Whether the quote at `location` starts a name in the value of `tag:` or `skip:`: right after the colon, after
    /// a comma, or after the `!` that follows the colon.
    private static func opensName(_ source: NSString, wordStart: Int, at location: Int) -> Bool {
        var head = source.substring(with: NSRange(location: wordStart, length: location - wordStart)).lowercased()
        if head.hasPrefix("!") { head.removeFirst() }
        guard let key = SearchQueryKey.allCases.first(where: { $0.takesNames && head.hasPrefix($0.word) }) else {
            return false
        }
        let value = head.dropFirst(key.word.count)
        return value.isEmpty || value == "!" || value.hasSuffix(",")
    }

    /// The names in the value of `tag:` or `skip:`: separated by commas, one in double quotes taken whole, spaces and
    /// commas and all. Nil when it can't be read: no name at all, a quote left open, something after a closing quote,
    /// or a `!` before a name that isn't the first (`tag:!red,blue` is neither; `tag:red,!blue` says nothing).
    public static func names(_ value: String) -> [String]? {
        var names: [String] = []
        var rest = Substring(value)
        while !rest.isEmpty {
            if rest.hasPrefix("\"") {
                let inside = rest.dropFirst()
                guard let close = inside.firstIndex(of: "\"") else { return nil }
                if close > inside.startIndex { names.append(String(inside[..<close])) }
                rest = inside[inside.index(after: close)...]
                guard rest.isEmpty || rest.hasPrefix(",") else { return nil }
                rest = rest.dropFirst()
            } else {
                let name = rest.prefix { $0 != "," }
                guard !name.hasPrefix("!") else { return nil }
                if !name.isEmpty { names.append(String(name)) }
                rest = rest.dropFirst(name.count).dropFirst()
            }
        }
        return names.isEmpty ? nil : names
    }

    /// A tag's or a folder's name as it is typed after its word: in quotes when it has a space or a comma, or starts
    /// with a quote's or a not's mark. Nil for a name that can't be typed (a quote inside one that needs quotes).
    public static func nameWord(_ name: String) -> String? {
        let needsQuotes =
            name.contains(",") || name.hasPrefix("!") || name.hasPrefix("\"")
            || name.unicodeScalars.contains { CharacterSet.whitespacesAndNewlines.contains($0) }
        guard needsQuotes else { return name.isEmpty ? nil : name }
        return name.contains("\"") ? nil : "\"" + name + "\""
    }

    /// `!` before a condition's word is `!` before its value: `!kind:pdf` is `kind:!pdf`.
    private static func word(_ text: String, range: NSRange, calendar: Calendar) -> SearchQueryWord {
        // `!!kind:pdf`: one `!` too many before a condition's word, which can't be read.
        let marks = text.prefix { $0 == "!" }.count
        if marks > 1, let colon = text.firstIndex(of: ":"),
            let key = SearchQueryKey(rawValue: text[text.index(text.startIndex, offsetBy: marks)..<colon].lowercased())
        {
            return SearchQueryWord(range: range, text: text, key: key, role: .unfinished)
        }
        let negated = text.hasPrefix("!")
        let body = negated ? text.dropFirst() : Substring(text)
        guard !body.hasPrefix("\""), let colon = body.firstIndex(of: ":"),
            let key = SearchQueryKey(rawValue: body[..<colon].lowercased())
        else { return SearchQueryWord(range: range, text: text, key: nil, role: .text) }
        let value = (negated ? "!" : "") + body[body.index(after: colon)...]
        let role: SearchQueryWord.Role = condition(key, value, calendar: calendar).map { .condition($0) } ?? .unfinished
        return SearchQueryWord(range: range, text: text, key: key, role: role)
    }

    /// The text without its conditions, finished or not: Clear Search Conditions.
    public static func removingConditions(from query: String) -> String {
        SearchQuery(query).text
    }

    // MARK: Values

    static let kindAliases: [String: SearchKind] = [
        "pdfs": .pdf, "image": .picture, "images": .picture, "pictures": .picture, "photo": .picture,
        "photos": .picture, "videos": .video, "movie": .video, "movies": .video, "music": .audio, "sound": .audio,
        "doc": .document, "docs": .document, "documents": .document, "sheet": .spreadsheet, "sheets": .spreadsheet,
        "spreadsheets": .spreadsheet, "slides": .presentation, "presentations": .presentation, "archives": .archive,
        "zip": .archive, "source": .code, "folders": .folder, "app": .application, "apps": .application,
        "applications": .application,
    ]

    static let attributeWords: [String: SearchAttribute] = [
        "hidden": .hidden, "executable": .executable, "runnable": .executable, "readonly": .readOnly,
        "read-only": .readOnly, "locked": .locked, "empty": .empty, "tagged": .tagged, "file": .file,
        "folder": .folder, "alias": .alias, "link": .symbolicLink, "symlink": .symbolicLink, "cloud": .cloud,
        "downloaded": .downloaded, "broken": .broken,
    ]

    static let colorWords: [String: SearchTagColor] = Dictionary(
        uniqueKeysWithValues: SearchTagColor.allCases.map { ($0.rawValue, $0) } + [("grey", .gray)])

    /// The user a word of `owner:` names: `me`, a number, or a user's name on this Mac; nil for none.
    public static func ownerID(_ word: String) -> uid_t? {
        if word.lowercased() == "me" { return getuid() }
        if !word.isEmpty, word.allSatisfy(isDigit) { return uid_t(word) }
        guard let entry = getpwnam(word) else { return nil }
        return entry.pointee.pw_uid
    }

    /// The word each attribute is typed as.
    public static func attributeWord(_ attribute: SearchAttribute) -> String {
        switch attribute {
        case .hidden: "hidden"
        case .executable: "executable"
        case .readOnly: "readonly"
        case .locked: "locked"
        case .empty: "empty"
        case .tagged: "tagged"
        case .file: "file"
        case .folder: "folder"
        case .alias: "alias"
        case .symbolicLink: "link"
        case .cloud: "cloud"
        case .downloaded: "downloaded"
        case .broken: "broken"
        }
    }

    public static func kind(_ word: String) -> SearchKind? {
        let word = word.lowercased()
        return SearchKind(rawValue: word) ?? kindAliases[word]
    }

    /// The condition `key` with `value` asks for, or nil when the value can't be read.
    public static func condition(_ key: SearchQueryKey, _ value: String, calendar: Calendar = .current)
        -> SearchCondition?
    {
        // `!` asks for what the rest doesn't: an attribute's other value, anything else's not. Once only.
        if value.hasPrefix("!") {
            guard key.takesNot, !value.dropFirst().hasPrefix("!"),
                let asked = condition(key, String(value.dropFirst()), calendar: calendar)
            else { return nil }
            if case .attributes(let attributes, let isSo) = asked { return .attributes(attributes, is: !isSo) }
            return .not(asked)
        }
        let lower = value.lowercased()
        let list = lower.split(separator: ",").map(String.init).filter { !$0.isEmpty }
        guard !list.isEmpty || key.takesNames else { return nil }
        switch key {
        case .kind:
            let kinds = list.map(kind)
            guard kinds.allSatisfy({ $0 != nil }) else { return nil }
            return .kind(Set(kinds.compactMap { $0 }))
        case .ext:
            // `none` is a name without an extension; `.none` the extension itself.
            let extensions = list.map { $0 == "none" ? "" : $0.hasPrefix(".") ? String($0.dropFirst()) : $0 }
            guard
                zip(list, extensions).allSatisfy({ typed, ext in
                    typed == "none" || (!ext.isEmpty && ext.allSatisfy { $0.isLetter || $0.isNumber })
                })
            else { return nil }
            return .fileExtension(extensions)
        case .size:
            return size(lower).map { .size($0) }
        case .tag:
            // Tags by name, as typed: they are compared case aside.
            return names(value).map { .tags($0, all: false) }
        case .is, .not:
            // Any of them (`is:link,alias`); after `not:`, none of them. Each once, in the order typed.
            let attributes = list.map { attributeWords[$0] }
            guard attributes.allSatisfy({ $0 != nil }) else { return nil }
            var seen = Set<SearchAttribute>()
            return .attributes(attributes.compactMap { $0 }.filter { seen.insert($0).inserted }, is: key == .is)
        case .skip:
            return names(value).map { .skipFolders($0) }
        case .from:
            return names(value).map { .downloadedFrom($0) }
        case .color:
            let colors = list.map { colorWords[$0] }
            guard colors.allSatisfy({ $0 != nil }) else { return nil }
            var seen = Set<SearchTagColor>()
            return .tagColors(colors.compactMap { $0 }.filter { seen.insert($0).inserted })
        case .owner:
            // As typed: a user's name is told by the system, which may not take it case aside.
            let owners = value.split(separator: ",").map(String.init).filter { !$0.isEmpty }
            guard !owners.isEmpty, owners.allSatisfy({ ownerID($0) != nil }) else { return nil }
            return .owners(owners)
        case .perm:
            // As typed: `S` and `T` aren't `s` and `t`.
            let modes = value.split(separator: ",").map { SearchPermissions.permission(String($0)) }
            guard !modes.isEmpty, modes.allSatisfy({ $0 != nil }) else { return nil }
            return .permissions(modes.compactMap { $0 })
        case .modified, .created, .added, .opened:
            guard let field = key.dateField, let rule = dateRule(lower, calendar: calendar) else { return nil }
            return .date(field, rule)
        }
    }

    private static let units: [String: SearchSizeUnit] = [
        "b": .bytes, "kb": .kilobytes, "mb": .megabytes, "gb": .gigabytes,
        "k": .kilobytes, "m": .megabytes, "g": .gigabytes,
    ]

    /// What each unit is typed as.
    public static func unitWord(_ unit: SearchSizeUnit) -> String {
        switch unit {
        case .bytes: "b"
        case .kilobytes: "kb"
        case .megabytes: "mb"
        case .gigabytes: "gb"
        }
    }

    /// `>=` and `<=` (or `=>` and `=<`, as easily typed), `>` or `<` before a size or a day, and what follows it.
    public static func sign(_ value: String) -> (text: String, comparison: SearchComparison?, rest: Substring) {
        for (text, comparison) in [
            (">=", SearchComparison.atLeast), ("=>", .atLeast), ("<=", .atMost), ("=<", .atMost), (">", .larger),
            ("<", .smaller),
        ] where value.hasPrefix(text) {
            return (text, comparison, value.dropFirst(text.count))
        }
        return ("", nil, Substring(value))
    }

    /// The largest size read, in bytes: a million terabytes, past any file, and well inside what `Int64` counts.
    static let largestSize = 1e18

    /// Whether a number typed with these digits is whole bytes in `unit`: `1.5kb` is 1,500 bytes; `1.5b` and
    /// `1.2345kb` are no number of bytes, and no file is that size (`>1.2345kb` still reads: larger than it).
    static func isWholeBytes(_ digits: Substring, _ unit: SearchSizeUnit) -> Bool {
        let places = digits.firstIndex(of: ".").map { digits[digits.index(after: $0)...].count } ?? 0
        return places <= Int(log10(unit.bytes).rounded())
    }

    /// `>10mb`, `<500kb`, `>=1mb`, `<=1mb`, `1mb..10mb`, and `1mb` alone: to its last digit, so 1 MB up to 2 MB (`SearchSizeRule.bounds`);
    /// `k`, `m` and `g` are `kb`, `mb` and `gb`.
    static func size(_ value: String) -> SearchSizeRule? {
        func amount(_ text: Substring) -> (Double, SearchSizeUnit)? {
            let digits = text.prefix { $0.isNumber || $0 == "." }
            guard !digits.hasSuffix("."), let number = Double(digits), number > 0,
                let unit = units[String(text.dropFirst(digits.count))], number * unit.bytes <= largestSize
            else { return nil }
            return (number, unit)
        }
        if let dots = value.range(of: "..") {
            guard let low = amount(value[..<dots.lowerBound]), let high = amount(value[dots.upperBound...]) else {
                return nil
            }
            // Both in the smaller unit, so neither is rounded.
            let unit = low.1.bytes <= high.1.bytes ? low.1 : high.1
            return SearchSizeRule(
                comparison: .between, value: low.0 * low.1.bytes / unit.bytes,
                upper: high.0 * high.1.bytes / unit.bytes, unit: unit)
        }
        let (_, compared, rest) = sign(value)
        guard let (number, unit) = amount(rest) else { return nil }
        let comparison = compared ?? .equal
        // The places typed, kept where the number alone loses them (`2.10kb`).
        let digits = rest.prefix { $0.isNumber || $0 == "." }
        // A size alone is to its last digit, and a digit finer than a byte is no size a file has.
        if comparison == .equal, !isWholeBytes(digits, unit) { return nil }
        let places = digits.firstIndex(of: ".").map { digits[digits.index(after: $0)...].count } ?? 0
        return SearchSizeRule(
            comparison: comparison, value: number, unit: unit,
            places: comparison == .equal && places != SearchSizeRule.decimals(number) ? places : nil)
    }

    /// The most digits a count of days, weeks, months or years has.
    static let largestCountDigits = 4

    /// One of 0 to 9, and no other digit: a digit of another script, or one with a mark on it, is no number here.
    static func isDigit(_ character: Character) -> Bool {
        character.isASCII && character.isNumber
    }

    private static let spans: [Character: SearchTimeUnit] = ["d": .days, "w": .weeks, "m": .months, "y": .years]

    /// `today`, `yesterday`, `week`, `month`, `year`; `7d` within the last; `>1y` more than ago; `2026-03-15` or
    /// `2026-03` that day or month, `<` before it, `>` after it, `>=` from it on, `<=` to its end; `2026-01..2026-03`
    /// between.
    static func dateRule(_ value: String, calendar: Calendar) -> SearchDateRule? {
        switch value {
        case "today": return .today
        case "yesterday": return .yesterday
        case "week": return .thisWeek
        case "month": return .thisMonth
        case "year": return .thisYear
        default: break
        }
        // A count is up to four digits: nothing is 10,000 days old that a longer count would tell apart.
        func count(_ text: Substring) -> (Int, SearchTimeUnit)? {
            let digits = text.dropLast()
            guard let last = text.last, let unit = spans[last], (1...largestCountDigits).contains(digits.count),
                digits.allSatisfy(isDigit), let number = Int(digits), number > 0
            else { return nil }
            return (number, unit)
        }
        let (_, compared, rest) = sign(value)
        // More than so long ago, or at least: the two differ by an instant.
        if compared == .larger || compared == .atLeast, let (number, unit) = count(rest) {
            return .moreThanAgo(number, unit)
        }
        if let (number, unit) = count(Substring(value)) { return .withinLast(number, unit) }
        if let dots = value.range(of: "..") {
            guard let first = days(value[..<dots.lowerBound], calendar),
                let second = days(value[dots.upperBound...], calendar)
            else { return nil }
            // Typed the later one first, it is the same days: from the start of the earlier to the end of the later.
            // A day to its own month (`2026-03-15..2026-03`) is in order: from the day to the month's end.
            return first.first <= second.last
                ? .between(first.first, second.last) : .between(second.first, first.last)
        }
        if let compared, let span = days(rest, calendar) {
            switch compared {
            case .smaller: return .before(span.first)
            case .larger: return .after(span.last)
            case .atLeast: return .onOrAfter(span.first)
            case .atMost: return .onOrBefore(span.last)
            case .equal, .between: return nil
            }
        }
        guard let span = days(Substring(value), calendar) else { return nil }
        return .between(span.first, span.last)
    }

    /// The calendar a typed day is read in: the one `2026-03-15` is written in everywhere, in `calendar`'s time zone.
    /// A Mac whose own calendar counts years otherwise (2569, or 8 of an era) reads the same days from the same text.
    static func typedCalendar(_ calendar: Calendar) -> Calendar {
        guard calendar.identifier != .gregorian else { return calendar }
        var typed = Calendar(identifier: .gregorian)
        typed.timeZone = calendar.timeZone
        return typed
    }

    /// The first and last day of `2026-03-15` (the same day) or `2026-03` (the month).
    static func days(_ text: Substring, _ calendar: Calendar) -> (first: Date, last: Date)? {
        let calendar = typedCalendar(calendar)
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.allSatisfy({ $0.allSatisfy(isDigit) }) else { return nil }
        guard parts.count == 2 || parts.count == 3, parts[0].count == 4, let year = Int(parts[0]),
            parts[1].count == 2, let month = Int(parts[1]), (1...12).contains(month)
        else { return nil }
        if parts.count == 3 {
            guard parts[2].count == 2, let day = Int(parts[2]),
                let date = calendar.date(from: DateComponents(year: year, month: month, day: day)),
                calendar.component(.day, from: date) == day
            else { return nil }
            return (date, date)
        }
        guard let first = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
            let next = calendar.date(byAdding: .month, value: 1, to: first),
            let last = calendar.date(byAdding: .day, value: -1, to: next)
        else { return nil }
        return (first, last)
    }
}
