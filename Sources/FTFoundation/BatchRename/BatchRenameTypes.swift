// Port of the types and constants of apps/desktop/src/shared/batchRename.ts
import Foundation

public enum BatchRenameMode: String, Codable, Sendable, CaseIterable {
    case replace, add, format
    case changeCase = "case"
}

public enum BatchRenameNameFormat: String, Codable, Sendable, CaseIterable { case index, counter, date }
public enum BatchRenameWhere: String, Codable, Sendable, CaseIterable { case after, before }
public enum BatchRenameDateSource: String, Codable, Sendable, CaseIterable { case created, modified, taken, today }
public enum BatchRenameCase: String, Codable, Sendable, CaseIterable { case lower, upper, title }

public enum BatchRenameApplyTo: String, Codable, Sendable, CaseIterable {
    case name, both
    case extensionPart = "extension"
}

/// What happens to an item whose new name is taken.
public enum BatchRenameOnConflict: String, Codable, Sendable, CaseIterable { case number, skip, block }

/// Between the name and its number or date.
public enum BatchRenameSeparator: String, Codable, Sendable, CaseIterable {
    case space = " ", hyphen = "-", underscore = "_", none = ""
}

/// Between the parts of a date.
public enum BatchRenameDateSeparator: String, Codable, Sendable, CaseIterable {
    case hyphen = "-", underscore = "_", dot = ".", space = " ", none = ""
}

public enum BatchRenameDateFormat: String, Codable, Sendable, CaseIterable {
    case ymd
    case ymdHM = "ymd_hm"
    case ymdHMS = "ymd_hms"
    case dmy, dmyy, mdy, yymd, ym, custom

    /// In the order the Date Format pop-up lists them (Custom is offered apart).
    public static let offered: [BatchRenameDateFormat] = [.ymd, .ymdHM, .ymdHMS, .dmy, .dmyy, .mdy, .yymd, .ym]

    /// The format's parts in order; Custom takes a pattern instead.
    public var tokens: [BatchRenameDateToken] {
        switch self {
        case .ymd: [.year4, .month, .day]
        case .ymdHM: [.year4, .month, .day, .hour, .minute]
        case .ymdHMS: [.year4, .month, .day, .hour, .minute, .second]
        case .dmy: [.day, .month, .year4]
        case .dmyy: [.day, .month, .year2]
        case .mdy: [.month, .day, .year4]
        case .yymd: [.year2, .month, .day]
        case .ym: [.year4, .month]
        case .custom: []
        }
    }
}

public enum BatchRenameDateToken: String, Sendable, CaseIterable {
    case year4 = "YYYY", year2 = "YY", month = "MM", day = "DD", hour = "HH", minute = "mm", second = "ss"
}

/// Counter only: how many digits, or as many as the last number needs.
public enum BatchRenameDigits: Equatable, Sendable, Codable {
    case auto
    case fixed(Int)

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let count = try? container.decode(Int.self), (2...5).contains(count) {
            self = .fixed(count)
        } else if (try? container.decode(String.self)) == "auto" {
            self = .auto
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "not a digits choice")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .auto: try container.encode("auto")
        case .fixed(let count): try container.encode(count)
        }
    }
}

public struct BatchRenameSettings: Equatable, Sendable, Codable {
    public var mode: BatchRenameMode
    // Replace Text
    public var find: String
    public var replaceWith: String
    public var matchCase: Bool
    public var useRegex: Bool
    // Add Text
    public var addText: String
    public var addWhere: BatchRenameWhere
    // Format
    public var nameFormat: BatchRenameNameFormat
    public var formatWhere: BatchRenameWhere
    public var customName: String
    public var keepNames: Bool
    public var startAt: Int
    public var step: Int
    public var digits: BatchRenameDigits
    public var separator: BatchRenameSeparator
    public var dateSource: BatchRenameDateSource
    public var dateFormat: BatchRenameDateFormat
    public var dateSeparator: BatchRenameDateSeparator
    public var customDatePattern: String
    // Change Case
    public var caseStyle: BatchRenameCase
    // Every mode but Format, which keeps extensions.
    public var applyTo: BatchRenameApplyTo
    public var onConflict: BatchRenameOnConflict

    /// DEFAULT_BATCH_RENAME_SETTINGS: Finder's starting point, Replace Text, and "File 1" for Format.
    public static let defaults = BatchRenameSettings()

    public init(
        mode: BatchRenameMode = .replace, find: String = "", replaceWith: String = "", matchCase: Bool = false,
        useRegex: Bool = false, addText: String = "", addWhere: BatchRenameWhere = .after,
        nameFormat: BatchRenameNameFormat = .index, formatWhere: BatchRenameWhere = .after,
        customName: String = "File", keepNames: Bool = false, startAt: Int = 1, step: Int = 1,
        digits: BatchRenameDigits = .fixed(5), separator: BatchRenameSeparator = .space,
        dateSource: BatchRenameDateSource = .created, dateFormat: BatchRenameDateFormat = .ymd,
        dateSeparator: BatchRenameDateSeparator = .hyphen, customDatePattern: String = "YYYY-MM-DD at HH.mm",
        caseStyle: BatchRenameCase = .lower, applyTo: BatchRenameApplyTo = .name,
        onConflict: BatchRenameOnConflict = .number
    ) {
        self.mode = mode
        self.find = find
        self.replaceWith = replaceWith
        self.matchCase = matchCase
        self.useRegex = useRegex
        self.addText = addText
        self.addWhere = addWhere
        self.nameFormat = nameFormat
        self.formatWhere = formatWhere
        self.customName = customName
        self.keepNames = keepNames
        self.startAt = startAt
        self.step = step
        self.digits = digits
        self.separator = separator
        self.dateSource = dateSource
        self.dateFormat = dateFormat
        self.dateSeparator = dateSeparator
        self.customDatePattern = customDatePattern
        self.caseStyle = caseStyle
        self.applyTo = applyTo
        self.onConflict = onConflict
    }
}

public struct BatchRenamePreset: Equatable, Sendable, Codable {
    public var name: String
    public var settings: BatchRenameSettings

    public init(name: String, settings: BatchRenameSettings) {
        self.name = name
        self.settings = settings
    }
}

/// A local date and time as the clock of this Mac reads it: "2026-05-14T18:02:11".
public typealias LocalDateTime = String

public struct BatchRenameItem: Equatable, Sendable {
    public var path: String
    /// The item's name now.
    public var name: String
    /// Folders have no extension; packages (an .app) and files do.
    public var isFolder: Bool
    public var createdAt: LocalDateTime?
    public var modifiedAt: LocalDateTime?
    /// When the photo was taken, from its own metadata; nil when it has none.
    public var takenAt: LocalDateTime?

    public init(
        path: String, name: String, isFolder: Bool = false, createdAt: LocalDateTime? = nil,
        modifiedAt: LocalDateTime? = nil, takenAt: LocalDateTime? = nil
    ) {
        self.path = path
        self.name = name
        self.isFolder = isFolder
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.takenAt = takenAt
    }
}

/// A piece of a new name, marked when it is what the rename changed.
public struct NameSegment: Equatable, Sendable {
    public var text: String
    public var changed: Bool

    public init(text: String, changed: Bool) {
        self.text = text
        self.changed = changed
    }
}

public enum ProposedName: Equatable, Sendable {
    /// Nothing in the settings applies to this item.
    case unchanged
    /// `usedCreatedForTaken`: the date taken was missing, and the date created was used.
    /// `emptyName`: nothing is left before the extension, so the name would be only ".txt".
    case renamed(name: String, segments: [NameSegment], usedCreatedForTaken: Bool, emptyName: Bool)
}

public struct ProposedNames: Equatable, Sendable {
    /// What is wrong with the settings themselves (a broken pattern); nil when nothing.
    public var settingsError: String?
    public var names: [ProposedName]
}

/// What is known of a folder some items are in.
public struct BatchRenameFolder: Equatable, Sendable {
    /// Every name in it, hidden ones included.
    public var names: [String]
    public var caseSensitive: Bool

    public init(names: [String], caseSensitive: Bool) {
        self.names = names
        self.caseSensitive = caseSensitive
    }
}

/// Why an item won't be renamed though it would have changed.
public enum BatchRenameItemProblem: Equatable, Sendable {
    /// The new name isn't a valid name (empty, a "/", too long): always fixed first.
    case invalid(message: String)
    /// The new name is taken, and the setting says not to rename until that is fixed.
    case taken(byItemInBatch: Bool)
    /// The new name is taken, and the setting says to leave this item as it is.
    case skippedTaken(byItemInBatch: Bool)
    /// The item can't be renamed at all (locked, or its folder can't be written to).
    case cannotRename(message: String)
}

public enum BatchRenamePlanItem: Equatable, Sendable {
    case unchanged
    /// `addedNumber`: the number added because the name was taken. `numberedForItemInBatch`: it was taken by
    /// another item of the batch getting it, not by the folder. `becomesHidden`: the new name starts with a dot.
    case rename(
        name: String, segments: [NameSegment], addedNumber: Int?, numberedForItemInBatch: Bool,
        usedCreatedForTaken: Bool, becomesHidden: Bool)
    case problem(proposedName: String, segments: [NameSegment], problem: BatchRenameItemProblem)
}

public struct BatchRenamePlan: Equatable, Sendable {
    public var settingsError: String?
    public var items: [BatchRenamePlanItem]
    public var renameCount: Int
    public var unchangedCount: Int
    /// Items left as they are on purpose (Skip, or locked): they don't stop the rename.
    public var skippedCount: Int
    /// Items that must be fixed before anything is renamed.
    public var blockingCount: Int
}

public struct BatchRenamePlanInput: Sendable {
    public var settings: BatchRenameSettings
    public var items: [BatchRenameItem]
    /// Keyed by folder path. A folder missing here is taken to hold only the items.
    public var folders: [String: BatchRenameFolder]
    /// Items that can't be renamed, and why.
    public var cannotRename: [String: String]
    public var now: LocalDateTime

    public init(
        settings: BatchRenameSettings, items: [BatchRenameItem], folders: [String: BatchRenameFolder] = [:],
        cannotRename: [String: String] = [:], now: LocalDateTime
    ) {
        self.settings = settings
        self.items = items
        self.folders = folders
        self.cannotRename = cannotRename
        self.now = now
    }
}
