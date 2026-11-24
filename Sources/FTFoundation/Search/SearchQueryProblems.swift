// A condition's word that can't be read: whether more typing could still make it a value, and what its values are.
// A word that could is being typed and is left alone; one that can't is marked at once, the list says what would do,
// and nothing is searched while it stays (`SearchQuery.problems`).
import Foundation

extension SearchQueryKey {
    /// What its values are, said where a word can't be read: "Not a size: a number and a unit, like …".
    public var expects: String {
        switch self {
        case .kind:
            "Not a kind: pdf, picture, video, audio, document, spreadsheet, presentation, archive, code, text, folder or application"
        case .ext: "Not an extension: letters and digits, like docx or mp4"
        case .size: "Not a size: a number and a unit, like 10mb, >1gb, <500kb, >=1mb or 1mb..10mb"
        case .picture: "Not a picture size: 1920, 4k, >hd, >=hd or <1920"
        case .modified, .created, .added, .opened, .taken:
            "Not a date: today, week, 7d, >1y, 2026-03-15, <2026-03, >=2026-03 or 2026-01..2026-03"
        case .tag: "Not a tag"
        case .is, .not: "Not an attribute: locked, readonly, executable, empty, alias, link or hidden"
        case .perm: "Not permissions: three digits like 755, or letters like rwxr-xr-x; ? for any"
        case .skip: "Not a folder's name"
        }
    }
}

/// A word of the search that can't be read, and what would do there.
public struct SearchQueryProblem: Equatable, Sendable {
    public var word: SearchQueryWord
    /// "“perm:www” can’t be read".
    public var title: String
    /// "Not permissions: three digits like 755, or letters like rwxr-xr-x; ? for any".
    public var detail: String
    /// Both, as a sentence each.
    public var message: String { title + ". " + detail }
}

extension SearchQuery {
    /// The words of `query` that can't be read: all of them, or only those more typing couldn't save (`whileTyping`,
    /// with the caret at `caret`, whose word is left alone while it can still become a value).
    public static func problems(
        _ query: String, caret: Int? = nil, whileTyping: Bool = false, calendar: Calendar = .current
    ) -> [SearchQueryProblem] {
        words(query, calendar: calendar).compactMap { word in
            guard word.role == .unfinished, let key = word.key else { return nil }
            if whileTyping {
                let typing = caret.map { $0 >= word.range.location && $0 <= NSMaxRange(word.range) } ?? false
                if typing && word.canStillBeRead { return nil }
            }
            return SearchQueryProblem(word: word, title: "“\(word.text)” can’t be read", detail: detail(word, key))
        }
    }

    private static func detail(_ word: SearchQueryWord, _ key: SearchQueryKey) -> String {
        if word.text.hasPrefix("!!") || word.value.hasPrefix("!!") { return "One ! is enough" }
        if (word.text.hasPrefix("!") || word.value.hasPrefix("!")) && !key.takesNot {
            return "A folder skipped is already left out: no ! before it"
        }
        if word.value.isEmpty { return key.expects.replacingOccurrences(of: "Not ", with: "Give ") }
        return key.expects
    }

    /// Whether what follows `key:` could still be read once more is typed after it: the start of a value, or of a list
    /// of values whose earlier ones are whole.
    public static func canBecome(_ key: SearchQueryKey, _ value: String) -> Bool {
        if value.hasPrefix("!") {
            guard key.takesNot, !value.dropFirst().hasPrefix("!") else { return false }
            return canBecome(key, String(value.dropFirst()))
        }
        switch key {
        case .size: return sizeCanBecome(value)
        case .picture: return pictureCanBecome(value)
        case .modified, .created, .added, .opened, .taken: return dateCanBecome(value)
        case .tag, .skip: return true
        case .kind, .ext, .is, .not, .perm:
            // Values before the last comma are whole ones; the last is the start of one.
            let parts = value.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard parts.dropLast().allSatisfy({ $0.isEmpty || condition(key, $0) != nil }) else { return false }
            return valueCanBecome(key, parts.last ?? "")
        }
    }

    private static func valueCanBecome(_ key: SearchQueryKey, _ value: String) -> Bool {
        let lower = value.lowercased()
        if lower.isEmpty { return true }
        switch key {
        case .kind:
            return SearchKind.allCases.contains { $0.rawValue.hasPrefix(lower) }
                || kindAliases.keys.contains {
                    $0.hasPrefix(lower)
                }
        case .ext:
            let name = lower.hasPrefix(".") ? lower.dropFirst() : Substring(lower)
            return name.allSatisfy { $0.isLetter || $0.isNumber }
        case .is, .not:
            return attributeWords.keys.contains { $0.hasPrefix(lower) }
        case .perm:
            return permissionCanBecome(value)
        default:
            return true
        }
    }

    // MARK: Each kind of value

    /// Digits to four, each 0 to 7 or `?`; or letters, each one that can stand at its place, the type before them
    /// as `ls` writes it, or not.
    static func permissionCanBecome(_ value: String) -> Bool {
        let letters = Array(value)
        if letters.count <= 4, letters.allSatisfy({ ("0"..."7").contains($0) || $0 == "?" }) { return true }
        func fits(_ letters: ArraySlice<Character>) -> Bool {
            guard letters.count <= 9 else { return false }
            for (index, letter) in letters.enumerated() {
                var allowed: Set<Character> = ["-", "?", ["r", "w", "x"][index % 3]]
                if index == 2 || index == 5 { allowed.formUnion(["s", "S"]) }
                if index == 8 { allowed.formUnion(["t", "T"]) }
                if !allowed.contains(letter) { return false }
            }
            return true
        }
        if fits(letters[...]) { return true }
        // `ls`'s ten letters start with the item's type.
        guard let first = letters.first, "-dlbcps".contains(first) else { return false }
        return fits(letters.dropFirst())
    }

    /// A sign, a number, and the start of a unit; or a whole size, `..`, and the start of another.
    static func sizeCanBecome(_ value: String) -> Bool {
        let lower = value.lowercased()
        // The start of `=>` or `=<`.
        if lower == "=" { return true }
        let (text, _, typed) = sign(lower)
        let sign = !text.isEmpty
        let rest = String(typed)
        if let dots = rest.range(of: "..") {
            guard !sign, size(String(rest[..<dots.lowerBound])) != nil else { return false }
            return amountCanBecome(String(rest[dots.upperBound...]))
        }
        if amountCanBecome(rest) { return true }
        // A whole size and a point: the start of `..`.
        return !sign && rest.hasSuffix(".") && size(String(rest.dropLast())) != nil
    }

    /// A number, then the start of a unit: a number with no unit yet may be anything above 0 once one comes; with one,
    /// it must be.
    private static func amountCanBecome(_ text: String) -> Bool {
        let digits = text.prefix { $0.isNumber || $0 == "." }
        guard digits.filter({ $0 == "." }).count <= 1 else { return false }
        let unit = String(text.dropFirst(digits.count))
        guard ["", "b", "k", "kb", "m", "mb", "g", "gb"].contains(unit) else { return false }
        if unit.isEmpty { return true }
        guard let number = Double(digits), number > 0 else { return false }
        return true
    }

    /// A sign, then digits and `k`, or the start of `hd`.
    static func pictureCanBecome(_ value: String) -> Bool {
        let lower = value.lowercased()
        if lower == "=" { return true }
        let rest = sign(lower).rest
        if rest.isEmpty || "hd".hasPrefix(rest) { return true }
        let digits = rest.prefix { $0.isNumber }
        let after = rest.dropFirst(digits.count)
        guard !digits.isEmpty, after.isEmpty || after == "k" else { return false }
        return Int(digits).map { $0 > 0 } ?? false || after.isEmpty
    }

    /// The start of a word (`today`, `week`), of a count (`7d`, `>1y`), or of a day or a month with a sign or `..`.
    static func dateCanBecome(_ value: String) -> Bool {
        let lower = value.lowercased()
        if ["today", "yesterday", "week", "month", "year"].contains(where: { $0.hasPrefix(lower) }) { return true }
        if lower == "=" { return true }
        let (_, compared, typed) = sign(lower)
        let rest = String(typed)
        // A count: digits, then a unit after one above 0. `<` and `<=` are for days and months only.
        let digits = rest.prefix { $0.isNumber }
        let after = rest.dropFirst(digits.count)
        let before = compared == .smaller || compared == .atMost
        if !before, after.isEmpty || (after.count == 1 && "dwmy".contains(after)) {
            if after.isEmpty { return digits.count <= 4 || dayCanBecome(rest) }
            return Int(digits).map { $0 > 0 } ?? false
        }
        if let dots = rest.range(of: "..") {
            guard compared == nil, days(Substring(rest[..<dots.lowerBound]), .current) != nil
            else { return false }
            return dayCanBecome(String(rest[dots.upperBound...]))
        }
        if dayCanBecome(rest) { return true }
        // A whole day or month and a point: the start of `..`.
        return compared == nil && rest.hasSuffix(".") && days(Substring(rest.dropLast()), .current) != nil
    }

    /// The start of `YYYY-MM-DD`: four digits, a dash, a month of 01 to 12, a dash, a day of 01 to 31.
    private static func dayCanBecome(_ text: String) -> Bool {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard parts.count <= 3, parts.allSatisfy({ $0.allSatisfy(\.isNumber) }) else { return false }
        let year = parts[0]
        guard year.count <= 4, parts.count == 1 || year.count == 4 else { return false }
        if parts.count >= 2 {
            let month = parts[1]
            guard month.count <= 2, parts.count == 2 || month.count == 2 else { return false }
            if month.count == 1, !"01".contains(month) { return false }
            if month.count == 2, !(1...12).contains(Int(month) ?? 0) { return false }
        }
        if parts.count == 3 {
            let day = parts[2]
            guard day.count <= 2 else { return false }
            if day.count == 1, !"0123".contains(day) { return false }
            if day.count == 2, !(1...31).contains(Int(day) ?? 0) { return false }
        }
        return true
    }
}

extension SearchQueryWord {
    /// Whether more typing after it could make it a condition: one being typed (`size:1`, `kind:pd`), not one that
    /// can never be (`perm:www`, `kind:zzz`, `!!kind:pdf`). Any word that reads as it is can.
    public var canStillBeRead: Bool {
        guard role == .unfinished, let key else { return true }
        if text.hasPrefix("!!") { return false }
        return SearchQuery.canBecome(key, (text.hasPrefix("!") ? "!" : "") + value)
    }
}
