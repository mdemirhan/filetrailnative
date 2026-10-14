// Port of apps/desktop/src/shared/batchRename.ts: the new name each item gets, from the Rename sheet's settings
import Foundation

/// Renaming several items at once. Pure functions only: the folders' contents and the items' dates are passed in.
public enum BatchRename {
    public static let maxPresets = 50
    static let maxTextSettingLength = 255
    static let maxNumberSetting = 999_999_999

    // MARK: Names

    /// The new name of every item, in the order given: that order numbers them. `now` is the moment the sheet
    /// opened, for Today. Names are trimmed of spaces at their ends, as the single rename does.
    public static func proposeNames(
        settings: BatchRenameSettings, items: [BatchRenameItem], now: LocalDateTime
    ) -> ProposedNames {
        let settingsError = settingsError(settings)
        if settingsError != nil {
            return ProposedNames(settingsError: settingsError, names: items.map { _ in .unchanged })
        }
        let pattern = settings.mode == .replace ? try? findPattern(settings) : nil
        let names = items.enumerated().map { index, item -> ProposedName in
            let result =
                settings.mode == .format
                ? formatName(settings, item, index: index, count: items.count, now: now)
                : transformInScope(settings, item, pattern: pattern)
            guard let result else { return .unchanged }
            let trimmed = trimSegments(result.segments)
            let name = trimmed.map(\.text).joined()
            // The same name with its accents written another way is the same name to the disk.
            if sameAfterNFC(name, item.name) {
                return .unchanged
            }
            return .renamed(
                name: name, segments: mergeSegments(trimmed), usedCreatedForTaken: result.usedCreatedForTaken,
                emptyName: result.emptyName)
        }
        return ProposedNames(settingsError: nil, names: names)
    }

    /// What is wrong with the settings as typed, or nil.
    public static func settingsError(_ settings: BatchRenameSettings) -> String? {
        if settings.mode == .replace, settings.useRegex, !settings.find.isEmpty {
            do {
                _ = try findPattern(settings)
            } catch {
                let message = (error as? JSRegExpError)?.message ?? "\(error)"
                return "The pattern isn\u{2019}t valid: \(message)"
            }
        }
        if settings.mode == .format, settings.nameFormat == .date, settings.dateFormat == .custom,
            !hasDateToken(removingBrackets(settings.customDatePattern))
        {
            return "Put at least one of YYYY, YY, MM, DD, HH, mm or ss in the date pattern"
        }
        return nil
    }

    static func nfc(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping
    }

    static func sameAfterNFC(_ left: String, _ right: String) -> Bool {
        nfc(left).utf8.elementsEqual(nfc(right).utf8)
    }

    /// The pattern Replace Text looks for; nil when there is nothing to find. Names and what is typed are compared
    /// with accents written one way: "é" typed as one character finds it written as "e" and an accent.
    static func findPattern(_ settings: BatchRenameSettings) throws -> JSRegExp? {
        guard !settings.find.isEmpty else { return nil }
        let find = nfc(settings.find)
        return settings.useRegex
            ? try JSRegExp(source: find, ignoreCase: !settings.matchCase)
            : try JSRegExp(literal: find, ignoreCase: !settings.matchCase)
    }

    private struct Transformed {
        var segments: [NameSegment]
        var usedCreatedForTaken = false
        var emptyName = false
    }

    // Replace Text, Add Text and Change Case work on the part Apply To names; the rest of the name stays as it is.
    private static func transformInScope(
        _ settings: BatchRenameSettings, _ item: BatchRenameItem, pattern: JSRegExp?
    ) -> Transformed? {
        let split = NumberedNames.splitItemName(item.name, isFolder: item.isFolder)
        func transform(_ part: String) -> [NameSegment]? { transformText(settings, part, pattern: pattern) }
        switch settings.applyTo {
        case .both:
            return transform(item.name).map { Transformed(segments: $0) }
        case .extensionPart:
            guard let ext = split.extension, let changed = transform(ext) else { return nil }
            // An extension replaced with nothing takes its dot with it: "a", not "a.".
            if changed.allSatisfy({ JSString.trimmed($0.text).isEmpty }) {
                return Transformed(segments: [NameSegment(text: split.stem, changed: false)])
            }
            return Transformed(segments: [NameSegment(text: "\(split.stem).", changed: false)] + changed)
        case .name:
            guard let changed = transform(split.stem) else { return nil }
            // The name's own ends lose their spaces, not just the whole name's: "a copy.txt" without "copy" is
            // "a.txt", not "a .txt".
            let trimmedStem = trimSegments(changed)
            guard let ext = split.extension else { return Transformed(segments: trimmedStem) }
            return Transformed(
                segments: trimmedStem + [NameSegment(text: ".\(ext)", changed: false)],
                emptyName: trimmedStem.isEmpty)
        }
    }

    // One part of a name changed by Replace Text, Add Text or Change Case; nil when it isn't.
    private static func transformText(
        _ settings: BatchRenameSettings, _ part: String, pattern: JSRegExp?
    ) -> [NameSegment]? {
        switch settings.mode {
        case .replace:
            return pattern.flatMap { replaceText(part, pattern: $0, settings: settings) }
        case .add:
            guard !settings.addText.isEmpty else { return nil }
            let added = NameSegment(text: settings.addText, changed: true)
            let kept = NameSegment(text: part, changed: false)
            return settings.addWhere == .after ? [kept, added] : [added, kept]
        case .changeCase, .format:
            let changed = changeCase(part, settings.caseStyle)
            return changed.utf8.elementsEqual(part.utf8) ? nil : [NameSegment(text: changed, changed: true)]
        }
    }

    // Every match is replaced. With a regular expression, the replacement can name what the pattern captured
    // ($1, $<name>, $&); plain text is put in as typed.
    private static func replaceText(
        _ original: String, pattern: JSRegExp, settings: BatchRenameSettings
    ) -> [NameSegment]? {
        let part = nfc(original)
        let matches = pattern.matches(in: part)
        guard !matches.isEmpty else { return nil }
        let units = Array(part.utf16)
        var segments: [NameSegment] = []
        var position = 0
        for match in matches {
            if match.index > position {
                segments.append(NameSegment(text: JSString.string(units[position..<match.index]), changed: false))
            }
            let replacement =
                settings.useRegex
                ? expandReplacement(settings.replaceWith, match: match, subject: part) : settings.replaceWith
            segments.append(NameSegment(text: replacement, changed: true))
            position = match.index + match.text.utf16.count
        }
        if position < units.count {
            segments.append(NameSegment(text: JSString.string(units[position...]), changed: false))
        }
        return segments
    }

    /// A replacement with what was matched put in, as JavaScript's String.replace does: $$ is a dollar sign, $& the
    /// match, $` and $' what is before and after it, $1 to $99 the groups, $<name> a named group. Anything else is
    /// kept as typed.
    static func expandReplacement(_ template: String, match: JSMatch, subject: String) -> String {
        let units = Array(template.utf16)
        let subjectUnits = Array(subject.utf16)
        let groupCount = match.groups.count - 1
        let start = match.index
        let matched = Array(match.text.utf16)
        func isDigit(_ unit: UInt16) -> Bool { (0x30...0x39).contains(unit) }
        func group(_ number: Int) -> [UInt16] { Array((match.groups[number] ?? "").utf16) }
        var result: [UInt16] = []
        var index = 0
        while index < units.count {
            let character = units[index]
            if character != 0x24 || index == units.count - 1 {
                result.append(character)
                index += 1
                continue
            }
            let next = units[index + 1]
            if next == 0x24 {  // $$
                result.append(0x24)
                index += 2
            } else if next == 0x26 {  // $&
                result += matched
                index += 2
            } else if next == 0x60 {  // $`
                result += subjectUnits[..<min(start, subjectUnits.count)]
                index += 2
            } else if next == 0x27 {  // $'
                result += subjectUnits[min(start + matched.count, subjectUnits.count)...]
                index += 2
            } else if next == 0x3C, let named = match.namedGroups {
                guard let close = units[(index + 2)...].firstIndex(of: 0x3E) else {
                    result.append(character)
                    index += 1
                    continue
                }
                let name = JSString.string(units[(index + 2)..<close])
                result += Array(((named[name] ?? nil) ?? "").utf16)
                index = close + 1
            } else if isDigit(next) {
                // Two digits when that group exists ($12), else one ($1 followed by "2").
                if index + 2 < units.count, isDigit(units[index + 2]) {
                    let two = Int(next - 0x30) * 10 + Int(units[index + 2] - 0x30)
                    if two >= 1, two <= groupCount {
                        result += group(two)
                        index += 3
                        continue
                    }
                }
                let one = Int(next - 0x30)
                if one >= 1, one <= groupCount {
                    result += group(one)
                    index += 2
                    continue
                }
                result.append(character)
                index += 1
            } else {
                result.append(character)
                index += 1
            }
        }
        return JSString.string(result)
    }

    /// lowercase, UPPERCASE, or Title Case: the first letter of each word up, the rest as is.
    public static func changeCase(_ text: String, _ style: BatchRenameCase) -> String {
        switch style {
        case .lower:
            return JSString.lowercased(text)
        case .upper:
            return uppercased(text)
        case .title:
            return titleCased(text)
        }
    }

    /// `toUpperCase()`: Unicode's full upper-case mappings ("ß" is "SS"), with no rule that depends on the language.
    private static func uppercased(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            result.append(contentsOf: scalar.properties.uppercaseMapping.unicodeScalars)
        }
        return String(result)
    }

    // `text.replace(/(^|[\s_\-.([{])(\p{Ll})/gu, …)`: a lower-case letter at the start or after white space,
    // "_", "-", ".", "(", "[" or "{" is raised. The character before is part of the match, so it can't also be the
    // letter of another.
    private static func titleCased(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        func isLower(_ scalar: Unicode.Scalar) -> Bool { scalar.properties.generalCategory == .lowercaseLetter }
        func isSeparator(_ scalar: Unicode.Scalar) -> Bool {
            switch scalar {
            case "_", "-", ".", "(", "[", "{": true
            default: scalar.value <= 0xFFFF && JSString.isWhitespace(UInt16(scalar.value))
            }
        }
        var result = String.UnicodeScalarView()
        var index = 0
        while index < scalars.count {
            if index == 0, isLower(scalars[0]) {
                result.append(contentsOf: scalars[0].properties.uppercaseMapping.unicodeScalars)
                index = 1
            } else if isSeparator(scalars[index]), index + 1 < scalars.count, isLower(scalars[index + 1]) {
                result.append(scalars[index])
                result.append(contentsOf: scalars[index + 1].properties.uppercaseMapping.unicodeScalars)
                index += 2
            } else {
                result.append(scalars[index])
                index += 1
            }
        }
        return String(result)
    }

    // MARK: Format

    // Format: a new name, or the name kept, with a number or a date after or before it. The extension is always kept.
    private static func formatName(
        _ settings: BatchRenameSettings, _ item: BatchRenameItem, index: Int, count: Int, now: LocalDateTime
    ) -> Transformed? {
        let split = NumberedNames.splitItemName(item.name, isFolder: item.isFolder)
        let tag: String
        var usedCreatedForTaken = false
        if settings.nameFormat == .date {
            var date: LocalDateTime?
            switch settings.dateSource {
            case .taken:
                date = item.takenAt
                if date == nil {
                    date = item.createdAt
                    usedCreatedForTaken = true
                }
            case .created: date = item.createdAt
            case .modified: date = item.modifiedAt
            case .today: date = now
            }
            guard let date else { return nil }
            tag = formatDate(date, settings)
        } else {
            tag = formatNumber(settings, index: index, count: count)
        }
        let base = settings.keepNames ? split.stem : settings.customName
        let baseSegment = NameSegment(text: base, changed: !settings.keepNames)
        let tagSegment = NameSegment(
            text: settings.formatWhere == .after ? "\(settings.separator.rawValue)\(tag)" : "\(tag)\(settings.separator.rawValue)",
            changed: true)
        var segments = settings.formatWhere == .after ? [baseSegment, tagSegment] : [tagSegment, baseSegment]
        if let ext = split.extension {
            segments.append(NameSegment(text: ".\(ext)", changed: false))
        }
        return Transformed(segments: segments, usedCreatedForTaken: usedCreatedForTaken)
    }

    /// The number of the item at `index`: Index as is, Counter padded with zeros.
    public static func formatNumber(_ settings: BatchRenameSettings, index: Int, count: Int) -> String {
        let value = settings.startAt + index * settings.step
        guard settings.nameFormat == .counter else { return String(value) }
        let width: Int
        switch settings.digits {
        case .auto: width = String(settings.startAt + max(0, count - 1) * settings.step).count
        case .fixed(let digits): width = digits
        }
        let text = String(value)
        return String(repeating: "0", count: max(0, width - text.count)) + text
    }

    // MARK: Dates

    private static let tokenPattern: [[UInt16]] = ["YYYY", "YY", "MM", "DD", "HH", "mm", "ss"].map { Array($0.utf16) }

    /// A date in the chosen format: its parts with the separator between them, or the pattern.
    public static func formatDate(_ date: LocalDateTime, _ settings: BatchRenameSettings) -> String {
        let parts = readLocalDateTime(date)
        func value(_ token: BatchRenameDateToken) -> String {
            let number: Int
            let width: Int
            switch token {
            case .year4: (number, width) = (parts.year, 4)
            case .year2: (number, width) = (parts.year % 100, 2)
            case .month: (number, width) = (parts.month, 2)
            case .day: (number, width) = (parts.day, 2)
            case .hour: (number, width) = (parts.hour, 2)
            case .minute: (number, width) = (parts.minute, 2)
            case .second: (number, width) = (parts.second, 2)
            }
            let text = String(number)
            return String(repeating: "0", count: max(0, width - text.count)) + text
        }
        guard settings.dateFormat == .custom else {
            return settings.dateFormat.tokens.map(value).joined(separator: settings.dateSeparator.rawValue)
        }
        // /\[([^\]]*)\]|YYYY|YY|MM|DD|HH|mm|ss/gu: text in square brackets is kept as typed, so a word can hold
        // letters like "ss".
        let units = Array(settings.customDatePattern.utf16)
        var result: [UInt16] = []
        var index = 0
        while index < units.count {
            if units[index] == 0x5B, let close = units[(index + 1)...].firstIndex(of: 0x5D) {
                result += units[(index + 1)..<close]
                index = close + 1
            } else if let token = BatchRenameDateToken.allCases.first(where: { matches($0, in: units, at: index) }) {
                result += Array(value(token).utf16)
                index += token.rawValue.utf16.count
            } else {
                result.append(units[index])
                index += 1
            }
        }
        return JSString.string(result)
    }

    private static func matches(_ token: BatchRenameDateToken, in units: [UInt16], at index: Int) -> Bool {
        let wanted = Array(token.rawValue.utf16)
        return index + wanted.count <= units.count && units[index..<index + wanted.count].elementsEqual(wanted)
    }

    private static func removingBrackets(_ pattern: String) -> String {
        // /\[[^\]]*\]/gu
        let units = Array(pattern.utf16)
        var result: [UInt16] = []
        var index = 0
        while index < units.count {
            if units[index] == 0x5B, let close = units[(index + 1)...].firstIndex(of: 0x5D) {
                index = close + 1
            } else {
                result.append(units[index])
                index += 1
            }
        }
        return JSString.string(result)
    }

    private static func hasDateToken(_ pattern: String) -> Bool {
        let units = Array(pattern.utf16)
        return units.indices.contains { index in
            BatchRenameDateToken.allCases.contains { matches($0, in: units, at: index) }
        }
    }

    /// How a date format reads with the separator chosen: "YYYY-MM-DD", "DDMMYY".
    public static func describeDateFormat(_ format: BatchRenameDateFormat, separator: BatchRenameDateSeparator)
        -> String
    {
        format.tokens.map(\.rawValue).joined(separator: separator.rawValue)
    }

    public struct LocalDateParts: Equatable, Sendable {
        public var year = 0
        public var month = 0
        public var day = 0
        public var hour = 0
        public var minute = 0
        public var second = 0
    }

    /// `/^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})/u`; a date it can't read is all zeros.
    public static func readLocalDateTime(_ date: LocalDateTime) -> LocalDateParts {
        let units = Array(date.utf16)
        // Positions of the digit groups: 4, 2, 2, 2, 2, 2 with "-", "-", "T", ":", ":" between.
        let layout: [(start: Int, length: Int)] = [(0, 4), (5, 2), (8, 2), (11, 2), (14, 2), (17, 2)]
        let separators: [(Int, UInt16)] = [(4, 0x2D), (7, 0x2D), (10, 0x54), (13, 0x3A), (16, 0x3A)]
        guard units.count >= 19, separators.allSatisfy({ units[$0.0] == $0.1 }) else { return LocalDateParts() }
        var values: [Int] = []
        for (start, length) in layout {
            var number = 0
            for unit in units[start..<start + length] {
                guard (0x30...0x39).contains(unit) else { return LocalDateParts() }
                number = number * 10 + Int(unit - 0x30)
            }
            values.append(number)
        }
        return LocalDateParts(
            year: values[0], month: values[1], day: values[2], hour: values[3], minute: values[4], second: values[5])
    }

    /// A moment as the clock of this Mac reads it.
    public static func toLocalDateTime(_ date: Date) -> LocalDateTime {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        func pad(_ value: Int?, _ width: Int) -> String {
            let text = String(value ?? 0)
            return String(repeating: "0", count: max(0, width - text.count)) + text
        }
        return "\(pad(parts.year, 4))-\(pad(parts.month, 2))-\(pad(parts.day, 2))T"
            + "\(pad(parts.hour, 2)):\(pad(parts.minute, 2)):\(pad(parts.second, 2))"
    }

    // MARK: Segments

    // The segments without the spaces at either end of the text they make, dropping any left empty.
    static func trimSegments(_ segments: [NameSegment]) -> [NameSegment] {
        var result = segments
        while !result.isEmpty {
            result[0].text = JSString.trimmedStart(result[0].text)
            if !result[0].text.isEmpty { break }
            result.removeFirst()
        }
        while !result.isEmpty {
            result[result.count - 1].text = JSString.trimmedEnd(result[result.count - 1].text)
            if !result[result.count - 1].text.isEmpty { break }
            result.removeLast()
        }
        return result
    }

    // Neighbours of the same kind become one, and empty ones go (a replacement with nothing).
    static func mergeSegments(_ segments: [NameSegment]) -> [NameSegment] {
        var merged: [NameSegment] = []
        for segment in segments where !segment.text.isEmpty {
            if let last = merged.last, last.changed == segment.changed {
                merged[merged.count - 1].text += segment.text
            } else {
                merged.append(segment)
            }
        }
        return merged
    }

    // MARK: Clashes

    /// Two names that the disk treats as one: macOS disks ignore how an accented letter was typed (é as one
    /// character or e plus an accent), and, unless the disk is case-sensitive, whether letters are capitals.
    public static func nameKey(_ name: String, caseSensitive: Bool) -> String {
        NameKeys.nameKey(name, caseSensitive: caseSensitive)
    }

    /// The folder an item is in: its path up to the last "/".
    public static func parentPath(of path: String) -> String {
        let units = Array(path.utf16)
        guard let slash = units.lastIndex(of: 0x2F), slash > 0 else { return "/" }
        return JSString.string(units[..<slash])
    }
}
