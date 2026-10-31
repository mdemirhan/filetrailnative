// Port of the texts of apps/desktop/src/renderer/components/BatchRenameSheet.tsx: PREVIEW_ROW_LIMIT, EXAMPLE_DATE,
// MODES, DATE_TOKEN_NAMES, the pop-ups' choices, describeRow, Summary and describeSettingsError
import Foundation

/// What the Rename sheet for several items says: its title, its choices, each row's note and the footer's summary.
public enum BatchRenameSheetText {
    /// `PREVIEW_ROW_LIMIT`: rows drawn in the preview; the counts below it always cover every item.
    public static let previewRowLimit = 1_000
    /// `EXAMPLE_DATE`: the date the example under the date options is written for.
    public static let exampleDate: LocalDateTime = "2026-05-14T18:02:11"

    /// `MODES`, in the order the segments show them.
    public static let modes: [(mode: BatchRenameMode, label: String)] = [
        (.replace, "Replace Text"), (.add, "Add Text"), (.format, "Format"), (.changeCase, "Change Case"),
    ]

    /// The radio group's name.
    public static let modeGroupLabel = "How to rename"

    /// "Rename 1,234 Items"; one item comes here only to be tried again after a rename of several.
    public static func title(count: Int) -> String {
        "Rename \(ContextMenuRules.groupedCount(count)) \(count == 1 ? "Item" : "Items")"
    }

    /// The default button: "Rename N Items" once something will be renamed and it may be, else "Rename".
    public static func renameButton(renameCount: Int, canRename: Bool) -> String {
        guard renameCount > 0, canRename else { return "Rename" }
        return "Rename \(ContextMenuRules.groupedCount(renameCount)) \(renameCount == 1 ? "Item" : "Items")"
    }

    /// The line under the last row drawn: "and 5 more".
    public static func moreRows(_ count: Int) -> String {
        "and \(ContextMenuRules.groupedCount(count)) more"
    }

    // MARK: Choices

    /// One choice of a pop-up: the setting's value and what the pop-up says.
    public struct Choice<Value: Equatable & Sendable>: Equatable, Sendable {
        public var value: Value
        public var title: String
    }

    public static let applyToChoices: [Choice<BatchRenameApplyTo>] = [
        .init(value: .name, title: "Name"), .init(value: .extensionPart, title: "Extension"),
        .init(value: .both, title: "Name and Extension"),
    ]
    public static let onConflictChoices: [Choice<BatchRenameOnConflict>] = [
        .init(value: .number, title: "Add a Number"), .init(value: .skip, title: "Skip Those Items"),
        .init(value: .block, title: "Don\u{2019}t Rename"),
    ]
    public static let whereChoices: [Choice<BatchRenameWhere>] = [
        .init(value: .after, title: "after name"), .init(value: .before, title: "before name"),
    ]
    public static let nameFormatChoices: [Choice<BatchRenameNameFormat>] = [
        .init(value: .index, title: "Name and Index"), .init(value: .counter, title: "Name and Counter"),
        .init(value: .date, title: "Name and Date"),
    ]
    public static let separatorChoices: [Choice<BatchRenameSeparator>] = [
        .init(value: .space, title: "Space"), .init(value: .hyphen, title: "Hyphen (-)"),
        .init(value: .underscore, title: "Underscore (_)"), .init(value: .none, title: "None"),
    ]
    public static let dateSourceChoices: [Choice<BatchRenameDateSource>] = [
        .init(value: .created, title: "Date Created"), .init(value: .modified, title: "Date Modified"),
        .init(value: .taken, title: "Date Taken"), .init(value: .today, title: "Today"),
    ]
    public static let dateSeparatorChoices: [Choice<BatchRenameDateSeparator>] = [
        .init(value: .hyphen, title: "Hyphen (-)"), .init(value: .underscore, title: "Underscore (_)"),
        .init(value: .dot, title: "Period (.)"), .init(value: .space, title: "Space"),
        .init(value: .none, title: "None"),
    ]
    /// Digits is saved as a number from 2 to 5 or `auto`, never as the pop-up's text.
    public static let digitsChoices: [Choice<BatchRenameDigits>] = [
        .init(value: .auto, title: "As Many as Needed"), .init(value: .fixed(2), title: "2"),
        .init(value: .fixed(3), title: "3"), .init(value: .fixed(4), title: "4"), .init(value: .fixed(5), title: "5"),
    ]
    public static let caseChoices: [Choice<BatchRenameCase>] = [
        .init(value: .lower, title: "lowercase"), .init(value: .upper, title: "UPPERCASE"),
        .init(value: .title, title: "Title Case"),
    ]

    /// The date formats, each written with the separator chosen ("YYYYMMDD"), then Custom….
    public static func dateFormatChoices(separator: BatchRenameDateSeparator) -> [Choice<BatchRenameDateFormat>] {
        BatchRenameDateFormat.offered.map {
            Choice(value: $0, title: BatchRename.describeDateFormat($0, separator: separator))
        } + [Choice(value: .custom, title: "Custom\u{2026}")]
    }

    // MARK: Date pattern

    /// `DATE_TOKEN_NAMES`: what each date token puts in a name, shown for the date the example is written for.
    public static func tokenName(_ token: BatchRenameDateToken) -> String {
        switch token {
        case .year4: "Year (2026)"
        case .year2: "Year (26)"
        case .month: "Month (05)"
        case .day: "Day (14)"
        case .hour: "Hour, 24-hour (18)"
        case .minute: "Minutes (02)"
        case .second: "Seconds (11)"
        }
    }

    /// The tokens in the order their buttons show them (`DATE_TOKENS`).
    public static let tokens: [BatchRenameDateToken] = [.year4, .year2, .month, .day, .hour, .minute, .second]

    public static let insertLabel = "Insert"
    public static let bracketsNote = "Text in [brackets] is kept as typed"

    /// "Example: …": the custom pattern applied to the example date.
    public static func example(_ settings: BatchRenameSettings) -> String {
        "Example: \(BatchRename.formatDate(exampleDate, settings))"
    }

    // MARK: Notes

    public static let regexHint = "Use $1, $2\u{2026} or $<name> for groups, $& for the whole match"
    public static let extensionAdvice = "Changing an extension can change the app a file opens in."
    public static let namesOnlyNote = "Names only: extensions are kept"
    public static let noChange = "No change"
    public static let becomes = ", becomes "
    public static let notRenamed = ", not renamed"
    public static let inspectFailure = "File Trail couldn\u{2019}t read the items to check their new names."

    // MARK: Rows

    /// How a row's note is drawn.
    public enum NoteTone: String, Equatable, Sendable {
        case danger, muted, warning
    }

    public struct RowNote: Equatable, Sendable {
        public var text: String
        public var tone: NoteTone
    }

    /// `describeRow`: what is said under an item's new name, if anything.
    public static func describeRow(_ item: BatchRenamePlanItem) -> RowNote? {
        switch item {
        case .unchanged:
            return nil
        case .rename(_, _, let addedNumber, let numberedForItemInBatch, let usedCreatedForTaken, let becomesHidden):
            if becomesHidden {
                return RowNote(text: "Starts with \u{201C}.\u{201D}: it will be hidden", tone: .warning)
            }
            if addedNumber != nil {
                return RowNote(
                    text: numberedForItemInBatch
                        ? "Same new name as another item: a number is added" : "That name is taken: a number is added",
                    tone: .muted)
            }
            if usedCreatedForTaken {
                return RowNote(text: "No date taken: the date created is used", tone: .muted)
            }
            return nil
        case .problem(_, _, let problem):
            switch problem {
            case .invalid(let message):
                return RowNote(text: message, tone: .danger)
            case .taken(let byItemInBatch):
                return RowNote(
                    text: byItemInBatch
                        ? "Another item here would get this name" : "An item in this folder already has this name",
                    tone: .danger)
            case .skippedTaken:
                return RowNote(text: "Left as it is: the name is taken", tone: .muted)
            case .cannotRename(let message):
                return RowNote(text: "Left as it is: \(message)", tone: .muted)
            }
        }
    }

    /// How a row is drawn as a whole.
    public enum RowTone: Equatable, Sendable {
        case plain
        /// To fix before anything is renamed: tinted as danger.
        case danger
        /// Left as it is on purpose: its new name struck through.
        case skipped
    }

    public static func rowTone(_ item: BatchRenamePlanItem) -> RowTone {
        guard case .problem(_, _, let problem) = item else { return .plain }
        switch problem {
        case .skippedTaken, .cannotRename: return .skipped
        case .invalid, .taken: return .danger
        }
    }

    /// The new name and its pieces, nil for an item left unchanged ("No change").
    public static func newName(_ item: BatchRenamePlanItem) -> (name: String, segments: [NameSegment])? {
        switch item {
        case .unchanged: nil
        case .rename(let name, let segments, _, _, _, _): (name, segments)
        case .problem(let name, let segments, _): (name, segments)
        }
    }

    /// What a screen reader reads of a row: the old name, ", becomes ", the new one (", not renamed" when left).
    public static func accessibilityText(oldName: String, item: BatchRenamePlanItem) -> String {
        guard let new = newName(item) else { return oldName + becomes + noChange }
        let note = describeRow(item).map { " \($0.text)" } ?? ""
        let skipped = rowTone(item) == .skipped ? notRenamed : ""
        return oldName + becomes + new.name + skipped + note
    }

    // MARK: Summary

    public struct Summary: Equatable, Sendable {
        public var text: String
        public var danger: Bool
    }

    /// `Summary`: the footer's line, in its order of precedence.
    public static func summary(plan: BatchRenamePlan, checking: Bool, checkError: String?) -> Summary {
        if let checkError, !checkError.isEmpty {
            return Summary(text: checkError, danger: true)
        }
        if let settingsError = plan.settingsError, !settingsError.isEmpty {
            return Summary(text: describeSettingsError(settingsError), danger: true)
        }
        if checking {
            return Summary(text: "Checking names\u{2026}", danger: false)
        }
        if plan.blockingCount > 0 {
            let count = ContextMenuRules.groupedCount(plan.blockingCount)
            return Summary(
                text: "\(count) \(plan.blockingCount == 1 ? "name" : "names") to fix before renaming", danger: true)
        }
        if plan.renameCount == 0 {
            return Summary(text: "Nothing to rename yet", danger: false)
        }
        var parts = ["\(ContextMenuRules.groupedCount(plan.renameCount)) will be renamed"]
        let numbered = plan.items.filter {
            if case .rename(_, _, let added, _, _, _) = $0 { return added != nil }
            return false
        }.count
        if numbered > 0 { parts.append("\(ContextMenuRules.groupedCount(numbered)) get a number") }
        if plan.skippedCount > 0 {
            parts.append("\(ContextMenuRules.groupedCount(plan.skippedCount)) left as they are")
        }
        if plan.unchangedCount > 0 { parts.append("\(ContextMenuRules.groupedCount(plan.unchangedCount)) unchanged") }
        return Summary(text: parts.joined(separator: " \u{00B7} "), danger: false)
    }

    /// `describeSettingsError`: the settings' fault as the sheet says it. JavaScript's own words for a broken pattern
    /// ("Invalid regular expression: /(/giu: ") are left out, the reason kept
    /// (`/^(The pattern isn’t valid: )(?:Invalid regular expression: )?\/.*\/[a-z]*: /su`).
    public static func describeSettingsError(_ error: String) -> String {
        let prefix = "The pattern isn\u{2019}t valid: "
        guard error.hasPrefix(prefix) else { return error }
        var rest = Substring(error.dropFirst(prefix.count))
        let engine = "Invalid regular expression: "
        if rest.hasPrefix(engine) { rest = rest.dropFirst(engine.count) }
        guard rest.hasPrefix("/") else { return error }
        // `\/.*\/[a-z]*: ` with a greedy `.*`: the last "/" followed by flags and ": ".
        let body = rest.dropFirst()
        var candidate = body.endIndex
        while let slash = body[body.startIndex..<candidate].lastIndex(of: "/") {
            var after = body.index(after: slash)
            while after < body.endIndex, ("a"..."z").contains(body[after]) { after = body.index(after: after) }
            if body[after...].hasPrefix(": ") {
                return prefix + String(body[body.index(after, offsetBy: 2)...])
            }
            candidate = slash
        }
        return error
    }
}
