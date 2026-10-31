// Ports by feature the cases of apps/desktop/src/renderer/components/{ActionNoticeDialog,CopyPasteDialog,
// TextPromptDialog,UndoQuestionAlert,AppDialogs}.test.tsx and the tree's Trash confirmation of
// App.menusAndTree.test.tsx: the in-window alerts on a tab whose window is never shown
import AppKit
import FTFoundation
import FTOperations
import Foundation
import Testing

@testable import FTAppKit
@testable import FTFileSystem

extension ExplorerWindowlessTests {
    @MainActor
    @Suite struct AlertTests {
        private func open() async throws -> (ExplorerHarness, MainWindowController, NSWindow) {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            return (harness, tab, try #require(tab.window))
        }

        /// Asks `question` in the background; the answer comes once a button, Return or Escape gave it.
        private final class Answer {
            var value: Bool?
        }

        private func ask(_ question: WriteQuestion, in window: NSWindow) -> Answer {
            let answer = Answer()
            Task { @MainActor in answer.value = await InWindowAlerts.confirm(question, in: window) }
            return answer
        }

        private func card(_ tab: MainWindowController) async -> AlertCard? {
            _ = await waitUntil { tab.frontAlert != nil }
            tab.window?.contentView?.layoutSubtreeIfNeeded()
            return tab.frontAlert
        }

        // A notice has one OK, focused; a click outside does nothing; Return dismisses it, and the keys typed meanwhile
        // go nowhere.
        // T-ac167682 T-5d1384c4 F-872 B-NAV-217
        // B-SEL-170 B-TREE-191
        @Test func aNoticeHasOneFocusedOKAndClosesOnlyFromIt() async throws {
            let (harness, tab, window) = try await open()
            tab.showNotice(title: "Couldn’t Open", message: "Something went wrong.")
            let alert = try #require(await card(tab))
            #expect(alert.titleLabel.stringValue == "Couldn’t Open")
            #expect(alert.messageLabel?.stringValue == "Something went wrong.")
            #expect(alert.buttons.map(\.title) == ["OK"])
            #expect(window.firstResponder === alert.buttons[0])
            #expect(tab.canPerform(.goEnclosingFolder) == false)
            // A 272 wide card, centred; its buttons 28 tall.
            #expect(alert.frame.width == 272)
            #expect(alert.buttons[0].frame.height == 28)
            try #require(tab.dialogs.first).mouseDown(with: NSEvent())
            #expect(tab.frontAlert === alert)
            DialogKeys.press(0, "a", in: window)
            #expect(tab.frontAlert === alert)
            DialogKeys.press(36, "\r", in: window)
            #expect(await waitUntil { tab.frontAlert == nil })
            await harness.close()
        }

        // Move to Trash opens with its button focused; Return (or the button) confirms it, and the alert goes at once.
        // T-50080f20 T-c659113c T-89eb2fb5 T-c4830123 T-b0545566 F-872
        // B-CLIP-132 B-TREE-146
        @Test func moveToTrashIsConfirmedWithReturnAndClosesAtOnce() async throws {
            let (harness, tab, window) = try await open()
            let question = LocalWriteRules.trashQuestion([harness.folder.appending("Alpha").path])
            var answer = ask(question, in: window)
            var alert = try #require(await card(tab))
            #expect(alert.buttons.map(\.title) == ["Cancel", "Move to Trash"])
            #expect(alert.defaultButton?.title == "Move to Trash")
            #expect(window.firstResponder === alert.defaultButton)
            #expect(alert.defaultButton?.isDestructive == false)
            DialogKeys.press(36, "\r", in: window)
            #expect(tab.frontAlert == nil)
            #expect(await waitUntil { answer.value == true })
            answer = ask(question, in: window)
            alert = try #require(await card(tab))
            alert.press("Move to Trash")
            #expect(tab.frontAlert == nil)
            #expect(await waitUntil { answer.value == true })
            await harness.close()
        }

        // What can't be undone, and the dot name, open on Cancel.
        // T-e8357d8c T-e7e44bb0 T-f763b70f F-872 B-CLIP-198
        // B-CLIP-132 B-CLIP-133
        @Test func irreversibleQuestionsDefaultToCancel() async throws {
            let (harness, tab, window) = try await open()
            for question in [
                LocalWriteRules.deleteImmediatelyQuestion([harness.folder.appending("note.txt").path]),
                LocalWriteRules.emptyTrashQuestion, LocalWriteRules.dotNameQuestion,
                LocalWriteRules.deleteWithoutTrashQuestion([harness.folder.appending("note.txt").path]),
            ] {
                let answer = ask(question, in: window)
                let alert = try #require(await card(tab))
                #expect(alert.buttons.map(\.title) == [question.confirmLabel, "Cancel"])
                #expect(alert.defaultButton?.title == "Cancel")
                #expect(window.firstResponder === alert.defaultButton)
                #expect(alert.buttons[0].isDestructive == question.destructive)
                DialogKeys.press(36, "\r", in: window)
                #expect(await waitUntil { answer.value == false })
            }
            await harness.close()
        }

        // Tab goes round the alert's buttons and wraps; Escape answers Cancel.
        // T-26c267d3 T-f00c1c15 F-872
        // B-SEL-170 B-TREE-191
        @Test func tabStaysInsideTheAlertAndEscapeCancels() async throws {
            let (harness, tab, window) = try await open()
            let answer = ask(LocalWriteRules.trashQuestion([harness.folder.appending("Alpha").path]), in: window)
            let alert = try #require(await card(tab))
            #expect(alert.defaultButton?.suppressesFocusRing == true)
            DialogKeys.press(48, "\t", in: window)
            #expect(window.firstResponder === alert.buttons[0])
            #expect(alert.defaultButton?.suppressesFocusRing == false)
            DialogKeys.press(48, "\t", in: window)
            #expect(window.firstResponder === alert.buttons[1])
            DialogKeys.press(48, "\t", modifiers: .shift, in: window)
            #expect(window.firstResponder === alert.buttons[0])
            DialogKeys.press(53, "\u{1b}", in: window)
            #expect(await waitUntil { answer.value == false })
            await harness.close()
        }

        // T-5495c714 T-32447e02 F-880 F-881 B-CLIP-188 B-CLIP-189 B-CLIP-190 B-CLIP-191
        @Test func theUndoQuestionListsTheNamesWithItsDefault() async throws {
            let (harness, tab, window) = try await open()
            let names = (1...7).map { "File \($0).txt" }
            let taken = WindowWriteActions.undoQuestion(.nameTaken(names: names), .undo, .rename)
            var answer = ask(taken, in: window)
            var alert = try #require(await card(tab))
            #expect(alert.buttons.map(\.title) == ["Cancel", "Keep Both"])
            #expect(alert.defaultButton?.title == "Keep Both")
            let list = try #require(alert.content.accessory as? DetailListView)
            #expect(list.rows.map(\.stringValue) == Array(names.prefix(5)) + ["and 2 more"])
            DialogKeys.press(36, "\r", in: window)
            #expect(await waitUntil { answer.value == true })
            let changed = WindowWriteActions.undoQuestion(
                .changed(items: [UndoQuestion.ChangedItem(name: "a.txt", putBack: true, replaced: false)]), .undo,
                .trash)
            answer = ask(changed, in: window)
            alert = try #require(await card(tab))
            #expect(alert.buttons.map(\.title) == ["Move to Trash", "Cancel"])
            #expect(alert.defaultButton?.title == "Cancel")
            #expect(alert.buttons[0].isDestructive == false)
            #expect(alert.content.accessory == nil)
            DialogKeys.press(53, "\u{1b}", in: window)
            #expect(await waitUntil { answer.value == false })
            await harness.close()
        }

        // The name prompt selects the whole name, can't submit an empty one, keeps what was typed with the reason under
        // it, and starts again from the name when it opens again.
        // T-debddd61 T-2c3367f6 T-1d6d1c20 T-8a6aa0b0 T-00961b8a F-882 F-883 B-SEL-124
        @Test func theNamePromptSelectsTheNameAndShowsWhyItWasRefused() async throws {
            let (harness, tab, window) = try await open()
            let path = harness.folder.appending("Alpha").path
            var submitted: [String] = []
            var done = false
            Task { @MainActor in
                await InWindowAlerts.askName(.rename(path), in: window) { name in
                    submitted.append(name)
                    return name == "Taken" ? .refuse("An item named “Taken” already exists.") : .close
                }
                done = true
            }
            var alert = try #require(await card(tab))
            var prompt = try #require(alert.content.accessory as? TextPromptAccessory)
            #expect(alert.titleLabel.stringValue == "Rename “Alpha”")
            #expect(alert.buttons.map(\.title) == ["Cancel", "Rename"])
            #expect(prompt.holdsKeyboard)
            #expect(prompt.field.currentEditor()?.selectedRange == NSRange(location: 0, length: 5))
            prompt.field.stringValue = "  "
            prompt.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
            #expect(alert.defaultButton?.isEnabled == false)
            DialogKeys.press(36, "\r", in: window)
            #expect(submitted.isEmpty)
            prompt.field.stringValue = " Taken "
            prompt.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
            DialogKeys.press(36, "\r", in: window)
            #expect(await waitUntil { !prompt.errorLabel.isHidden })
            #expect(submitted == ["Taken"])
            #expect(prompt.errorLabel.stringValue == "An item named “Taken” already exists.")
            #expect(prompt.field.stringValue == " Taken ")
            #expect(tab.frontAlert === alert)
            DialogKeys.press(53, "\u{1b}", in: window)
            #expect(await waitUntil { done })
            // Opened again, it starts from the name.
            done = false
            Task { @MainActor in
                await InWindowAlerts.askName(.newFolder(in: path, initialName: "untitled folder"), in: window) { _ in
                    .close
                }
                done = true
            }
            alert = try #require(await card(tab))
            prompt = try #require(alert.content.accessory as? TextPromptAccessory)
            #expect(alert.titleLabel.stringValue == "New Folder")
            #expect(alert.messageLabel?.stringValue == "In “Alpha”")
            #expect(prompt.field.stringValue == "untitled folder")
            #expect(prompt.field.currentEditor()?.selectedRange == NSRange(location: 0, length: 15))
            // Tab goes round the field and the two buttons.
            DialogKeys.press(48, "\t", in: window)
            #expect(window.firstResponder === alert.buttons[0])
            DialogKeys.press(48, "\t", in: window)
            DialogKeys.press(48, "\t", in: window)
            #expect(prompt.holdsKeyboard)
            alert.press("Create Folder")
            #expect(await waitUntil { done })
            await harness.close()
        }

        // A rename that failed is told by its reason alone, once, under "Rename", with no "0 of 1 item done".
        // T-00cac55d
        @Test func aFailedRenameIsToldByItsReasonAlone() async throws {
            let (harness, tab, _) = try await open()
            let error = "An item named “b.txt” already exists."
            let started = Date(timeIntervalSince1970: 0)
            let result = WriteOperationResult(
                operationId: "write-op-1", action: .rename, status: .failed, targetPath: nil, startedAt: started,
                finishedAt: started.addingTimeInterval(1),
                summary: CopyPasteOperationSummary(
                    topLevelItemCount: 1, totalItemCount: 1, completedItemCount: 0, failedItemCount: 1,
                    skippedItemCount: 0, cancelledItemCount: 0, completedByteCount: 0, totalBytes: nil),
                items: [
                    WriteOperationItem(
                        sourcePath: "/tmp/a.txt", destinationPath: "/tmp/b.txt", status: .failed, error: error)
                ], error: error)
            PlainResultNotice().present(
                WriteOperationEvent(
                    operationId: "write-op-1", action: .rename, status: .failed, totalItemCount: 1, result: result),
                in: tab)
            let alert = try #require(await card(tab))
            #expect(alert.titleLabel.stringValue == "Rename")
            #expect(alert.buttons.map(\.title) == ["OK"])
            let lines = (alert.content.accessory as? DetailListView)?.rows.map(\.stringValue) ?? []
            let text = ([alert.titleLabel.stringValue, alert.messageLabel?.stringValue ?? ""] + lines).joined(
                separator: "\n")
            #expect(text.components(separatedBy: error).count == 2)
            #expect(!text.contains("of 1 item"))
            await harness.close()
        }

        // The eject questions stack their three buttons, the default on top; Escape cancels.
        // F-884 F-885 B-TREE-170 B-TREE-171 B-TREE-172
        @Test func theEjectQuestionsStackTheirButtons() async throws {
            let (harness, tab, window) = try await open()
            let presenter = InWindowEjectPresenter(window: { window })
            var which: EjectWhichVolumesAnswer?
            presenter.askWhichVolumes(name: "Data", otherNames: ["Backup"]) { which = $0 }
            var alert = try #require(await card(tab))
            #expect(alert.buttons.map(\.title) == ["Eject All", "Eject", "Cancel"])
            #expect(alert.content.isStacked)
            #expect(alert.defaultButton === alert.buttons[0])
            #expect(alert.buttons[0].frame.minY < alert.buttons[1].frame.minY)
            #expect(alert.buttons[0].frame.width == alert.buttons[1].frame.width)
            DialogKeys.press(53, "\u{1b}", in: window)
            #expect(await waitUntil { which == .cancel })
            var busy: EjectBusyAnswer?
            presenter.askBusy(EjectNotice(title: "Busy", message: "In use.")) { busy = $0 }
            alert = try #require(await card(tab))
            #expect(alert.buttons.map(\.title) == ["Try Again", "Force Eject", "Cancel"])
            #expect(alert.buttons[1].isDestructive)
            DialogKeys.press(36, "\r", in: window)
            #expect(await waitUntil { busy == .retry })
            presenter.show(EjectNotice(title: "Couldn’t Eject", message: "No."))
            alert = try #require(await card(tab))
            #expect(alert.buttons.map(\.title) == ["OK"])
            alert.press("OK")
            #expect(await waitUntil { tab.frontAlert == nil })
            await harness.close()
        }
    }
}
