// Ports apps/desktop/src/renderer/components/HelpView.test.tsx; the zoom case uses another command's plus key (D-005)
import AppKit
import FTFoundation
import Testing

@testable import FTAppKit

@MainActor
@Suite struct HelpViewTests {
    private func make(
        topic: HelpTopicID = .navigation, layout: SinglePanelLayout? = nil, shortcuts: ShortcutDisplay = .defaults,
        size: NSSize = NSSize(width: 900, height: 680), topInset: CGFloat? = nil
    ) -> HelpView {
        _ = NSApplication.shared
        let view = HelpView(shortcuts: shortcuts, layoutMode: layout, initialTopic: topic, topInset: topInset)
        view.frame = NSRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()
        return view
    }

    /// Types into Search help, as typing does.
    private func type(_ text: String, in view: HelpView) {
        view.searchField.input.stringValue = text
        view.searchField.controlTextDidChange(
            Notification(name: NSControl.textDidChangeNotification, object: view.searchField.input))
        view.layoutSubtreeIfNeeded()
    }

    private func pressEscape(in view: HelpView) -> Bool {
        let field = view.searchField
        return field.control(
            field.input, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:)))
    }

    private func titles(_ view: HelpView) -> [String] { texts("help.pageTitle", in: view) }
    private func headings(_ view: HelpView) -> [String] { texts("help.sectionTitle", in: view) }
    private func shortcutTexts(_ view: HelpView) -> [String] { texts("help.shortcutRow.description", in: view) }

    // T-774fa7ec F-664 B-DLG-258
    @Test func exposesTheSelectedLayoutMode() {
        #expect(make(layout: .compact).layoutMode == .compact)
        #expect(make(layout: .narrow).layoutMode == .narrow)
        // Without one it follows the width.
        #expect(make(size: NSSize(width: 1280, height: 680)).layoutMode == .wide)
        #expect(make(size: NSSize(width: 920, height: 680)).layoutMode == .narrow)
        #expect(make(size: NSSize(width: 640, height: 680)).layoutMode == .compact)
    }

    // T-31f053f9 F-663 B-DLG-250
    @Test func listsEveryTopicAndOpensOnTheFirstOne() {
        let view = make()
        #expect(
            view.topicTitles == [
                "Getting around", "Working with files", "Searching", "Views and panels", "Keyboard shortcuts",
            ])
        #expect(view.currentTopic == .navigation)
        #expect(titles(view) == ["Getting around"])
        #expect(views("help.topic", in: view).count == 5)
        #expect(views("help.search", in: view).count == 1)
    }

    // T-e207c847 F-665 F-666 B-DLG-252
    @Test func showsATopicsExplanationsFollowedByItsShortcuts() {
        let view = make()
        view.clickTopic(.search)
        view.layoutSubtreeIfNeeded()

        #expect(titles(view) == ["Searching"])
        #expect(headings(view).contains("Glob patterns"))
        // Patterns are shown as code, with what they match beside them.
        let labels = views("help.row.label", in: view).compactMap { $0 as? ThemedText }
        let pattern = labels.first { $0.stringValue == "*.{jpg,png,gif}" }
        #expect(pattern != nil)
        let font = pattern?.attributedStringValue.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        #expect(font?.isFixedPitch == true)
        #expect(texts("help.row.description", in: view).contains("Any of several endings"))
        // Backticks in the text become inline code.
        let inline = (views("help.row.description", in: view) + views("help.note", in: view)).compactMap {
            $0 as? ThemedText
        }
        .contains { field in
            var found = false
            let text = field.attributedStringValue
            text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) { value, range, _ in
                if (value as? NSFont)?.isFixedPitch == true, text.attributedSubstring(from: range).string == "**/" {
                    found = true
                }
            }
            return found
        }
        #expect(inline)
        // The topic's own shortcuts close the page; others stay on their topics.
        #expect(headings(view).last == "Shortcuts")
        #expect(shortcutTexts(view).contains("Find files"))
        #expect(!shortcutTexts(view).contains("Move to Trash"))
    }

    // T-1e2f1618 F-667 B-DLG-255
    @Test func listsEveryShortcutOnTheKeyboardShortcutsPageGroupedByTopic() {
        let view = make(topic: .shortcuts)
        #expect(headings(view) == ["Getting around", "Working with files", "Searching", "Views and panels"])
        let shown = shortcutTexts(view)
        for item in HelpContent.listShortcuts() { #expect(shown.contains(item.description), "\(item.description)") }
        // Nothing leads to Settings unless the window offers it.
        #expect(views("help.action", in: view).isEmpty)
    }

    // T-2e306242 F-665 F-667 B-DLG-253 B-DLG-254 B-DLG-255
    @Test func showsTheKeysChosenInSettingsAndLeadsThereToChangeThem() {
        let overrides: JSONNode = .object([
            "duplicateSelection": .array([.string("Cmd+Shift+D")]), "newTab": .array([]),
        ])
        let display = ShortcutDisplay(shortcuts: ShortcutCommands.resolve(overrides))
        let view = make(topic: .shortcuts, shortcuts: display)
        var customized = 0
        view.onCustomizeShortcuts = { customized += 1 }
        view.layoutSubtreeIfNeeded()

        let row = views("help.shortcutRow", in: view).first {
            texts("help.shortcutRow.description", in: $0) == ["Duplicate"]
        }
        #expect(row.map { texts("help.keycap", in: $0) } == ["⇧", "⌘", "D"])
        #expect(!shortcutTexts(view).contains("New tab, on the same folder"))

        (views("help.action", in: view).first as? PushButton)?.perform()
        #expect(customized == 1)

        // A sentence that named the key names the menu item instead.
        view.clickTopic(.navigation)
        view.layoutSubtreeIfNeeded()
        #expect(
            texts("help.row.description", in: view).contains {
                $0.hasPrefix("File > New Tab opens a tab on the folder you are in")
            })
    }

    // T-833871bc F-667 B-DLG-254 (a plus key of Copy the path instead of Zoom in: D-005)
    @Test func rendersShortcutKeysAsSeparateKeycapsAndPreservesTrailingPlusKeys() {
        let overrides: JSONNode = .object(["copyPath": .array([.string("Cmd+Plus")])])
        let view = make(
            topic: .files, shortcuts: ShortcutDisplay(shortcuts: ShortcutCommands.resolve(overrides)))
        let row = views("help.shortcutRow", in: view).first {
            texts("help.shortcutRow.description", in: $0) == ["Copy the path"]
        }
        #expect(row.map { texts("help.keycap", in: $0) } == ["⌘", "+"])
        #expect(views("help.keycap", in: view).count > 4)
        #expect(ShortcutLabels.parts("Cmd+Shift+G") == ["⇧", "⌘", "G"])
        #expect(ShortcutLabels.parts("Cmd+Option+C") == ["⌥", "⌘", "C"])
    }

    // T-309164f3 F-668 B-DLG-256 B-DLG-257
    @Test func searchesAcrossAllTopicsAndShortcutsAndEscapeClearsTheSearch() {
        let view = make()
        type("trash", in: view)

        #expect(titles(view) == ["Results for “trash”"])
        // A row and a shortcut from Working with files, nothing from other topics.
        #expect(headings(view).contains("Working with files"))
        let hits = texts("help.row.label", in: view) + shortcutTexts(view)
        #expect(hits.filter { $0 == "Move to Trash" }.count == 2)
        #expect(!headings(view).contains("Views and panels"))
        // While searching, no topic is marked as the current page.
        #expect(view.currentTopic == nil)
        #expect(view.isSearching)

        // The shortcut as written also matches.
        type("cmd+f", in: view)
        #expect(shortcutTexts(view).contains("Find files"))

        type("zzzz", in: view)
        #expect(texts("help.intro", in: view).contains { $0.hasPrefix("Nothing in Help matches") })
        #expect(texts("help.intro", in: view) == ["Nothing in Help matches. Try a shorter or different word."])

        // Escape clears the search instead of leaving Help.
        #expect(pressEscape(in: view))
        #expect(view.query.isEmpty)
        #expect(titles(view) == ["Getting around"])
        // With nothing to clear, Escape passes through.
        #expect(!pressEscape(in: view))
    }

    // T-edac6214 F-668 B-DLG-251
    @Test func choosingATopicLeavesSearchResults() {
        let view = make()
        type("view", in: view)
        #expect(view.isSearching)

        view.clickTopic(.views)
        view.layoutSubtreeIfNeeded()

        #expect(view.query.isEmpty)
        #expect(titles(view) == ["Views and panels"])
        #expect(view.currentTopic == .views)
    }

    // T-a1594b16 F-668 B-DLG-248
    @Test func tellsWhichPageIsOnScreenSoHelpCanOpenOnItAgain() {
        let view = make(topic: .search)
        var told: [HelpTopicID] = []
        view.onTopicChange = { told.append($0) }
        view.announceTopic()
        #expect(titles(view) == ["Searching"])
        #expect(told.last == .search)

        view.clickTopic(.files)
        #expect(told.last == .files)
        // Choosing the page already shown tells nothing new.
        view.clickTopic(.files)
        #expect(told == [.search, .files])
    }

    // B-DLG-249: a topic asked for while Help is open replaces the whole view
    @Test func aTopicAskedForReplacesTheSearchAndTheScroll() {
        let view = make()
        type("trash", in: view)
        view.show(topic: .shortcuts)
        view.layoutSubtreeIfNeeded()
        #expect(view.query.isEmpty)
        #expect(titles(view) == ["Keyboard shortcuts"])
        #expect(view.currentTopic == .shortcuts)
    }

    // F-663 F-664: the sidebar is 208 wide (188 narrow); compact moves the topics above the page
    @Test func laysTheSidebarOutByLayoutMode() {
        let wide = make(layout: .wide)
        #expect(wide.sidebar.frame.width == 208)
        #expect(wide.topicButtons.map(\.frame.height) == Array(repeating: 28, count: 5))
        // 12 in, a field of 24, 10, then topics of 28 with 1 between.
        #expect(wide.searchField.frame == NSRect(x: 10, y: 12, width: 187, height: 24))
        #expect(wide.topicButtons.map(\.frame.minY) == [46, 75, 104, 133, 162])

        let narrow = make(layout: .narrow)
        #expect(narrow.sidebar.frame.width == 188)

        let compact = make(layout: .compact, size: NSSize(width: 640, height: 680))
        #expect(compact.sidebar.frame.width == 640)
        #expect(compact.sidebar.frame.minY == 0)
        #expect(compact.topicButtons.allSatisfy { $0.frame.minY >= 46 })
        // The page starts below the topics.
        #expect((compact.page?.frame.minY ?? 0) == 16)
    }

    // F-663 the window's sidebar runs under the traffic lights: its content and the page start 52 down
    @Test func startsTheContentUnderTheTrafficLightsInTheWindow() {
        let view = make(topInset: 52)
        #expect(view.searchField.frame.minY == 52)
        #expect(view.topicButtons.first?.frame.minY == 86)
        #expect(view.page?.frame.minY == 52)
    }

    // F-663 the content column is at most 720 wide, padded 28 at the sides
    @Test func holdsTheContentColumnTo720() {
        let view = make(layout: .wide, size: NSSize(width: 1600, height: 680))
        #expect(view.page?.frame.width == 720)
        #expect(view.page?.frame.minX == 28)
        let small = make(layout: .wide, size: NSSize(width: 700, height: 680))
        #expect((small.page?.frame.width ?? 0) <= 700 - 208 - 56)
    }

    // F-667 the keycaps are 21 tall and at least 22 wide
    @Test func drawsKeycapsOf21ByAtLeast22() {
        let view = make(topic: .shortcuts)
        let keycaps = views("help.keycap", in: view)
        #expect(!keycaps.isEmpty)
        #expect(keycaps.allSatisfy { $0.frame.height == 21 && $0.frame.width >= 22 })
    }

    // F-667 the two columns of the shortcuts page, groups kept whole
    @Test func putsTheShortcutGroupsInTwoColumnsWhenThereIsRoom() {
        let wide = make(topic: .shortcuts, layout: .wide, size: NSSize(width: 1400, height: 680))
        let headingFrames = views("help.sectionTitle", in: wide).map { rect($0, in: wide) }
        #expect(Set(headingFrames.map { $0.minX }).count == 2)
        let narrow = make(topic: .shortcuts, layout: .compact, size: NSSize(width: 560, height: 680))
        let narrowFrames = views("help.sectionTitle", in: narrow).map { rect($0, in: narrow) }
        #expect(Set(narrowFrames.map { $0.minX }).count == 1)
    }
}
