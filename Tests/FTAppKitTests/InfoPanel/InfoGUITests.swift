// Covers the path bar's editor in a real explorer window on screen, by feature row (ContentPane.test.tsx's path
// bar): the editor takes the first responder and the field editor
import AppKit
import FTFileSystem
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowGUITests {
    @MainActor
    @Suite struct InfoGUITests {
        // F-745 F-746 B-INFO-110 B-INFO-112 B-INFO-114: a double click opens the editor on the current path; Escape closes it.
        // B-VIEW-015 T-73dec6db
        @Test func theEditorOpensOnTheCurrentPathAndEscapeClosesIt() async throws {
            let harness = try ExplorerHarness()
            let tab = try await harness.open()
            let bar = tab.content.contentShell.pathBarRow
            bar.beginEditing()
            harness.layout(tab)
            #expect(bar.isEditing)
            #expect(bar.editor.field.stringValue == harness.folder.path)
            #expect(bar.status.isHidden)
            let editor = try #require(bar.editor.field.currentEditor() as? NSTextView)
            #expect(editor.selectedRange.location == harness.folder.path.utf16.count)
            _ = bar.editor.control(
                bar.editor.field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
            #expect(!bar.isEditing)
            await harness.close()
        }
    }
}
