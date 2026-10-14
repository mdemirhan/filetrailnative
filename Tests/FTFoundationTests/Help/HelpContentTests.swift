// Port of apps/desktop/src/renderer/lib/helpContent.test.ts (the application-menu case is in FTAppKitTests/Help), with the
// help-content golden recorded from the reference (tools/parity/golden/help-content.ts)
import FTTestSupport
import Foundation
import Testing

@testable import FTFoundation

struct HelpContentTests {
    // T-7229a2ec F-665 F-666
    @Test func givesEveryTopicATitleAnIntroductionAndUniquelyNamedSectionsAndRows() {
        #expect(HelpContent.topics.map(\.id) == [.navigation, .files, .search, .views, .shortcuts])
        for topic in HelpContent.topics {
            #expect(!topic.title.isEmpty)
            #expect(!topic.intro.isEmpty)
            let sectionTitles = topic.sections.map(\.title)
            #expect(Set(sectionTitles).count == sectionTitles.count)
            for section in topic.sections {
                let labels = section.rows.map(\.label)
                #expect(Set(labels).count == labels.count)
                // Backticks come in pairs, or the rest of a sentence would turn into code.
                for text in [section.note ?? ""] + section.rows.map(\.description) {
                    #expect(text.components(separatedBy: "`").count % 2 == 1, "\(text)")
                }
            }
        }
        // Getting around, Working with files, Searching, Views and panels, Keyboard shortcuts.
        #expect(
            HelpContent.topics.map(\.title) == [
                "Getting around", "Working with files", "Searching", "Views and panels", "Keyboard shortcuts",
            ])
    }

    // T-16be1b56 F-667
    @Test func listsShortcutsForEachTopicWithoutRepeatingOneWithinATopic() {
        let shown = HelpContent.listShortcuts()
        for group in HelpContent.shortcutGroups {
            let rows = shown.filter { $0.group == group }.map { "\($0.shortcut) \($0.description)" }
            #expect(!rows.isEmpty)
            #expect(Set(rows).count == rows.count)
        }
        // A command without a key has no row, and a second key is mentioned after the first.
        #expect(!shown.map(\.description).contains("Show in Finder"))
        #expect(shown.first { $0.shortcut == "Cmd+[" }?.description == "Go back (Cmd+Left also works)")
        #expect(
            shown.first { $0.description.hasPrefix("Rename") }
                == HelpShownShortcut(group: .files, shortcut: "Return", description: "Rename (F2 also works)"))
    }

    // T-d680d940 F-665 F-667
    @Test func followsTheKeysChosenInSettingsInTheListAndInTheSentences() {
        let overrides: JSONNode = .object([
            "newTab": .array([]), "goBack": .array([.string("Cmd+Option+Left")]),
            "showInFinder": .array([.string("Cmd+Shift+J")]),
            "copyPath": .array([.string("Cmd+="), .string("Cmd+Plus")]),
        ])
        let display = ShortcutDisplay(shortcuts: ShortcutCommands.resolve(overrides))
        let shown = HelpContent.listShortcuts(display)

        #expect(!shown.map(\.description).contains("New tab, on the same folder"))
        #expect(shown.first { $0.description == "Go back" }?.shortcut == "Cmd+Option+Left")
        #expect(shown.first { $0.description == "Show in Finder" }?.shortcut == "Cmd+Shift+J")
        #expect(shown.first { $0.shortcut == "Cmd+=" }?.description == "Copy the path (Cmd++ also works)")
        // A sentence names the key, or the menu item when the command has no key.
        #expect(
            HelpContent.fillShortcutMentions("{goBack} goes back; {newTab} opens a tab.", display)
                == "⌥⌘← goes back; File > New Tab opens a tab.")
        // Braces that name no command are left as they are (search patterns use them).
        #expect(
            HelpContent.fillShortcutMentions("*.{jpg,png} and \\d{2} and {nothing}")
                == "*.{jpg,png} and \\d{2} and {nothing}")
        #expect(HelpContent.search("cmd+shift+j", display).first?.shortcuts.first?.description == "Show in Finder")
    }

    // T-4f2e3f5e F-665
    @Test func namesOnlyCommandsThatExistInItsSentences() {
        let texts = HelpContent.topics.flatMap { topic in
            [topic.intro]
                + topic.sections.flatMap { [$0.note ?? ""] + $0.rows.map(\.description) }
        }
        let mentions = texts.flatMap { text -> [String] in
            var found: [String] = []
            var rest = Substring(text)
            while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
                let name = String(rest[rest.index(after: open)..<close])
                if !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) { found.append(name) }
                rest = rest[rest.index(after: close)...]
            }
            return found
        }
        #expect(mentions.count > 8)
        for mention in mentions { #expect(ShortcutCommandID(rawValue: mention) != nil, "{\(mention)}") }
        // No sentence spells a changeable key out. ⌘⌫ in Go To, ⌃⌘F and ⌘-click are always the same.
        for text in texts {
            let changeable = text.replacingOccurrences(of: "⌘⌫", with: "").replacingOccurrences(of: "⌃⌘F", with: "")
                .replacingOccurrences(of: "⌘-click", with: "").replacingOccurrences(of: "⌘-double-click", with: "")
            #expect(!changeable.contains { "⌘⌥⌃⇧".contains($0) }, "\(text)")
        }
    }

    // T-b51e9329 F-666
    @Test func coversTheSearchPatternsPeopleGetWrong() {
        let search = HelpContent.topic(.search)
        let patterns = search.sections.flatMap { $0.rows.filter(\.code).map(\.label) }
        for pattern in ["*.pdf", "report*", "*draft*", "*.{jpg,png,gif}", "**/src/**/*.ts"] {
            #expect(patterns.contains(pattern), "\(pattern)")
        }
        let notes = search.sections.map { $0.note ?? "" }.joined(separator: " ")
        #expect(notes.contains("must match the whole name"))
        #expect(notes.contains("Start a glob with `**/`"))
    }

    // T-9ccf0275 F-668
    @Test func searchesRowsAndShortcutsByTheirWordsAndByTheShortcutAsWritten() {
        #expect(HelpContent.search("   ").isEmpty)
        let trash = HelpContent.search("TRASH")
        #expect(trash.map(\.topic.id) == [.files])
        #expect(trash.first?.shortcuts.map(\.shortcut) == ["Cmd+Backspace", "Cmd+Shift+Backspace"])
        #expect(
            HelpContent.search("cmd+k").first?.shortcuts.first?.description
                == "Go to a folder by name or path (Cmd+Shift+G also works)")
        // A section title brings its rows along ("glob" is in "Glob patterns").
        #expect((HelpContent.search("glob patterns").first?.rows.count ?? 0) >= 6)
    }

    // F-668 the empty result text is the view's; a query nothing matches finds nothing
    @Test func findsNothingForAQueryNothingMatches() {
        #expect(HelpContent.search("nothing matches this").isEmpty)
    }

    // F-665 the content leaves out the zoom rows (DEVIATIONS D-005)
    @Test func leavesOutTheZoomRows() {
        let texts = HelpContent.topics.flatMap { topic in
            [topic.intro] + topic.sections.flatMap { $0.rows.map(\.description) + $0.rows.map(\.label) }
        }
        #expect(!texts.contains { $0.lowercased().contains("zoom") })
        #expect(!HelpContent.shortcutItems.contains { $0.description.lowercased().contains("zoom") })
    }

    @Test func splitsASentenceIntoPlainTextAndCode() {
        let parts = HelpContent.inlineParts("Press `Tab` to complete; {goBack} goes back")
        #expect(parts.map(\.text) == ["Press ", "Tab", " to complete; ⌘[ goes back"])
        #expect(parts.map(\.isCode) == [false, true, false])
    }

    // MARK: Golden

    struct Input: Codable, Sendable {
        let overrides: JSONNode
        let returnKeyAction: String
        let queries: [String]
        let texts: [String]
    }

    struct Shortcut: Codable, Equatable, Sendable {
        let group: String
        let shortcut: String
        let description: String
    }

    struct Hit: Codable, Equatable, Sendable {
        let topic: String
        let rows: [[String]]
        let shortcuts: [Shortcut]
    }

    struct Output: Codable, Equatable, Sendable {
        let shortcuts: [Shortcut]
        let mentions: [String]
        let searches: [[Hit]]
    }

    static func run(_ input: Input) -> Output {
        let display = ShortcutDisplay(
            shortcuts: ShortcutCommands.resolve(input.overrides),
            returnKeyAction: ReturnKeyAction(rawValue: input.returnKeyAction) ?? .rename)
        func shortcut(_ item: HelpShownShortcut) -> Shortcut {
            Shortcut(group: item.group.rawValue, shortcut: item.shortcut, description: item.description)
        }
        return Output(
            shortcuts: HelpContent.listShortcuts(display).map(shortcut),
            mentions: input.texts.map { HelpContent.fillShortcutMentions($0, display) },
            searches: input.queries.map { query in
                HelpContent.search(query, display).map { result in
                    Hit(
                        topic: result.topic.id.rawValue, rows: result.rows.map { [$0.section, $0.row.label] },
                        shortcuts: result.shortcuts.map(shortcut))
                }
            })
    }

    // T-7229a2ec T-16be1b56 T-d680d940 T-9ccf0275
    @Test func listsMentionsAndSearchesLikeTheOriginal() throws {
        let cases: [GoldenCase<Input, Output>] = try Golden.load(suite: "help-content")
        #expect(cases.count >= 20)
        Golden.expectMatches(cases) { Self.run($0) }
    }
}
