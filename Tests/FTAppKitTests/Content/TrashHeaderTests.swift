// The bar above the Trash on a real tab whose window is never shown, with a folder of the test's own as the Trash
import AppKit
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    @MainActor
    @Suite struct TrashHeaderTests {
        /// A tab on its folder, whose home folder is that folder, with a Trash holding one file and a folder.
        private func open() async throws -> (window: WritingWindow, trash: URL) {
            let window = try await WritingWindow.open()
            let trash = window.folder.appendingPathComponent(".Trash")
            try FileManager.default.createDirectory(
                at: trash.appendingPathComponent("Inner"), withIntermediateDirectories: true)
            try "x".write(to: trash.appendingPathComponent("gone.txt"), atomically: true, encoding: .utf8)
            window.tab.trashHomePath = window.folder.path
            window.tab.trashIsEmptyReader = { false }
            return (window, trash)
        }

        private func go(_ window: WritingWindow, to url: URL) async {
            window.tab.go(to: url)
            #expect(await waitUntil { window.tab.shownFolderPath == url.path && !window.tab.content.entries.isEmpty })
            window.harness.layout(window.tab)
        }

        private func header(_ window: WritingWindow) -> TrashHeaderView? {
            window.tab.content.contentShell.trashHeader
        }

        @Test func onlyTheTrashItselfHasTheBarAboveItsList() async throws {
            let (window, trash) = try await open()
            let shell = window.tab.content.contentShell
            #expect(header(window) == nil)
            let listTop = try #require(shell.list).frame.minY
            #expect(listTop == 0)

            await go(window, to: trash)
            let bar = try #require(header(window))
            #expect(bar.superview === shell)
            shell.layout()
            #expect(bar.frame.minY == 0)
            #expect(bar.frame.width == shell.bounds.width)
            #expect(try #require(shell.list).frame.minY == bar.frame.maxY)
            bar.layout()
            #expect(bar.emptyButton.title == "Empty")
            let inset = bar.bounds.width - bar.emptyButton.frame.maxX
            #expect(abs(inset - SearchLayout.standard.scopeBarPaddingHorizontal) < 0.01)

            window.tab.go(to: trash.appendingPathComponent("Inner"))
            #expect(await waitUntil { window.tab.shownFolderPath.hasSuffix("/.Trash/Inner") })
            #expect(header(window) == nil)

            await go(window, to: window.folder)
            #expect(header(window) == nil)
            shell.layout()
            #expect(try #require(shell.list).frame.minY == 0)
            await window.close()
        }

        @Test func emptyIsDimmedWithNothingToEraseAndNotWhenItCantBeTold() async throws {
            let (window, trash) = try await open()
            await go(window, to: trash)
            let button = try #require(header(window)).emptyButton
            #expect(await waitUntil { window.tab.trashIsEmpty == false })
            #expect(button.isEnabled)

            window.tab.trashIsEmptyReader = { true }
            window.tab.refreshTrashState()
            #expect(await waitUntil { !button.isEnabled })

            // Without Full Disk Access nothing says there is nothing to do, as Empty Trash in the menu has it.
            window.tab.trashIsEmptyReader = { nil }
            window.tab.refreshTrashState()
            #expect(await waitUntil { button.isEnabled })
            await window.close()
        }

        @Test func anOlderReadThatAnswersLateDoesNotReplaceANewerAnswer() async throws {
            let (window, trash) = try await open()
            await go(window, to: trash)
            #expect(await waitUntil { window.tab.trashIsEmpty == false })
            // The first read is held until the second has answered: it says "empty" too late to count.
            let held = DispatchSemaphore(value: 0)
            let answered = DispatchSemaphore(value: 0)
            window.tab.trashIsEmptyReader = {
                held.wait()
                defer { answered.signal() }
                return true
            }
            window.tab.refreshTrashState()
            window.tab.trashIsEmptyReader = { nil }
            window.tab.refreshTrashState()
            #expect(await waitUntil { window.tab.trashIsEmpty == nil })
            held.signal()
            await withCheckedContinuation { done in
                DispatchQueue.global().async {
                    answered.wait()
                    done.resume()
                }
            }
            // Its answer reaches the main actor a moment after the read ends.
            try await Task.sleep(for: .milliseconds(300))
            #expect(window.tab.trashIsEmpty == nil)
            await window.close()
        }

        @Test func emptyAsksFinderQuestionAndEmptiesOnYes() async throws {
            let (window, trash) = try await open()
            await go(window, to: trash)
            let button = try #require(header(window)).emptyButton
            var emptied = 0
            window.operations.emptyTrash = {
                emptied += 1
                return (true, nil)
            }
            var asked: [WriteQuestion] = []
            let answer = MainActorFlag()
            var dialogs = window.recorder.dialogs
            dialogs.confirm = { question, _ in
                asked.append(question)
                return answer.isSet
            }
            window.operations.dialogs = dialogs
            button.performClick(nil)
            #expect(await waitUntil { asked.count == 1 })
            #expect(asked.first?.confirmLabel == LocalWriteRules.emptyTrashQuestion.confirmLabel)
            await settle()
            #expect(emptied == 0)

            answer.isSet = true
            button.performClick(nil)
            #expect(await waitUntil { emptied == 1 })
            await window.close()
        }

        // Only the app itself is given Finder's Empty Trash: actions made without one erase nothing.
        @Test func actionsWithoutAnEmptyTrashEraseNothing() async throws {
            let window = try await WritingWindow.open()
            let session = try #require(window.tab.writeActions).session
            let result = await WindowWriteActions(session: session, tab: window.tab).emptyTrashRunner()
            #expect(!result.ok)
            await window.close()
        }

        @Test func searchResultsTakeTheBarsPlaceAndGiveItBack() async throws {
            let (window, trash) = try await open()
            await go(window, to: trash)
            let tab = window.tab
            let engine = FakeSearchEngine()
            let timers = ManualTimers()
            tab.search.session.engine = engine
            tab.search.session.timers = timers
            engine.finds = { _ in (["gone.txt"], false, false) }
            let field = try #require(tab.searchField)
            field.stringValue = "gone"
            tab.search.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
            timers.advance(0.4)
            #expect(await waitUntil { tab.content.contentShell.searchHeader != nil })
            #expect(header(window) == nil)

            tab.search.session.hideResults()
            #expect(tab.content.contentShell.searchHeader == nil)
            #expect(header(window) != nil)
            await window.close()
        }

        // After the toolbar comes Empty, when it can be pressed; from it, Tab is `paneTabSwitch` as from the results bar.
        @Test func tabLeavesTheToolbarForEmptyAndEmptyForTheTree() async throws {
            let (window, trash) = try await open()
            await go(window, to: trash)
            let tab = window.tab
            let nsWindow = try #require(tab.window)
            let button = try #require(header(window)).emptyButton
            #expect(await waitUntil { button.isEnabled })

            ToolbarKeyboard.enterFromEnd(of: nsWindow)
            let last = try #require(nsWindow.firstResponder as? NSView)
            ToolbarKeyboard.move(from: last, backward: false)
            #expect(nsWindow.firstResponder === button)

            let event = try #require(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: nsWindow.windowNumber, context: nil, characters: "\t",
                    charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48))
            button.keyDown(with: event)
            #expect(tab.sidebarController.isInside(nsWindow.firstResponder))

            tab.trashIsEmptyReader = { true }
            tab.refreshTrashState()
            #expect(await waitUntil { !button.isEnabled })
            ToolbarKeyboard.enterFromEnd(of: nsWindow)
            let lastAgain = try #require(nsWindow.firstResponder as? NSView)
            ToolbarKeyboard.move(from: lastAgain, backward: false)
            #expect(nsWindow.firstResponder === tab.content.focusView)
            await window.close()
        }
    }
}
