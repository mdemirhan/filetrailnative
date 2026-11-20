// Gathering on the clipboard in a window that is never shown, with the app's real file operations on a temporary
// folder: the Adds, a paste that copies some items and moves others, Move Items Here, the question about two items of
// one name, Put Back, and the shared clipboard's own rules
import AppKit
import FTFileSystem
import FTFoundation
import FTOperations
import Foundation
import Testing

@testable import FTAppKit

@MainActor
struct SharedClipboardPutBackTests {
    private func gathered() -> CopyPasteClipboard {
        let copied = ClipboardRules.set(.copy, ["/a/x"], capturedAt: "t1")
        return ClipboardRules.applyAdd(ClipboardRules.planAdd(copied, .cut, ["/b/y"]), to: copied, stamp: "t2")
            .clipboard
    }

    @Test func aCopyOverAClipboardBuiltWithAddKeepsItToPutBack() {
        var told: [CopyPasteClipboard] = []
        let clipboard = SharedClipboard { told.append($1) }
        clipboard.set(gathered(), from: 1)
        let copy = ClipboardRules.set(.copy, ["/c/z"], capturedAt: "t3")
        #expect(clipboard.replace(with: copy, from: 1) == gathered())
        #expect(clipboard.previous == gathered())
        #expect(clipboard.contents == copy)

        // Put Back swaps the two, so a second one swaps them again.
        #expect(clipboard.putBack(from: 1))
        #expect(clipboard.contents == gathered())
        #expect(clipboard.previous == copy)
        #expect(clipboard.putBack(from: 1))
        #expect(clipboard.contents == copy)
        #expect(told.last == copy)
    }

    @Test func aCopyOverOneNeverAddedToKeepsNothing() {
        let clipboard = SharedClipboard()
        clipboard.set(ClipboardRules.set(.copy, ["/a/x"], capturedAt: "t1"), from: nil)
        #expect(clipboard.replace(with: ClipboardRules.set(.cut, ["/b/y"], capturedAt: "t2"), from: nil) == nil)
        #expect(clipboard.previous == nil)
        #expect(!clipboard.putBack(from: nil))
    }

    /// Clear Clipboard means it: there is nothing to put back after it.
    @Test func clearingTheClipboardLetsGoOfWhatWasKept() {
        let clipboard = SharedClipboard()
        clipboard.set(gathered(), from: nil)
        clipboard.replace(with: ClipboardRules.set(.copy, ["/c/z"], capturedAt: "t3"), from: nil)
        clipboard.set(.empty, from: nil)
        #expect(clipboard.previous == nil)
    }

    /// What happens to the items meanwhile happens to the clipboard kept too, so it is put back where they are.
    @Test func theClipboardKeptFollowsItsItems() {
        let clipboard = SharedClipboard()
        clipboard.set(gathered(), from: nil)
        clipboard.replace(with: ClipboardRules.set(.copy, ["/c/z"], capturedAt: "t3"), from: nil)
        clipboard.followKept { ClipboardRules.followThroughRemoval($0, ["/a/x"]) }
        #expect(clipboard.previous?.sourcePaths == ["/b/y"])
        clipboard.followKept { ClipboardRules.followThroughRemoval($0, ["/b/y"]) }
        #expect(clipboard.previous == nil)
    }
}

@MainActor
struct ToastActionTests {
    @Test func aNotificationsButtonDoesWhatItSaysAndTheNotificationGoes() {
        let center = ToastCenter()
        center.schedule = { _, _ in ToastCenter.Cancel {} }
        var pressed = 0
        let id = center.push(.success, title: "1 item copied", action: ("Put Back", { pressed += 1 }))
        #expect(center.entries.first?.actionTitle == "Put Back")
        center.performAction(try! #require(id))
        #expect(pressed == 1)
        #expect(center.entries.isEmpty)
        // Gone, its button does nothing more.
        center.performAction(id!)
        #expect(pressed == 1)
        // One without a button has no title for it.
        center.push(.info, title: "Plain")
        #expect(center.entries.first?.actionTitle == nil)
    }
}

extension ExplorerWindowlessTests {
    @MainActor
    @Suite struct ClipboardShelfWindowTests: ListTesting {
        private func path(_ window: WritingWindow, _ relative: String) -> String {
            window.folder.appendingPathComponent(relative).path
        }

        private func write(_ window: WritingWindow, _ relative: String, _ text: String = "x") throws {
            try text.write(toFile: path(window, relative), atomically: true, encoding: .utf8)
        }

        /// Opens a folder of the test folder and waits for its items.
        private func open(_ window: WritingWindow, _ folder: String, showing names: [String] = []) async {
            window.tab.go(to: window.folder.appendingPathComponent(folder))
            #expect(
                await waitUntil {
                    window.tab.folder.lastPathComponent == folder
                        && names.allSatisfy { name in window.tab.content.entries.contains { $0.name == name } }
                })
        }

        private func select(_ window: WritingWindow, _ relative: [String]) {
            window.tab.content.select(paths: relative.map { path(window, $0) })
            window.tab.content.focusList()
        }

        private func toast(_ tab: MainWindowController, _ title: String) async -> Bool {
            await waitUntil { tab.notifications?.toasts.entries.contains { $0.title == title } == true }
        }

        @Test func gathersFromSeveralFoldersThenPastesEachAsItWasPutOnAndUndoesItInOne() async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            try write(window, "Alpha/a.txt", "a")
            try write(window, "Beta/b.txt", "b")

            await open(window, "Alpha", showing: ["a.txt"])
            select(window, ["Alpha/a.txt"])
            tab.perform(.copySelection)
            await open(window, "Beta", showing: ["b.txt"])
            select(window, ["Beta/b.txt"])
            #expect(tab.canPerform(.addToCut))
            tab.perform(.addToCut)

            let contents = tab.services.clipboard.contents
            #expect(contents.copiedPaths == [path(window, "Alpha/a.txt")])
            #expect(contents.cutPaths == [path(window, "Beta/b.txt")])
            #expect(await toast(tab, "Added \u{201C}b.txt\u{201D} to move \u{B7} 1 to move, 1 to copy"))
            window.harness.layout(tab)
            let button = try #require(tab.explorerToolbar.clipboardButton)
            #expect(button.count.stringValue == "1")
            #expect(button.copiedCount.stringValue == "1")
            #expect(!button.copiedCount.isHidden)

            await open(window, "Gamma")
            #expect(tab.canPerform(.pasteSelection))
            tab.perform(.pasteSelection)
            #expect(await waitUntil { window.exists("Gamma/a.txt") && window.exists("Gamma/b.txt") })
            #expect(window.exists("Alpha/a.txt"))
            #expect(await waitUntil { !window.exists("Beta/b.txt") })
            // The paste used the clipboard up: what was copied left it with what moved.
            #expect(await waitUntil { !tab.services.clipboard.contents.hasItems })
            #expect(window.recorder.shown.isEmpty)

            // One Undo: the copy goes, the moved item goes back.
            #expect(await waitUntil { !tab.isWriteLocked })
            tab.perform(.undo)
            #expect(await waitUntil { !window.exists("Gamma/a.txt") && window.exists("Beta/b.txt") })
            #expect(!window.exists("Gamma/b.txt"))
            #expect(window.exists("Alpha/a.txt"))
            await window.close()
        }

        /// Finder's ⌥⌘V after Copy: everything moves, and leaves the clipboard.
        @Test func moveItemsHereMovesWhatWasCopied() async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            window.select(["note.txt"])
            tab.perform(.copySelection)
            await open(window, "Alpha")
            #expect(tab.canPerform(.moveItemsHere))
            tab.perform(.moveItemsHere)
            #expect(await waitUntil { window.exists("Alpha/note.txt") && !window.exists("note.txt") })
            #expect(await waitUntil { !tab.services.clipboard.contents.hasItems })
            await window.close()
        }

        @Test func anItemOfANameOnTheClipboardIsAskedAboutAndKeptBesideIt() async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            try write(window, "Alpha/README.md", "alpha")
            try write(window, "Beta/README.md", "beta")
            var asked: [[ClipboardNameClash]] = []
            let ask = ClipboardClashQuestion.ask
            ClipboardClashQuestion.ask = { clashes, _ in
                asked.append(clashes)
                return .keepBoth
            }
            defer { ClipboardClashQuestion.ask = ask }

            await open(window, "Alpha", showing: ["README.md"])
            select(window, ["Alpha/README.md"])
            tab.perform(.copySelection)
            await open(window, "Beta", showing: ["README.md"])
            select(window, ["Beta/README.md"])
            tab.perform(.addToCopied)
            #expect(await waitUntil { tab.services.clipboard.contents.picks.count == 2 })
            #expect(
                asked == [
                    [
                        ClipboardNameClash(
                            path: path(window, "Beta/README.md"), otherPath: path(window, "Alpha/README.md"))
                    ]
                ])
            #expect(tab.services.clipboard.contents.renamedIfSharedPaths == [path(window, "Beta/README.md")])

            // The paste doesn't ask again: the one added takes a name of its own.
            await open(window, "Gamma")
            tab.perform(.pasteSelection)
            #expect(await waitUntil { window.exists("Gamma/README.md") && window.exists("Gamma/README copy.md") })
            #expect(try String(contentsOfFile: path(window, "Gamma/README.md"), encoding: .utf8) == "alpha")
            #expect(try String(contentsOfFile: path(window, "Gamma/README copy.md"), encoding: .utf8) == "beta")
            #expect(asked.count == 1)
            #expect(window.recorder.shown.isEmpty)
            await window.close()
        }

        @Test func useThisOneTakesTheOtherOffAndDontAddLeavesItOff() async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            try write(window, "Alpha/README.md", "alpha")
            try write(window, "Beta/README.md", "beta")
            /// What the question is answered with, changed between the Adds.
            final class Answer {
                var value = ClipboardClashAnswer.useThisOne
            }
            let answer = Answer()
            let ask = ClipboardClashQuestion.ask
            ClipboardClashQuestion.ask = { _, _ in answer.value }
            defer { ClipboardClashQuestion.ask = ask }

            await open(window, "Alpha", showing: ["README.md"])
            select(window, ["Alpha/README.md"])
            tab.perform(.copySelection)
            await open(window, "Beta", showing: ["README.md"])
            select(window, ["Beta/README.md"])
            tab.perform(.addToCut)
            #expect(
                await waitUntil { tab.services.clipboard.contents.sourcePaths == [path(window, "Beta/README.md")] })
            #expect(tab.services.clipboard.contents.mode == .cut)

            answer.value = .dontAdd
            await open(window, "Alpha", showing: ["README.md"])
            select(window, ["Alpha/README.md"])
            tab.perform(.addToCopied)
            // Asked and answered: nothing changed.
            try await Task.sleep(for: .milliseconds(100))
            #expect(tab.services.clipboard.contents.sourcePaths == [path(window, "Beta/README.md")])
            await window.close()
        }

        @Test func aCopyOverAGatheredClipboardOffersPutBack() async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            try write(window, "Alpha/a.txt")
            await open(window, "Alpha", showing: ["a.txt"])
            select(window, ["Alpha/a.txt"])
            tab.perform(.copySelection)
            await open(window, "Beta")
            select(window, ["Beta/Inner"])
            tab.perform(.addToCopied)
            let gathered = tab.services.clipboard.contents
            #expect(gathered.sourcePaths == [path(window, "Alpha/a.txt"), path(window, "Beta/Inner")])

            await open(window, "Gamma")
            select(window, ["Gamma/Inner"])
            tab.perform(.copySelection)
            #expect(tab.services.clipboard.contents.sourcePaths == [path(window, "Gamma/Inner")])
            let title = "Inner copied \u{B7} replaced 2 items on the clipboard"
            #expect(await toast(tab, title))
            let entry = try #require(tab.notifications?.toasts.entries.first { $0.title == title })
            #expect(entry.actionTitle == "Put Back")
            tab.notifications?.toasts.performAction(entry.id)
            #expect(tab.services.clipboard.contents == gathered)
            #expect(await toast(tab, "Put back 2 items on the clipboard"))
            // Put back, it is the clipboard built with Add again: a Copy keeps it once more. A Copy over that Copy, never
            // added to, keeps nothing.
            tab.perform(.copySelection)
            #expect(tab.services.clipboard.previous == gathered)
            tab.perform(.copySelection)
            #expect(tab.services.clipboard.previous == nil)
            await window.close()
        }

        @Test func removeFromClipboardAndSwitchingAnItemActOnWhatIsSelected() async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            window.select(["note.txt"])
            tab.perform(.cutSelection)
            #expect(tab.canPerform(.removeFromClipboard))
            tab.setClipboardMode([path(window, "note.txt")], to: .copy)
            #expect(tab.services.clipboard.contents.mode == .copy)
            tab.perform(.removeFromClipboard)
            #expect(!tab.services.clipboard.contents.hasItems)
            #expect(!tab.canPerform(.removeFromClipboard))
            await window.close()
        }
    }
}
