// Share… from each place it is offered gives the system's share popover the items it is for
import AppKit
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    @MainActor @Suite struct ShareTests: ToolbarTesting {
        /// Where the popover was hung: by which rectangle of which view.
        private final class Anchors {
            var all: [(rect: NSRect, view: NSView)] = []
        }

        /// A tab whose Share… records what it would share, so no popover comes on screen.
        private func open() async throws -> (ExplorerHarness, MainWindowController, () -> [[String]]) {
            let (harness, tab, shared, _) = try await openWithAnchors()
            return (harness, tab, shared)
        }

        private func openWithAnchors() async throws -> (
            ExplorerHarness, MainWindowController, () -> [[String]], Anchors
        ) {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            harness.layout(tab)
            var shared: [[String]] = []
            let anchors = Anchors()
            tab.showSharePicker = { paths, rect, view in
                shared.append(paths)
                anchors.all.append((rect, view))
            }
            return (harness, tab, { shared }, anchors)
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

        // From the menu the popover hangs under the lead item of the selection, inside the part of the list in
        // sight; from a button, under the button.
        @Test func thePopoverHangsUnderTheLeadItemOrTheButtonPressed() async throws {
            let (harness, tab, shared, anchors) = try await openWithAnchors()
            try select(["Alpha", "note.txt"], tab)
            let list = tab.content.view
            tab.perform(.shareSelection)
            let lead = try #require(tab.content.selection.leadPath)
            let frame = try #require(
                QuickLookItemFrame.screenFrame(of: lead, entries: tab.content.entries, in: list))
            let window = try #require(tab.window)
            let row = list.convert(window.convertFromScreen(frame), from: nil)
            #expect(anchors.all.count == 1)
            #expect(anchors.all[0].view === list)
            #expect(anchors.all[0].rect == row.intersection(list.visibleRect))
            #expect(!anchors.all[0].rect.isEmpty)

            setItems(tab, ToolbarItems.defaultTopItems + [.share], harness)
            tab.explorerToolbar.reload()
            let share = try #require(button(tab, .share))
            tab.shareSelection(from: share)
            #expect(anchors.all.count == 2)
            #expect(anchors.all[1].view === share && anchors.all[1].rect == share.bounds)
            #expect(shared().count == 2)
            await harness.close()
        }

        // Items in the Trash are never shared, whichever way Share is asked for: a key set for it runs the command
        // though its menu item is dimmed.
        @Test func nothingInTheTrashIsShared() async throws {
            let (harness, tab, shared) = try await open()
            let home = tab.trashHomePath
            tab.share([home + "/.Trash/gone.txt"])
            tab.share([try path("note.txt", tab), home + "/.Trash/gone.txt"])
            #expect(shared().isEmpty)
            tab.share([try path("note.txt", tab)])
            #expect(shared().count == 1)
            await harness.close()
        }

        // The toolbar's Share button is off with nothing selected.
        @Test func theToolbarButtonIsOffWithNothingSelected() async throws {
            let (harness, tab, _) = try await open()
            setItems(tab, ToolbarItems.defaultTopItems + [.share], harness)
            tab.content.applySelection(.empty)
            tab.explorerToolbar.reload()
            #expect(try #require(button(tab, .share)).isEnabled == false)
            try select(["note.txt"], tab)
            tab.explorerToolbar.reload()
            #expect(try #require(button(tab, .share)).isEnabled)
            await harness.close()
        }
    }
}
