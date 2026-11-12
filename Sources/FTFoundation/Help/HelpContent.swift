import Foundation
import Synchronization

public enum HelpTopicID: String, CaseIterable, Sendable, Hashable {
    case navigation
    case files
    case search
    case views
    case shortcuts
}

/// The topics a shortcut can belong to (everything except the shortcut list itself).
public enum HelpShortcutGroup: String, CaseIterable, Sendable, Hashable {
    case navigation
    case files
    case search
    case views

    public var topicID: HelpTopicID { HelpTopicID(rawValue: rawValue) ?? .navigation }
}

public struct HelpRow: Equatable, Sendable {
    public var label: String
    /// Show the label as code (a search pattern).
    public var code: Bool
    public var description: String

    public init(label: String, code: Bool = false, description: String) {
        self.label = label
        self.code = code
        self.description = description
    }
}

public struct HelpSection: Equatable, Sendable {
    public var title: String
    public var rows: [HelpRow]
    /// A short remark under the rows, for the mistake people make most.
    public var note: String?

    public init(title: String, rows: [HelpRow], note: String? = nil) {
        self.title = title
        self.rows = rows
        self.note = note
    }
}

public struct HelpTopic: Equatable, Sendable {
    public var id: HelpTopicID
    public var title: String
    public var intro: String
    public var sections: [HelpSection]

    public init(id: HelpTopicID, title: String, intro: String, sections: [HelpSection]) {
        self.id = id
        self.title = title
        self.intro = intro
        self.sections = sections
    }
}

/// A row of the shortcut list. One that names a command shows the key the command has now (Settings → Shortcuts) and is
/// left out while the command has none; the others are keys that are always the same.
public struct HelpShortcutItem: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        /// Written as "Cmd+Shift+G"; shown as keycaps.
        case fixed(String)
        case command(ShortcutCommandID)
    }

    public var group: HelpShortcutGroup
    public var source: Source
    public var description: String

    public init(group: HelpShortcutGroup, _ source: Source, _ description: String) {
        self.group = group
        self.source = source
        self.description = description
    }
}

/// A row as it is shown: the key, and what it does.
public struct HelpShownShortcut: Equatable, Sendable {
    public var group: HelpShortcutGroup
    public var shortcut: String
    public var description: String
}

public struct HelpSearchResult: Equatable, Sendable {
    public var topic: HelpTopic
    public var rows: [(section: String, row: HelpRow)]
    public var shortcuts: [HelpShownShortcut]

    public static func == (left: HelpSearchResult, right: HelpSearchResult) -> Bool {
        left.topic == right.topic && left.shortcuts == right.shortcuts && left.rows.count == right.rows.count
            && zip(left.rows, right.rows).allSatisfy { $0.section == $1.section && $0.row == $1.row }
    }
}

/// Help content is static data so wording can be tuned without touching the view. Text in `backticks` is shown as code,
/// and `{newTab}` as the key that command has now.
public enum HelpContent {
    public static let shortcutGroups: [HelpShortcutGroup] = [.navigation, .files, .search, .views]

    /// The topics' data is in `HelpTopics.swift`; the shortcuts topic is last and has no sections.
    public static func topic(_ id: HelpTopicID) -> HelpTopic {
        topics.first { $0.id == id } ?? topics[0]
    }

    /// The shortcut list as it is shown: every row with the key it has now. A command's other key is mentioned after
    /// what it does ("Go back (Cmd+Left also works)").
    public static func listShortcuts(_ display: ShortcutDisplay = .defaults) -> [HelpShownShortcut] {
        shortcutItems.flatMap { item -> [HelpShownShortcut] in
            switch item.source {
            case .fixed(let shortcut):
                return [HelpShownShortcut(group: item.group, shortcut: shortcut, description: item.description)]
            case .command(let id):
                guard let shortcut = display.written(id), !shortcut.isEmpty else { return [] }
                let description =
                    display.alternate(id).map { "\(item.description) (\(writeForReading($0)) also works)" }
                    ?? item.description
                return [HelpShownShortcut(group: item.group, shortcut: shortcut, description: description)]
            }
        }
    }

    /// "Cmd+Plus" reads as "Cmd++".
    static func writeForReading(_ shortcut: String) -> String {
        JSString.hasSuffix(shortcut, "+Plus") ? String(shortcut.dropLast(4)) + "+" : shortcut
    }

    /// Help's sentences name a command's key as `{newTab}`. It is replaced by the key the command has now, or by where
    /// the command is in the menus when it has none. Braces that name no command are left as they are.
    public static func fillShortcutMentions(_ text: String, _ display: ShortcutDisplay = .defaults) -> String {
        var result = ""
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "{") {
            result += rest[..<open]
            let afterOpen = rest.index(after: open)
            var end = afterOpen
            while end < rest.endIndex, isWordCharacter(rest[end]) { end = rest.index(after: end) }
            if end > afterOpen, end < rest.endIndex, rest[end] == "}" {
                let name = String(rest[afterOpen..<end])
                if let id = ShortcutCommandID(rawValue: name) {
                    result += display.mention(id)
                } else {
                    result += rest[open...end]
                }
                rest = rest[rest.index(after: end)...]
            } else {
                result += "{"
                rest = rest[afterOpen...]
            }
        }
        return result + rest
    }

    /// An ASCII letter, digit or underscore.
    private static func isWordCharacter(_ character: Character) -> Bool {
        character.unicodeScalars.count == 1
            && character.unicodeScalars.allSatisfy {
                $0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0) || $0 == "_")
            }
    }

    /// What the "Search help" field looks through: every row and every shortcut, by the words on screen (and the
    /// shortcut as written, so "cmd+f" finds Find files).
    public static func search(_ query: String, _ display: ShortcutDisplay = .defaults) -> [HelpSearchResult] {
        let needle = Array(JSString.lowercased(JSString.trimmed(query)).utf16)
        if needle.isEmpty { return [] }
        func matches(_ texts: [[UInt16]]) -> Bool {
            texts.contains { JSString.index(of: needle, in: $0) != nil }
        }
        return searchIndex(display).topics.compactMap { entry in
            let rows = entry.rows.filter { matches($0.texts) }.map { (section: $0.section, row: $0.row) }
            let shortcuts = entry.shortcuts.filter { matches($0.texts) }.map(\.shown)
            return rows.isEmpty && shortcuts.isEmpty
                ? nil : HelpSearchResult(topic: entry.topic, rows: rows, shortcuts: shortcuts)
        }
    }

    /// What "Search help" looks through for one display, every text lowercased once: lowercasing them all again for
    /// each letter typed was most of a search's time.
    private struct SearchIndex: Sendable {
        struct Row: Sendable {
            let section: String
            let row: HelpRow
            /// The label, the description with its keys filled in, and the section's title.
            let texts: [[UInt16]]
        }

        struct Shortcut: Sendable {
            let shown: HelpShownShortcut
            /// What it does, and the shortcut as written.
            let texts: [[UInt16]]
        }

        struct Topic: Sendable {
            let topic: HelpTopic
            let rows: [Row]
            let shortcuts: [Shortcut]
        }

        let display: ShortcutDisplay
        let topics: [Topic]

        init(_ display: ShortcutDisplay) {
            func lowered(_ texts: String...) -> [[UInt16]] { texts.map { Array(JSString.lowercased($0).utf16) } }
            let shown = HelpContent.listShortcuts(display)
            self.display = display
            topics = HelpContent.topics.filter { $0.id != .shortcuts }.map { topic in
                Topic(
                    topic: topic,
                    rows: topic.sections.flatMap { section in
                        section.rows.map { row in
                            Row(
                                section: section.title, row: row,
                                texts: lowered(
                                    row.label, HelpContent.fillShortcutMentions(row.description, display),
                                    section.title))
                        }
                    },
                    shortcuts: shown.filter { $0.group.topicID == topic.id }.map { shortcut in
                        Shortcut(
                            shown: shortcut,
                            texts: lowered(shortcut.description, HelpContent.writeForReading(shortcut.shortcut)))
                    })
            }
        }
    }

    /// The index of the display searched last; the keys change only in Settings.
    private static let lastSearchIndex = Mutex<SearchIndex?>(nil)

    private static func searchIndex(_ display: ShortcutDisplay) -> SearchIndex {
        if let index = lastSearchIndex.withLock({ $0 }), index.display == display { return index }
        let index = SearchIndex(display)
        lastSearchIndex.withLock { $0 = index }
        return index
    }

    /// Pieces of a sentence for display: the plain text between `backticks` and the code inside them.
    public static func inlineParts(_ text: String, _ display: ShortcutDisplay = .defaults) -> [(
        text: String, isCode: Bool
    )] {
        fillShortcutMentions(text, display).components(separatedBy: "`").enumerated()
            .map { (text: $0.element, isCode: $0.offset % 2 == 1) }
    }
}
