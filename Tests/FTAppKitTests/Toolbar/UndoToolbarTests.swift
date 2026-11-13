import AppKit
import FTFoundation
import FTOperations
import FTTestSupport
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    @MainActor
    @Suite struct UndoToolbarTests: ToolbarTesting {
        static func rename(_ from: String, _ to: String) -> FinishedWrite {
            FinishedWrite(
                action: .write(.rename),
                log: .undoable(units: [
                    UndoUnit(steps: [
                        .moved(UndoStep.Moved(from: from, to: to, id: nil, itemKind: .file, parentId: nil))
                    ])
                ]), items: [])
        }

        /// A tab whose toolbar and Undo History list follow `history`.
        func open(_ harness: ExplorerHarness, _ history: UndoHistory) async throws -> MainWindowController {
            let tab = try await harness.open()
            tab.explorerToolbar.undoHistory = { history }
            setItems(tab, ToolbarItems.defaultTopItems + [.undoHistory, .undo, .redo], harness)
            return tab
        }

        @Test func undoAndRedoSayWhatTheyWouldDoAndAreOffWithNothingToDo() async throws {
            let harness = try ExplorerHarness.windowless()
            let history = UndoHistory()
            let tab = try await open(harness, history)
            let toolbar = tab.explorerToolbar
            #expect(button(tab, .undo)?.isEnabled == false)
            #expect(button(tab, .undo)?.tooltip == "Undo (⌘Z)")
            #expect(button(tab, .redo)?.tooltip == "Redo (⇧⌘Z)")
            history.record(Self.rename("/p/a", "/p/b"))
            toolbar.refreshStates()
            #expect(button(tab, .undo)?.isEnabled == true)
            #expect(button(tab, .undo)?.tooltip == "Undo Rename (⌘Z)")
            #expect(button(tab, .redo)?.isEnabled == false)
            let entry = try #require(toolbar.item(.undo)?.menuFormRepresentation)
            #expect(entry.title == "Undo Rename")
            await harness.close()
        }

        @Test func theHistoryButtonShowsOnlyWithSomethingToListAndItsListFollowsTheHistory() async throws {
            let harness = try ExplorerHarness.windowless()
            let history = UndoHistory()
            let tab = try await open(harness, history)
            let toolbar = tab.explorerToolbar
            #expect(toolbar.item(.undoHistory)?.isHidden == true)
            #expect(!toolbar.rowKeys.contains("undoHistory"))
            history.record(Self.rename("/p/a", "/p/b"))
            toolbar.refreshStates()
            #expect(toolbar.item(.undoHistory)?.isHidden == false)
            #expect(toolbar.rowKeys.contains("undoHistory"))

            let button = try #require(toolbar.undoHistoryButton)
            _ = button.accessibilityPerformPress()
            #expect(tab.undoHistoryUI.isOpen)
            #expect(button.isOn)
            #expect(tab.undoHistoryUI.view?.content.undo.map(\.title) == ["Rename"])
            let row = try #require(
                tab.undoHistoryUI.view?.descendants.compactMap { $0 as? UndoHistoryView.UndoHistoryRowView }.first)
            #expect(row.toolTip?.hasPrefix("In /p\na → b\nDone ") == true)

            // An operation while it is open shows at once.
            history.record(Self.rename("/p/c", "/p/d"))
            #expect(tab.undoHistoryUI.view?.content.undo.map(\.items) == [["c → d"], ["a → b"]])

            // Escape closes it.
            key(53, "\u{1B}", in: tab.window)
            #expect(!tab.undoHistoryUI.isOpen)
            #expect(!button.isOn)
            await harness.close()
        }

        // The buttons follow the history by themselves: what the app posts at each change of it reaches the toolbar.
        @Test func theButtonsFollowTheHistoryWhenItChanges() async throws {
            let harness = try ExplorerHarness.windowless()
            let history = UndoHistory()
            let tab = try await open(harness, history)
            let toolbar = tab.explorerToolbar
            #expect(button(tab, .undo)?.isEnabled == false)
            #expect(toolbar.item(.undoHistory)?.isHidden == true)
            history.record(Self.rename("/p/a", "/p/b"))
            UndoHistoryMenu.post(history.menu())
            #expect(button(tab, .undo)?.isEnabled == true)
            #expect(button(tab, .undo)?.tooltip == "Undo Rename (⌘Z)")
            #expect(toolbar.item(.undoHistory)?.isHidden == false)
            // The menus of the other tests are told there is nothing to undo again.
            UndoHistoryMenu.post(UndoHistory().menu())
            await harness.close()
        }

        // A new toolbar has no Undo History button: it is added while customizing.
        @Test func aNewToolbarHasNoHistoryButton() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            setItems(tab, ToolbarItems.defaultTopItems, harness)
            #expect(tab.explorerToolbar.item(.clipboard) != nil)
            #expect(tab.explorerToolbar.item(.undoHistory) == nil)
            await harness.close()
        }

        // One list at a time: opening the clipboard's closes the Undo History, and the other way round. A tab that
        // closes takes its open list with it.
        @Test func theClipboardAndHistoryListsAreNeverOpenTogether() async throws {
            let harness = try ExplorerHarness.windowless()
            let history = UndoHistory()
            let tab = try await open(harness, history)
            history.record(Self.rename("/p/a", "/p/b"))
            tab.explorerToolbar.refreshStates()
            tab.services.clipboard.set(
                .ready(mode: .copy, sourcePaths: ["/a"], sourceEntries: [:], capturedAt: "1"), from: nil)
            tab.clipboardChanged()
            let historyButton = try #require(tab.explorerToolbar.undoHistoryButton)
            tab.undoHistoryUI.toggle(from: historyButton)
            #expect(tab.undoHistoryUI.isOpen)
            tab.showClipboard()
            #expect(tab.clipboardUI.isOpen)
            #expect(!tab.undoHistoryUI.isOpen)
            #expect(!historyButton.isOn)
            tab.undoHistoryUI.toggle(from: historyButton)
            #expect(tab.undoHistoryUI.isOpen)
            #expect(!tab.clipboardUI.isOpen)
            tab.services.clipboard.set(.empty, from: nil)
            await harness.close()
            #expect(!tab.undoHistoryUI.isOpen)
            #expect(!historyButton.isOn)
        }

        // The clipboard and Undo History buttons can be taken off, and keep their room while it is short.
        @Test func theClipboardAndHistoryButtonsCanBeTakenOffAndKeepTheirRoom() async throws {
            let harness = try ExplorerHarness.windowless()
            let history = UndoHistory()
            let tab = try await open(harness, history)
            let toolbar = tab.explorerToolbar
            #expect(toolbar.item(.clipboard)?.visibilityPriority == .high)
            #expect(toolbar.item(.undoHistory)?.visibilityPriority == .high)
            #expect(toolbar.item(.undo)?.visibilityPriority == .standard)
            setItems(tab, [.back, .title, .search, .viewOptions], harness)
            #expect(toolbar.item(.clipboard) == nil)
            #expect(toolbar.item(.undoHistory) == nil)
            #expect(harness.store.preferences().topToolbarItems == [.back, .title, .search, .viewOptions])
            let allowed = toolbar.toolbarAllowedItemIdentifiers(toolbar.toolbar)
            #expect(allowed.contains(ExplorerToolbar.identifier(.clipboard)))
            #expect(allowed.contains(ExplorerToolbar.identifier(.undoHistory)))
            await harness.close()
        }
    }
}

extension NSView {
    /// Every view under this one.
    fileprivate var descendants: [NSView] { subviews + subviews.flatMap(\.descendants) }
}
