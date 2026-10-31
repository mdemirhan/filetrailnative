// Ports by feature the cases of apps/desktop/src/renderer/components/{CopyPasteReviewDialog,
// CopyPasteRuntimeConflictDialog,CopyPasteResultDialog}.test.tsx and the sheet, conflict and result cases of
// App.pasteFlow.test.tsx, App.fileOperations.test.tsx ("copy/paste dialogs"), App.menusAndTree.test.tsx and
// App.undo.test.tsx: the copy and paste dialogs on an explorer window that is never shown, with the app's real file
// operations on a temporary folder
import AppKit
import FTFileSystem
import FTFoundation
import FTOperations
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    @MainActor
    @Suite(.windowlessAlone) struct CopyPasteDialogsTests {
        private var reviews: CopyPasteReviewPresenter { CopyPasteReviewPresenter.shared }
        private var results: CopyPasteResultPresenter { CopyPasteResultPresenter.shared }

        private func write(_ window: WritingWindow, _ relative: String, _ text: String = "x") throws {
            try text.write(to: window.folder.appendingPathComponent(relative), atomically: true, encoding: .utf8)
        }

        /// Puts `names` on the clipboard (copied, or cut) and pastes them into `folder`.
        private func paste(_ names: [String], into folder: String, _ window: WritingWindow, cut: Bool = false) async {
            let tab = window.tab
            let paths = names.map { window.folder.appendingPathComponent($0).path }
            tab.services.clipboard.set(ClipboardRules.set(cut ? .cut : .copy, paths, capturedAt: "t"), from: nil)
            tab.clipboardChanged()
            if tab.folder.lastPathComponent != folder {
                tab.go(to: window.folder.appendingPathComponent(folder))
                _ = await waitUntil { tab.folder.lastPathComponent == folder }
            }
            tab.perform(.pasteSelection)
        }

        private func reviewSheet(_ window: WritingWindow) async -> CopyPasteReviewSheet? {
            _ = await waitUntil { reviews.sheet?.window === window.tab.window && reviews.sheet?.window != nil }
            window.tab.window?.contentView?.layoutSubtreeIfNeeded()
            return reviews.sheet?.window === window.tab.window ? reviews.sheet : nil
        }

        private func group(of window: WritingWindow) -> ExplorerTabGroup? { window.tab.group }

        private func press(
            _ code: UInt16, _ characters: String, _ window: WritingWindow, _ modifiers: NSEvent.ModifierFlags = []
        ) {
            DialogKeys.press(code, characters, modifiers: modifiers, in: window.tab.window)
        }

        // covered-by-feature F-867 T-d7a7c28b T-6d9f49ef T-aae8fec2 (Replace refused where it can't be done, kept)
        // covered-by-feature F-867 T-f10b2d4f T-15f564ad (the first 300 rows, then "Show all N")
        // covered-by-feature F-868 T-f9bdb3fb (singular, plural and grouped counts: CopyPasteReviewTests)
        // covered-by-feature F-865 T-e2456922 (a large operation without conflicts: ReviewSheetText)
        // covered-by-feature F-681 T-f81ebbab T-42ef2e11 (when the review shows and which cut is cleared: paste flow)
        // The review lists only the conflicts, each skipped, with a plain start button that Return presses; what a
        // skip-everything paste did is told by a toast, and the copy stays on the clipboard. While the sheet is up the
        // window waits: its folder changes are held and it is a copy and paste dialog for the shortcuts.
        // T-970c7072 T-0a97d76f T-fb9b7b7d T-e46d1013 T-173cb040 F-679 F-681 F-865 F-866 F-867 F-868 B-CLIP-083 B-CLIP-084
        // B-CLIP-085 B-CLIP-089 B-CLIP-090 B-CLIP-100 B-CLIP-102 B-CLIP-103 B-CLIP-114
        // B-CLIP-076 B-CLIP-147 T-f9bdb3fb
        @Test func theReviewListsOnlyTheConflictsSkippedAndReturnStartsIt() async throws {
            let window = try await WritingWindow.open()
            try write(window, "a.txt", "new a")
            try write(window, "b.txt", "new b")
            try write(window, "c.txt", "new c")
            try write(window, "Alpha/a.txt", "old a")
            try write(window, "Alpha/b.txt", "old b")
            await paste(["a.txt", "b.txt", "c.txt"], into: "Alpha", window)
            let sheet = try #require(await reviewSheet(window))
            #expect(sheet.titleLabel.stringValue == "2 of 3 items already exist in \u{201C}Alpha\u{201D}")
            #expect(
                sheet.messageLabel.stringValue
                    == "Nothing is replaced unless you choose Replace. The other item will be added.")
            #expect(sheet.rowViewsShown.map { $0.row?.name } == ["a.txt", "b.txt"])
            #expect(sheet.rowViewsShown.map { $0.popUp.titleOfSelectedItem } == ["Skip", "Skip"])
            #expect(sheet.bar?.control.segments.map(\.title) == ["Skip", "Keep All", "Replace"])
            #expect(sheet.bar?.control.value == .skip)
            #expect(sheet.bar?.hint.stringValue == "Existing items stay as they are.")
            #expect(sheet.bar?.link.title == "Show 1 new item")
            #expect(sheet.note.text == "1 item will be added, 2 skipped")
            #expect(sheet.primaryButton.title == "Paste")
            #expect(sheet.primaryButton.isDefault)
            #expect(sheet.window?.firstResponder === sheet.primaryButton)
            #expect(sheet.frame.width == 680)
            #expect(sheet.frame.minY == 60)
            #expect(window.tab.folderChangesHeld)
            #expect(CopyPasteDialogs.isOpen(in: window.tab.window))
            #expect(window.tab.isDialogOpen)
            // The window waits: no drag, no tab change, and Merge All Windows is told it is busy (copyPasteModalOpen).
            let group = try #require(window.tab.group)
            #expect(window.tab.dragDrop.isBlocked)
            #expect(group.isBlocked)
            #expect(group.mergeAnswer.busy)
            // Return on the "Show 1 new item" link is the link's: the new item is listed, "Adds" on its right.
            window.tab.window?.makeFirstResponder(sheet.bar?.link)
            press(36, "\r", window)
            #expect(sheet.rowViewsShown.map { $0.row?.name } == ["a.txt", "b.txt", "c.txt"])
            #expect(sheet.rowViewsShown.last?.addsLabel.stringValue == "Adds")
            #expect(sheet.bar?.link.title == "Hide new items")
            window.tab.window?.makeFirstResponder(sheet.primaryButton)
            press(36, "\r", window)
            #expect(await waitUntil { window.exists("Alpha/c.txt") })
            #expect(await waitUntil { sheet.window == nil })
            #expect(!CopyPasteDialogs.isOpen(in: window.tab.window))
            #expect(!window.tab.folderChangesHeld)
            #expect(!group.isBlocked)
            let kept = try String(contentsOf: window.folder.appendingPathComponent("Alpha/a.txt"), encoding: .utf8)
            #expect(kept == "old a")
            #expect(window.tab.services.clipboard.contents.hasItems)
            await window.close()
        }

        // Replace is explicit: the rows go red and say what is replaced, the note warns of the Trash, the start button
        // reads "Replace 2 and Paste" in red, and Return no longer starts it. Escape and ⌘. close the sheet, nothing
        // started, the clipboard untouched.
        // T-0e8fba2f T-c9019c49 T-17fdca6f T-5909f6a0 T-5fd04cf4 T-98211d21 F-866 F-868 B-CLIP-088 B-CLIP-096
        // B-CLIP-101 B-CLIP-102 B-CLIP-103 B-CLIP-105
        // B-SEL-143 B-SEL-171 T-6d9f49ef
        @Test func replaceIsExplicitAndEscapeClosesTheSheet() async throws {
            let window = try await WritingWindow.open()
            try write(window, "a.txt", "new a")
            try write(window, "b.txt", "new b")
            try write(window, "Alpha/a.txt", "old a")
            try write(window, "Alpha/b.txt", "old b")
            await paste(["a.txt", "b.txt"], into: "Alpha", window)
            var sheet = try #require(await reviewSheet(window))
            sheet.bar?.control.pick(.overwrite)
            #expect(sheet.bar?.control.value == .overwrite)
            #expect(sheet.bar?.hint.stringValue == "Existing items go to the Trash.")
            #expect(sheet.rowViewsShown.allSatisfy { $0.isReplacing })
            #expect(
                sheet.rowViewsShown.first?.detailLabel.stringValue.hasPrefix("Replaces the existing 5 B file") == true)
            #expect(sheet.note.isWarning)
            #expect(sheet.note.text == "2 existing items will be moved to the Trash")
            #expect(sheet.primaryButton.title == "Replace 2 and Paste")
            #expect(sheet.primaryButton.isDestructive && !sheet.primaryButton.isDefault)
            window.tab.window?.makeFirstResponder(sheet.primaryButton)
            press(36, "\r", window)
            #expect(!sheet.starting)
            #expect(sheet.window != nil)
            // A row set back to Skip makes "For all" mixed; setting it to Replace again makes it Replace.
            sheet.rowViewsShown[0].popUp.selectItem(withTitle: "Skip")
            sheet.rowViewsShown[0].popUp.sendAction(sheet.rowViewsShown[0].popUp.action, to: sheet.rowViewsShown[0])
            #expect(sheet.bar?.control.value == nil)
            #expect(sheet.bar?.hint.stringValue == "Set separately for some items below.")
            #expect(sheet.primaryButton.title == "Replace 1 and Paste")
            press(53, "\u{1b}", window)
            #expect(sheet.window == nil)
            #expect(
                try String(contentsOf: window.folder.appendingPathComponent("Alpha/a.txt"), encoding: .utf8) == "old a")
            #expect(window.tab.services.clipboard.contents.hasItems)
            window.tab.perform(.pasteSelection)
            sheet = try #require(await reviewSheet(window))
            press(47, ".", window, .command)
            #expect(sheet.window == nil)
            await window.close()
        }

        // One folder that already exists is reviewed in the sheet, to show what is inside: Add Missing (only for a
        // copy with a folder) merges it, listing its conflicts nested under it; a move leaves Add Missing out.
        // T-31ee02a9 T-f2e7c2ec T-e31fa6aa T-fc88809d T-1b93aa4e T-6f170757 T-1b55dd36 T-958293d7 F-842 F-845 F-866 F-867
        // B-CLIP-087 B-CLIP-088 B-CLIP-091 B-CLIP-097
        // B-CLIP-081 B-CLIP-092
        @Test func oneFolderIsReviewedInTheSheetAndMergesWithAddMissing() async throws {
            let window = try await WritingWindow.open()
            try FileManager.default.createDirectory(
                at: window.folder.appendingPathComponent("Beta/Alpha/Inner"), withIntermediateDirectories: true)
            try write(window, "Alpha/Inner/x.txt", "new")
            try write(window, "Beta/Alpha/Inner/x.txt", "old")
            await paste(["Alpha"], into: "Beta", window)
            let sheet = try #require(await reviewSheet(window))
            #expect(sheet.titleLabel.stringValue == "\u{201C}Alpha\u{201D} already exists in \u{201C}Beta\u{201D}")
            #expect(sheet.bar?.control.segments.map(\.choice) == [.skip, .addMissing, .keepAll, .overwrite])
            sheet.bar?.control.pick(.addMissing)
            #expect(sheet.rowViewsShown.map { $0.row?.relativePath } == ["Alpha", "Alpha/Inner", "Alpha/Inner/x.txt"])
            #expect(sheet.rowViewsShown.map { $0.row?.depth } == [0, 1, 2])
            #expect(sheet.rowViewsShown[1].glyph.shape == .folder)
            #expect(sheet.rowViewsShown[2].popUp.accessibilityLabel() == "Choice for Alpha/Inner/x.txt")
            #expect(sheet.note.isWarning)
            #expect(sheet.note.text.hasSuffix("Merging can\u{2019}t be undone"))
            #expect(sheet.bar?.hint.stringValue == "Folders merge. Only files that aren\u{2019}t there yet are added.")
            // Keep Both on the file inside does what Keep All does; Skip again, what Add Missing gives it, is no choice of
            // its own.
            sheet.rowViewsShown[2].popUp.selectItem(withTitle: "Keep Both")
            sheet.rowViewsShown[2].popUp.sendAction(sheet.rowViewsShown[2].popUp.action, to: sheet.rowViewsShown[2])
            #expect(sheet.bar?.control.value == .keepAll)
            sheet.rowViewsShown[2].popUp.selectItem(withTitle: "Skip")
            sheet.rowViewsShown[2].popUp.sendAction(sheet.rowViewsShown[2].popUp.action, to: sheet.rowViewsShown[2])
            #expect(sheet.bar?.control.value == .addMissing)
            #expect(sheet.model.overrides.isEmpty)
            press(53, "\u{1b}", window)
            // The same folder moved: no Add Missing.
            await paste(["Alpha"], into: "Beta", window, cut: true)
            let move = try #require(await reviewSheet(window))
            #expect(move.bar?.control.segments.map(\.choice) == [.skip, .keepAll, .overwrite])
            #expect(move.primaryButton.title == "Move")
            press(53, "\u{1b}", window)
            await window.close()
        }

        // One file that already exists is asked about in a plain alert, as Finder does: Cancel aside, Replace in red,
        // Keep Both the default; Return keeps both.
        // T-928df937 T-540d0552 F-864 B-CLIP-106
        @Test func oneFileIsAskedAboutInAPlainAlertAndReturnKeepsBoth() async throws {
            let window = try await WritingWindow.open()
            try write(window, "Gamma/note.txt", "old")
            await paste(["note.txt"], into: "Gamma", window)
            _ = await waitUntil { reviews.alert?.window === window.tab.window }
            let alert = try #require(reviews.alert)
            #expect(alert.titleLabel.stringValue == "\u{201C}note.txt\u{201D} already exists in \u{201C}Gamma\u{201D}")
            #expect(alert.messageLabel?.stringValue == "Replace moves the item there to the Trash.")
            #expect(alert.asideButton?.title == "Cancel")
            #expect(alert.buttons.map(\.title) == ["Replace", "Keep Both"])
            #expect(alert.buttons[0].isDestructive)
            // Cancel stands apart (`alert-button-aside`): at the left of the first of three equal cells, as wide as
            // its title; Replace and Keep Both fill theirs.
            let cancel = try #require(alert.asideButton)
            let cell = alert.buttons[0].frame.width
            let spacing = alert.buttons[1].frame.minX - alert.buttons[0].frame.maxX
            #expect(abs(alert.buttons[1].frame.width - cell) < 0.5)
            #expect(abs(cancel.frame.minX + cell + spacing - alert.buttons[0].frame.minX) < 0.5)
            #expect(cancel.frame.width < cell)
            #expect(cancel.frame.width < CGFloat(SystemButton.minWidth))
            #expect(group(of: window)?.isBlocked == true)
            #expect(alert.defaultButton?.title == "Keep Both")
            #expect(window.tab.window?.firstResponder === alert.defaultButton)
            #expect(window.tab.folderChangesHeld)
            press(36, "\r", window)
            #expect(await waitUntil { window.exists("Gamma/note copy.txt") })
            #expect(await waitUntil { alert.window == nil })
            #expect(
                try String(contentsOf: window.folder.appendingPathComponent("Gamma/note.txt"), encoding: .utf8) == "old"
            )
            await window.close()
        }

        // The start is guarded: a second press while starting doesn't start again, and a start that failed (here,
        // an analysis that has gone) lets the button work again, the sheet still up, the failure told.
        // T-29c999ca T-58193def T-8bdec570 T-6eaf035c T-b4901e38 T-a82a26bd F-868 B-CLIP-104
        // B-CLIP-077
        @Test func theStartIsGuardedAndWorksAgainWhenItFailed() async throws {
            let window = try await WritingWindow.open()
            try write(window, "a.txt")
            try write(window, "b.txt")
            try write(window, "Alpha/a.txt")
            try write(window, "Alpha/b.txt")
            await paste(["a.txt", "b.txt"], into: "Alpha", window)
            let sheet = try #require(await reviewSheet(window))
            let actions = try #require(window.tab.writeActions)
            let report = sheet.model.report
            // Two presses: one start, busy meanwhile; once it runs the sheet goes.
            sheet.primaryButton.perform()
            #expect(sheet.starting)
            #expect(!sheet.primaryButton.isEnabled)
            sheet.primaryButton.perform()
            #expect(await waitUntil { sheet.window == nil })
            _ = await waitUntil { !actions.session.isWriteLocked }
            #expect(window.recorder.shown.isEmpty)
            // The analysis was used: a review of it fails to start, says why, and its button works again.
            reviews.review(
                report, action: .paste, policy: CopyPasteReview.safePolicy, clearsCutClipboard: nil, actions: actions)
            let again = try #require(await reviewSheet(window))
            again.primaryButton.perform()
            #expect(again.starting)
            #expect(await waitUntil { !again.starting })
            #expect(again.primaryButton.isEnabled)
            #expect(again.window != nil)
            #expect(window.tab.window?.firstResponder === again.primaryButton)
            #expect(window.recorder.shown.map(\.title) == ["Couldn\u{2019}t Paste"])
            press(53, "\u{1b}", window)
            await window.close()
        }

        // The question an operation paused on: a wide alert titled by what changed, the item there and the one on
        // its way compared, the safe answer the default on the right, Replace red only when something is there,
        // Stop at the left. One answer per alert: everything is disabled after the first; the question stays when
        // the answer can't be sent; a new conflict gets a fresh alert; it goes once the operation goes on.
        // T-122f8e46 T-3546bb92 T-e7be4c6a T-bed3d7c3 T-e40b3cf3 T-f0f5984a T-8dc8f8fa T-2e27c3d5 T-076e460a
        // T-511d3afb T-ce0f2f7d F-846 F-869 F-870 B-CLIP-117 B-CLIP-118 B-CLIP-119 B-CLIP-120 B-CLIP-121 B-CLIP-122
        // B-CLIP-123
        @Test func aPausedOperationAsksInAWideAlertAndTakesOneAnswer() async throws {
            let window = try await WritingWindow.open()
            let session = try #require(window.tab.writeActions?.session)
            let ui = try #require(WindowWriteUI.attached(to: session))
            func fingerprint(_ kind: CopyPasteNodeKind, exists: Bool = true) -> NodeFingerprint {
                NodeFingerprint(exists: exists, kind: kind, size: kind == .file ? 1536 : nil, mtimeMs: nil)
            }
            func ask(
                _ id: String, _ reason: RuntimeConflictReason, _ conflictClass: ConflictClass = .fileConflict,
                destination: NodeFingerprint? = nil, action: WriteOperationAction = .paste
            ) -> AlertCard? {
                let conflict = CopyPasteRuntimeConflict(
                    conflictId: id, analysisId: "analysis-1", sourcePath: "/src/report.txt",
                    destinationPath: "/Users/demo/Folder/report.txt", sourceKind: .file,
                    destinationKind: conflictClass == .directoryConflict ? .directory : .file,
                    conflictClass: conflictClass, reason: reason, sourceFingerprint: fingerprint(.file),
                    destinationFingerprint: fingerprint(.file), currentSourceFingerprint: fingerprint(.file),
                    currentDestinationFingerprint: destination ?? fingerprint(.file))
                ui.handle(
                    .progress(
                        WriteOperationEvent(
                            operationId: "copy-op-1", action: action, status: .awaitingResolution,
                            runtimeConflict: conflict)))
                window.tab.window?.contentView?.layoutSubtreeIfNeeded()
                return ui.runtimeConflicts.card
            }
            var alert = try #require(ask("q-1", .destinationCreated))
            #expect(
                alert.titleLabel.stringValue
                    == "\u{201C}report.txt\u{201D} appeared in \u{201C}Folder\u{201D} while pasting")
            #expect(
                alert.messageLabel?.stringValue
                    == "Another app created it after you reviewed this. Choose what to do with your item.")
            #expect(alert.buttons.map(\.title) == ["Replace", "Skip", "Keep Both"])
            #expect(alert.buttons[0].isDestructive)
            #expect(alert.defaultButton?.title == "Keep Both")
            #expect(alert.asideButton?.title == "Stop Pasting")
            #expect(alert.frame.width == 520)
            let accessory = try #require(ui.runtimeConflicts.accessory)
            #expect(accessory.cards.map(\.label.stringValue) == ["In \u{201C}Folder\u{201D} now", "Being pasted"])
            #expect(accessory.cards.map(\.facts.stringValue) == ["1.5 KB", "1.5 KB"])
            #expect(accessory.checkboxLabel.stringValue == "Do the same for similar changes while pasting")
            #expect(window.tab.folderChangesHeld)
            #expect(CopyPasteDialogs.isOpen(in: window.tab.window))
            #expect(window.tab.dragDrop.isBlocked)
            #expect(group(of: window)?.isBlocked == true)
            #expect(group(of: window)?.mergeAnswer.busy == true)
            // One answer: everything goes disabled; no operation takes it, so the question stays.
            alert.press("Keep Both")
            alert.press("Skip")
            #expect(alert.buttons.allSatisfy { !$0.isEnabled })
            #expect(alert.asideButton?.isEnabled == false)
            #expect(!accessory.checkbox.isEnabled)
            #expect(alert.window != nil)
            // A new conflict: a fresh alert. A folder offers Merge, says merging can't be undone.
            alert = try #require(
                ask("q-2", .destinationCreated, .directoryConflict, destination: fingerprint(.directory)))
            #expect(alert.buttons.allSatisfy { $0.isEnabled })
            #expect(alert.buttons.map(\.title) == ["Replace", "Keep Both", "Skip", "Merge"])
            #expect(alert.messageLabel?.stringValue.hasSuffix("Merging can\u{2019}t be undone.") == true)
            #expect(ui.runtimeConflicts.accessory?.cards.first?.facts.stringValue == "Folder")
            // Nothing there any more: go ahead (not red) or skip.
            alert = try #require(ask("q-3", .destinationDeleted, destination: fingerprint(.file, exists: false)))
            #expect(alert.buttons.map(\.title) == ["Skip", "Paste Anyway"])
            #expect(alert.buttons.allSatisfy { !$0.isDestructive })
            #expect(ui.runtimeConflicts.accessory?.cards.first?.facts.stringValue == "Not there anymore")
            #expect(alert.messageLabel?.stringValue.contains("Merging") == false)
            // The source gone: only Skip.
            alert = try #require(ask("q-4", .sourceDeleted, action: .copyTo))
            #expect(alert.buttons.map(\.title) == ["Skip"])
            #expect(alert.asideButton?.title == "Stop Copying")
            #expect(ui.runtimeConflicts.accessory?.cards.last?.label.stringValue == "Being copied")
            // No Trash: Skip is the default, Replace deletes permanently.
            alert = try #require(ask("q-5", .trashUnavailable))
            #expect(alert.buttons.map(\.title) == ["Delete Permanently", "Skip"])
            #expect(alert.defaultButton?.title == "Skip")
            #expect(
                ui.runtimeConflicts.accessory?.checkboxLabel.stringValue
                    == "Do the same for other items that can\u{2019}t be moved to the Trash while pasting")
            // The operation goes on: the question goes.
            ui.handle(.progress(WriteOperationEvent(operationId: "copy-op-1", action: .paste, status: .running)))
            #expect(alert.window == nil)
            #expect(!window.tab.folderChangesHeld)
            await window.close()
        }

        private func result(
            _ action: WriteOperationAction, _ items: [WriteOperationItem], status: WriteOperationStatus = .partial,
            target: String? = "/Users/demo/Folder"
        ) -> WriteOperationEvent {
            let started = Date(timeIntervalSince1970: 0)
            let result = WriteOperationResult(
                operationId: "op-1", action: action, status: status, targetPath: target, startedAt: started,
                finishedAt: started,
                summary: CopyPasteOperationSummary(
                    topLevelItemCount: items.count, totalItemCount: items.count,
                    completedItemCount: items.filter { $0.status == .completed }.count,
                    failedItemCount: items.filter { $0.status == .failed }.count,
                    skippedItemCount: items.filter { $0.status == .skipped }.count,
                    cancelledItemCount: items.filter { $0.status == .cancelled }.count, completedByteCount: 0,
                    totalBytes: nil), items: items, error: nil)
            return WriteOperationEvent(
                operationId: "op-1", action: action, status: status, totalItemCount: items.count, result: result)
        }

        // A copy that finished with problems: every problem with its reason, by section, and Retry for the failed
        // and never-started top-level items; a long section lists its first 200, then "and N more". Done and Escape
        // dismiss it. A move reminds where unmoved items are. No toast is added when the sheet shows.
        // T-2a36e31e T-b2344bac T-da9ef65a T-1d7468ca T-a6e8d77c T-46685522 T-7a16e7bd T-b40da6dc T-3f5f36eb
        // T-6129333b F-871 B-CLIP-134 B-CLIP-135 B-CLIP-136 B-CLIP-137 B-CLIP-139
        @Test func theResultSheetListsEveryProblemAndOffersRetry() async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            var event = result(
                .copyTo,
                [
                    WriteOperationItem(sourcePath: "/src/a.txt", destinationPath: "/d/a.txt", status: .completed),
                    WriteOperationItem(
                        sourcePath: "/src/b.txt", destinationPath: "/d/b.txt", status: .failed,
                        error: "You don\u{2019}t have permission."),
                    WriteOperationItem(sourcePath: "/src/c.txt", destinationPath: "/d/c.txt", status: .cancelled),
                    WriteOperationItem(
                        sourcePath: "/src/d.txt", destinationPath: "/d/d.txt", status: .skipped,
                        skipReason: .plannedConflictPolicy),
                ])
            let session = try #require(tab.writeActions?.session)
            let ui = try #require(WindowWriteUI.attached(to: session))
            let toasts = tab.notifications?.toasts.entries.count ?? 0
            ui.handle(.ended(event, inTabOnScreen: true))
            var sheet = try #require(results.sheet)
            #expect(sheet.window === tab.window)
            #expect(sheet.text.title == "Copied 1 of 4 items into \u{201C}Folder\u{201D}")
            #expect(
                sheet.messageLabel.stringValue
                    == "1 item couldn\u{2019}t be copied. 1 item wasn't started because the operation was stopped. 1 item was skipped."
            )
            #expect(
                sheet.sectionViews.map(\.titleLabel.stringValue) == ["Couldn\u{2019}t copy", "Not started", "Skipped"])
            #expect(sheet.sectionViews[0].rows.map(\.detail.stringValue) == ["You don\u{2019}t have permission."])
            #expect(sheet.sectionViews[2].rows.map(\.detail.stringValue) == ["Already existed \u{B7} you chose Skip"])
            #expect(sheet.buttons.map(\.title) == ["Retry 2 Items", "Done"])
            #expect(tab.window?.firstResponder === sheet.doneButton)
            #expect(tab.notifications?.toasts.entries.count ?? 0 == toasts)
            #expect(tab.folderChangesHeld)
            #expect(tab.dragDrop.isBlocked)
            #expect(group(of: window)?.isBlocked == true)
            #expect(group(of: window)?.mergeAnswer.busy == true)
            press(53, "\u{1b}", window)
            #expect(sheet.window == nil)
            // A move that failed whole, with 250 failures: the failure title, the reminder, the first 200 rows.
            let failures = (0..<250).map {
                WriteOperationItem(
                    sourcePath: "/src/f\($0).txt", destinationPath: nil, status: .failed, error: "The disk is full.")
            }
            event = result(.moveTo, failures, status: .failed, target: nil)
            results.present(event, in: tab)
            sheet = try #require(results.sheet)
            #expect(sheet.text.title == "Moved 0 of 250 items")
            #expect(sheet.text.message.hasSuffix("Items that weren't moved are still in their original folder."))
            #expect(sheet.sectionViews[0].rows.count == 200)
            #expect(sheet.sectionViews[0].moreLabel?.stringValue == "and 50 more")
            sheet.doneButton.perform()
            #expect(sheet.window == nil)
            #expect(!tab.folderChangesHeld)
            await window.close()
        }

        // A rename of several that skipped items says why, and offers Try Again… (which reopens the Rename sheet);
        // an Undo that left items as they were says so, with the shortcut that redoes it, and has no Retry.
        // T-e7a3f56a T-a972ec15 T-5689a456 T-dc33b10d T-d02cde47 T-97f261e6 T-8913287c T-c0c7cf73 T-8339f67a F-871
        // B-CLIP-137 B-CLIP-194
        @Test func renamesAndUndosTellWhatTheyLeftAndHowToGoOn() async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            let rename = result(
                .batchRename,
                [
                    WriteOperationItem(sourcePath: "/d/a.txt", destinationPath: "/d/x.txt", status: .completed),
                    WriteOperationItem(
                        sourcePath: "/d/b.txt", destinationPath: "/d/y.txt", status: .skipped,
                        error: "\u{201C}y.txt\u{201D} is taken."),
                ], target: "/d")
            results.present(rename, in: tab)
            var sheet = try #require(results.sheet)
            #expect(sheet.text.title == "Renamed 1 of 2 items in \u{201C}d\u{201D}")
            #expect(sheet.sectionViews.map(\.titleLabel.stringValue) == ["Skipped"])
            #expect(sheet.sectionViews[0].rows.map(\.detail.stringValue) == ["\u{201C}y.txt\u{201D} is taken."])
            #expect(sheet.buttons.map(\.title) == ["Try Again\u{2026}", "Done"])
            // The real button: the result sheet goes and the Rename sheet comes up on what wasn't renamed.
            sheet.retryButton?.perform()
            #expect(sheet.window == nil)
            let again = try #require(tab.batchRenameSheet)
            #expect(again.titleLabel.stringValue == "Rename 1 Item")
            again.onCancel()
            let undo = result(
                .undo,
                [
                    WriteOperationItem(sourcePath: "/Trash/a.txt", destinationPath: "/d/a.txt", status: .completed),
                    WriteOperationItem(
                        sourcePath: "/Trash/b.txt", destinationPath: "/d/b.txt", status: .skipped,
                        error: "Something else is there now."),
                ], target: nil)
            results.present(undo, in: tab)
            sheet = try #require(results.sheet)
            #expect(sheet.text.title == "Undid 1 of 2 items")
            #expect(sheet.text.message == "1 item was left as it is. \u{21E7}\u{2318}Z redoes what was undone.")
            #expect(sheet.sectionViews.map(\.titleLabel.stringValue) == ["Left as it is"])
            #expect(sheet.sectionViews[0].rows.map(\.path.stringValue) == ["b.txt"])
            #expect(sheet.buttons.map(\.title) == ["Done"])
            sheet.doneButton.perform()
            await window.close()
        }

        // Retry analyzes the failed and never-started top-level items again into the same folder; a folder that half
        // arrived is reviewed with the retry policy (files skipped, folders merged), so nothing is copied twice.
        // T-b4955a23 T-864f456d T-a70d7df5 T-e6d081d7 F-871 B-CLIP-138
        @Test func retryReviewsTheFailedItemsWithTheRetryPolicy() async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            try FileManager.default.createDirectory(
                at: window.folder.appendingPathComponent("Beta/Alpha/Inner"), withIntermediateDirectories: true)
            try write(window, "Alpha/Inner/x.txt", "new")
            try write(window, "Beta/Alpha/Inner/x.txt", "arrived")
            let source = window.folder.appendingPathComponent("Alpha").path
            let event = result(
                .copyTo,
                [
                    WriteOperationItem(
                        sourcePath: source, destinationPath: nil, status: .failed, childFailureCount: 1),
                    WriteOperationItem(
                        sourcePath: source + "/Inner/y.txt", destinationPath: nil, status: .failed, error: "Gone."),
                ], status: .failed, target: window.folder.appendingPathComponent("Beta").path)
            results.present(event, in: tab)
            let sheet = try #require(results.sheet)
            #expect(sheet.buttons.first?.title == "Retry 1 Item")
            sheet.retryButton?.perform()
            let review = try #require(await reviewSheet(window))
            #expect(review.model.policy == CopyPasteReview.retryPolicy)
            #expect(review.bar?.control.value == .addMissing)
            #expect(review.rowViewsShown.map { $0.row?.choice } == [.merge, .merge, .skip])
            press(53, "\u{1b}", window)
            await window.close()
        }
    }
}
