// A tab that let go of its folder has an empty currentPath in the original (useExplorerTabs.ts, useExplorerActions.ts,
// useExplorerDragAndDrop.ts, useExplorerSearchController.ts, useExplorerShortcuts.ts): nothing acts on the folder it left
import AppKit
import FTFileSystem
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    @MainActor
    @Suite struct ReleasedFolderTests {
        // B-TREE-060, `backgroundTakesDrop`: a drag from elsewhere has no folder to go to, over or on the pane.
        @Test func aFileDragFromElsewhereIsNotTaken() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open(harness.folder.appending("Alpha").path)
            let window = try #require(tab.window)
            let info = AutomationDraggingInfo(
                urls: [harness.folder.appending("note.txt")], location: .zero, window: window)
            defer { info.draggingPasteboard.releaseGlobally() }
            #expect(tab.dragDrop.contentDragUpdated(info, entry: nil) != [])
            tab.sidebarController.model.clearSelection()
            #expect(tab.dragDrop.contentDragUpdated(info, entry: nil) == [])
            #expect(tab.dragDrop.contentPerformDrop(info, entry: nil) == false)
            await harness.close()
        }

        // `resolvePasteDestinationPath`: no folder to paste into, by the keys or the menu.
        @Test func pasteHasNoDestination() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            #expect(tab.pasteDestinationPath != nil)
            tab.sidebarController.model.clearSelection()
            #expect(tab.shownFolderPath.isEmpty)
            #expect(tab.pasteDestinationPath == nil)
            await harness.close()
        }

        // `disambiguateTabLabels` with the empty currentPath of both: no clash.
        @Test func twoReleasedTabsAreBothFavorites() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let group = try #require(tab.group)
            group.openTab(path: harness.folder.appending("Alpha").path, from: tab)
            let other = try #require(group.tabs.last)
            other.ensureLoaded()
            try await Task.sleep(for: .milliseconds(200))
            tab.sidebarController.model.clearSelection()
            other.sidebarController.model.clearSelection()
            group.refreshTitles()
            #expect(tab.window?.tab.title == "Favorites")
            #expect(other.window?.tab.title == "Favorites")
            await harness.close()
        }

        // `startSearch`: a search needs a folder to start from.
        @Test func searchDoesNotStart() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let engine = FakeSearchEngine()
            let timers = ManualTimers()
            tab.search.session.engine = engine
            tab.search.session.timers = timers
            engine.finds = { _ in (["note.txt"], false, false) }
            tab.sidebarController.model.clearSelection()
            let field = try #require(tab.searchField)
            field.stringValue = "no"
            tab.search.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
            timers.advance(0.4)
            try await Task.sleep(for: .milliseconds(150))
            #expect(tab.searchRootPath == nil)
            await harness.close()
        }

        // `openContextMenu`: empty space has no menu without a folder.
        // B-VIEW-205
        @Test func emptySpaceHasNoMenu() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            #expect(tab.contextMenus.contentMenu(for: nil) != nil)
            tab.sidebarController.model.clearSelection()
            #expect(tab.contextMenus.contentMenu(for: nil) == nil)
            await harness.close()
        }

        // `closeTabsOnUnmountedDisks`: the folder let go of is not the tab's any more, only its tree root counts.
        @Test func aDiskUnderAReleasedFolderLeavesTheTab() async throws {
            let harness = try ExplorerHarness.windowless()
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

        // `goEnclosingFolder` from the keys and the menu: nothing without a folder.
        @Test func goEnclosingFromContentDoesNothing() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            tab.sidebarController.model.clearSelection()
            tab.goToEnclosingFolder(nil)
            try await Task.sleep(for: .milliseconds(200))
            #expect(tab.shownFolderPath.isEmpty)
            let item = NSMenuItem(
                title: "", action: #selector(MainWindowController.goToEnclosingFolder(_:)), keyEquivalent: "")
            #expect(tab.validateMenuItem(item) == false)
            #expect(tab.canPerform(.goEnclosingFolder) == false)
            await harness.close()
        }

        // `navigateToParentFolder`, the toolbar's button: `parentDirectoryPath("")` is the top of the disk.
        @Test func theToolbarsEnclosingFolderOpensTheTopOfTheDisk() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            tab.updatePreferences(["topToolbarItems": .array([.string(ToolbarItemID.up.rawValue)])])
            harness.layout(tab)
            tab.sidebarController.model.clearSelection()
            tab.explorerToolbar.refreshStates()
            let up = try #require(tab.explorerToolbar.button(.up))
            #expect(up.isEnabled)
            _ = up.accessibilityPerformPress()
            #expect(await waitUntil { tab.shownFolderPath == "/" })
            await harness.close()
        }

        // `refreshDirectory`: a write that ends with no folder on screen reads none.
        @Test func aWriteEndingReadsNoFolder() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            tab.sidebarController.model.clearSelection()
            tab.applyWriteEnd(WriteEndRefresh(path: "", selecting: nil, treeSelectionPath: nil, treeReloadPaths: []))
            try await Task.sleep(for: .milliseconds(200))
            #expect(tab.shownFolderPath.isEmpty)
            #expect(tab.content.entries.isEmpty)
            await harness.close()
        }
    }
}
