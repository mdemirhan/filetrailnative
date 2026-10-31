// Ports by behavior row what components/ContentPane.test.tsx and PathSuggestionDropdown say of the path bar in a tab: the
// expanded bar folding back, the editor closing with the folder and its suggestions from the keyboard, and of a folder
// opened normally starting with nothing selected (hooks/useExplorerNavigationController.ts)
import AppKit
import FTFileSystem
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

/// The path bar's editor and its suggestions, on the row alone in a window that is never shown: Tab, the arrows, Return and
/// a click on a suggestion, with the debounce moved by hand.
@MainActor
struct PathEditorSuggestionTests {
    private let rows = [
        PathSuggestionRow(path: "/typed/one", name: "one"), PathSuggestionRow(path: "/typed/two", name: "two"),
    ]

    /// What is opened on, what the editor went to, and the timers of its debounce.
    @MainActor
    private final class Editing {
        let window: ExplorerTabWindow
        let bar = PathBarRowView()
        let timers = ManualTimers()
        var went: [String] = []

        init() {
            _ = NSApplication.shared
            window = ExplorerTabWindow(
                contentRect: NSRect(x: 0, y: 0, width: 800, height: 400), styleMask: [.titled], backing: .buffered,
                defer: true)
            window.isReleasedWhenClosed = false
            window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
            bar.frame = NSRect(x: 0, y: 0, width: 800, height: 28)
            window.contentView?.addSubview(bar)
            bar.path = "/start"
            bar.editor.timers = timers
            bar.onNavigate = { [unowned self] in self.went.append($0) }
        }

        /// The debounce is over, and the suggestions asked for have come.
        func suggestionsCome() async {
            timers.advance(InfoMetrics.suggestionDebounce)
            #expect(await waitUntil { self.bar.editor.suggestionsAreShown })
        }
    }

    private func editing() async -> Editing {
        let editing = Editing()
        let rows = rows
        editing.bar.requestSuggestions = { _ in rows }
        editing.bar.beginEditing()
        await editing.suggestionsCome()
        return editing
    }

    private func press(_ selector: Selector, _ bar: PathBarRowView) throws {
        let editor = try #require(bar.editor.field.currentEditor() as? NSTextView)
        _ = bar.editor.control(bar.editor.field, textView: editor, doCommandBy: selector)
    }

    private let tabKey = #selector(NSResponder.insertTab(_:))
    private let backtab = #selector(NSResponder.insertBacktab(_:))
    private let down = #selector(NSResponder.moveDown(_:))
    private let up = #selector(NSResponder.moveUp(_:))
    private let escape = #selector(NSResponder.cancelOperation(_:))
    private let enter = #selector(NSResponder.insertNewline(_:))

    // B-VIEW-101: Tab marks the first suggestion (Shift+Tab the last), Return fills that row in and keeps the editor,
    // which goes nowhere. The row had the keyboard and is gone: the field doesn't get it back, so the next keys
    // don't reach it (`PathSuggestionDropdown` without `refocusInputOnAccept`).
    @Test func tabMarksASuggestionAndReturnFillsItIn() async throws {
        let editing = await editing()
        let bar = editing.bar
        try press(tabKey, bar)
        #expect(bar.editor.state.highlighted == 0)
        #expect(bar.editor.field.stringValue == "/typed/one/")
        try press(enter, bar)
        #expect(bar.isEditing)
        #expect(bar.editor.state.draft == "/typed/one/")
        #expect(bar.editor.field.stringValue == bar.editor.state.draft)
        #expect(!bar.editor.suggestionsAreShown)
        #expect(editing.went.isEmpty)
        #expect(bar.editor.field.currentEditor() == nil)
        await editing.suggestionsCome()
        #expect(bar.isEditing)
        #expect(bar.editor.field.stringValue == "/typed/one/")
        #expect(bar.editor.field.currentEditor() == nil)
    }

    // B-VIEW-101: a click on a suggestion never took the keyboard from the field, which goes on being edited.
    @Test func aClickOnASuggestionLeavesTheKeyboardInTheField() async throws {
        let editing = await editing()
        let bar = editing.bar
        let root = try #require(editing.window.contentView)
        let row = try #require(allViews(in: root).compactMap { $0 as? PathSuggestionRowView }.last)
        row.onClick()
        #expect(bar.isEditing)
        #expect(bar.editor.state.draft == "/typed/two/")
        #expect(bar.editor.field.stringValue == bar.editor.state.draft)
        #expect(!bar.editor.suggestionsAreShown)
        #expect(editing.went.isEmpty)
        let editor = try #require(bar.editor.field.currentEditor())
        #expect(editor.selectedRange == NSRange(location: "/typed/two/".utf16.count, length: 0))
        await editing.suggestionsCome()
        try press(backtab, bar)
        #expect(bar.editor.state.highlighted == 1)
    }

    private func allViews(in view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(allViews)
    }

    // B-INFO-117: in the list the arrows move with wrap.
    @Test func theArrowsWrapInTheSuggestionList() async throws {
        let editing = await editing()
        let bar = editing.bar
        try press(tabKey, bar)
        #expect(bar.editor.state.highlighted == 0)
        try press(down, bar)
        #expect(bar.editor.state.highlighted == 1)
        #expect(bar.editor.field.stringValue == "/typed/two/")
        try press(down, bar)
        #expect(bar.editor.state.highlighted == 0)
        try press(up, bar)
        #expect(bar.editor.state.highlighted == 1)
        withExtendedLifetime(editing) {}
    }

    // B-INFO-117: Escape in the list clears the suggestions and stays in the field, with what was typed.
    @Test func escapeInTheListStaysInTheField() async throws {
        let editing = await editing()
        let bar = editing.bar
        let typed = bar.editor.state.draft
        try press(tabKey, bar)
        try press(escape, bar)
        #expect(!bar.editor.suggestionsAreShown)
        #expect(bar.isEditing)
        #expect(bar.editor.field.stringValue == typed)
        #expect(bar.window?.firstResponder === bar.editor.field.currentEditor())
        withExtendedLifetime(editing) {}
    }

    // B-INFO-117: Tab goes back to the field: Return no longer fills the row in, it goes to the one marked.
    @Test func tabLeavesTheList() async throws {
        let editing = await editing()
        let bar = editing.bar
        try press(tabKey, bar)
        try press(tabKey, bar)
        try press(enter, bar)
        #expect(editing.went == ["/typed/one"])
        #expect(!bar.isEditing)
    }
}

extension ExplorerWindowlessTests {
    @MainActor
    @Suite struct PathBarRoutesTests {
        private let rows = [
            PathSuggestionRow(path: "/typed/one", name: "one"), PathSuggestionRow(path: "/typed/two", name: "two"),
        ]

        /// The tab with its path bar's editor open and the two suggestions showing.
        private func editing() async throws -> (ExplorerHarness, MainWindowController, PathBarRowView) {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let bar = tab.content.contentShell.pathBarRow
            let timers = ManualTimers()
            bar.editor.timers = timers
            let rows = rows
            bar.requestSuggestions = { _ in rows }
            bar.beginEditing()
            timers.advance(InfoMetrics.suggestionDebounce)
            #expect(await waitUntil { bar.editor.suggestionsAreShown })
            return (harness, tab, bar)
        }

        private func press(_ selector: Selector, _ bar: PathBarRowView) throws {
            let editor = try #require(bar.editor.field.currentEditor() as? NSTextView)
            _ = bar.editor.control(bar.editor.field, textView: editor, doCommandBy: selector)
        }

        private let escape = #selector(NSResponder.cancelOperation(_:))

        // MARK: The editor's suggestions

        // B-VIEW-102: Escape first clears the suggestions and keeps the editor; the next closes it, giving the
        // keyboard back to the list.
        @Test func escapeClearsTheSuggestionsThenClosesTheEditor() async throws {
            let (harness, tab, bar) = try await editing()
            try press(escape, bar)
            #expect(!bar.editor.suggestionsAreShown)
            #expect(bar.isEditing)
            try press(escape, bar)
            #expect(!bar.isEditing)
            #expect(tab.window?.firstResponder === tab.content.focusView)
            await harness.close()
        }

        // B-INFO-118 B-VIEW-097: the folder on screen changing closes the editor with its draft reset, and it
        // doesn't keep the keyboard.
        @Test func anotherFolderClosesTheEditor() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let bar = tab.content.contentShell.pathBarRow
            bar.beginEditing()
            bar.editor.field.stringValue = "/half/typed"
            bar.editor.controlTextDidChange(
                Notification(name: NSControl.textDidChangeNotification, object: bar.editor.field))
            let beta = harness.folder.appending("Beta").path
            tab.go(to: URL(fileURLWithPath: beta))
            #expect(await waitUntil { !bar.isEditing })
            #expect(samePath(bar.path, beta))
            #expect(bar.editor.isHidden)
            #expect(bar.editor.field.currentEditor() == nil)
            bar.beginEditing()
            #expect(bar.editor.field.stringValue == bar.path)
            await harness.close()
        }

        // MARK: The expanded bar

        private func expanded() async throws -> (ExplorerHarness, MainWindowController, PathBarRowView, NSWindow) {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            harness.layout(tab)
            let bar = tab.content.contentShell.pathBarRow
            bar.pathBar.setExpanded(true)
            #expect(bar.pathBar.expanded)
            return (harness, tab, bar, try #require(tab.window))
        }

        private func pointer(_ type: NSEvent.EventType, inside: Bool, _ bar: PathBarRowView, _ window: NSWindow) throws
        {
            let inBar = bar.pathBar.convert(NSPoint(x: bar.pathBar.bounds.midX, y: bar.pathBar.bounds.midY), to: nil)
            let point = inside ? inBar : NSPoint(x: inBar.x, y: inBar.y + 200)
            let event = try #require(MouseEvents.event(type, at: point, in: window))
            _ = WindowEventRouting.intercept(event, in: window)
        }

        // T-a38008df B-VIEW-097: a mouse move inside keeps it open; one outside folds it, and so does a press outside.
        @Test func theExpandedBarFoldsWhenThePointerLeavesOrOnAPressOutside() async throws {
            let (harness, _, bar, window) = try await expanded()
            try pointer(.mouseMoved, inside: true, bar, window)
            #expect(bar.pathBar.expanded)
            try pointer(.leftMouseDown, inside: true, bar, window)
            #expect(bar.pathBar.expanded)
            try pointer(.mouseMoved, inside: false, bar, window)
            #expect(!bar.pathBar.expanded)
            bar.pathBar.setExpanded(true)
            #expect(bar.pathBar.expanded)
            try pointer(.leftMouseDown, inside: false, bar, window)
            #expect(!bar.pathBar.expanded)
            await harness.close()
        }

        // B-VIEW-097: it stays while a separator's menu is open, which belongs to it.
        @Test func theExpandedBarStaysWhileASeparatorsMenuIsOpen() async throws {
            let (harness, tab, bar, window) = try await expanded()
            harness.layout(tab)
            bar.layoutSubtreeIfNeeded()
            let separator = try #require(
                findViews("pathBar.separator", in: bar).compactMap { $0 as? PathSeparatorView }.last)
            separator.onClick?()
            #expect(await waitUntil { AppMenuPresenter.shared.menu?.identifier == "pathBarMenu" })
            try pointer(.mouseMoved, inside: false, bar, window)
            #expect(bar.pathBar.expanded)
            AppMenuPresenter.shared.close()
            await harness.close()
        }

        // B-VIEW-097: and it folds when the folder changes.
        @Test func theExpandedBarFoldsWithAnotherFolder() async throws {
            let (harness, tab, bar, _) = try await expanded()
            let beta = harness.folder.appending("Beta").path
            tab.go(to: URL(fileURLWithPath: beta))
            #expect(await waitUntil { samePath(bar.path, beta) })
            #expect(!bar.pathBar.expanded)
            await harness.close()
        }

        // MARK: A folder opened

        // B-SEL-029: opening a folder starts with nothing selected, and going up doesn't select the folder come from.
        @Test func aFolderOpenedStartsWithNothingSelected() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, _) = try await harness.openList()
            let alpha = try #require(tab.content.entries.first { $0.name == "Alpha" })
            tab.content.select(paths: [alpha.path])
            #expect(tab.content.selection.paths == [alpha.path])
            _ = await tab.navigate(to: URL(fileURLWithPath: alpha.path))
            #expect(tab.folder.lastPathComponent == "Alpha")
            #expect(tab.content.selection.isEmpty)
            tab.perform(.goEnclosingFolder)
            #expect(await waitUntil { samePath(tab.folder.path, harness.folder.path) && !tab.isNavigating })
            #expect(tab.content.selection.isEmpty)
            await harness.close()
        }
    }
}
