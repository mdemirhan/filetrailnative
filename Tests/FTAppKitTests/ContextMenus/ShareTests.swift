// Share… from each place it is offered gives the system's share popover the items it is for
import AppKit
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    @MainActor @Suite struct ShareTests: ToolbarTesting {
        /// A tab whose Share… records what it would share, so no popover comes on screen.
        private func open() async throws -> (ExplorerHarness, MainWindowController, () -> [[String]]) {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            harness.layout(tab)
            var shared: [[String]] = []
            tab.showSharePicker = { shared.append($0) }
            return (harness, tab, { shared })
        }

        private func path(_ name: String, _ tab: MainWindowController) throws -> String {
            try #require(tab.content.entries.first { $0.name == name }?.path)
        }

        private func select(_ names: [String], _ tab: MainWindowController) throws {
            tab.content.select(paths: try names.map { try path($0, tab) })
            tab.content.focusList()
        }

        // The right-click menu shares the items it is for, a file and a folder together.
        @Test func theRightClickMenuSharesItsItems() async throws {
            let (harness, tab, shared) = try await open()
            let entries = try ["note.txt", "Alpha"].map { name in
                try #require(tab.content.entries.first { $0.name == name })
            }
            let menu = try #require(tab.contextMenus.contentMenu(for: entries))
            let item = try #require(menu.items.first { $0.title == "Share…" })
            _ = NSApp.sendAction(try #require(item.action), to: item.target, from: item)
            #expect(shared() == [entries.map(\.path)])
            await harness.close()
        }

        // File ▸ Share… shares the selection, and is off with nothing selected and while the tree has the keyboard.
        @Test func theFileMenuSharesTheSelection() async throws {
            let (harness, tab, shared) = try await open()
            #expect(!tab.canPerform(.shareSelection))
            try select(["note.txt"], tab)
            #expect(tab.canPerform(.shareSelection))
            tab.perform(.shareSelection)
            #expect(shared() == [[try path("note.txt", tab)]])
            tab.perform(.focusTreePane)
            #expect(!tab.canPerform(.shareSelection))
            await harness.close()
        }

        // The toolbar's Share button, once added, shares the selection.
        @Test func theToolbarButtonSharesTheSelection() async throws {
            let (harness, tab, shared) = try await open()
            setItems(tab, ToolbarItems.defaultTopItems + [.share], harness)
            try select(["note.txt", "Alpha"], tab)
            tab.explorerToolbar.reload()
            let share = try #require(button(tab, .share))
            #expect(share.isEnabled)
            share.onClick?()
            #expect(shared() == [tab.content.selection.paths])
            #expect(Set(shared().first ?? []) == Set([try path("note.txt", tab), try path("Alpha", tab)]))
            await harness.close()
        }

        // The Info panel's Share shares the item it describes.
        @Test func theInfoPanelSharesItsItem() async throws {
            let (harness, tab, shared) = try await open()
            tab.perform(.toggleInfoPanel)
            harness.layout(tab)
            let note = try path("note.txt", tab)
            tab.content.select(paths: [note])
            let info = try #require(tab.infoController)
            #expect(await waitUntil { info.resolvedItemPath == note })
            info.panel.onAction(.share)
            #expect(shared() == [[note]])
            await harness.close()
        }
    }
}
