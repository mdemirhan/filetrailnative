// Port by feature of "keeps showing the folder's info in the Info panel after the folder reloads" of App.commands.test.tsx
// and "shows the Info of a sidebar folder" of App.menusAndTree.test.tsx (App.tsx:2238-2244, :2619-2621): the Info panel
// through a reload and from a row of the tree, on a window that is never shown
import AppKit
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    @MainActor
    @Suite struct InfoPanelWritesMatrixTests {
        // T-321434ce B-INFO-017: the folder read again keeps what the panel shows on screen, and asks for the properties
        // again: the new size comes without the selection changing.
        @Test func aReloadKeepsTheInfoOnScreenAndAsksAgain() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            tab.perform(.viewAsDetails)
            tab.perform(.toggleInfoPanel)
            harness.layout(tab)
            let info = try #require(tab.infoController)
            let note = try #require(tab.content.entries.first { $0.name == "note.txt" })
            tab.content.select(paths: [note.path])
            func name() -> String? { (findViews("infoPanel.name", in: info.panel).first as? NSTextField)?.stringValue }
            #expect(await waitUntil { info.resolvedItemPath == note.path && name() == "note.txt" })
            #expect(await waitUntil { info.resolved?.item.sizeBytes != nil })

            let bigger = String(repeating: "x", count: 4321)
            try bigger.write(toFile: note.path, atomically: true, encoding: .utf8)
            tab.reload(changedPaths: [note.path])
            #expect(name() == "note.txt")
            var blanked = false
            let updated = await waitUntil {
                if name() != "note.txt" { blanked = true }
                return info.resolved?.item.sizeBytes == 4321
            }
            #expect(updated)
            #expect(!blanked)
            await harness.close()
        }

        // T-9cb4c249 B-TREE-049: Show Info on a row of the tree is about that folder, not the list's selection; the panel
        // adds it to the Favorites and takes it away, and roots the tree there.
        @Test func showInfoOfARowIsAboutThatFolderAndActsOnIt() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            tab.perform(.viewAsDetails)
            harness.layout(tab)
            let info = try #require(tab.infoController)
            let note = try #require(tab.content.entries.first { $0.name == "note.txt" })
            let alpha = try #require(tab.content.entries.first { $0.name == "Alpha" }?.path)
            tab.content.select(paths: [note.path])
            tab.contextMenus.contextMenu(
                perform: .showInfo, subject: ContextMenuSubject(surface: .treeFolder, paths: [alpha], targetPath: alpha)
            )
            #expect(await waitUntil { info.resolvedItemPath == alpha })
            #expect(tab.panels.propertiesOpen)
            #expect(tab.content.selection.leadPath == note.path)

            let sidebar = tab.sidebarController
            let wasFavorite = sidebar.isFavorite(alpha)
            info.panel.onAction(.favorite)
            #expect(sidebar.isFavorite(alpha) != wasFavorite)
            info.panel.onAction(.favorite)
            #expect(sidebar.isFavorite(alpha) == wasFavorite)
            info.panel.onAction(.rootTree)
            #expect(await waitUntil { sidebar.model.rootPath == alpha })
            await harness.close()
        }
    }
}
