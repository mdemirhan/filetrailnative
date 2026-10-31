// Port by feature of components/ClipboardButton.test.tsx, components/ClipboardMarks.test.tsx, the paste-flow cases of
// App.pasteFlow.test.tsx and App.fileOperations.test.tsx, and "the clipboard" of App.windows.test.tsx: the clipboard of
// an explorer window that is never shown, with the app's real file operations on a temporary folder
import AppKit
import FTFileSystem
import FTFoundation
import FTOperations
import Foundation
import Testing

@testable import FTAppKit

/// The notices a test's file operations showed.
@MainActor
final class DialogRecorder {
    private(set) var shown: [(title: String, message: String)] = []

    var dialogs: WriteDialogs {
        WriteDialogs(
            show: { [weak self] title, message, _ in self?.shown.append((title, message)) },
            showInfo: { [weak self] title, message, _ in self?.shown.append((title, message)) })
    }
}

/// A windowless explorer window with the app's file operations.
@MainActor
struct WritingWindow {
    let harness: ExplorerHarness
    let tab: MainWindowController
    let operations: AppWriteOperations
    let recorder: DialogRecorder
    /// The folder as the tab names it (/private/var, not /var).
    let folder: URL

    static func open(_ path: String? = nil) async throws -> WritingWindow {
        PreparingSheet.isEnabled = false
        let harness = try ExplorerHarness.windowless()
        let tab = try await harness.open(path)
        let operations = AppWriteOperations(
            userData: harness.folder.url, directoryService: harness.services.directoryService, windows: harness.windows,
            trash: .standIn,
            log: { _ in })
        let recorder = DialogRecorder()
        operations.dialogs = recorder.dialogs
        tab.perform(.viewAsDetails)
        _ = await waitUntil { !tab.content.entries.isEmpty }
        harness.layout(tab)
        return WritingWindow(
            harness: harness, tab: tab, operations: operations, recorder: recorder,
            folder: tab.content.entries.first.map { $0.url.deletingLastPathComponent() } ?? tab.folder)
    }

    func select(_ names: [String]) {
        let paths = names.map { folder.appendingPathComponent($0).path }
        tab.content.select(paths: paths)
        tab.content.focusList()
    }

    func exists(_ relative: String) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(relative).path)
    }

    func close() async {
        tab.services.clipboard.set(.empty, from: nil)
        withExtendedLifetime(operations) {}
        await harness.close()
    }
}

extension ExplorerWindowlessTests {
    @MainActor
    @Suite(.windowlessAlone) struct ClipboardWindowTests: ListTesting {
        private func path(_ window: WritingWindow, _ name: String) -> String {
            window.folder.appendingPathComponent(name).path
        }

        // T-5ce8b24a T-d3e678fd F-643 F-800 B-CLIP-001 B-CLIP-005 B-CLIP-019: Copy fills the app's clipboard; the
        // button counts it, its title names the item, its name says how many; the list opens only when clicked.
        // B-CLIP-006 T-ac3dbdb3 T-ad0a5cc6
        @Test func copyFillsTheClipboardAndTheButtonSaysSo() async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            window.select(["note.txt"])
            tab.perform(.copySelection)
            let contents = tab.services.clipboard.contents
            #expect(contents.mode == .copy)
            #expect(contents.sourcePaths == [path(window, "note.txt")])
            #expect(contents.sourceEntries[path(window, "note.txt")]?.kind == .file)
            window.harness.layout(tab)
            let button = try #require(tab.explorerToolbar.clipboardButton)
            #expect(button.count.stringValue == "1")
            #expect(button.tooltip == "note.txt copied")
            #expect(button.accessibilityLabel() == "Clipboard: 1 item copied")
            #expect(!tab.clipboardUI.isOpen)
            await window.close()
        }

        // T-b6500c53 T-32b9cf2d T-409a0b20 T-3553aecb F-791 B-CLIP-013 B-CLIP-014 B-CLIP-015: the copy glyph after
        // a copied item's name, the scissors and a dimmed name for a cut one, and none with the setting off.
        // B-VIEW-076 T-de752420
        @Test func marksCopiedAndCutRowsAndNoneWithTheSettingOff() async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            window.select(["note.txt"])
            tab.perform(.copySelection)
            window.harness.layout(tab)
            func row() -> DetailsBarView? { bars(tab).first { $0.entry?.name == "note.txt" } }
            #expect(row()?.nameCell.markGlyph.mark == .copy)
            #expect(row()?.nameLabel.alphaValue == 1)
            #expect(bars(tab).filter { $0.nameCell.markGlyph.mark != nil }.count == 1)
            tab.perform(.cutSelection)
            #expect(row()?.nameCell.markGlyph.mark == .cut)
            #expect(row()?.nameLabel.alphaValue == CGFloat(ClipboardLayout.Mark.cutLabelAlpha))
            tab.updatePreferences(["markClipboardItems": .bool(false)])
            tab.clipboardMarksChanged()
            #expect(row()?.nameCell.markGlyph.mark == nil)
            #expect(row()?.nameLabel.alphaValue == 1)
            await window.close()
        }

        // T-4914f3c3 T-59f31d60 T-42e70625 T-acd2e0bd F-801 F-802 B-CLIP-020 B-CLIP-021 B-CLIP-029 B-CLIP-030
        // B-CLIP-031 B-CLIP-038: Show Clipboard opens the list; ↓ and ⌫ take one item off and the list stays; Clear
        // Clipboard empties it and the list goes with the button.
        // B-CLIP-039 T-0c69a005 T-4851fd44
        @Test func theListIsWorkedWithItsKeysAndClearEmptiesIt() async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            window.select(["note.txt", "Alpha"])
            tab.perform(.copySelection)
            window.harness.layout(tab)
            tab.perform(.showClipboard)
            let menu = try #require(tab.clipboardUI.menu)
            let button = try #require(tab.explorerToolbar.clipboardButton)
            #expect(menu.summary.countLabel == "2 items copied")
            #expect(menu.pasteHint == "Paste with \u{2318}V")
            #expect(menu.modelForTests.activeIndex == -1)
            func key(_ code: UInt16) -> Bool {
                let event = NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                    characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
                return tab.clipboardUI.intercept(event)
            }
            #expect(key(125))
            #expect(menu.modelForTests.activeIndex == 0)
            // Opened from the menu, the button never had the focus.
            #expect(!button.showsKeyboardRing)
            #expect(key(51))
            #expect(tab.clipboardUI.isOpen)
            #expect(tab.services.clipboard.contents.sourcePaths.count == 1)
            // Opened by a click, the button has the focus, and the first key shows its ring until the list closes (173).
            tab.clipboardUI.close()
            tab.clipboardUI.toggle(from: button)
            #expect(tab.clipboardUI.isOpen && !button.showsKeyboardRing)
            #expect(key(125))
            #expect(button.showsKeyboardRing)
            tab.clipboardUI.close()
            #expect(!button.showsKeyboardRing)
            tab.perform(.clearClipboard)
            #expect(!tab.services.clipboard.contents.hasItems)
            #expect(!tab.clipboardUI.isOpen)
            tab.perform(.showClipboard)
            #expect(!tab.clipboardUI.isOpen)
            await window.close()
        }

        // T-9ce97f0a F-801 B-CLIP-028: an item of the list is shown in its folder, selected.
        @Test func anItemOfTheListIsShownInItsFolder() async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            let inner = window.folder.appendingPathComponent("Alpha/Inner").path
            tab.services.clipboard.set(ClipboardRules.set(.copy, [inner], capturedAt: "t"), from: nil)
            tab.clipboardChanged()
            tab.revealClipboardItem(inner)
            #expect(await waitUntil { tab.folder.path.hasSuffix("/Alpha") && tab.selectedPaths == [inner] })
            await window.close()
        }

        // T-2540d465 T-ea5c50e9 F-684 B-CLIP-051 B-CLIP-054 B-CLIP-075: Paste goes into the folder on screen at once
        // with the safe policy when nothing clashes; the copy stays on the clipboard for more pastes, and a toast says
        // where it went.
        // B-CLIP-077 T-85ab3d1a T-a9b252b4 T-ac3dbdb3
        @Test func pasteCopiesIntoTheFolderOnScreen() async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            window.select(["note.txt"])
            tab.perform(.copySelection)
            tab.go(to: window.folder.appendingPathComponent("Alpha"))
            #expect(await waitUntil { tab.folder.lastPathComponent == "Alpha" })
            #expect(tab.canPerform(.pasteSelection))
            tab.perform(.pasteSelection)
            #expect(await waitUntil { window.exists("Alpha/note.txt") })
            #expect(window.exists("note.txt"))
            #expect(tab.services.clipboard.contents.hasItems)
            #expect(
                await waitUntil {
                    tab.notifications?.toasts.entries.contains { $0.title == "Pasted into Alpha" } == true
                })
            #expect(window.recorder.shown.isEmpty)
            await window.close()
        }

        // T-b945ba5e T-2cdfbe92 B-CLIP-062 B-CLIP-073 B-CLIP-078: a cut is moved by Paste and cleared once it moved
        // something; pasting a cut into the folder it is in quietly does nothing.
        // B-CLIP-064 B-CLIP-077 T-6789eb23 T-9bc2c171 T-de752420
        @Test func pasteMovesACutAndClearsIt() async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            window.select(["note.txt"])
            tab.perform(.cutSelection)
            // Until that paste has looked and given up: its card is up meanwhile, and a paste made then is refused
            // as busy. A fixed wait was too short when other suites kept the main actor or the disk busy.
            let session = try #require(tab.writeActions?.session)
            var cardWent = false
            var cardCame = false
            let observation = session.observe { event in
                guard case .card(let card) = event else { return }
                if card != nil { cardCame = true } else if cardCame { cardWent = true }
            }
            tab.perform(.pasteSelection)
            #expect(await waitUntil { cardWent && session.card == nil })
            withExtendedLifetime(observation) {}
            #expect(window.exists("note.txt"))
            #expect(tab.services.clipboard.contents.mode == .cut)
            #expect(window.recorder.shown.isEmpty)
            tab.go(to: window.folder.appendingPathComponent("Beta"))
            #expect(await waitUntil { tab.folder.lastPathComponent == "Beta" })
            tab.perform(.pasteSelection)
            #expect(await waitUntil { window.exists("Beta/note.txt") && !window.exists("note.txt") })
            #expect(await waitUntil { !tab.services.clipboard.contents.hasItems })
            await window.close()
        }

        // T-fc49f1f2 T-f3d3ef14 B-CLIP-074: items gone since they were copied are taken off the clipboard, the rest
        // are pasted, and a notice names what was left out.
        // T-7567e39d T-e04b3e03
        @Test func pasteLeavesOutItemsGoneSinceTheyWereCopied() async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            try "b".write(to: window.folder.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
            tab.services.clipboard.set(
                ClipboardRules.set(.copy, [path(window, "note.txt"), path(window, "b.txt")], capturedAt: "t"), from: nil
            )
            tab.clipboardChanged()
            try FileManager.default.removeItem(atPath: path(window, "note.txt"))
            tab.go(to: window.folder.appendingPathComponent("Gamma"))
            #expect(await waitUntil { tab.folder.lastPathComponent == "Gamma" })
            tab.perform(.pasteSelection)
            #expect(await waitUntil { window.exists("Gamma/b.txt") })
            #expect(await waitUntil { !window.recorder.shown.isEmpty })
            #expect(window.recorder.shown.first?.title == "An item couldn\u{2019}t be pasted")
            #expect(
                window.recorder.shown.first?.message
                    == "\u{201C}note.txt\u{201D} couldn\u{2019}t be pasted because it was moved or deleted since it was copied."
            )
            #expect(tab.services.clipboard.contents.sourcePaths == [path(window, "b.txt")])
            await window.close()
        }

        // T-ba10f104 T-aca62778 B-CLIP-063 B-CLIP-107: while a write runs, Paste says so and starts nothing.
        // T-5389fe11
        @Test func pasteIsRefusedWhileAWriteRuns() async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            window.select(["note.txt"])
            tab.perform(.copySelection)
            let session = window.operations.session(for: try #require(tab.group))
            session.applyCard(WriteOperationCardState(action: .copyTo, stage: .running, targetPath: "/x"))
            #expect(!tab.canPerform(.pasteSelection))
            #expect(tab.canPerform(.copySelection))
            let actions = try #require(tab.writeActions)
            _ = await actions.pasteFromClipboard(into: window.folder.appendingPathComponent("Alpha").path)
            #expect(window.recorder.shown.map(\.title) == ["Couldn\u{2019}t Paste"])
            #expect(window.recorder.shown.first?.message == WriteDialogs.busyMessage)
            #expect(!window.exists("Alpha/note.txt"))
            session.applyCard(nil)
            await window.close()
        }

        // T-cc6ebb98 T-d4b3c2fe B-CLIP-057 B-CLIP-058: nothing is pasted into search results or the Trash.
        // B-CLIP-053 T-adb6c85c
        @Test func noPasteDestinationInSearchResults() async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            window.select(["note.txt"])
            tab.perform(.copySelection)
            #expect(tab.pasteDestinationPath == tab.folder.path)
            tab.searchRootPath = window.folder.path
            #expect(tab.pasteDestinationPath == nil)
            #expect(!tab.canPerform(.pasteSelection))
            tab.searchRootPath = nil
            await window.close()
        }

        // T-317cfcc8 T-450db1e9 T-688aee9c B-VIEW-184: what is copied in one window is told to the others, and a new
        // window opens with it.
        // B-CLIP-011
        @Test func anotherWindowSeesTheClipboard() async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            tab.perform(.newWindow)
            #expect(await waitUntil { window.harness.windows.allTabs.count == 2 })
            let other = try #require(window.harness.windows.allTabs.first { $0 !== tab })
            other.servicesOverride = window.harness.services
            #expect(await waitUntil { !other.content.entries.isEmpty })
            window.select(["note.txt"])
            tab.perform(.copySelection)
            #expect(other.services.clipboard.contents.sourcePaths == [path(window, "note.txt")])
            #expect(other.content.clipboardMarks?.mark(for: path(window, "note.txt")) == .copy)
            window.harness.layout(other)
            let button = other.explorerToolbar.clipboardButton
            #expect(button?.count.stringValue == "1")
            await window.close()
        }

        // T-317cfcc8 F-638 F-643 B-VIEW-171 B-VIEW-184: what is copied in one window is pasted in another (scenario 38),
        // the file listed and selected there.
        // B-CLIP-011 B-SEL-032 T-2a23a39f
        @Test func anotherWindowPastesWhatWasCopied() async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            tab.perform(.newWindow)
            #expect(await waitUntil { window.harness.windows.allTabs.count == 2 })
            let other = try #require(window.harness.windows.allTabs.first { $0 !== tab })
            other.servicesOverride = window.harness.services
            other.ensureLoaded()
            other.go(to: window.folder.appendingPathComponent("Gamma"))
            #expect(await waitUntil { other.folder.lastPathComponent == "Gamma" })
            window.select(["note.txt"])
            tab.perform(.copySelection)
            other.perform(.pasteSelection)
            #expect(await waitUntil { window.exists("Gamma/note.txt") })
            #expect(await waitUntil { other.content.entries.map(\.name).contains("note.txt") })
            #expect(await waitUntil { other.content.selectedEntries.map(\.name) == ["note.txt"] })
            await window.close()
        }

        // T-d754e570 B-VIEW-171: what is copied in one tab is pasted in another.
        // N/A T-07c17e51 T-001cf8ca D-003: the system's tab bar owns drags over tabs.
        // T-eb9edd5d
        @Test func anotherTabPastesWhatWasCopied() async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            window.select(["note.txt"])
            tab.perform(.copySelection)
            let group = try #require(tab.group)
            group.openTab(path: window.folder.appendingPathComponent("Gamma").path, from: tab)
            #expect(await waitUntil { group.tabs.count == 2 })
            let other = try #require(group.tabs.first { $0 !== tab })
            other.servicesOverride = window.harness.services
            other.ensureLoaded()
            #expect(await waitUntil { other.folder.lastPathComponent == "Gamma" })
            other.perform(.pasteSelection)
            #expect(await waitUntil { window.exists("Gamma/note.txt") })
            await window.close()
        }

        // B-CLIP-001 B-CLIP-055 B-CLIP-056: Copy from an item's menu takes its items; "Paste into" a folder's
        // menu pastes there.
        // T-0516f92a T-1c693346 T-32391861 T-84eec894
        @Test func theRightClickMenusCopyAndPasteIntoAFolder() async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            let note = path(window, "note.txt")
            let alpha = path(window, "Alpha")
            tab.contextMenuFileOperation(
                .copy,
                ContextMenuSubject(
                    surface: .content, scope: .selection, paths: [note], targetPath: note,
                    entries: [CommandEntry(path: note, kind: .file)]))
            #expect(tab.services.clipboard.contents.sourcePaths == [note])
            tab.contextMenuFileOperation(
                .paste,
                ContextMenuSubject(
                    surface: .content, scope: .selection, paths: [alpha], targetPath: alpha,
                    entries: [CommandEntry(path: alpha, kind: .directory)]))
            #expect(await waitUntil { window.exists("Alpha/note.txt") })
            await window.close()
        }

        // A click inside can give the popover the keyboard: a key with ⌘, ⌃ or ⌥ closes the list and still acts, in the
        // window the list hangs from, and the list's own keys stop there (ClipboardButton.tsx:147-151).
        // B-CLIP-032
        @Test func aKeyThePopoverHasGoesOnToTheWindowOnlyWithAModifier() async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            window.select(["note.txt"])
            tab.perform(.copySelection)
            window.harness.layout(tab)
            tab.perform(.showClipboard)
            func key(_ code: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags) -> NSEvent {
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 987_654,
                    context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false,
                    keyCode: code)!
            }
            #expect(tab.clipboardUI.popoverKey(key(125, "", [])) == nil)
            #expect(tab.clipboardUI.isOpen)
            let passed = try #require(tab.clipboardUI.popoverKey(key(9, "v", .command)))
            #expect(!tab.clipboardUI.isOpen)
            #expect(passed.keyCode == 9 && passed.charactersIgnoringModifiers == "v")
            #expect(passed.modifierFlags.contains(.command))
            #expect(passed.windowNumber == tab.window?.windowNumber)
            await window.close()
        }

        // T-cd735b31 F-801 B-CLIP-037: a press outside the list closes it, and goes on to where it was pressed.
        // N/A T-35d9394c AppKit's own window frame takes no clicks from an open menu: nothing marks the page.
        @Test func aPressOutsideTheListClosesIt() async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            window.select(["note.txt"])
            tab.perform(.copySelection)
            window.harness.layout(tab)
            tab.perform(.showClipboard)
            let menu = try #require(tab.clipboardUI.menu)
            let outside = menu.convert(NSPoint(x: -40, y: -40), to: nil)
            let press = NSEvent.mouseEvent(
                with: .leftMouseDown, location: outside, modifierFlags: [], timestamp: 0,
                windowNumber: tab.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            #expect(!tab.clipboardUI.intercept(press))
            #expect(!tab.clipboardUI.isOpen)
            await window.close()
        }
    }
}
