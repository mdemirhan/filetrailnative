// Ports by feature what the wave-3-end checkpoint compared of the review and result sheets
// (CopyPasteReviewDialog.tsx, CopyPasteResultDialog.tsx and the .copy-paste-sheet-* rules of styles.css): the sheet
// growing with its rows, the rows' heights, the button it opens on, the list behind it, on an explorer window that is
// never shown, with the app's real file operations on a temporary folder
import AppKit
import FTFileSystem
import FTFoundation
import FTOperations
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    @MainActor
    @Suite(.windowlessAlone) struct CopyPasteSheetLookTests {
        private var reviews: CopyPasteReviewPresenter { CopyPasteReviewPresenter.shared }
        private var results: CopyPasteResultPresenter { CopyPasteResultPresenter.shared }

        private func write(_ window: WritingWindow, _ relative: String, _ text: String = "x") throws {
            try text.write(to: window.folder.appendingPathComponent(relative), atomically: true, encoding: .utf8)
        }

        private func reviewSheet(_ window: WritingWindow) async -> CopyPasteReviewSheet? {
            _ = await waitUntil { reviews.sheet?.window === window.tab.window && reviews.sheet?.window != nil }
            window.tab.window?.contentView?.layoutSubtreeIfNeeded()
            return reviews.sheet?.window === window.tab.window ? reviews.sheet : nil
        }

        /// Copies `names` and pastes them into `folder` (the tab goes there first).
        private func paste(_ names: [String], into folder: String, _ window: WritingWindow) async {
            let tab = window.tab
            let paths = names.map { window.folder.appendingPathComponent($0).path }
            tab.services.clipboard.set(ClipboardRules.set(.copy, paths, capturedAt: "t"), from: nil)
            tab.clipboardChanged()
            tab.go(to: window.folder.appendingPathComponent(folder))
            _ = await waitUntil { tab.folder.lastPathComponent == folder }
            tab.content.focusList()
            tab.perform(.pasteSelection)
        }

        // Add Missing lists the merged folder's conflicts under it: the sheet grows to show them all, as the original's
        // does, its footer below the last row. Each row after the first starts with its 1 pt line; a row of a name and
        // its detail is 48 tall (two lines of 15, 2 between, 8 above and below).
        // T-31ee02a9 T-fc88809d F-845 F-866 F-867 B-CLIP-087 B-CLIP-097
        @Test func theSheetGrowsWithItsRowsWhenAddMissingListsThem() async throws {
            let window = try await WritingWindow.open()
            try FileManager.default.createDirectory(
                at: window.folder.appendingPathComponent("Beta/Shared/icons"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: window.folder.appendingPathComponent("Shared/icons"), withIntermediateDirectories: true)
            try write(window, "Shared/notes.txt", "new")
            try write(window, "Shared/icons/star.svg", "new")
            try write(window, "Beta/Shared/notes.txt", "old")
            try write(window, "Beta/Shared/icons/star.svg", "old")
            await paste(["Shared"], into: "Beta", window)
            let sheet = try #require(await reviewSheet(window))
            let before = sheet.frame.height
            #expect(sheet.rowViewsShown.count == 1)
            sheet.bar?.control.pick(.addMissing)
            window.tab.window?.contentView?.layoutSubtreeIfNeeded()
            #expect(sheet.rowViewsShown.count == 4)
            #expect(sheet.frame.height > before)
            // Every row shows: the list's room is the rows' height.
            #expect(sheet.scroll.frame.height >= sheet.list.frame.height)
            let rows = sheet.rowViewsShown
            #expect(rows.allSatisfy { $0.frame.height == 48 })
            for (above, below) in zip(rows, rows.dropFirst()) { #expect(below.frame.minY == above.frame.maxY + 1) }
            #expect(sheet.list.separators.count == 3)
            DialogKeys.press(53, "\u{1b}", in: window.tab.window)
            await window.close()
        }

        // The sheet opens on its start button with no focus ring (it is marked by its fill); the ring comes once Tab
        // is used. The button's focus blurs the list, so its selection is gray under the sheet (`explorerFocusSuppressed`
        // keeps it so), and the list has the keyboard again once the sheet closes.
        // T-74d708a8 F-866 B-CLIP-105
        @Test func theStartButtonOpensWithoutARingAndTheListGoesGrayUnderIt() async throws {
            let window = try await WritingWindow.open()
            try write(window, "a.txt", "new a")
            try write(window, "b.txt", "new b")
            try write(window, "Alpha/a.txt", "old a")
            try write(window, "Alpha/b.txt", "old b")
            await paste(["a.txt", "b.txt"], into: "Alpha", window)
            let sheet = try #require(await reviewSheet(window))
            let tabWindow = try #require(window.tab.window)
            #expect(tabWindow.firstResponder === sheet.primaryButton)
            #expect(sheet.buttons.allSatisfy { $0.suppressesFocusRing })
            let list = try #require(window.tab.content.pane as? ListViewController)
            #expect(!list.hasKeyboard)
            DialogKeys.press(48, "\t", in: tabWindow)
            #expect(sheet.buttons.allSatisfy { !$0.suppressesFocusRing })
            DialogKeys.press(53, "\u{1b}", in: tabWindow)
            #expect(sheet.window == nil)
            #expect(tabWindow.firstResponder === list.focusView)
            #expect(list.hasKeyboard)
            await window.close()
        }

        // A row's choice reads Replace in red, its down chevron too (`.copy-paste-choice.is-danger` sets the color the
        // menu list's arrow is painted in); any other choice is in the primary color, chevron and all.
        // F-867 B-CLIP-087
        @Test func theChoiceChevronIsRedWhileItReadsReplace() {
            let palette = AppearanceModel.shared.theme.palette
            let popUp = ReviewChoicePopUp()
            popUp.set([.skip, .keepBoth, .overwrite], selected: .overwrite, blockedReason: nil, label: "Choice for a")
            #expect(popUp.titleColor == NSColor(palette.danger))
            #expect(popUp.chevronColor == NSColor(palette.danger))
            popUp.set([.skip, .keepBoth, .overwrite], selected: .skip, blockedReason: nil, label: "Choice for a")
            #expect(popUp.titleColor == NSColor(palette.textPrimary))
            #expect(popUp.chevronColor == NSColor(palette.textPrimary))
        }

        // The result sheet holds the folder's changes from outside, but the operation's own read of the folder goes
        // through under it: what was pasted shows behind the sheet.
        // F-871 B-CLIP-114 B-CLIP-137
        @Test func theFolderBehindTheResultSheetShowsWhatWasPasted() async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            let session = try #require(tab.writeActions?.session)
            let ui = try #require(WindowWriteUI.attached(to: session))
            try write(window, "Avatar.jsx", "pasted")
            let started = Date(timeIntervalSince1970: 0)
            let path = window.folder.appendingPathComponent("Avatar.jsx").path
            let items = [
                WriteOperationItem(sourcePath: "/src/Avatar.jsx", destinationPath: path, status: .completed),
                WriteOperationItem(
                    sourcePath: "/src/Other.jsx", destinationPath: nil, status: .failed, error: "No permission."),
            ]
            let result = WriteOperationResult(
                operationId: "op-1", action: .paste, status: .partial, targetPath: window.folder.path,
                startedAt: started, finishedAt: started,
                summary: CopyPasteOperationSummary(
                    topLevelItemCount: 2, totalItemCount: 2, completedItemCount: 1, failedItemCount: 1,
                    skippedItemCount: 0, cancelledItemCount: 0, completedByteCount: 0, totalBytes: nil),
                items: items, error: nil)
            let event = WriteOperationEvent(
                operationId: "op-1", action: .paste, status: .partial, totalItemCount: 2, result: result)
            // As the write's end does: the listings forgotten, the result, then the folder read again.
            tab.services.directoryService.cache.clear()
            ui.handle(.ended(event, inTabOnScreen: true))
            tab.reload()
            let sheet = try #require(results.sheet)
            #expect(tab.folderChangesHeld)
            #expect(await waitUntil { tab.content.entries.contains { $0.name == "Avatar.jsx" } })
            #expect(sheet.window != nil)
            #expect(tab.folderChangesHeld)
            sheet.doneButton.perform()
            #expect(!tab.folderChangesHeld)
            await window.close()
        }
    }
}
