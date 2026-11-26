// Reveal in Tree adds no second step for the folder on screen, on a window that is never shown
import AppKit
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    @MainActor
    @Suite struct InfoPanelItemTests {
        /// Asks for a navigation, and waits for it to have shown its folder.
        private func navigating(_ tab: MainWindowController, _ ask: () -> Void) async {
            var shown = false
            let watching = tab.observe { if $0 == .folder { shown = true } }
            ask()
            #expect(await waitUntil { shown && !tab.isNavigating })
            withExtendedLifetime(watching) {}
        }

        // Reveal in Tree of the folder on screen overwrites its step, and its tree row is selected; of another folder
        // it is a new step.
        @Test func revealInTreeAddsNoStepForTheFolderOnScreen() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let start = tab.folderPath
            let alpha = try #require(tab.content.entries.first { $0.name == "Alpha" }?.path)
            let model = tab.sidebarController.model
            model.selectItem(.favorite(start))
            #expect(await waitUntil { model.selected == .favorite(start) && tab.historyPaths == [start, start] })
            func reveal(_ path: String) {
                let subject = ContextMenuSubject(surface: .favorite, paths: [path], targetPath: path, entries: [])
                tab.contextMenus.contextMenu(perform: .revealInTree, subject: subject)
            }
            await navigating(tab) { reveal(start) }
            #expect(await waitUntil { model.selected == .filesystem(start) })
            #expect(tab.historyPaths == [start, start])
            reveal(alpha)
            #expect(await waitUntil { tab.folderPath == alpha && tab.historyPaths == [start, start, alpha] })
            await harness.close()
        }
    }
}
