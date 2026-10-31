// Covers Tab with the folder tree hidden (B-SEL-105, useExplorerShortcuts.ts paneTabSwitch and focusTreePane) and the
// held-key repeat of shortcuts that start a write (B-SEL-114), windowless
import AppKit
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    @MainActor
    @Suite struct SelectionFixesTests {
        // B-SEL-105: with the tree hidden Tab from the list stays in the list.
        // B-NAV-102
        @Test func tabFromTheListStaysInTheListWhileTheTreeIsHidden() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, list) = try await harness.openList()
            tab.perform(.toggleFolderTree)
            #expect(!tab.panels.folderTreeOpen)
            tab.content.focusList()
            #expect(list.hasKeyboard)
            tab.content.onSwitchPane?()
            #expect(list.hasKeyboard)
            #expect(!tab.sidebarController.isInside(list.window.firstResponder))
            #expect(!tab.panels.folderTreeOpen)
            await harness.close()
        }

        // B-SEL-105: with the tree shown, Tab hands the keyboard to it.
        // B-NAV-102
        @Test func tabFromTheListGoesToTheTreeWhileItIsShown() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, list) = try await harness.openList()
            #expect(tab.panels.folderTreeOpen)
            tab.content.focusList()
            tab.content.onSwitchPane?()
            #expect(tab.sidebarController.isInside(list.window.firstResponder))
            await harness.close()
        }

        // B-SEL-114: a held key repeats no shortcut that starts a write, and still repeats the others.
        @Test func aHeldKeyDoesNotRepeatAWriteStartingShortcut() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, list) = try await harness.openList()
            var run: [String] = []
            tab.content.onCommand = {
                run.append($0.rawValue)
                return true
            }
            tab.content.focusList()
            func press(_ key: String, repeating: Bool) {
                let event = NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: list.window.windowNumber, context: nil, characters: key,
                    charactersIgnoringModifiers: key, isARepeat: repeating, keyCode: 120)
                if let event { list.table?.keyDown(with: event) }
            }
            // F2 is Rename, a shortcut that starts a write: once per press.
            press(String(UnicodeScalar(NSF2FunctionKey)!), repeating: false)
            press(String(UnicodeScalar(NSF2FunctionKey)!), repeating: true)
            #expect(run == ["renameSelection"])
            await harness.close()
        }

        // The focus-tree command brings a hidden tree back before it takes the keyboard.
        // B-TREE-018 B-TREE-119 T-110bd505
        @Test func focusingTheTreeShowsAHiddenTree() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, list) = try await harness.openList()
            tab.perform(.toggleFolderTree)
            #expect(!tab.panels.folderTreeOpen)
            tab.perform(.focusTreePane)
            #expect(tab.panels.folderTreeOpen)
            #expect(tab.sidebarController.isInside(list.window.firstResponder))
            await harness.close()
        }

        // B-SEL-123, App.tsx `copyPasteModalOpen` holds `renameDialogState`: while a name is edited in its row the
        // toolbar's view switch and sort dim, and the window's commands wait. Settings and the field's editing don't.
        // B-NAV-218 T-3baf2a61
        @Test(.windowlessAlone) func theWindowsCommandsWaitWhileANameIsEdited() async throws {
            let harness = try ExplorerHarness.windowless()
            let writes = try harness.writeOperations()
            defer { withExtendedLifetime(writes) {} }
            let (tab, list) = try await harness.openList()
            await list.click(name: "note.txt")
            let toolbar = tab.explorerToolbar
            let switcher = try #require(toolbar.viewSwitch)
            let sort = try #require(toolbar.button(.sort))
            #expect(switcher.isEnabled && sort.isEnabled)
            #expect(tab.canPerform(.viewAsIcons) && tab.canPerform(.newTab))
            let viewMode = tab.viewMode

            tab.renameSelected()
            #expect(tab.content.inlineRename != nil)
            harness.layout(tab)
            #expect(!switcher.isEnabled)
            #expect(!sort.isEnabled)
            for command: RendererCommand in [.viewAsIcons, .sortByName, .newTab, .closeTab, .goEnclosingFolder] {
                #expect(!tab.canPerform(command), "\(command)")
            }
            #expect(tab.canPerform(.editPaste))
            #expect(tab.canPerform(.openSettings))
            // `canChangeTabs`: the tabs don't change either (`blocked: copyPasteModalOpen`, App.tsx:1150).
            #expect(tab.group?.isBlocked == true)
            // The menu's items and their keys go by the same rule (`runRendererCommand`).
            tab.perform(.viewAsIcons)
            #expect(tab.viewMode == viewMode)
            #expect(tab.content.inlineRename != nil)

            tab.content.renameCancelled()
            harness.layout(tab)
            #expect(tab.group?.isBlocked == false)
            #expect(switcher.isEnabled && sort.isEnabled)
            #expect(tab.canPerform(.viewAsIcons))
            tab.perform(.viewAsIcons)
            #expect(tab.viewMode != viewMode)
            await harness.close()
        }

        // App.tsx `copyPasteModalOpen` holds `newFolderDialogState`: a new folder's name is edited in its row, as a
        // rename's.
        @Test(.windowlessAlone) func theToolbarDimsWhileANewFolderIsNamed() async throws {
            let harness = try ExplorerHarness.windowless()
            let writes = try harness.writeOperations()
            defer { withExtendedLifetime(writes) {} }
            let (tab, _) = try await harness.openList()
            let toolbar = tab.explorerToolbar
            let switcher = try #require(toolbar.viewSwitch)
            let sort = try #require(toolbar.button(.sort))
            tab.perform(.newFolder)
            #expect(await waitUntil { tab.content.inlineRename != nil })
            harness.layout(tab)
            #expect(!switcher.isEnabled)
            #expect(!sort.isEnabled)
            #expect(!tab.canPerform(.viewAsIcons))
            tab.content.renameCancelled()
            await harness.close()
        }
    }
}
