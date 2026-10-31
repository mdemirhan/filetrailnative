// Port by feature of "after an Undo" of App.undo.test.tsx (hooks/useExplorerActions.ts pushTerminalCopyPasteToast), of
// refreshDirectory's tree selection (useExplorerNavigationController.ts) and of "marks the folder that is on the
// clipboard" of TreePane.test.tsx: what a write's end does in a real tab, through the commands and menus a person uses
import AppKit
import FTFoundation
import FTOperations
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    @MainActor
    @Suite(.windowlessAlone) struct WriteEndInWindowTests: SidebarTesting {
        private func toasts(_ tab: MainWindowController, _ title: String) -> [String?] {
            tab.notifications?.toasts.entries.filter { $0.title == title }.map(\.message) ?? []
        }

        private func treeMenu(_ tab: MainWindowController, _ action: ContextMenuActionID, on path: String) {
            tab.contextMenus.contextMenu(
                perform: action, subject: ContextMenuSubject(surface: .treeFolder, paths: [path], targetPath: path))
        }

        /// The item on screen trashed from the keyboard, and the write over.
        private func trash(_ name: String, _ window: WritingWindow) async {
            window.select([name])
            window.tab.perform(.trashSelection)
            #expect(await waitUntil { !window.exists(name) && !window.tab.isWriteLocked })
        }

        // T-eeefccac B-CLIP-130 B-VIEW-202: ⌘Z and ⇧⌘Z whose changes are out of sight say so, with what they did.
        @Test func anUndoOutOfSightIsToldWithItsLabel() async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            await trash("note.txt", window)
            tab.go(to: window.folder.appendingPathComponent("Alpha"))
            #expect(await waitUntil { tab.folder.lastPathComponent == "Alpha" && !tab.isNavigating })

            tab.perform(.undo)
            #expect(await waitUntil { window.exists("note.txt") && !toasts(tab, "Undone").isEmpty })
            #expect(toasts(tab, "Undone").first??.contains("note.txt") == true)

            #expect(await waitUntil { !tab.isWriteLocked })
            tab.perform(.redo)
            #expect(await waitUntil { !window.exists("note.txt") && !toasts(tab, "Redone").isEmpty })
            #expect(toasts(tab, "Redone").first??.contains("note.txt") == true)
            #expect(window.recorder.shown.isEmpty)
            await window.close()
        }

        // T-eeefccac T-f0c2b565 B-CLIP-130 B-CLIP-193: an Undo that changes the folder on screen is in sight there: what
        // came back is selected, and nothing is said.
        @Test func anUndoInTheFolderOnScreenSaysNothing() async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            await trash("note.txt", window)

            tab.perform(.undo)
            #expect(await waitUntil { window.exists("note.txt") && !tab.isWriteLocked })
            #expect(await waitUntil { tab.content.entries.contains { $0.name == "note.txt" } })
            #expect(await waitUntil { tab.content.selection.leadPath?.hasSuffix("/note.txt") == true })
            #expect(toasts(tab, "Undone").isEmpty)
            await window.close()
        }

        // B-TREE-094: New Folder from a row's menu selects the new folder's row; the folder on screen and the history
        // stay as they are.
        @Test func aFolderMadeFromTheTreeIsSelectedWithoutOpeningIt() async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            let alpha = window.folder.appendingPathComponent("Alpha").path
            let shown = tab.folder.path
            let steps = tab.navigationHistory.paths
            window.operations.dialogs.askName = { _, _, submit in _ = await submit("Made") }

            treeMenu(tab, .newFolder, on: alpha)
            #expect(await waitUntil { sidebar(tab).selectedTreeTargetPath == alpha + "/Made" })
            #expect(window.exists("Alpha/Made"))
            #expect(sidebar(tab).selectedTreeTargetKind == .filesystemFolder)
            #expect(sidebar(tab).model.subview == .tree)
            await settle()
            #expect(sidebar(tab).selectedTreeTargetPath == alpha + "/Made")
            #expect(tab.folder.path == shown)
            #expect(tab.navigationHistory.paths == steps)
            #expect(window.recorder.shown.isEmpty)
            await window.close()
        }

        // B-TREE-094: Duplicate from a row's menu copies that folder, next to it, whatever the list has selected, and
        // the copy's row is selected, unopened.
        @Test func aFolderDuplicatedFromTheTreeIsSelectedWithoutOpeningIt() async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            let alpha = window.folder.appendingPathComponent("Alpha").path
            let shown = tab.folder.path
            let steps = tab.navigationHistory.paths
            window.select(["note.txt"])

            treeMenu(tab, .duplicate, on: alpha)
            #expect(await waitUntil { sidebar(tab).selectedTreeTargetPath == alpha + " copy" })
            #expect(window.exists("Alpha copy/Inner"))
            #expect(!window.exists("note copy.txt"))
            await settle()
            #expect(sidebar(tab).selectedTreeTargetPath == alpha + " copy")
            #expect(tab.folder.path == shown)
            #expect(tab.navigationHistory.paths == steps)
            await window.close()
        }

        // B-TREE-094: the folder on screen, trashed from its row, gives way to its parent, whose row is selected; a
        // write's end adds no step to the history.
        @Test func aFolderTrashedFromTheTreeLeavesItsParentSelected() async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            let alpha = window.folder.appendingPathComponent("Alpha")
            tab.go(to: alpha)
            #expect(await waitUntil { tab.folder.lastPathComponent == "Alpha" && !tab.isNavigating })
            #expect(await waitUntil { sidebar(tab).selectedTreeTargetPath == alpha.path })
            let steps = tab.navigationHistory.paths.count
            window.operations.dialogs.confirm = { _, _ in true }

            treeMenu(tab, .trash, on: alpha.path)
            #expect(await waitUntil { !window.exists("Alpha") })
            #expect(await waitUntil { tab.folder.path == window.folder.path && !tab.isNavigating })
            #expect(await waitUntil { sidebar(tab).selectedTreeTargetPath == window.folder.path })
            #expect(tab.navigationHistory.paths.count == steps)
            await window.close()
        }

        // B-TREE-094: the next write that asks for no row brings the tree back to the folder on screen.
        @Test func theNextWriteBringsTheTreeBackToTheFolderOnScreen() async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            let alpha = window.folder.appendingPathComponent("Alpha").path
            let shown = tab.folder.path
            window.operations.dialogs.askName = { _, _, submit in _ = await submit("Made") }

            treeMenu(tab, .newFolder, on: alpha)
            #expect(await waitUntil { sidebar(tab).selectedTreeTargetPath == alpha + "/Made" })
            await trash("note.txt", window)
            #expect(await waitUntil { sidebar(tab).selectedTreeTargetPath == shown })
            await settle()
            #expect(sidebar(tab).selectedTreeTargetPath == shown)
            #expect(tab.folder.path == shown)
            await window.close()
        }

        // B-TREE-094: a write that moves the folder on screen overwrites its step of the history (`navigateTo` "replace").
        // Back then Forward land on the folder shown, and the trashed one is not offered.
        @Test func aFolderTrashedOnScreenReplacesItsHistoryStep() async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            let alpha = window.folder.appendingPathComponent("Alpha")
            tab.go(to: alpha)
            #expect(await waitUntil { tab.folder.lastPathComponent == "Alpha" && !tab.isNavigating })
            window.operations.dialogs.confirm = { _, _ in true }

            treeMenu(tab, .trash, on: alpha.path)
            #expect(await waitUntil { tab.folder.path == window.folder.path && !tab.isNavigating })
            await settle()
            #expect(tab.navigationHistory.paths[tab.navigationHistory.index] == window.folder.path)
            #expect(!tab.navigationHistory.paths.contains(alpha.path))

            await tab.navigate(to: window.folder, history: .back)
            await tab.navigate(to: window.folder, history: .forward)
            #expect(tab.folder.path == window.folder.path)
            await window.close()
        }

        // T-97a1b5a0 B-TREE-016: a favorite and a location point at a folder; only the folder's own row in the tree
        // takes the mark, the dimmed name and with them the flash, which asks the row's mark.
        @Test func onlyTheFoldersOwnRowIsMarked() async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            await rooted(tab, window.harness)
            await setPlacement(tab, "integrated", window.harness)
            let controller = sidebar(tab)
            let alpha = window.folder.appendingPathComponent("Alpha").path
            controller.toggleFavorite(alpha)
            #expect(
                await waitUntil {
                    self.cells(controller).contains { $0.state?.item.path == alpha && $0.state?.item.kind == .favorite }
                        && self.cells(controller).contains {
                            $0.state?.item.path == alpha && $0.state?.item.kind == .filesystem
                        }
                })
            let location = try #require(
                cells(controller).first { $0.state?.item.kind == .location }?.state?.item.path)

            tab.services.clipboard.set(ClipboardRules.set(.cut, [alpha, location], capturedAt: "t"), from: nil)
            tab.clipboardChanged()
            window.harness.layout(tab)
            func row(_ path: String, _ kind: TreeItemKind) -> SidebarItemCell? {
                cells(controller).first { $0.state?.item.path == path && $0.state?.item.kind == kind }
            }
            #expect(await waitUntil { row(alpha, .filesystem)?.state?.clipboardMark == .cut })
            #expect(row(alpha, .favorite)?.state?.clipboardMark == nil)
            #expect(row(location, .location)?.state?.clipboardMark == nil)
            await window.close()
        }
    }
}
