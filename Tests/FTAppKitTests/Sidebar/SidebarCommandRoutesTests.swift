// Covers the commands that choose between the tree and the list (useExplorerShortcuts.ts:1415-1425, :760-766,
// lib/shortcutTargets.ts:72-88), Remove from Favorites from a favorite's own row (useExplorerActions.ts:2795-2813,
// :2941-2950) and Copy Path in the tree (App.menusAndTree.test.tsx) on a tab whose window is never shown
import AppKit
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    @MainActor
    @Suite struct SidebarCommandRoutesTests: SidebarTesting {
        private func open() async throws -> (ExplorerHarness, MainWindowController, SidebarViewController) {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open(listed(harness, ""))
            await rooted(tab, harness)
            let controller = sidebar(tab)
            #expect(await waitUntil { self.labels(controller).contains("Beta") })
            return (harness, tab, controller)
        }

        /// The tree holds the keyboard, on a row that isn't the folder on screen.
        private func focusTree(on path: String, _ tab: MainWindowController) {
            tab.perform(.focusTreePane)
            tab.sidebarController.model.restoreSelected(.filesystem(path))
            #expect(tab.focusedPane == .tree)
        }

        // MARK: Enclosing Folder

        // B-NAV-062: the tree's parent with the tree focused, the list's otherwise. The row and the folder on screen differ
        // here, so each route goes somewhere the other doesn't.
        @Test func enclosingFolderFollowsTheFocusedPane() async throws {
            let (harness, tab, controller) = try await open()
            let root = listed(harness, "")
            let alpha = listed(harness, "Alpha")
            let inner = listed(harness, "Alpha/Inner")
            let beta = listed(harness, "Beta")

            // The tree has heard of the folder (in a task of its own) before the row is put elsewhere.
            func onInner() async {
                await tab.navigate(to: URL(fileURLWithPath: inner))
                #expect(await waitUntil { controller.model.selected == .filesystem(inner) })
            }

            await onInner()
            focusTree(on: beta, tab)
            tab.perform(.goEnclosingFolder)
            #expect(await waitUntil { tab.shownFolderPath == root })
            #expect(await waitUntil { controller.model.selected == .filesystem(root) })

            await onInner()
            controller.model.restoreSelected(.filesystem(beta))
            tab.content.focusList()
            #expect(tab.focusedPane == .content)
            tab.perform(.goEnclosingFolder)
            #expect(await waitUntil { tab.shownFolderPath == alpha })
            await harness.close()
        }

        // MARK: Home

        // B-NAV-099
        @Test func homeRootsTheTreeThereAddingAStepOnlyFromElsewhere() async throws {
            let (harness, tab, controller) = try await open()
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let steps = tab.navigationHistory.paths.count

            tab.perform(.goHomeRootTree)
            #expect(await waitUntil { tab.shownFolderPath == home && controller.model.rootPath == home })
            #expect(await waitUntil { controller.model.currentPath == home })
            #expect(tab.navigationHistory.paths.count == steps + 1)

            tab.perform(.goHomeRootTree)
            await settle()
            try await Task.sleep(for: .milliseconds(100))
            #expect(tab.shownFolderPath == home)
            #expect(controller.model.rootPath == home)
            #expect(tab.navigationHistory.paths.count == steps + 1)
            await harness.close()
        }

        // MARK: Use as Tree Root

        // B-TREE-077: the row the menu is open on, else the tree's row with the tree focused, else the list's one folder,
        // else the folder on screen.
        @Test func useAsTreeRootActsOnWhatHasTheFocus() async throws {
            let (harness, tab, controller) = try await open()
            let model = controller.model
            let root = listed(harness, "")
            let alpha = listed(harness, "Alpha")
            let beta = listed(harness, "Beta")
            let gamma = listed(harness, "Gamma")
            let note = listed(harness, "note.txt")

            /// Back on the folder, with the tree rooted over it again.
            func backOnTheFolder() async {
                model.rootTree(at: root)
                #expect(await waitUntil { model.rootPath == root && tab.shownFolderPath == root })
                #expect(await waitUntil { model.currentPath == root && model.nodes[beta] != nil })
            }

            // The list's one folder.
            tab.content.select(paths: [alpha])
            tab.content.focusList()
            tab.perform(.rootTreeAtSelection)
            #expect(await waitUntil { model.rootPath == alpha })
            await backOnTheFolder()

            // The list's selection isn't one folder: the folder on screen. The tree is somewhere else first.
            model.rootTree(at: gamma)
            #expect(await waitUntil { model.rootPath == gamma && tab.shownFolderPath == gamma })
            tab.go(to: URL(fileURLWithPath: root))
            #expect(await waitUntil { tab.shownFolderPath == root && model.currentPath == root })
            tab.content.select(paths: [note])
            tab.content.focusList()
            tab.perform(.rootTreeAtSelection)
            #expect(await waitUntil { model.rootPath == root })
            #expect(await waitUntil { model.nodes[beta] != nil })

            // With the tree focused its row wins over the list's folder.
            tab.content.select(paths: [alpha])
            tab.content.focusList()
            focusTree(on: beta, tab)
            tab.perform(.rootTreeAtSelection)
            #expect(await waitUntil { model.rootPath == beta })
            await backOnTheFolder()

            // The row the menu is open on wins over all.
            tab.content.select(paths: [alpha])
            tab.content.focusList()
            model.menuTarget = SidebarMenuTarget(path: gamma, subview: .tree, kind: .treeFolder)
            tab.perform(.rootTreeAtSelection)
            #expect(await waitUntil { model.rootPath == gamma })
            model.menuTarget = nil
            await harness.close()
        }

        // MARK: Remove from Favorites

        private func rightClick(
            _ cell: SidebarItemCell, _ tab: MainWindowController
        ) throws -> NSMenu {
            let outline = try #require(enclosingOutline(cell))
            let window = try #require(tab.window)
            let point = cell.convert(NSPoint(x: cell.bounds.midX, y: cell.bounds.midY), to: nil)
            let event = try #require(MouseEvents.event(.rightMouseDown, at: point, in: window))
            return try #require(outline.menu(for: event))
        }

        private func choose(_ title: String, in menu: NSMenu) throws {
            let item = try #require(menu.items.first { $0.title == title }, "\(title)")
            _ = NSApp.sendAction(try #require(item.action), to: item.target, from: item)
        }

        private func withFavorite(
            _ name: String
        ) async throws -> (ExplorerHarness, MainWindowController, SidebarViewController, String) {
            let (harness, tab, controller) = try await open()
            await setPlacement(tab, "separate", harness)
            let path = listed(harness, name)
            controller.toggleFavorite(path)
            harness.layout(tab)
            return (harness, tab, controller, path)
        }

        // B-TREE-039: the folder on screen is shown as a row of the tree, its history step replaced.
        @Test func removingTheFavoriteOnScreenFromItsRowSelectsItInTheTreeAndReplacesTheStep() async throws {
            let (harness, tab, controller, gamma) = try await withFavorite("Gamma")
            controller.model.selectItem(.favorite(gamma))
            #expect(await waitUntil { tab.shownFolderPath == gamma })
            let history = tab.navigationHistory.paths
            harness.layout(tab)

            try choose("Remove from Favorites", in: try rightClick(try row(gamma, .favorite, in: controller), tab))
            #expect(!controller.isFavorite(gamma))
            #expect(controller.model.selected == .filesystem(gamma))
            #expect(controller.model.subview == .tree)
            await settle()
            #expect(tab.shownFolderPath == gamma)
            #expect(tab.navigationHistory.paths == history)
            await harness.close()
        }

        // B-TREE-039: another folder is gone to, one step more.
        @Test func removingAnotherFavoriteFromItsRowOpensItFromTheTree() async throws {
            let (harness, tab, controller, gamma) = try await withFavorite("Gamma")
            let history = tab.navigationHistory.paths

            try choose("Remove from Favorites", in: try rightClick(try row(gamma, .favorite, in: controller), tab))
            #expect(!controller.isFavorite(gamma))
            #expect(controller.model.selected == .filesystem(gamma))
            #expect(await waitUntil { tab.shownFolderPath == gamma })
            #expect(tab.navigationHistory.paths == history + [gamma])
            await harness.close()
        }

        // B-TREE-039: chosen from the tree it only removes.
        @Test func removingAFavoriteFromATreeRowOnlyRemovesIt() async throws {
            let (harness, tab, controller, gamma) = try await withFavorite("Gamma")
            let (selected, shown, history) = (
                controller.model.selected, tab.shownFolderPath, tab.navigationHistory.paths
            )

            let menu = try rightClick(try row(gamma, .filesystem, in: controller), tab)
            controller.model.menuTarget = nil
            try choose("Remove from Favorites", in: menu)
            #expect(!controller.isFavorite(gamma))
            await settle()
            #expect(controller.model.selected == selected)
            #expect(tab.shownFolderPath == shown)
            #expect(tab.navigationHistory.paths == history)
            await harness.close()
        }

        // MARK: Copy Path

        private func copied(_ harness: ExplorerHarness) -> String? {
            harness.pasteboard.string(forType: .string)
        }

        // T-a3480ced: the menu's command, with a selection left behind in the list.
        @Test func copyPathInTheTreeCopiesTheTreesFolderNotTheListsSelection() async throws {
            let (harness, tab, _) = try await open()
            let alpha = listed(harness, "Alpha")
            tab.content.select(paths: [listed(harness, "note.txt")])
            focusTree(on: alpha, tab)
            #expect(tab.canPerform(.copyPath))
            tab.perform(.copyPath)
            #expect(copied(harness) == alpha)

            // In the list it's the list's own.
            tab.content.focusList()
            tab.perform(.copyPath)
            #expect(copied(harness) == listed(harness, "note.txt"))
            await harness.close()
        }

        // T-081ac5a0: ⌘⌥C reaching the window from the focused tree.
        @Test func commandOptionCInTheTreeCopiesTheTreesFolder() async throws {
            let (harness, tab, _) = try await open()
            let alpha = listed(harness, "Alpha")
            tab.content.select(paths: [listed(harness, "note.txt")])
            focusTree(on: alpha, tab)
            let responder = try #require(tab.window?.firstResponder)
            responder.keyDown(with: try systemKeyEvent(8, [.maskCommand, .maskAlternate]))
            #expect(copied(harness) == alpha)
            await harness.close()
        }
    }
}
