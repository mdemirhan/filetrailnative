// Port of the rename cases of apps/desktop/src/renderer/components/InlineRenameField.test.tsx and
// hooks/useExplorerNavigationController.ts (:664-683), through F2 and the app's file operations
import AppKit
import FTFileSystem
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    /// The file operations' `current` is the app's one: no other test at the same time.
    @MainActor
    @Suite(.windowlessAlone) struct RenameFieldMatrixTests {
        private func path(_ tab: MainWindowController, _ name: String) throws -> String {
            try #require(tab.content.listed.first { $0.name == name }?.path)
        }

        private func field(_ tab: MainWindowController) throws -> InlineRenameField {
            try #require(identified("rename.field", in: tab.window?.contentView).first as? InlineRenameField)
        }

        // T-b4cc6249: a folder's whole name is selected, dots and all.
        @Test func f2SelectsTheWholeNameOfAFolderWithDots() async throws {
            let harness = try ExplorerHarness.windowless()
            let writes = try harness.writeOperations()
            defer { withExtendedLifetime(writes) {} }
            try FileManager.default.createDirectory(
                at: harness.folder.appending("Photos 2026.10.03"), withIntermediateDirectories: false)
            let (tab, list) = try await harness.openList()
            tab.content.select(paths: [try path(tab, "Photos 2026.10.03")])
            tab.content.focusList()
            list.key("F2")
            #expect(try field(tab).currentEditor()?.selectedRange == NSRange(location: 0, length: 17))
            tab.content.renameCancelled()
            await harness.close()
        }

        // T-2ced1d75 B-SEL-129: while text is being composed Return and Escape are the composition's, not the rename's.
        @Test func returnAndEscapeBelongToTheCompositionWhileTextIsMarked() async throws {
            let harness = try ExplorerHarness.windowless()
            let writes = try harness.writeOperations()
            defer { withExtendedLifetime(writes) {} }
            let (tab, list) = try await harness.openList()
            let note = try path(tab, "note.txt")
            tab.content.select(paths: [note])
            tab.content.focusList()
            list.key("F2")
            let field = try field(tab)
            let editor = try #require(field.currentEditor() as? NSTextView)
            editor.setMarkedText(
                "か", selectedRange: NSRange(location: 1, length: 0), replacementRange: editor.selectedRange())
            #expect(editor.hasMarkedText())
            for command in [#selector(NSResponder.insertNewline(_:)), #selector(NSResponder.cancelOperation(_:))] {
                #expect(!field.control(field, textView: editor, doCommandBy: command))
                #expect(tab.content.inlineRename?.path == note)
            }
            // Composed, Escape is the rename's again.
            editor.unmarkText()
            #expect(field.control(field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
            #expect(tab.content.inlineRename == nil)
            #expect(FileManager.default.fileExists(atPath: note))
            await harness.close()
        }

        // T-7f1c1f2a B-SEL-034 B-SEL-080: a rename to a name outside the filter selects the item and clears the filter.
        @Test func aRenameOutsideTheFilterSelectsItAndClearsTheFilter() async throws {
            let harness = try ExplorerHarness.windowless()
            let writes = try harness.writeOperations()
            defer { withExtendedLifetime(writes) {} }
            let (tab, list) = try await harness.openList()
            tab.content.setFilter("note")
            #expect(list.rowNames == ["note.txt"])
            let note = try path(tab, "note.txt")
            tab.content.select(paths: [note])
            tab.content.focusList()
            list.key("F2")
            #expect(tab.content.inlineRename?.path == note)
            tab.content.renameSubmitted("memo.txt")
            #expect(await waitUntil { list.rowNames.contains("memo.txt") })
            #expect(tab.content.filter.isEmpty)
            #expect(list.selectedNames == ["memo.txt"])
            #expect(list.rowNames.contains("Alpha"))
            #expect(tab.content.selection.leadPath == (note as NSString).deletingLastPathComponent + "/memo.txt")
            await harness.close()
        }
    }
}
