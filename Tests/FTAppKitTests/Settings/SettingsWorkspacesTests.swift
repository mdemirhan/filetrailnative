// Checks the workspaces' list in Settings ▸ Browsing: renaming, removing and reordering them, and the keys their rows
// show
import AppKit
import FTFoundation
import Testing

@testable import FTAppKit

@MainActor
@Suite struct SettingsWorkspacesTests {
    typealias Kit = SettingsTestKit

    private static func workspace(_ id: String, _ name: String) -> Workspace {
        var session = AppPreferences.defaults().windowSession
        session.openTabs = [tab("/Users/demo/\(id)")]
        session.activeTabIndex = 0
        return Workspace(
            id: id, name: name, bounds: StoredWindowState(width: 900, height: 600, maximized: false), session: session)
    }

    private static func make(_ names: [String]) throws -> (SettingsWindowController, SettingsRecorder, NSWindow) {
        let kept = names.enumerated().map { workspace("w\($0.offset)", $0.element) }
        let preferences = AppPreferences.defaults(theme: .light).with { $0.workspaces = kept }
        let (controller, recorder) = Kit.make(tab: .browsing, preferences: preferences)
        return (controller, recorder, try #require(controller.window))
    }

    private static func list(_ controller: SettingsWindowController) throws -> SettingsListView {
        try Kit.list("Workspaces", in: controller)
    }

    private static func keys(_ list: SettingsListView) -> [String?] { list.rows.map(\.spec.trailingNote) }

    private static func alert(_ window: NSWindow) -> AlertCard? {
        DialogScrim.front(in: window)?.panel as? AlertCard
    }

    /// Rename… on the selected row, `name` typed and Rename pressed; the prompt is left as the answer leaves it.
    private static func rename(
        _ label: String, to name: String, in controller: SettingsWindowController, window: NSWindow
    ) async throws -> AlertCard {
        if alert(window) == nil {
            Kit.click(Kit.barButton(label, in: controller.settingsView))
            #expect(await waitUntil { alert(window)?.content.accessory is TextPromptAccessory })
        }
        let card = try #require(alert(window))
        let prompt = try #require(card.content.accessory as? TextPromptAccessory)
        prompt.field.stringValue = name
        prompt.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        card.press("Rename")
        return card
    }

    // The first five rows show the key that opens them, by their place in the list: a row moved by its buttons, by
    // the keyboard or by a drag takes the key of the place it moves to.
    @Test func theKeysFollowTheOrderAsRowsAreMovedUpDownAndDragged() throws {
        let (controller, recorder, _) = try Self.make(["A", "B", "C", "D", "E", "F"])
        let list = try Self.list(controller)
        #expect(Kit.names(list) == ["A", "B", "C", "D", "E", "F"])
        #expect(Self.keys(list) == ["⌃⌘1", "⌃⌘2", "⌃⌘3", "⌃⌘4", "⌃⌘5", nil])

        list.select(0)
        #expect(Kit.barButton("Move A Up", in: controller.settingsView)?.isEnabled == false)
        #expect(Kit.barButton("Move A Down", in: controller.settingsView)?.isEnabled == true)
        list.select(5)
        #expect(Kit.barButton("Move F Down", in: controller.settingsView)?.isEnabled == false)
        Kit.click(Kit.barButton("Move F Up", in: controller.settingsView))
        #expect(Kit.names(list) == ["A", "B", "C", "D", "F", "E"])
        #expect(Self.keys(list) == ["⌃⌘1", "⌃⌘2", "⌃⌘3", "⌃⌘4", "⌃⌘5", nil])
        #expect(recorder.current.workspaces.map(\.id) == ["w0", "w1", "w2", "w3", "w5", "w4"])
        #expect(list.rows[list.selectedIndex ?? -1].spec.name == "F")

        list.select(0)
        Kit.click(Kit.barButton("Move A Down", in: controller.settingsView))
        #expect(Kit.names(list) == ["B", "A", "C", "D", "F", "E"])

        // A drag of the last row to the top.
        list.drop(5, on: 0)
        #expect(Kit.names(list) == ["E", "B", "A", "C", "D", "F"])
        #expect(Self.keys(list) == ["⌃⌘1", "⌃⌘2", "⌃⌘3", "⌃⌘4", "⌃⌘5", nil])
        #expect(recorder.current.workspaces.map(\.name) == ["E", "B", "A", "C", "D", "F"])
        #expect(list.rows[list.selectedIndex ?? -1].spec.name == "E")

        // ⌘↓ moves the selected row down.
        #expect(list.handleKey(Kit.key(Kit.down.0, code: Kit.down.1, modifiers: .command, window: controller.window)))
        #expect(Kit.names(list) == ["B", "E", "A", "C", "D", "F"])
        // Past the end nothing moves.
        list.select(5)
        Kit.click(Kit.barButton("Move F Down", in: controller.settingsView))
        #expect(recorder.current.workspaces.map(\.name) == ["B", "E", "A", "C", "D", "F"])
    }

    // A key changed in Settings ▸ Shortcuts is the one the row shows; one taken away shows none.
    @Test func theRowsShowTheKeysChosenInShortcuts() throws {
        let kept = ["A", "B"].enumerated().map { Self.workspace("w\($0.offset)", $0.element) }
        let preferences = AppPreferences.defaults(theme: .light).with {
            $0.workspaces = kept
            $0.shortcutOverrides = ["openWorkspace1": ["Ctrl+Option+Cmd+P"], "openWorkspace2": []]
        }
        let (controller, _) = Kit.make(tab: .browsing, preferences: preferences)
        let list = try Self.list(controller)
        #expect(Self.keys(list) == ["⌃⌥⌘P", nil])
    }

    // A name another workspace has is refused, whatever its case and however its accented letter is stored; the
    // workspace's own name in other letters isn't. What is kept is trimmed and composed.
    @Test func renamingRefusesANameTakenIgnoringCaseAndHowItsLettersAreStored() async throws {
        let (controller, recorder, window) = try Self.make(["Photos", "Caf\u{E9}"])
        let list = try Self.list(controller)
        list.select(0)

        var card = try await Self.rename("Rename Photos", to: "CAFE\u{301}", in: controller, window: window)
        let prompt = try #require(card.content.accessory as? TextPromptAccessory)
        #expect(await waitUntil { prompt.error != nil })
        #expect(prompt.error == "There\u{2019}s already a workspace called \u{201C}Caf\u{E9}\u{201D}.")
        #expect(Self.alert(window) === card)
        #expect(recorder.current.workspaces.map(\.name) == ["Photos", "Caf\u{E9}"])

        card = try await Self.rename("Rename Photos", to: "  Cafe\u{301} Trips  ", in: controller, window: window)
        #expect(await waitUntil { Self.alert(window) == nil })
        let renamed = try #require(recorder.current.workspaces.first)
        #expect(renamed.id == "w0")
        #expect(renamed.name.unicodeScalars.elementsEqual("Caf\u{E9} Trips".unicodeScalars))
        #expect(Kit.names(list) == ["Caf\u{E9} Trips", "Caf\u{E9}"])

        // Its own name in other letters.
        list.select(1)
        _ = try await Self.rename("Rename Caf\u{E9}", to: "CAF\u{C9}", in: controller, window: window)
        #expect(await waitUntil { Self.alert(window) == nil })
        #expect(recorder.current.workspaces.map(\.name) == ["Caf\u{E9} Trips", "CAF\u{C9}"])
    }

    // Remove asks first; Cancel keeps the workspace, and once it goes the rows after it take its keys.
    @Test func removingAsksAndTheRowsAfterTakeTheKeys() async throws {
        let (controller, recorder, window) = try Self.make(["A", "B", "C", "D", "E", "F"])
        let list = try Self.list(controller)
        list.select(1)

        Kit.click(Kit.barButton("Remove B", in: controller.settingsView))
        #expect(await waitUntil { Self.alert(window) != nil })
        var question = try #require(Self.alert(window))
        #expect(question.titleLabel.stringValue == "Remove \u{201C}B\u{201D}?")
        question.press("Cancel")
        #expect(await waitUntil { Self.alert(window) == nil })
        await Kit.settle()
        #expect(recorder.current.workspaces.count == 6)

        // ⌫ asks as the button does.
        #expect(
            list.handleKey(Kit.key(Kit.backspace.0, code: Kit.backspace.1, window: controller.window)))
        #expect(await waitUntil { Self.alert(window) != nil })
        question = try #require(Self.alert(window))
        question.press("Remove")
        #expect(await waitUntil { recorder.current.workspaces.count == 5 })
        #expect(recorder.current.workspaces.map(\.id) == ["w0", "w2", "w3", "w4", "w5"])
        #expect(Kit.names(list) == ["A", "C", "D", "E", "F"])
        #expect(Self.keys(list) == ["⌃⌘1", "⌃⌘2", "⌃⌘3", "⌃⌘4", "⌃⌘5"])
    }
}
