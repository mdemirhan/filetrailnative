import AppKit
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    /// Delete Immediately (⌥⌘⌫) is for what is in the Trash. Its key still reaches the window while its item is dimmed,
    /// so the command itself refuses anything else, before any question.
    @MainActor
    @Suite struct DeleteImmediatelyWindowTests {
        @Test func outsideTheTrashItDeletesNothingAndAsksNothing() async throws {
            let harness = try ExplorerHarness.windowless()
            let writes = try harness.writeOperations()
            defer { withExtendedLifetime(writes) {} }
            // Every question is answered Delete: what stops it must be the command, not a Cancel.
            var asked: [String] = []
            writes.dialogs.confirm = { question, _ in
                asked.append(question.title)
                return true
            }
            let file = harness.folder.appending("keep.txt")
            try "keep".write(to: file, atomically: true, encoding: .utf8)
            let tab = try await harness.open()
            tab.perform(.refreshOrApplySearchSort)
            let path = try #require(
                realpath(file.path, nil).map { pointer in
                    defer { free(pointer) }
                    return String(cString: pointer)
                })
            #expect(await waitUntil { tab.activePane.content.listedEntry(at: path) != nil })
            tab.activePane.content.select(paths: [path])
            // The list has the keyboard, as it has when ⌥⌘⌫ is pressed there.
            tab.focusPane(tab.activePane)
            #expect(tab.focusedPane == .content)
            #expect(!tab.canPerform(.deleteImmediately))

            tab.perform(.deleteImmediately)
            try await Task.sleep(for: .milliseconds(300))
            #expect(FileManager.default.fileExists(atPath: path))
            #expect(asked.isEmpty)
            await harness.close()
        }
    }
}
