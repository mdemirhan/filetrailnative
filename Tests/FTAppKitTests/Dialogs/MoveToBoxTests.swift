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
            window.tab.updatePreferences(["favorites": .array([])])
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

        // ⇧⌘M opens Move To on the folder shown; Return does nothing until a folder is chosen; Choose… fills the field
        // from the picker; Move moves and the box closes.
        @Test func movesIntoTheFolderChosen() async throws {
            let window = try await open()
            var pickedFrom: [String?] = []
            let alpha = window.folder.appendingPathComponent("Alpha").path
            MainWindowController.pickDirectory = { path, _ in
                pickedFrom.append(path)
                return alpha
            }
            let box = try openMove(window, ["note.txt"])
            #expect(box.titleLabel?.stringValue == "Move To")
            #expect(box.field.accessibilityLabel() == "Destination folder")
            #expect(box.submitButton.title == "Move")
            #expect(!box.submitButton.isEnabled)
            #expect(box.browseButton?.title == "Choose…")
            #expect(box.rowViews.first(where: \.isSelected) == nil)
            #expect(window.tab.focusedPane == nil)
            DialogKeys.press(36, "\r", in: window.tab.window)
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
            await close(window)
        }

        // A destination that isn't a folder keeps the box open with the reason.
        @Test func refusesADestinationThatIsNotAFolder() async throws {
            let window = try await open()
            let box = try openMove(window, ["note.txt"])
            submit(box, window.folder.appendingPathComponent("Nowhere").path, in: window)
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
