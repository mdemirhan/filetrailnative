// Keys, commands and presses that reach the window as a person's do: shortcuts.ts:725-790, useExplorerShortcuts.ts:789,
// :1325-1332, useExplorerActions.ts:3263-3274, main.ts:698-701, ContentPane.tsx:472-486, entryItemEvents.ts:59-60,109
import AppKit
import FTFileSystem
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

/// A key press as the system makes it, characters and all.
@MainActor
func systemKeyEvent(_ code: UInt16, _ flags: CGEventFlags = []) throws -> NSEvent {
    let source = CGEventSource(stateID: .privateState)
    let event = try #require(CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true))
    event.flags = flags
    return try #require(NSEvent(cgEvent: event))
}

extension ExplorerWindowlessTests {
    @MainActor
    @Suite struct KeysAndPressesTests {
        private func spelled(_ code: UInt16, _ flags: CGEventFlags = []) throws -> String? {
            Shortcuts.fromKeyboardEvent(ContentKeyboard.shortcutEvent(try systemKeyEvent(code, flags)))
        }

        /// Keys are spelled by the key, whatever ⇧ or ⌥ make it type.
        @Test func aKeyIsSpelledByTheKeyPressed() throws {
            #expect(try spelled(30, [.maskCommand, .maskShift]) == "Cmd+Shift+]")
            #expect(try spelled(33, [.maskCommand, .maskShift]) == "Cmd+Shift+[")
            #expect(try spelled(18, [.maskCommand, .maskShift]) == "Cmd+Shift+1")
            #expect(try spelled(18, [.maskCommand, .maskAlternate]) == "Cmd+Option+1")
            #expect(try spelled(43, [.maskCommand, .maskAlternate]) == "Cmd+Option+,")
            #expect(try spelled(47, [.maskCommand, .maskShift]) == "Cmd+Shift+.")
            #expect(try spelled(50, [.maskControl, .maskShift]) == "Ctrl+Shift+`")
            for (code, name) in [
                (UInt16(105), "F13"), (107, "F14"), (113, "F15"), (106, "F16"), (64, "F17"), (79, "F18"), (80, "F19"),
                (90, "F20"),
            ] {
                #expect(try spelled(code) == name)
            }
            // As before.
            #expect(try spelled(30, [.maskCommand]) == "Cmd+]")
            #expect(try spelled(8, [.maskCommand, .maskAlternate]) == "Cmd+Option+C")
            #expect(try spelled(44, [.maskShift]) == "?")
            #expect(try spelled(18) == "1")
        }

        // useExplorerShortcuts.ts:659,667: the alternate keys of Show Next Tab and Show Previous Tab step through tabs.
        @Test func theAlternateTabKeysStepThroughTheTabs() async throws {
            let harness = try ExplorerHarness.windowless()
            let first = try await harness.open()
            let group = try #require(first.group)
            group.openTab(path: harness.folder.appending("Alpha").path, from: first)
            #expect(await waitUntil { group.tabs.count == 2 })
            group.select(first)
            let window = try #require(first.window)
            window.firstResponder?.keyDown(with: try systemKeyEvent(30, [.maskCommand, .maskShift]))
            #expect(group.selected === group.tabs[1])
            let second = try #require(group.selected?.window)
            second.firstResponder?.keyDown(with: try systemKeyEvent(33, [.maskCommand, .maskShift]))
            #expect(group.selected === first)
            await harness.close()
        }

        // useExplorerActions.ts:3263-3274: File ▸ Open in New Tab and Open in New Window open the alias's folder.
        // B-NAV-073 T-5fd895a0 T-8a72ceff T-90885193
        @Test func openingASelectedFolderAliasInANewTabOrWindowOpensItsTarget() async throws {
            let harness = try ExplorerHarness.windowless()
            try FileManager.default.createSymbolicLink(
                at: harness.folder.appending("Alias"), withDestinationURL: harness.folder.appending("Beta"))
            let tab = try await harness.open()
            let alias = try #require(tab.content.listed.first { $0.name == "Alias" })
            #expect(alias.kind == .symlinkDirectory)
            let target = try #require(
                try? NativeFileSystem().realpath(harness.folder.appending("Beta").path))
            tab.content.select(paths: [alias.path])
            tab.content.focusList()
            let group = try #require(tab.group)
            tab.perform(.openSelectionInNewTab)
            #expect(await waitUntil { group.tabs.count == 2 })
            #expect(group.tabs.last?.folder.path == target)

            group.select(tab)
            tab.perform(.openSelectionInNewWindow)
            #expect(await waitUntil { harness.windows.allTabs.count == 3 })
            #expect(harness.windows.allTabs.last { $0.group !== group }?.folder.path == target)
            await harness.close()
        }

        // main.ts:698-701: with every window off screen, New Window opens on the front window's folder; the Go menu's
        // places open where the last window closed.
        // T-bd532a00
        @Test func newWindowWithNoWindowOnScreenOpensFromTheFrontWindow() {
            let host = FakeWindowHost()
            let menu = MainMenu(windows: host.windows)
            menu.connect(
                openWindowFor: { host.openDefaultWindow(initialCommand: $0) },
                openNewWindowFromFront: { host.openNewWindowFromFront() })
            menu.router.explorerFor = { _ in nil }
            menu.router.send(.newWindow, focusedWindow: nil)
            menu.router.send(.goDocuments, focusedWindow: nil)
            #expect(host.calls == ["newWindowFromFront", "default goDocuments"])
        }

        // useExplorerShortcuts.ts:789: ⇧ and a paging key move the tree as the key does without ⇧.
        // B-NAV-086 B-NAV-100 B-SEL-061
        @Test func aPagingKeyWithShiftMovesTheTree() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            _ = tab.sidebarController.focusTree()
            let window = try #require(tab.window)
            let start = tab.sidebarController.selectedTreeItemID
            window.firstResponder?.keyDown(with: try systemKeyEvent(116, [.maskShift]))
            let moved = tab.sidebarController.selectedTreeItemID
            #expect(moved != start)
            window.firstResponder?.keyDown(with: try systemKeyEvent(121, [.maskShift]))
            #expect(tab.sidebarController.selectedTreeItemID != moved)
            // A command's own keys stay its own.
            tab.updatePreferences(["shortcutOverrides": .object(["toggleInfoRow": .array([.string("Shift+PageUp")])])])
            let before = tab.sidebarController.selectedTreeItemID
            let row = tab.preferences.detailRowOpen
            window.firstResponder?.keyDown(with: try systemKeyEvent(116, [.maskShift]))
            #expect(tab.sidebarController.selectedTreeItemID == before)
            #expect(tab.preferences.detailRowOpen != row)
            await harness.close()
        }

        // ContentPane.tsx:472-486: a press anywhere in an empty folder gives the content pane the keyboard.
        // B-SEL-161
        @Test func aPressInAnEmptyFolderGivesTheListTheKeyboard() async throws {
            let harness = try ExplorerHarness.windowless()
            let empty = harness.folder.appending("Empty")
            try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: false)
            let (tab, list) = try await harness.openList(empty.path)
            #expect(await waitUntil { tab.content.container.stateView.kind != .none })
            harness.layout(tab)
            let table = try #require(list.table)
            let container = tab.content.container
            let inside = NSPoint(x: container.bounds.midX, y: container.bounds.midY)
            #expect(container.hitTest(container.convert(inside, to: container.superview)) === table)
            _ = tab.sidebarController.focusTree()
            #expect(!list.hasKeyboard)
            await list.click(at: container.convert(inside, to: nil))
            #expect(list.hasKeyboard)
            await harness.close()
        }

        @Test func aPressInAnEmptyFolderOfIconsGivesTheGridTheKeyboard() async throws {
            let harness = try ExplorerHarness.windowless()
            let empty = harness.folder.appending("Empty")
            try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: false)
            let tab = try await harness.open(empty.path)
            tab.perform(.viewAsIcons)
            #expect(await waitUntil { tab.content.container.stateView.kind != .none })
            harness.layout(tab)
            let probe = GridProbe(tab: tab)
            let grid = try #require(probe.grid)
            let container = tab.content.container
            let inside = NSPoint(x: container.bounds.midX, y: container.bounds.midY)
            #expect(container.hitTest(container.convert(inside, to: container.superview)) === grid)
            await harness.close()
        }

        // A button of a state is its own.
        // B-SEL-161
        @Test func aStatesButtonStillTakesThePress() throws {
            let state = ContentStateView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
            state.show(.noMatches(query: "x"), theme: AppearanceModel.shared.theme)
            state.layoutSubtreeIfNeeded()
            let buttons = descendants(of: state, SystemButton.self)
            for button in buttons {
                let inside = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: state)
                #expect(state.hitTest(inside) === button)
            }
            #expect(state.hitTest(NSPoint(x: 5, y: 5)) == nil)
        }

        // ContentPane.tsx:472-486: on a column header, or beside its cells, the press gives the list the keyboard and
        // not on the column resizer (`.details-column-resizer`).
        // B-SEL-161
        @Test func aPressOnTheColumnHeaderGivesTheListTheKeyboard() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, list) = try await harness.openList()
            let content = try #require(tab.window?.contentView)
            let header = try #require(descendants(of: content, DetailsHeaderView.self).first)
            let cell = try #require(header.cell(for: .name))
            let event = try #require(
                MouseEvents.event(.leftMouseDown, at: cell.convert(NSPoint.zero, to: nil), in: list.window))

            _ = tab.sidebarController.focusTree()
            #expect(!list.hasKeyboard)
            cell.mouseDown(with: event)
            #expect(list.hasKeyboard)

            _ = tab.sidebarController.focusTree()
            cell.separator.mouseDown(with: event)
            cell.separator.mouseUp(with: event)
            #expect(!list.hasKeyboard)

            let beside = NSPoint(x: 1, y: 1)
            #expect(header.hitTest(header.convert(beside, to: header.superview)) === header)
            header.mouseDown(with: event)
            #expect(list.hasKeyboard)
            await harness.close()
        }

        // entryItemEvents.ts:59-60,109: only the second click of a run opens; a third is a click.
        @Test func aThirdClickOpensNothing() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, list) = try await harness.openList()
            var opened: [String] = []
            tab.openFile = { opened.append($0.lastPathComponent) }
            await list.click(name: "note.txt", count: 3)
            #expect(await waitUntil { !opened.isEmpty })
            await Task.yield()
            #expect(opened == ["note.txt"])
            await harness.close()
        }

        @Test func aThirdClickOnAnIconOpensNothing() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, probe) = try await harness.openGrid(.viewAsIcons)
            var opened: [String] = []
            tab.openFile = { opened.append($0.lastPathComponent) }
            let item = try #require(probe.iconItems["note.txt"])
            probe.press(at: probe.point(in: item.view), count: 3)
            #expect(await waitUntil { !opened.isEmpty })
            await Task.yield()
            #expect(opened == ["note.txt"])
            await harness.close()
        }

        // The items a test trashes go to its stand-in, and Undo puts them back from there.
        @Test(.windowlessAlone) func aTrashedItemGoesToTheStandIn() async throws {
            let name = "stand-in-\(UUID().uuidString).txt"
            let window = try await WritingWindow.open()
            let tab = window.tab
            try "x".write(to: window.folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
            tab.refresh()
            #expect(await waitUntil { tab.content.entries.contains { $0.name == name } })
            window.select([name])
            tab.perform(.trashSelection)
            let inTrash = StandInTrash.folder.appendingPathComponent(name).path
            #expect(await waitUntil { FileManager.default.fileExists(atPath: inTrash) })
            #expect(!window.exists(name))
            let session = window.operations.session(for: try #require(tab.group))
            #expect(await waitUntil { session.card == nil })
            tab.perform(.undo)
            #expect(await waitUntil { window.exists(name) })
            #expect(!FileManager.default.fileExists(atPath: inTrash))
            await window.close()
        }
    }
}
