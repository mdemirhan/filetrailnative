import AppKit
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    @MainActor
    @Suite struct SelectionFixesTests {
        // With the tree hidden Tab from the list stays in the list.
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

        // With the tree shown, Tab hands the keyboard to it.
        @Test func tabFromTheListGoesToTheTreeWhileItIsShown() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, list) = try await harness.openList()
            #expect(tab.panels.folderTreeOpen)
            tab.content.focusList()
            tab.content.onSwitchPane?()
            #expect(tab.sidebarController.isInside(list.window.firstResponder))
            await harness.close()
        }

        // A held key repeats no shortcut that starts a write, and still repeats the others.
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

        // While a name is edited in its row the toolbar's view switch and sort dim, and the window's commands wait.
        // Settings and the field's editing don't.
        @Test func theWindowsCommandsWaitWhileANameIsEdited() async throws {
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
            // The tabs don't change either.
            #expect(tab.group?.isBlocked == true)
            // The menu's items and their keys go by the same rule.
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

        // A new folder's name is edited in its row, as a rename's.
        @Test func theToolbarDimsWhileANewFolderIsNamed() async throws {
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
