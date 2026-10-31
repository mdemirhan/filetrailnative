// Ports by feature App.tsx's Info panel callbacks (:2614-2640) and revealFavoriteInTree (useExplorerActions.ts:2795): the
// Quick Look button previews the item the panel describes, and the Where link and Reveal in Tree add no second step for
// the folder on screen, on a window that is never shown
import AppKit
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    @MainActor
    @Suite struct InfoPanelItemTests {
        private func quickActionButton(in tab: MainWindowController) throws -> InfoIconButton {
            let content = try #require(tab.window?.contentView)
            return try #require(findViews("infoPanel.action", in: content).first as? InfoIconButton)
        }

        /// The navigation just asked for has started and finished.
        private func settle(_ tab: MainWindowController) async throws {
            try await Task.sleep(for: .milliseconds(150))
            #expect(await waitUntil { !tab.isNavigating })
        }

        // B-INFO-001: with nothing selected the panel describes the folder on screen, and its button previews that.
        // B-INFO-058
        @Test func quickLookPreviewsTheFolderWithNothingSelected() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            tab.perform(.toggleInfoPanel)
            harness.layout(tab)
            var shown: [String] = []
            tab.showQuickLook = { shown.append($0) }
            let info = try #require(tab.infoController)
            #expect(await waitUntil { info.resolvedItemPath == tab.folder.path })
            info.panel.onAction(.quickLook)
            #expect(shown == [tab.folder.path])
            await harness.close()
        }

        // F-805 B-INFO-009: Show Info's target is previewed, not the selection under it.
        // B-INFO-058
        @Test func quickLookPreviewsShowInfosTarget() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            tab.perform(.toggleInfoPanel)
            harness.layout(tab)
            var shown: [String] = []
            tab.showQuickLook = { shown.append($0) }
            let note = try #require(tab.content.entries.first { $0.name == "note.txt" })
            let alpha = try #require(tab.content.entries.first { $0.name == "Alpha" })
            tab.content.select(paths: [note.path])
            let info = try #require(tab.infoController)
            #expect(await waitUntil { info.resolvedItemPath == note.path })
            info.showInfo(for: alpha.path)
            #expect(await waitUntil { info.resolvedItemPath == alpha.path })
            info.panel.onAction(.quickLook)
            #expect(shown == [alpha.path])
            await harness.close()
        }

        // App.tsx:2614: Where pointing at the folder on screen overwrites its step; any other folder is a new step.
        // B-NAV-077
        @Test func whereAddsNoStepForTheFolderOnScreen() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            tab.perform(.viewAsDetails)
            tab.perform(.toggleInfoPanel)
            harness.layout(tab)
            let start = tab.folder.path
            let alpha = try #require(tab.content.entries.first { $0.name == "Alpha" }?.path)
            tab.go(to: URL(fileURLWithPath: alpha))
            #expect(await waitUntil { tab.folder.path == alpha && tab.historyPaths == [start, alpha] })
            let panel = try #require(tab.infoController?.panel)
            panel.onNavigate(alpha)
            try await settle(tab)
            #expect(tab.historyPaths == [start, alpha])
            #expect(tab.historyIndex == 1)
            panel.onNavigate(start)
            #expect(await waitUntil { tab.folder.path == start && tab.historyPaths == [start, alpha, start] })
            await harness.close()
        }

        // useExplorerActions.ts:2795: Reveal in Tree of the folder on screen overwrites its step, and its tree row is
        // selected; of another folder it is a new step.
        // B-TREE-040
        @Test func revealInTreeAddsNoStepForTheFolderOnScreen() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let start = tab.folder.path
            let alpha = try #require(tab.content.entries.first { $0.name == "Alpha" }?.path)
            let model = tab.sidebarController.model
            model.selectItem(.favorite(start))
            #expect(await waitUntil { model.selected == .favorite(start) && tab.historyPaths == [start, start] })
            func reveal(_ path: String) {
                let subject = ContextMenuSubject(surface: .favorite, paths: [path], targetPath: path, entries: [])
                tab.contextMenus.contextMenu(perform: .revealInTree, subject: subject)
            }
            reveal(start)
            #expect(await waitUntil { model.selected == .filesystem(start) })
            try await settle(tab)
            #expect(tab.historyPaths == [start, start])
            reveal(alpha)
            #expect(await waitUntil { tab.folder.path == alpha && tab.historyPaths == [start, start, alpha] })
            await harness.close()
        }
    }
}
