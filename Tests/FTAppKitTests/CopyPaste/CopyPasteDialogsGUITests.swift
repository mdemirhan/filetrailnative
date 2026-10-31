// Ports the focus cases of components/{CopyPasteReviewDialog,CopyPasteRuntimeConflictDialog,CopyPasteResultDialog}
// .test.tsx and App.fileOperations.test.tsx ("copy/paste dialogs") on a real explorer window on screen: Tab kept inside
// the sheet or the alert, and the keyboard given back when it closes
import AppKit
import FTFileSystem
import FTFoundation
import FTOperations
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowGUITests {
    @MainActor
    @Suite struct CopyPasteDialogsGUITests {
        /// A window on screen with the app's file operations.
        private func open() async throws -> (ExplorerHarness, MainWindowController, AppWriteOperations) {
            PreparingSheet.isEnabled = false
            let harness = try ExplorerHarness()
            let tab = try await harness.open()
            let operations = AppWriteOperations(
                userData: harness.folder.url, directoryService: DirectoryService(), windows: harness.windows,
                trash: .standIn,
                log: { _ in })
            operations.dialogs = DialogRecorder().dialogs
            return (harness, tab, operations)
        }

        private func pressTab(_ window: NSWindow?) {
            DialogKeys.press(48, "\t", in: window)
        }

        // Tab goes round the sheet's controls (the "For all" choice, each row's popup, Cancel, the start button) and
        // stays inside it; Escape closes it and the keyboard goes back where it was.
        // T-74d708a8 T-c37d1a82 F-866 F-867 F-868 B-CLIP-105
        // B-SEL-171
        @Test func tabStaysInsideTheReviewSheetAndFocusComesBack() async throws {
            let (harness, tab, operations) = try await open()
            let folder = harness.folder.url
            for name in ["a.txt", "b.txt", "Alpha/a.txt", "Alpha/b.txt"] {
                try "x".write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
            }
            let window = try #require(tab.window)
            tab.content.focusList()
            let before = window.firstResponder
            let actions = try #require(tab.writeActions)
            let paths = ["a.txt", "b.txt"].map { folder.appendingPathComponent($0).path }
            actions.putOnClipboard(.copy, paths: paths)
            await actions.pasteFromClipboard(into: folder.appendingPathComponent("Alpha").path)
            #expect(await waitUntil { CopyPasteReviewPresenter.shared.sheet?.window === window })
            let sheet = try #require(CopyPasteReviewPresenter.shared.sheet)
            #expect(window.firstResponder === sheet.primaryButton)
            let order = sheet.focusOrder()
            #expect(order.count == 5)
            for expected in order + [order[0]] {
                pressTab(window)
                #expect(window.firstResponder === expected)
            }
            DialogKeys.press(53, "\u{1b}", in: window)
            #expect(sheet.window == nil)
            #expect(window.firstResponder === before)
            withExtendedLifetime(operations) {}
            await harness.close()
        }

        // Tab goes round the conflict alert's controls, "Do the same for similar changes" and Stop included, and
        // stays inside it: from Keep Both it wraps to the checkbox, and ⇧Tab comes back.
        // T-f3bfcf55 F-869 B-CLIP-123
        @Test func tabStaysInsideTheRuntimeConflictAlert() async throws {
            let (harness, tab, operations) = try await open()
            let session = try #require(tab.writeActions?.session)
            let ui = try #require(WindowWriteUI.attached(to: session))
            let file = NodeFingerprint(exists: true, kind: .file, size: 10)
            let conflict = CopyPasteRuntimeConflict(
                conflictId: "q-1", analysisId: "analysis-1", sourcePath: "/src/a.txt", destinationPath: "/d/a.txt",
                sourceKind: .file, destinationKind: .file, conflictClass: .fileConflict, reason: .destinationChanged,
                sourceFingerprint: file, destinationFingerprint: file, currentSourceFingerprint: file,
                currentDestinationFingerprint: file)
            ui.handle(
                .progress(
                    WriteOperationEvent(
                        operationId: "op-1", action: .paste, status: .awaitingResolution, runtimeConflict: conflict)))
            let alert = try #require(ui.runtimeConflicts.card)
            let window = try #require(tab.window)
            let checkbox = try #require(ui.runtimeConflicts.accessory?.checkbox)
            #expect(window.firstResponder === alert.defaultButton)
            pressTab(window)
            #expect(window.firstResponder === checkbox)
            DialogKeys.press(48, "\t", modifiers: .shift, in: window)
            #expect(window.firstResponder === alert.defaultButton)
            var seen: [String] = []
            for _ in 0..<5 {
                pressTab(window)
                if let button = window.firstResponder as? SystemButton, button.isDescendant(of: alert) {
                    seen.append(button.title)
                } else if window.firstResponder === checkbox {
                    seen.append("checkbox")
                }
            }
            #expect(seen.count == 5)
            #expect(Set(seen) == ["checkbox", "Stop Pasting", "Replace", "Skip", "Keep Both"])
            ui.runtimeConflicts.dismiss()
            withExtendedLifetime(operations) {}
            await harness.close()
        }

        // Tab goes between Retry and Done, and stays in the result sheet; Escape dismisses it and the keyboard goes
        // back where it was.
        // T-bea8e90e T-6129333b F-871 B-CLIP-137 B-CLIP-139
        @Test func tabStaysInsideTheResultSheetAndFocusComesBack() async throws {
            let (harness, tab, operations) = try await open()
            let window = try #require(tab.window)
            tab.content.focusList()
            let before = window.firstResponder
            let started = Date(timeIntervalSince1970: 0)
            let items = [
                WriteOperationItem(sourcePath: "/src/a.txt", destinationPath: nil, status: .failed, error: "No.")
            ]
            let result = WriteOperationResult(
                operationId: "op-1", action: .paste, status: .failed, targetPath: "/d", startedAt: started,
                finishedAt: started,
                summary: CopyPasteOperationSummary(
                    topLevelItemCount: 1, totalItemCount: 1, completedItemCount: 0, failedItemCount: 1,
                    skippedItemCount: 0, cancelledItemCount: 0, completedByteCount: 0, totalBytes: nil),
                items: items, error: nil)
            CopyPasteResultPresenter.shared.present(
                WriteOperationEvent(operationId: "op-1", action: .paste, status: .failed, result: result), in: tab)
            let sheet = try #require(CopyPasteResultPresenter.shared.sheet)
            #expect(window.firstResponder === sheet.doneButton)
            pressTab(window)
            #expect(window.firstResponder === sheet.retryButton)
            pressTab(window)
            #expect(window.firstResponder === sheet.doneButton)
            DialogKeys.press(53, "\u{1b}", in: window)
            #expect(sheet.window == nil)
            #expect(window.firstResponder === before)
            withExtendedLifetime(operations) {}
            await harness.close()
        }
    }
}
