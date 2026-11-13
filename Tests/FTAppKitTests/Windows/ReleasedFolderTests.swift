// A tab that let go of its folder has no current folder: nothing acts on the folder it left
import AppKit
import FTFileSystem
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    @MainActor
    @Suite struct ReleasedFolderTests {
        // Nothing acts on the folder let go of: a drag from elsewhere has no folder to go to, over or on the pane;
        // there is no folder to paste into, by the keys or the menu; empty space has no menu; a search needs a folder
        // to start from (`startSearch`); `goEnclosingFolder` from the keys and the menu does nothing; and a write
        // that ends with no folder on screen reads none.
        @Test func nothingActsOnTheFolderLetGoOf() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open(harness.folder.appending("Alpha").path)
            let window = try #require(tab.window)
            let info = AutomationDraggingInfo(
                urls: [harness.folder.appending("note.txt")], location: .zero, window: window)
            defer { info.draggingPasteboard.releaseGlobally() }
            let engine = FakeSearchEngine()
            let timers = ManualTimers()
            tab.search.session.engine = engine
            tab.search.session.timers = timers
            engine.finds = { _ in (["note.txt"], false, false) }
            #expect(tab.dragDrop.contentDragUpdated(info, entry: nil) != [])
            #expect(tab.pasteDestinationPath != nil)
            #expect(tab.contextMenus.contentMenu(for: nil) != nil)

            tab.sidebarController.model.clearSelection()

            #expect(tab.shownFolderPath.isEmpty)
            #expect(tab.dragDrop.contentDragUpdated(info, entry: nil) == [])
            #expect(tab.dragDrop.contentPerformDrop(info, entry: nil) == false)
            #expect(tab.pasteDestinationPath == nil)
            #expect(tab.contextMenus.contentMenu(for: nil) == nil)

            let field = try #require(tab.searchField)
            field.stringValue = "no"
            tab.search.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
            timers.advance(0.4)
            await settle()
            #expect(tab.searchRootPath == nil)

            tab.goToEnclosingFolder(nil)
            await settle()
            #expect(tab.shownFolderPath.isEmpty)
            #expect(tab.canPerform(.goEnclosingFolder) == false)

            tab.applyWriteEnd(WriteEndRefresh(path: "", selecting: nil, treeSelectionPath: nil, treeReloadPaths: []))
            await settle()
            #expect(tab.shownFolderPath.isEmpty)
            #expect(tab.content.entries.isEmpty)
            await harness.close()
        }

        // Two tabs without a folder: their labels don't clash.
        @Test func twoReleasedTabsAreBothFavorites() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let group = try #require(tab.group)
            group.openTab(path: harness.folder.appending("Alpha").path, from: tab)
            let other = try #require(group.tabs.last)
            var read = false
            other.whenFirstReadFinished { _ in read = true }
            other.ensureLoaded()
            #expect(await waitUntil { read })
            tab.sidebarController.model.clearSelection()
            other.sidebarController.model.clearSelection()
            group.refreshTitles()
            #expect(tab.window?.tab.title == "Favorites")
            #expect(other.window?.tab.title == "Favorites")
            await harness.close()
        }

        // The folder let go of is not the tab's any more, only its tree root counts.
        @Test func aDiskUnderAReleasedFolderLeavesTheTab() async throws {
            let harness = try ExplorerHarness.windowless()
            harness.startsTheTreeAtTheDisk()
            let tab = try await harness.open()
            let group = try #require(tab.group)
            group.openTab(path: harness.folder.appending("Alpha").path, from: tab)
            let other = try #require(group.tabs.last)
            let released = tab.folder.path
            tab.sidebarController.model.rootTree(at: "/")
            other.sidebarController.model.rootTree(at: "/")
            tab.sidebarController.model.clearSelection()
            let count = group.tabs.count
            group.disksUnmounted(
                ["/Volumes/Gone"], homePath: "/", volumeRoot: { $0 == released ? "/Volumes/Gone" : "/" })
            #expect(group.tabs.count == count)
            await harness.close()
        }

        // The toolbar's button: `parentDirectoryPath("")` is the top of the disk.
        @Test func theToolbarsEnclosingFolderOpensTheTopOfTheDisk() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            tab.updatePreferences { $0.topToolbarItems = [.up] }
            harness.layout(tab)
            tab.sidebarController.model.clearSelection()
            tab.explorerToolbar.refreshStates()
            let up = try #require(tab.explorerToolbar.button(.up))
            #expect(up.isEnabled)
            _ = up.accessibilityPerformPress()
            #expect(await waitUntil { tab.shownFolderPath == "/" })
            await harness.close()
        }
    }
}
