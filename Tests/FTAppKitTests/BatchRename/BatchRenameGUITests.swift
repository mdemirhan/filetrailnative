// Ports the keyboard cases of the Rename sheet for several items that need a window on screen
// (components/BatchRenameSheet.test.tsx, components/useDialogFocus.ts and App.menusAndTree.test.tsx): focus on open,
// Tab wrapping inside the sheet and focus given back, Escape from anywhere in the window, and F2 and Return reaching
// the sheet through the window
import AppKit
import FTFileSystem
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowGUITests {
    @MainActor
    @Suite struct BatchRenameGUITests {
        /// A window on screen whose a.txt and b.txt are selected, the list with the keyboard.
        private func open() async throws -> (ExplorerHarness, MainWindowController) {
            let harness = try ExplorerHarness()
            for name in ["a.txt", "b.txt"] {
                try "x".write(to: harness.folder.appending(name), atomically: true, encoding: .utf8)
            }
            let tab = try await harness.open()
            let paths = ["a.txt", "b.txt"].compactMap { name in tab.content.entries.first { $0.name == name }?.path }
            tab.content.applySelection(ContentSelection.of(paths))
            tab.perform(.focusContentPane)
            return (harness, tab)
        }

        private func opened(_ tab: MainWindowController) async -> BatchRenameSheetView? {
            _ = await waitUntil { tab.batchRenameSheet.map { !$0.model.checking } ?? false }
            return tab.batchRenameSheet
        }

        // F-796 B-DLG-092: the keyboard starts in Find; Tab and ⇧Tab go round the sheet and never leave it; closing
        // gives it back to the list.
        @Test func focusStartsInFindWrapsInsideTheSheetAndGoesBackOnClose() async throws {
            let (harness, tab) = try await open()
            let window = try #require(tab.window)
            let list = window.firstResponder
            tab.renameSelected()
            let sheet = try #require(await opened(tab))
            #expect(sheet.findField.holdsKeyboard)
            let chain = sheet.focusChain
            for _ in 0..<(chain.count + 1) {
                DialogKeys.press(KeyCode.tab, "\t", in: window)
                #expect(sheet.focusedControl.map { $0.isDescendant(of: sheet) } == true)
            }
            DialogKeys.press(KeyCode.tab, "\t", modifiers: .shift, in: window)
            #expect(sheet.focusedControl.map { $0.isDescendant(of: sheet) } == true)
            sheet.cancelButton.perform()
            #expect(tab.batchRenameSheet == nil)
            #expect(window.firstResponder === list)
            await harness.close()
        }

        // B-DLG-090: Escape closes the sheet from any control, and from outside it.
        @Test func escapeClosesTheSheetFromAnywhereInTheWindow() async throws {
            let (harness, tab) = try await open()
            let window = try #require(tab.window)
            tab.renameSelected()
            let sheet = try #require(await opened(tab))
            window.makeFirstResponder(sheet.onConflictPopUp)
            DialogKeys.press(KeyCode.escape, "\u{1b}", in: window)
            #expect(tab.batchRenameSheet == nil)
            tab.renameSelected()
            _ = try #require(await opened(tab))
            window.makeFirstResponder(nil)
            DialogKeys.press(KeyCode.escape, "\u{1b}", in: window)
            #expect(tab.batchRenameSheet == nil)
            await harness.close()
        }

        // F-796 B-DLG-073: F2 and Return in the list open the sheet for several items. F2 is a write command, which
        // goes to the app's file operations, as in the app.
        @Test func f2AndReturnInTheListOpenTheSheet() async throws {
            let (harness, tab) = try await open()
            let operations = AppWriteOperations(
                userData: harness.folder.url, directoryService: harness.services.directoryService,
                windows: harness.windows, trash: .standIn, log: { _ in })
            defer { withExtendedLifetime(operations) {} }
            let window = try #require(tab.window)
            DialogKeys.press(120, "\u{F705}", in: window)  // F2
            #expect(await opened(tab) != nil)
            tab.batchRenameSheet?.cancelButton.perform()
            tab.perform(.focusContentPane)
            DialogKeys.press(KeyCode.returnKey, "\r", in: window)
            #expect(await opened(tab) != nil)
            tab.batchRenameSheet?.cancelButton.perform()
            await harness.close()
        }
    }
}
