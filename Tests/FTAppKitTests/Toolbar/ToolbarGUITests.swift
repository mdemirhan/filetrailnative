// Ports the UI cases of apps/desktop/src/renderer/components/ExplorerWorkspace.test.tsx and HistoryButton.test.tsx
// on a real explorer window on screen: the toolbar menus opened, keyed and closed through the window
import AppKit
import FTFileSystem
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowGUITests {
    @MainActor
    @Suite struct ToolbarGUITests: ToolbarTesting {
        // T-97a63c67 T-2e1aa716 T-27aa0227 T-e7cc3251 F-712 F-715 B-VIEW-125 B-VIEW-127
        @Test func listsTheViewOptionsAndSortsFromTheSortMenu() async throws {
            let harness = try ExplorerHarness()
            let tab = try await harness.open()
            _ = button(tab, .viewOptions)?.accessibilityPerformPress()
            #expect(
                titles(menu) == [
                    "Folders First", "Hidden Files", "-", "Info Panel", "Info Row", "-", "Customize Toolbar…",
                ])
            #expect(menu?.items.first?.shortcut == ShortcutDisplay.defaults.label(.toggleFoldersFirst))
            // Escape closes it.
            key(53, "\u{1b}", in: tab.window)
            #expect(menu == nil)
            _ = button(tab, .viewOptions)?.accessibilityPerformPress()
            choose("Info Row")
            #expect(await waitUntil { tab.panels.detailRowOpen })

            let sort = try #require(button(tab, .sort))
            #expect(sort.tooltip == "Sort By: Name, Ascending")
            _ = sort.accessibilityPerformPress()
            #expect(titles(menu) == ["Name", "Kind", "Date Modified", "Size", "-", "Ascending", "Descending"])
            #expect(menu?.minWidth == 200)
            choose("Size")
            // A new Size order starts descending (B-NAV-127).
            #expect(tab.viewState.sortBy == .size && tab.viewState.sortDirection == .desc)
            _ = sort.accessibilityPerformPress()
            choose("Ascending")
            #expect(tab.viewState.sortDirection == .asc)
            #expect(sort.tooltip == "Sort By: Size, Ascending")
            // Pressing the button again closes its menu.
            _ = sort.accessibilityPerformPress()
            _ = sort.accessibilityPerformPress()
            #expect(menu == nil)
            await harness.close()
        }

        // T-b9cc1ec4 T-01a9e06b T-943ef637 T-84e77094 T-2cb340ef F-698 B-NAV-025 B-NAV-027 B-NAV-028 B-NAV-029 B-NAV-031
        // B-NAV-032 B-NAV-034 B-NAV-036 B-NAV-037
        @Test func stepsOnAClickAndListsTheFoldersWhenHeld() async throws {
            let harness = try ExplorerHarness()
            let root = harness.folder.url
            let tab = try await harness.open(root.path)
            let back = try #require(button(tab, .back))
            // No history: no menu.
            back.onRightClick?()
            #expect(menu == nil)
            for name in ["Alpha", "Alpha/Inner"] {
                await tab.navigate(to: root.appendingPathComponent(name))
            }
            // A click steps once.
            back.onPress?()
            back.onRelease?(true)
            back.onClick?()
            #expect(await waitUntil { tab.currentFolder.lastPathComponent == "Alpha" })
            await tab.navigate(to: root.appendingPathComponent("Alpha/Inner"))
            harness.layout(tab)

            // Held 350 ms: the folders behind, nearest first; the click that ends the hold does not step.
            back.onPress?()
            #expect(await waitUntil { menu != nil })
            back.onRelease?(true)
            back.onClick?()
            #expect(tab.currentFolder.lastPathComponent == "Inner")
            #expect(titles(menu).count == 2)
            #expect(menu?.items.first?.title == "Alpha")
            #expect(menu?.activeIndex == 0)
            // ↓ moves the mark, Return chooses: a jump, adding nothing to the history.
            key(125, "", in: tab.window)
            #expect(menu?.activeIndex == 1)
            key(36, "\r", in: tab.window)
            #expect(await waitUntil { tab.historyIndex == 0 })
            #expect(tab.currentFolder.lastPathComponent == root.lastPathComponent)
            #expect(tab.historyPaths.count == 3)

            // Released before 350 ms: no menu.
            let forward = try #require(button(tab, .forward))
            forward.onPress?()
            forward.onRelease?(true)
            try await Task.sleep(for: .milliseconds(450))
            #expect(menu == nil)
            // A right-click opens it at once; Escape closes it.
            forward.onRightClick?()
            #expect(menu != nil)
            key(53, "\u{1b}", in: tab.window)
            #expect(menu == nil)
            await harness.close()
        }
    }
}
