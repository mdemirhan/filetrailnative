// What the search field's list offers for the word at the caret: a condition's values after its word and colon, and,
// for a plain word, the conditions it could be besides the text to find.
import Foundation

public struct SearchQuerySuggestion: Equatable, Sendable {
    /// What the row says: "PDF", "Larger than 10 MB", "Date Modified".
    public var title: String
    /// What it types, shown at the row's end.
    public var hint: String
    /// What replaces the word at the caret; nil for the row that keeps the word as text to find.
    public var replacement: String?
    /// The replacement is a word and its colon: the list stays open with its values.
    public var keepsListOpen: Bool
    /// The row opens Help at Search, for the words and how they combine.
    public var opensHelp: Bool
    /// What the row is: a value to take, or what is wrong with a word and what would do (neither can be chosen).
    public var tone: Tone

    public enum Tone: Equatable, Sendable {
        case value
        /// "“perm:www” can’t be read".
        case problem
        /// What would do: "Not permissions: three digits like 755, …".
        case note
    }

    /// Whether ↑ ↓ reach it and Return, Tab or a click take it.
    public var canBeChosen: Bool { tone == .value }

    public init(
        title: String, hint: String, replacement: String?, keepsListOpen: Bool = false, opensHelp: Bool = false,
        tone: Tone = .value
    ) {
        self.title = title
        self.hint = hint
        self.replacement = replacement
        self.keepsListOpen = keepsListOpen
        self.opensHelp = opensHelp
        self.tone = tone
    }

}

public struct SearchQuerySuggestions: Equatable, Sendable {
    public struct Section: Equatable, Sendable {
        public var title: String?
        public var rows: [SearchQuerySuggestion]
    }

    /// The text a chosen row replaces, in UTF-16 units.
    public var range: NSRange
    public var sections: [Section]
    /// Whether the first row is highlighted from the start, for Return to take. A plain word's list starts with none,
    /// so Return searches for the word as a name; ↓ or Tab takes a condition.
    public var highlightsFirst = true
    /// What is typed of the word at the caret reads as it is (`size:1mb`, `kind:pdf`): Return and Tab keep it, rather
    /// than take a row nobody chose.
    public var typedIsComplete = false
    public var rows: [SearchQuerySuggestion] { sections.flatMap(\.rows) }

    /// At most this many values are listed.
    public static let maxValues = 12

    /// The words that can't be read, each with what would do, none to choose: for the word at the caret, or for every
    /// one when Return found them.
    public static func problems(_ problems: [SearchQueryProblem]) -> SearchQuerySuggestions? {
        guard let first = problems.first else { return nil }
        let rows = problems.flatMap { problem in
            [
                SearchQuerySuggestion(title: problem.title, hint: "", replacement: nil, tone: .problem),
                SearchQuerySuggestion(title: problem.detail, hint: "", replacement: nil, tone: .note),
            ]
        }
        return SearchQuerySuggestions(
            range: first.word.range, sections: [Section(title: "Can’t search yet", rows: rows)], highlightsFirst: false,
            typedIsComplete: true)
    }

    /// What to offer for `query` with the caret at `caret`; nil for nothing. `listsWordsForNewWord`: where a new word
    /// starts, in an empty field or after a whole condition, every condition's word is listed, none highlighted. `offersConditionWords`: a plain word offers the conditions it could be; the Edit Search
    /// box, which lists the words below, offers only a condition's values. `tags` and `folders` are offered after
    /// `tag:` and `skip:`.
    public static func make(
        query: String, caret: Int, tags: [String] = [], folders: [String] = [], listsWordsForNewWord: Bool = false,
        offersConditionWords: Bool = true, now: Date = Date(), calendar: Calendar = .current
    ) -> SearchQuerySuggestions? {
        let words = SearchQuery.words(query, calendar: calendar)
        guard let word = words.first(where: { caret >= $0.range.location && caret <= NSMaxRange($0.range) }) else {
            // A new word: after nothing or a whole condition, another condition is likely, so every word is listed;
            // after a word of the name, the name goes on.
            let afterCondition: Bool
            switch words.last(where: { NSMaxRange($0.range) < caret })?.role {
            case nil, .condition: afterCondition = true
            case .text, .unfinished: afterCondition = false
            }
            guard listsWordsForNewWord, afterCondition else { return nil }
            // Help is the link at the foot of every list (`SearchSyntaxHelpLink`), not a row: a row's end says what it
            // types.
            let rows = SearchQueryKey.menuOrder.map {
                SearchQuerySuggestion(title: $0.title, hint: $0.word, replacement: $0.word, keepsListOpen: true)
            }
            return SearchQuerySuggestions(
                range: NSRange(location: caret, length: 0), sections: [Section(title: "Conditions", rows: rows)],
                highlightsFirst: false)
        }
        if let key = word.key {
            // A word more typing can't save says what is wrong with it, and what would do.
            if !word.canStillBeRead {
                return problems(
                    SearchQuery.problems(word.text, calendar: calendar).map { problem in
                        var problem = problem
                        problem.word.range = word.range
                        return problem
                    })
            }
            // `kind:!pd` offers what `kind:pd` does, each a not.
            var value = word.value
            let not = key.takesNot && value.hasPrefix("!") ? "!" : ""
            value.removeFirst(not.count)
            let head = value.lastIndex(of: ",").map { String(value[...$0]) } ?? ""
            let partial = String(value.dropFirst(head.count))
            let rows = values(key, partial: partial, tags: tags, folders: folders, now: now, calendar: calendar)
                .map { title, typed in
                    SearchQuerySuggestion(
                        title: not.isEmpty ? title : "Not " + Self.inSentence(title), hint: not + typed,
                        replacement: String(word.text.prefix(word.keyLength)) + not + head + typed + " ")
                }
            guard !rows.isEmpty else { return nil }
            // A free name (a tag, a folder) is whole only once it is one listed.
            let complete =
                word.role != .unfinished
                && ((key != .tag && key != .skip) || rows.contains { $0.hint.lowercased() == word.value.lowercased() })
            return SearchQuerySuggestions(
                range: word.range, sections: [Section(title: key.title, rows: rows)], highlightsFirst: !complete,
                typedIsComplete: complete)
        }
        // A name left out (`!draft`), or the box's plain words: nothing to offer.
        guard offersConditionWords, !word.text.hasPrefix("!") else { return nil }
        let typed = word.text.lowercased()
        // A word is found by what is typed for it or by its name: "d" and "date" find every date, "tak" Date Taken.
        var rows: [SearchQuerySuggestion] = SearchQueryKey.menuOrder.filter { key in
            key.rawValue.hasPrefix(typed)
                || key.title.lowercased().split(separator: " ").contains { $0.hasPrefix(typed) }
        }.map {
            SearchQuerySuggestion(title: $0.title, hint: $0.word, replacement: $0.word, keepsListOpen: true)
        }
        if typed.count >= 2 {
            for kind in SearchKind.allCases
            where kind.rawValue.hasPrefix(typed) || kind.label.lowercased().hasPrefix(typed) {
                let condition = SearchCondition.kind([kind])
                rows.append(row(condition, typed: "kind:" + kind.rawValue))
            }
            if SearchKind.allCases.contains(where: { $0.extensions.contains(typed) }) {
                rows.append(row(.fileExtension([typed]), typed: "ext:" + typed))
            }
            for tag in tags where tag.lowercased().hasPrefix(typed) {
                rows.append(row(.tags([tag], all: false), typed: "tag:" + tag))
            }
        }
        guard !rows.isEmpty else { return nil }
        return SearchQuerySuggestions(
            range: word.range, sections: [Section(title: "Conditions", rows: rows)], highlightsFirst: false)
    }

    private static func row(_ condition: SearchCondition, typed: String) -> SearchQuerySuggestion {
        SearchQuerySuggestion(title: SearchConditionText.chip(condition), hint: typed, replacement: typed + " ")
    }

    /// The values `key` lists for `partial`: (what the row says, what it types).
    static func values(
        _ key: SearchQueryKey, partial: String, tags: [String], folders: [String], now: Date, calendar: Calendar
    ) -> [(String, String)] {
        let typed = partial.lowercased()
        var all: [(String, String)] = []
        switch key {
        case .kind:
            all = SearchKind.allCases.map { ($0.label, $0.rawValue) }
        case .ext:
            let common = [
                "pdf", "jpg", "png", "heic", "mov", "mp4", "mp3", "docx", "xlsx", "key", "zip", "swift", "txt",
            ]
            // Typed without a dot, and listed without one: "DOCX files" types `docx`.
            all = common.map { ("\($0.uppercased()) files", $0) }
        case .size:
            return sizes(typed)
        case .picture:
            all = [
                ("1,920 px (HD)", "hd"), ("3,840 px (4K)", "4k"), ("HD or larger", ">=hd"), ("4K or larger", ">=4k"),
                ("Larger than 4K", ">4k"), ("Smaller than HD", "<hd"),
            ]
        case .modified, .created, .added, .opened, .taken:
            if let number = Int(typed), number > 0 {
                return [
                    ("Within the last \(number) \(SearchTimeUnit.days.label(number))", "\(number)d"),
                    ("Within the last \(number) \(SearchTimeUnit.weeks.label(number))", "\(number)w"),
                    ("Within the last \(number) \(SearchTimeUnit.months.label(number))", "\(number)m"),
                    ("Within the last \(number) \(SearchTimeUnit.years.label(number))", "\(number)y"),
                    ("More than \(number) \(SearchTimeUnit.years.label(number)) ago", ">\(number)y"),
                ]
            }
            let year = calendar.component(.year, from: now)
            let lastMonth = calendar.date(byAdding: .month, value: -1, to: now) ?? now
            let monthName = lastMonth.formatted(.dateTime.month(.wide).year().locale(Locale(identifier: "en_US")))
            let monthWord = String(
                format: "%04d-%02d", calendar.component(.year, from: lastMonth),
                calendar.component(.month, from: lastMonth))
            all = [
                ("Today", "today"), ("Yesterday", "yesterday"), ("This week", "week"), ("This month", "month"),
                ("This year", "year"), ("Within the last 7 days", "7d"), ("Within the last 30 days", "30d"),
                ("More than a year ago", ">1y"), ("In \(monthName)", monthWord),
                ("From \(monthName) on", ">=" + monthWord),
                ("Between two days", "\(year)-01-01..\(year)-03-31"),
            ]
        case .tag:
            all = tags.map { ($0, $0) }
        case .is, .not:
            all = SearchAttribute.allCases.map { ($0.chip(is: key == .is), SearchQuery.attributeWord($0)) }
        case .skip:
            all = folders.map { ($0, $0) }
        case .perm:
            all = [0o755, 0o644, 0o700, 0o600, 0o750, 0o640, 0o777, 0o666, 0o444].map {
                (SearchPermissions.letters($0), SearchPermissions.octal($0) ?? "")
            }
        }
        var shown =
            typed.isEmpty ? all : all.filter { $0.1.lowercased().hasPrefix(typed) || $0.0.lowercased().contains(typed) }
        // What is typed, when it can be read and no listed value starts with it, comes first.
        if !typed.isEmpty, !shown.contains(where: { $0.1.lowercased().hasPrefix(typed) }),
            let condition = SearchQuery.condition(key, partial, calendar: calendar)
        {
            shown.insert((sentence(condition, key), partial), at: 0)
        }
        return Array(shown.prefix(maxValues))
    }

    /// What a size offers: the examples, one of each kind (larger, smaller, the size itself, between); a number, in
    /// each unit, as typed (`>50` larger, `50` the size itself); a range only once `..` is typed, from what is before
    /// it.
    private static func sizes(_ typed: String) -> [(String, String)] {
        let units: [SearchSizeUnit] = [.kilobytes, .megabytes, .gigabytes, .bytes]
        if let dots = typed.range(of: "..") {
            let low = String(typed[..<dots.lowerBound])
            let high = String(typed[dots.upperBound...])
            guard let lower = SearchQuery.size(low), lower.comparison == .equal else { return [] }
            let uppers: [(Double, SearchSizeUnit)]
            if high.isEmpty {
                uppers = [(lower.value * 10, lower.unit), (lower.value * 100, lower.unit)]
            } else if let number = Double(high) {
                uppers = units.map { (number, $0) }
            } else if let upper = SearchQuery.size(high) {
                uppers = [(upper.value, upper.unit)]
            } else {
                return []
            }
            // Only an upper end above the lower one.
            return uppers.compactMap { value, unit in
                guard value * unit.bytes > lower.value * lower.unit.bytes else { return nil }
                let text = low + ".." + number(value) + SearchQuery.unitWord(unit)
                return SearchQuery.size(text).map { (sizeTitle($0), text) }
            }
        }
        // What reads as it is says what it means, the same for any unit.
        if let rule = SearchQuery.size(typed) { return [(sizeTitle(rule), typed)] }
        let sign = SearchQuery.sign(typed).text
        let digits = String(typed.dropFirst(sign.count))
        if !digits.isEmpty, Double(digits) != nil {
            return units.compactMap { unit in
                let text = sign + digits + SearchQuery.unitWord(unit)
                return SearchQuery.size(text).map { (sizeTitle($0), text) }
            }
        }
        let examples = [">10mb", ">100mb", ">1gb", "<1mb", "1mb", "1mb..10mb"].compactMap { text in
            SearchQuery.size(text).map { (sizeTitle($0), text) }
        }
        return typed.isEmpty ? examples : examples.filter { !$0.1.contains("..") && $0.1.hasPrefix(typed) }
    }

    /// A number as typed: no point for a whole one.
    private static func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }

    /// A title inside a sentence: "Larger than 1 MB" is "larger than 1 MB", "Today" "today"; a name in capitals stays
    /// (`PDF`).
    private static func inSentence(_ title: String) -> String {
        let letters = Array(title)
        guard letters.count > 1, letters[0].isUppercase, letters[1].isLowercase else { return title }
        return title.prefix(1).lowercased() + title.dropFirst()
    }

    private static func sizeTitle(_ rule: SearchSizeRule) -> String {
        let words = SearchConditionText.chip(.size(rule))
        return String(words.dropFirst("Size is ".count)).capitalizedFirst
    }

    /// The condition's sentence without its subject, as a value row says it: "Larger than 37 MB".
    private static func sentence(_ condition: SearchCondition, _ key: SearchQueryKey) -> String {
        let chip = SearchConditionText.chip(condition)
        let subjects =
            ["Kind is ", "Extension is ", "Size is ", "Picture is ", "Tagged ", "Skipping ", "Permissions are "]
            + SearchDateField.allCases.map { $0.chipLabel + " " }
        for subject in subjects where chip.hasPrefix(subject) {
            return String(chip.dropFirst(subject.count)).capitalizedFirst
        }
        return chip
    }
}

extension String {
    fileprivate var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
