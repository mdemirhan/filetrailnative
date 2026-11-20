// The Move To box of a windowless tab with the app's file operations
import AppKit
import FTFileSystem
import FTFoundation
import FTOperations
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    @MainActor
    @Suite(.restoresWindowSeams) struct MoveToBoxTests {
        private func open() async throws -> WritingWindow {
            let window = try await WritingWindow.open()
            window.tab.updatePreferences { $0.favorites = [] }
            let store = window.harness.store
            MainWindowController.visitStore = { store }
            return window
        }

        private func close(_ window: WritingWindow) async {
            await window.close()
        }

        private func openMove(_ window: WritingWindow, _ names: [String]) throws -> GoToFolderBox {
            window.select(names)
            window.tab.perform(.moveSelection)
            let box = try #require(window.tab.goToBox)
            window.tab.window?.contentView?.layoutSubtreeIfNeeded()
            return box
        }

        private func submit(_ box: GoToFolderBox, _ text: String, in window: WritingWindow) {
            DialogKeys.type(text, into: box)
            DialogKeys.press(36, "\r", in: window.tab.window)
        }

        /// The folder as the box shows it: from "~", ending in "/".
        private func shown(_ path: String) -> String {
            Places.abbreviate(path, homePath: FileManager.default.homeDirectoryForCurrentUser.path) + "/"
        }

        // ⇧⌘M opens Move To on the folder shown, all of it selected; Return there says the item is in it already;
        // Choose… fills the field from the picker; Move moves, the box closes and the folder is remembered.
        @Test func movesIntoTheFolderChosen() async throws {
            let window = try await open()
            var pickedFrom: [String?] = []
            let alpha = window.folder.appendingPathComponent("Alpha").path
            MainWindowController.pickDirectory = { path, _ in
                pickedFrom.append(path)
                return alpha
            }
            let box = try openMove(window, ["note.txt"])
            #expect(box.titleLabel?.stringValue == "Move \u{201C}note.txt\u{201D} To")
            #expect(box.field.accessibilityLabel() == "Destination folder")
            #expect(box.submitButton.title == "Move")
            #expect(box.field.stringValue == shown(window.folder.path))
            let editor = try #require(box.field.currentEditor())
            #expect(editor.selectedRange == NSRange(location: 0, length: (box.field.stringValue as NSString).length))
            #expect(box.submitButton.isEnabled)
            #expect(box.browseButton?.title == "Choose…")
            #expect(box.rowViews.first(where: \.isSelected) == nil)
            #expect(window.tab.focusedPane == nil)
            DialogKeys.press(36, "\r", in: window.tab.window)
            #expect(
                await waitUntil { box.errorLabel.stringValue == "\u{201C}note.txt\u{201D} is already in this folder." })
            #expect(window.exists("note.txt"))
            #expect(window.tab.goToBox === box)
            try #require(box.browseButton).perform()
            #expect(await waitUntil { box.field.stringValue == alpha })
            #expect(pickedFrom == [window.tab.folder.path])
            #expect(box.submitButton.isEnabled)
            DialogKeys.press(36, "\r", in: window.tab.window)
            #expect(await waitUntil { window.exists("Alpha/note.txt") })
            #expect(!window.exists("note.txt"))
            #expect(await waitUntil { window.tab.goToBox == nil })
            #expect(window.harness.store.destinations().map(\.path) == [alpha])
            await close(window)
        }

        // A destination typed through an input method (Japanese, Chinese, Korean input): Return and Escape while it
        // composes are its own, so nothing moves and the box stays. Once the text is the field's own, Return moves.
        @Test func returnAndEscapeAreTheInputMethodsWhileItComposes() async throws {
            let window = try await open()
            let box = try openMove(window, ["note.txt"])
            let alpha = window.folder.appendingPathComponent("Alpha").path
            try DialogKeys.compose(alpha, in: box.field)
            DialogKeys.press(KeyCode.returnKey, "\r", in: window.tab.window)
            for _ in 0..<5 { await Task.yield() }
            #expect(!box.state.submitting)
            #expect(window.exists("note.txt"))
            #expect(window.tab.goToBox === box)
            try DialogKeys.compose(alpha, in: box.field)
            DialogKeys.press(KeyCode.escape, "\u{1b}", in: window.tab.window)
            #expect(window.tab.goToBox === box)
            try DialogKeys.compose(alpha, in: box.field).unmarkText()
            DialogKeys.press(KeyCode.returnKey, "\r", in: window.tab.window)
            #expect(await waitUntil { window.exists("Alpha/note.txt") })
            #expect(await waitUntil { window.tab.goToBox == nil })
            await close(window)
        }

        // A folder that isn't there, in one that is, is offered to be made: the button says Create and Move, and the
        // next Return makes it and moves the item into it. Typing something else takes the offer back.
        @Test func makesAFolderThatIsNotThereYet() async throws {
            let window = try await open()
            let box = try openMove(window, ["note.txt"])
            let nowhere = window.folder.appendingPathComponent("Nowhere").path
            submit(box, nowhere, in: window)
            #expect(await waitUntil { box.submitButton.title == "Create and Move" })
            #expect(
                box.errorLabel.stringValue
                    == "There\u{2019}s no folder \u{201C}Nowhere\u{201D} there yet: Create and Move makes it first.")
            #expect(!window.exists("Nowhere"))
            DialogKeys.type(nowhere + "2", into: box)
            #expect(box.submitButton.title == "Move")
            #expect(box.errorLabel.isHidden)
            submit(box, nowhere, in: window)
            #expect(await waitUntil { box.submitButton.title == "Create and Move" })
            DialogKeys.press(36, "\r", in: window.tab.window)
            #expect(await waitUntil { window.exists("Nowhere/note.txt") })
            #expect(await waitUntil { window.tab.goToBox == nil })
            #expect(!window.exists("note.txt"))
            await close(window)
        }

        // A destination that is a file, or in a folder that isn't there, keeps the box open with the reason.
        @Test func refusesADestinationThatIsNotAFolder() async throws {
            let window = try await open()
            let box = try openMove(window, ["note.txt"])
            submit(box, window.folder.appendingPathComponent("Nowhere/Deeper").path, in: window)
            #expect(await waitUntil { box.errorLabel.stringValue == "Destination must be an existing folder." })
            #expect(window.tab.goToBox === box)
            #expect(box.cancelButton.isEnabled)
            submit(box, window.folder.appendingPathComponent("note.txt").path, in: window)
            #expect(await waitUntil { !box.state.submitting })
            #expect(box.errorLabel.stringValue == "Destination must be an existing folder.")
            #expect(window.exists("note.txt"))
            await close(window)
        }

        // What the analysis refuses (moving into the folder the item is in, a folder into itself, an item gone
        // meanwhile) is said under the field and the box stays.
        @Test func keepsTheBoxOpenWhenTheAnalysisRefuses() async throws {
            let window = try await open()
            var box = try openMove(window, ["note.txt"])
            submit(box, window.folder.path, in: window)
            #expect(await waitUntil { !box.errorLabel.isHidden })
            #expect(window.tab.goToBox === box)
            DialogKeys.press(53, "\u{1b}", in: window.tab.window)
            box = try openMove(window, ["Alpha"])
            submit(box, window.folder.appendingPathComponent("Alpha/Inner").path, in: window)
            #expect(await waitUntil { !box.errorLabel.isHidden })
            #expect(window.exists("Alpha/Inner"))
            DialogKeys.press(53, "\u{1b}", in: window.tab.window)
            box = try openMove(window, ["note.txt"])
            try FileManager.default.removeItem(at: window.folder.appendingPathComponent("note.txt"))
            submit(box, window.folder.appendingPathComponent("Beta").path, in: window)
            #expect(await waitUntil { !box.errorLabel.isHidden })
            #expect(window.tab.goToBox === box)
            await close(window)
        }

        // A folder that isn't there yet, typed inside the item being moved or in the Trash, is refused before it is
        // offered to be made: made first, it was left behind when the move was then refused.
        @Test func makesNoFolderInsideTheItemMovedOrInTheTrash() async throws {
            let window = try await open()
            var box = try openMove(window, ["Alpha"])
            submit(box, window.folder.appendingPathComponent("Alpha/New").path, in: window)
            #expect(
                await waitUntil {
                    box.errorLabel.stringValue == "\u{201C}Alpha\u{201D} can\u{2019}t be moved into itself."
                })
            #expect(box.submitButton.title == "Move")
            DialogKeys.press(36, "\r", in: window.tab.window)
            await settle()
            #expect(!window.exists("Alpha/New"))
            DialogKeys.press(53, "\u{1b}", in: window.tab.window)
            if window.tab.goToBox != nil { DialogKeys.press(53, "\u{1b}", in: window.tab.window) }

            let trash = window.folder.appendingPathComponent(".Trash")
            try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
            window.tab.trashHomePath = window.folder.path
            box = try openMove(window, ["note.txt"])
            submit(box, trash.appendingPathComponent("New").path, in: window)
            #expect(await waitUntil { box.errorLabel.stringValue == "Items can\u{2019}t be moved into the Trash." })
            #expect(box.submitButton.title == "Move")
            #expect(!window.exists(".Trash/New") && window.exists("note.txt"))
            await close(window)
        }

        // With another operation running the start is refused under the field; the list's commands wait while the box
        // is up.
        @Test func saysAnotherOperationRunsAndTheListWaits() async throws {
            let window = try await open()
            let box = try openMove(window, ["note.txt"])
            #expect(!window.tab.canPerform(.trashSelection))
            #expect(!window.tab.canPerform(.duplicateSelection))
            let session = try #require(window.tab.group.map { window.operations.session(for: $0) })
            session.applyCard(WriteOperationCardState(action: .copyTo, stage: .running, targetPath: "/x"))
            submit(box, window.folder.appendingPathComponent("Alpha").path, in: window)
            #expect(await waitUntil { box.errorLabel.stringValue == WriteDialogs.busyMessage })
            #expect(window.exists("note.txt"))
            session.applyCard(nil)
            DialogKeys.press(53, "\u{1b}", in: window.tab.window)
            // Busy before it opens: the notice, and no box.
            session.applyCard(WriteOperationCardState(action: .copyTo, stage: .running, targetPath: "/x"))
            window.tab.perform(.moveSelection)
            #expect(window.tab.goToBox == nil)
            #expect(window.recorder.shown.map(\.title) == ["Couldn’t Move"])
            session.applyCard(nil)
            await close(window)
        }
    }
}
