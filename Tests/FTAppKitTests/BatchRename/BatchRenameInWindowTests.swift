// Ports by feature the "renaming several items" cases of apps/desktop/src/renderer/App.menusAndTree.test.tsx and
// App.writeRefusals.test.tsx, and the search results' rename of several of App.fileOperations.test.tsx, on a real tab
// whose window is never shown, with the app's file operations
import AppKit
import FTFileSystem
import FTFoundation
import FTOperations
import FTTestSupport
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    @MainActor
    @Suite(.windowlessAlone) struct BatchRenameInWindowTests {
        final class Notices {
            var titles: [String] = []
            var messages: [String] = []
        }

        /// What the sheet asked to rename, in order.
        final class Requests {
            var all: [BatchRenameRequest] = []
        }

        struct Opened {
            var harness: ExplorerHarness
            var tab: MainWindowController
            var operations: AppWriteOperations
            var notices: Notices
            var requests: Requests
            /// The folder as the listing spells it (/private/var for /var).
            var folder: String

            func path(_ name: String) -> String { folder + "/" + name }
        }

        /// A tab on a folder with a.txt, b.txt and c.txt (and the harness's folders), the app's file operations and
        /// their notices kept. With `records`, the renames are only recorded.
        private func open(names: [String] = ["a.txt", "b.txt", "c.txt"], records: Bool = true) async throws -> Opened {
            let harness = try ExplorerHarness.windowless()
            for name in names {
                try "x".write(to: harness.folder.appending(name), atomically: true, encoding: .utf8)
            }
            let tab = try await harness.open()
            let operations = AppWriteOperations(
                userData: harness.folder.url, directoryService: harness.services.directoryService,
                windows: harness.windows, trash: .standIn, log: { _ in })
            let notices = Notices()
            operations.dialogs.show = { title, message, _ in
                notices.titles.append(title)
                notices.messages.append(message)
            }
            operations.dialogs.confirm = { _, _ in false }
            let requests = Requests()
            MainWindowController.runBatchRename = { actions, request in
                requests.all.append(request)
                if !records { _ = await actions.batchRename(request) }
            }
            let folder = tab.content.entries.first.map { NodePath.dirname($0.path) } ?? tab.folder.path
            return Opened(
                harness: harness, tab: tab, operations: operations, notices: notices, requests: requests, folder: folder
            )
        }

        private func close(_ opened: Opened) async {
            MainWindowController.runBatchRename = { actions, request in _ = await actions.batchRename(request) }
            opened.tab.batchRenameSheet?.onCancel()
            withExtendedLifetime(opened.operations) {}
            await opened.harness.close()
        }

        private func select(_ opened: Opened, _ names: [String]) {
            opened.tab.content.applySelection(ContentSelection.of(names.map(opened.path)))
        }

        /// The sheet once its checks have come back.
        private func sheet(_ tab: MainWindowController) async throws -> BatchRenameSheetView {
            #expect(await waitUntil { tab.batchRenameSheet.map { !$0.model.checking } ?? false })
            let sheet = try #require(tab.batchRenameSheet)
            tab.window?.contentView?.layoutSubtreeIfNeeded()
            return sheet
        }

        /// Add Text "-old", then the default button.
        private func addOld(_ sheet: BatchRenameSheetView) {
            sheet.modeControl.choose(.add)
            batchRenameType(sheet.addTextField, "-old")
            sheet.renameButton.perform()
        }

        private func noChanges(_ sheet: BatchRenameSheetView) -> Int {
            sheet.preview.rows.filter { $0.newName == nil }.count
        }

        private func key(_ code: UInt16, _ characters: String, _ tab: MainWindowController) {
            DialogKeys.press(code, characters, in: tab.window)
        }

        /// The end of a rename of several, as the coordinator reports it: (asked for, where it is now, how it went,
        /// why).
        private func ended(
            _ status: WriteOperationStatus,
            _ items: [(String, String?, CopyPasteItemResult.Status, String?)]
        ) -> WriteOperationEvent {
            let count = { (wanted: CopyPasteItemResult.Status) in items.filter { $0.2 == wanted }.count }
            let summary = CopyPasteOperationSummary(
                topLevelItemCount: items.count, totalItemCount: items.count, completedItemCount: count(.completed),
                failedItemCount: count(.failed), skippedItemCount: count(.skipped),
                cancelledItemCount: count(.cancelled),
                completedByteCount: 0, totalBytes: nil)
            let result = WriteOperationResult(
                operationId: "rename-1", action: .batchRename, status: status, targetPath: items.first?.0,
                startedAt: Date(), finishedAt: Date(), summary: summary,
                items: items.map {
                    WriteOperationItem(sourcePath: $0.0, destinationPath: $0.1, status: $0.2, error: $0.3)
                }, error: nil)
            return WriteOperationEvent(operationId: "rename-1", action: .batchRename, status: status, result: result)
        }

        /// Another window's write runs until `release` is called.
        private func anotherWindowRuns(_ opened: Opened) throws -> () -> Void {
            let held = LocalWritesInWindowTests.Held()
            let other = OtherWindow()
            let coordinator = opened.operations.coordinator
            let handle = try coordinator.queueLocalWriteOperation(action: .trash, window: other) { operation in
                await held.wait()
                operation.emit(operation.progress(.cancelled))
            }
            let group = try #require(opened.tab.group)
            opened.operations.session(for: group).otherWindowProgress(
                WriteOperationEvent(operationId: handle.operationId, action: .trash, status: .running))
            return { held.open() }
        }

        @MainActor final class Inspected {
            var all: [[String]] = []
            func add(_ paths: [String]) { all.append(paths) }
        }

        final class OtherWindow: WriteOperationWindow {
            var isClosed = false
            func receive(_ message: WriteOperationMessage) throws {}
        }

        // F-796 B-DLG-073 B-DLG-075 B-DLG-086 B-DLG-087 B-DLG-089
        // T-2e1391bc
        @Test func renamesThemFromTheMenuShowingEveryNewNameFirst() async throws {
            let opened = try await open(records: false)
            let tab = opened.tab
            select(opened, ["a.txt", "b.txt"])
            let entries = tab.content.selectedEntries
            let menu = try #require(tab.contextMenus.contentMenu(for: entries))
            #expect(menu.items.contains { $0.title == "Rename 2 Items\u{2026}" })
            tab.contextMenus.contextMenu(
                perform: .rename,
                subject: ContextMenuSubject(
                    surface: .content, scope: .selection, paths: entries.map(\.path), targetPath: entries[0].path,
                    entries: entries.map(ContextMenuCoordinator.commandEntry)))
            let sheet = try await sheet(tab)
            // The checks have come back once the items are listed with no change.
            #expect(noChanges(sheet) == 2)
            addOld(sheet)
            #expect(await waitUntil { opened.requests.all.count == 1 })
            #expect(
                opened.requests.all == [
                    BatchRenameRequest(
                        items: [
                            .init(sourcePath: opened.path("a.txt"), destinationName: "a-old.txt", isFolder: false),
                            .init(sourcePath: opened.path("b.txt"), destinationName: "b-old.txt", isFolder: false),
                        ], onConflict: .number, numberSeparator: " ")
                ])
            #expect(tab.batchRenameSheet == nil)
            // What was typed is kept for next time.
            #expect(BatchRename.sanitizeSettings(tab.preferences.batchRenameSettings).addText == "-old")
            // Once done, the items are listed under their new names.
            #expect(
                await waitUntil {
                    Set(tab.content.entries.map(\.name)).isSuperset(of: ["a-old.txt", "b-old.txt"])
                })
            #expect(FileManager.default.fileExists(atPath: opened.path("a-old.txt")))
            #expect(opened.notices.titles.isEmpty)
            await close(opened)
        }

        // F-796 B-DLG-073 B-DLG-089 B-DLG-090
        // T-7d1b915c
        @Test func opensWithF2ReturnAndTheMenuBarsRenameAndClosesWithEscape() async throws {
            let opened = try await open()
            let tab = opened.tab
            let window = try #require(tab.window)
            select(opened, ["a.txt", "b.txt"])
            tab.perform(.focusContentPane)
            key(120, "\u{F705}", tab)
            let sheet = try await sheet(tab)
            #expect(sheet.findField.holdsKeyboard)
            key(KeyCode.escape, "\u{1b}", tab)
            #expect(tab.batchRenameSheet == nil)
            tab.perform(.renameSelection)
            _ = try await self.sheet(tab)
            tab.batchRenameSheet?.cancelButton.perform()
            #expect(tab.batchRenameSheet == nil)
            // Escape closes it wherever the keyboard is, even outside it.
            tab.perform(.focusContentPane)
            key(120, "\u{F705}", tab)
            _ = try await self.sheet(tab)
            window.makeFirstResponder(nil)
            key(KeyCode.escape, "\u{1b}", tab)
            #expect(tab.batchRenameSheet == nil)
            // Return renames, as Finder's does (Settings can make it open instead).
            tab.perform(.focusContentPane)
            key(KeyCode.returnKey, "\r", tab)
            _ = try await self.sheet(tab)
            #expect(tab.batchRenameSheet != nil)
            await close(opened)
        }

        // Behind the sheet the list keeps its focused look, the selected rows in the accent, as the original's does (240):
        // its focus restore sets the content focused before the sheet comes. The chosen mode reads as its title, and a click on a mode shows no
        // focus ring; Tab to it does.
        // F-796 F-873 B-DLG-073 B-DLG-092
        @Test func theListKeepsItsLookAndTheChosenModeReadsAsItsTitle() async throws {
            let opened = try await open()
            let tab = opened.tab
            let window = try #require(tab.window)
            tab.perform(.viewAsDetails)
            select(opened, ["a.txt", "b.txt"])
            tab.perform(.focusContentPane)
            let list = try #require(tab.content.pane as? ListViewController)
            #expect(list.hasKeyboard)
            key(120, "\u{F705}", tab)
            let sheet = try await sheet(tab)
            #expect(sheet.findField.holdsKeyboard)
            #expect(list.hasKeyboard)
            let chosen = try #require(sheet.modeControl.segments.first { !$0.selectedMark.isHidden })
            #expect(ElementFinder.text(of: chosen.selectedMark) == "Replace Text")
            #expect(ElementFinder.shows("Replace Text", chosen.selectedMark))
            // A click on Format: chosen, the keyboard on the modes, no ring.
            let format = try #require(sheet.modeControl.segments.first { $0.mode == .format })
            sheet.modeControl.focusByClick()
            sheet.modeControl.onSegment(try #require(sheet.modeControl.segments.firstIndex { $0 === format }))
            #expect(sheet.modeControl.selected == .format)
            #expect(window.firstResponder === sheet.modeControl)
            #expect(!sheet.modeControl.showsFocusRing)
            #expect(ElementFinder.text(of: format.selectedMark) == "Format")
            sheet.cancelButton.perform()
            #expect(tab.batchRenameSheet == nil)
            #expect(list.hasKeyboard)
            await close(opened)
        }

        // B-DLG-091
        // T-2bbfb2b6
        // F-796 (scenarios 246, 247): Select All from the menu selects the field's text, in this tab's window whichever
        // window is key, and what is typed next replaces it.
        @Test func selectAllSelectsTheTextOfTheFieldEdited() async throws {
            let opened = try await open()
            let tab = opened.tab
            select(opened, ["a.txt", "b.txt"])
            tab.perform(.renameSelection)
            let sheet = try await sheet(tab)
            let field = sheet.findField
            field.text = "File"
            field.focus(caret: 2)
            #expect(field.holdsKeyboard)
            tab.perform(.editSelectAll)
            #expect(field.selection == 0..<4)
            #expect(tab.batchRenameSheet != nil)
            await close(opened)
        }

        // B-SEL-171
        @Test func keepsTheListsShortcutsFromActingWhileItIsOpen() async throws {
            let opened = try await open()
            let tab = opened.tab
            select(opened, ["a.txt", "b.txt"])
            tab.renameSelected()
            _ = try await sheet(tab)
            #expect(tab.focusedPane == nil)
            key(KeyCode.delete, "\u{7f}", tab)
            DialogKeys.press(KeyCode.delete, "\u{7f}", modifiers: .command, in: tab.window)
            #expect(!tab.canPerform(.trashSelection))
            tab.perform(.trashSelection)
            for _ in 0..<5 { await Task.yield() }
            #expect(FileManager.default.fileExists(atPath: opened.path("a.txt")))
            #expect(tab.batchRenameSheet != nil)
            await close(opened)
        }

        // B-DLG-094
        // T-8a768343
        @Test func listsWhatWasntRenamedAndTriesItAgainFromTheSheet() async throws {
            let opened = try await open()
            let tab = opened.tab
            select(opened, ["a.txt", "b.txt"])
            tab.renameSelected()
            addOld(try await sheet(tab))
            tab.reopenBatchRename(
                after: ended(
                    .partial,
                    [
                        (opened.path("a.txt"), opened.path("a-old.txt"), .completed, nil),
                        (opened.path("b.txt"), nil, .failed, "\u{201C}b.txt\u{201D} is locked."),
                    ]))
            let again = try await sheet(tab)
            #expect(again.titleLabel.stringValue == "Rename 1 Item")
            await close(opened)
        }

        // B-DLG-075
        // T-e2459ba9
        @Test func saysAnotherOperationIsRunningInsteadOfOpening() async throws {
            let opened = try await open()
            let tab = opened.tab
            let release = try anotherWindowRuns(opened)
            select(opened, ["a.txt", "b.txt"])
            tab.renameSelected()
            #expect(tab.batchRenameSheet == nil)
            #expect(opened.notices.titles == ["Couldn\u{2019}t Rename"])
            #expect(opened.notices.messages == ["Another file operation is running. Try again when it has finished."])
            // Every way in, Try Again too.
            tab.openBatchRenameSheet([BatchRenameTarget(path: opened.path("a.txt"), name: "a.txt", isFolder: false)])
            #expect(tab.batchRenameSheet == nil)
            #expect(opened.notices.titles.count == 2)
            release()
            await close(opened)
        }

        // B-DLG-094
        // T-5360e1dd
        @Test func triesAgainOnlyTheItemsThatWerentRenamed() async throws {
            let opened = try await open()
            let tab = opened.tab
            select(opened, ["a.txt", "b.txt", "c.txt"])
            tab.renameSelected()
            addOld(try await sheet(tab))
            tab.reopenBatchRename(
                after: ended(
                    .partial,
                    [
                        (opened.path("a.txt"), opened.path("a-old.txt"), .completed, nil),
                        (opened.path("b.txt"), nil, .failed, nil), (opened.path("c.txt"), nil, .failed, nil),
                    ]))
            // The sheet has the two left, with what was typed before.
            let again = try await sheet(tab)
            #expect(again.titleLabel.stringValue == "Rename 2 Items")
            #expect(again.renameButton.title == "Rename 2 Items")
            again.renameButton.perform()
            #expect(await waitUntil { opened.requests.all.count == 2 })
            #expect(
                opened.requests.all.last
                    == BatchRenameRequest(
                        items: [
                            .init(sourcePath: opened.path("b.txt"), destinationName: "b-old.txt", isFolder: false),
                            .init(sourcePath: opened.path("c.txt"), destinationName: "c-old.txt", isFolder: false),
                        ], onConflict: .number, numberSeparator: " "))
            await close(opened)
        }

        // B-DLG-094
        // T-720c5e50
        @Test func triesAgainItemsSkippedBecauseTheirNewNamesWereTaken() async throws {
            let opened = try await open()
            let tab = opened.tab
            select(opened, ["a.txt", "b.txt"])
            tab.renameSelected()
            addOld(try await sheet(tab))
            tab.reopenBatchRename(
                after: ended(
                    .completed,
                    [
                        (
                            opened.path("a.txt"), nil, .skipped,
                            "An item named \u{201C}a-old.txt\u{201D} already exists."
                        ),
                        (
                            opened.path("b.txt"), nil, .skipped,
                            "An item named \u{201C}b-old.txt\u{201D} already exists."
                        ),
                    ]))
            #expect(try await sheet(tab).titleLabel.stringValue == "Rename 2 Items")
            await close(opened)
        }

        // B-DLG-094
        // T-6026c9fd
        @Test func triesAgainTheItemsNotStartedWhenTheRenameWasStopped() async throws {
            let opened = try await open()
            let tab = opened.tab
            select(opened, ["a.txt", "b.txt", "c.txt"])
            tab.renameSelected()
            addOld(try await sheet(tab))
            tab.reopenBatchRename(
                after: ended(
                    .partial,
                    [
                        (opened.path("a.txt"), opened.path("a-old.txt"), .completed, nil),
                        (opened.path("b.txt"), nil, .cancelled, nil), (opened.path("c.txt"), nil, .cancelled, nil),
                    ]))
            let again = try await sheet(tab)
            #expect(again.titleLabel.stringValue == "Rename 2 Items")
            again.renameButton.perform()
            #expect(await waitUntil { opened.requests.all.count == 2 })
            #expect(opened.requests.all.last?.items.map(\.sourcePath) == [opened.path("b.txt"), opened.path("c.txt")])
            await close(opened)
        }

        // B-DLG-094
        // T-84fd5b18
        @Test func triesAgainAnItemPutBackUnderItsOldNameWithANumber() async throws {
            let opened = try await open()
            let tab = opened.tab
            select(opened, ["a.txt", "b.txt"])
            tab.renameSelected()
            addOld(try await sheet(tab))
            // Another item took "b.txt" while b.txt waited under a hidden name.
            try "x".write(toFile: opened.path("b 2.txt"), atomically: true, encoding: .utf8)
            tab.reopenBatchRename(
                after: ended(
                    .partial,
                    [
                        (opened.path("a.txt"), opened.path("a-old.txt"), .completed, nil),
                        (opened.path("b.txt"), opened.path("b 2.txt"), .failed, "\u{201C}b.txt\u{201D} is locked."),
                    ]))
            // It is tried again where it is now, under the name it has now.
            let again = try await sheet(tab)
            #expect(again.titleLabel.stringValue == "Rename 1 Item")
            again.renameButton.perform()
            #expect(await waitUntil { opened.requests.all.count == 2 })
            #expect(
                opened.requests.all.last?.items == [
                    .init(sourcePath: opened.path("b 2.txt"), destinationName: "b 2-old.txt", isFolder: false)
                ])
            await close(opened)
        }

        // B-DLG-094
        // T-2534ef40
        @Test func triesAgainAnItemLeftUnderAHiddenTemporaryName() async throws {
            let opened = try await open()
            let tab = opened.tab
            select(opened, ["a.txt", "b.txt"])
            tab.renameSelected()
            addOld(try await sheet(tab))
            let hidden = opened.path(".filetrail-rename-abc123")
            try "x".write(toFile: hidden, atomically: true, encoding: .utf8)
            tab.reopenBatchRename(
                after: ended(
                    .partial,
                    [
                        (opened.path("a.txt"), opened.path("a-old.txt"), .completed, nil),
                        (opened.path("b.txt"), hidden, .failed, "\u{201C}b.txt\u{201D} is locked."),
                    ]))
            let again = try await sheet(tab)
            #expect(again.titleLabel.stringValue == "Rename 1 Item")
            again.renameButton.perform()
            #expect(await waitUntil { opened.requests.all.count == 2 })
            #expect(opened.requests.all.last?.items.map(\.sourcePath) == [hidden])
            #expect(opened.requests.all.last?.items.first?.isFolder == false)
            await close(opened)
        }

        // B-DLG-074 B-DLG-094
        // T-cec4474d
        @Test func triesAgainAFolderPutBackUnderAnotherNameAsAFolderThoughItIsntListed() async throws {
            let opened = try await open()
            let tab = opened.tab
            select(opened, ["b.txt", "Alpha"])
            tab.renameSelected()
            addOld(try await sheet(tab))
            #expect(await waitUntil { opened.requests.all.count == 1 })
            #expect(opened.requests.all.last?.items.map(\.isFolder) == [true, false])
            // The listing isn't read again before Try Again: "Alpha 2" isn't in it.
            try FileManager.default.createDirectory(atPath: opened.path("Alpha 2"), withIntermediateDirectories: false)
            tab.reopenBatchRename(
                after: ended(
                    .partial,
                    [
                        (opened.path("b.txt"), opened.path("b-old.txt"), .completed, nil),
                        (opened.path("Alpha"), opened.path("Alpha 2"), .failed, "\u{201C}Alpha\u{201D} is locked."),
                    ]))
            let again = try await sheet(tab)
            again.renameButton.perform()
            #expect(await waitUntil { opened.requests.all.count == 2 })
            // A folder's whole name is its name: "-old" goes at the end, not before an extension.
            #expect(
                opened.requests.all.last?.items == [
                    .init(sourcePath: opened.path("Alpha 2"), destinationName: "Alpha 2-old", isFolder: true)
                ])
            await close(opened)
        }

        // F-796 B-DLG-074
        // T-11f2cd1b
        @Test func numbersTheItemsInTheOrderTheListShowsThemNotTheOrderTheyWereClicked() async throws {
            let opened = try await open()
            let tab = opened.tab
            select(opened, ["c.txt", "a.txt", "b.txt"])
            tab.renameSelected()
            let sheet = try await sheet(tab)
            // Format, as it opens: "File" and the index after it.
            sheet.modeControl.choose(.format)
            sheet.renameButton.perform()
            #expect(await waitUntil { opened.requests.all.count == 1 })
            #expect(
                opened.requests.all == [
                    BatchRenameRequest(
                        items: [
                            .init(sourcePath: opened.path("a.txt"), destinationName: "File 1.txt", isFolder: false),
                            .init(sourcePath: opened.path("b.txt"), destinationName: "File 2.txt", isFolder: false),
                            .init(sourcePath: opened.path("c.txt"), destinationName: "File 3.txt", isFolder: false),
                        ], onConflict: .number, numberSeparator: " ")
                ])
            await close(opened)
        }

        // B-DLG-088
        // T-3fb59bfb
        // B-CLIP-196
        @Test func saysWhyTheyCouldntBeRenamed() async throws {
            let opened = try await open(records: false)
            let tab = opened.tab
            // The file operations refuse it before it starts: the reason is said under "Couldn’t Rename".
            tab.startBatchRename(
                BatchRenameRequest(items: [
                    .init(sourcePath: opened.path("a.txt"), destinationName: "a.txt", isFolder: false)
                ]))
            #expect(await waitUntil { !opened.notices.titles.isEmpty })
            #expect(opened.notices.titles == ["Couldn\u{2019}t Rename"])
            #expect(opened.notices.messages == ["Nothing would be renamed."])
            #expect(tab.notifications?.progress.state == nil)
            await close(opened)
        }

        // B-DLG-088
        // T-a8ac5b87
        @Test func saysAnotherOperationIsRunningWhenTheRenameStarts() async throws {
            let opened = try await open(records: false)
            let tab = opened.tab
            select(opened, ["a.txt", "b.txt"])
            tab.renameSelected()
            let sheet = try await sheet(tab)
            let release = try anotherWindowRuns(opened)
            addOld(sheet)
            #expect(tab.batchRenameSheet == nil)
            #expect(opened.notices.titles == ["Couldn\u{2019}t Rename"])
            #expect(opened.notices.messages == ["Another file operation is running. Try again when it has finished."])
            #expect(opened.requests.all.isEmpty)
            release()
            await close(opened)
        }

        /// Results of a search in the tab's folder, found by a stand-in for fd.
        private func search(_ names: [String], in tab: MainWindowController) throws -> ManualTimers {
            let engine = FakeSearchEngine()
            let timers = ManualTimers()
            tab.search.session.engine = engine
            tab.search.session.timers = timers
            engine.finds = { _ in (names, false, false) }
            let field = try #require(tab.searchField)
            field.stringValue = "txt"
            tab.search.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
            timers.advance(0.4)
            return timers
        }

        // F-796
        // T-0b1c4fac
        @Test func offersToRenameResultsFromDifferentFoldersTogetherButNotToDuplicateThem() async throws {
            let opened = try await open(names: ["source.txt", "Alpha/deep.txt"])
            let tab = opened.tab
            let timers = try search(["source.txt", "Alpha/deep.txt"], in: tab)
            #expect(
                await waitUntil {
                    timers.advance(0.2)
                    return tab.content.entries.count == 2
                })
            let source = try #require(tab.content.entries.first { $0.name == "source.txt" }?.path)
            let deep = try #require(tab.content.entries.first { $0.name == "deep.txt" }?.path)
            tab.content.applySelection(ContentSelection.of([source, deep]))
            let menu = try #require(tab.contextMenus.contentMenu(for: tab.content.selectedEntries))
            #expect(menu.items.contains { $0.title.hasPrefix("Move to Trash") })
            #expect(menu.items.contains { $0.title == "Rename 2 Items\u{2026}" })
            #expect(!menu.items.contains { $0.title.hasPrefix("Duplicate") })
            await close(opened)
        }

        // F-796 B-DLG-074
        // T-f34fe362
        @Test func renamesResultsFromDifferentFoldersTogetherEachInItsOwnFolder() async throws {
            let opened = try await open(names: ["source.txt", "Alpha/deep.txt"])
            let tab = opened.tab
            let inspected = Inspected()
            let native = MainWindowController.batchRenameInspector
            MainWindowController.batchRenameInspector = { home in
                let inner = native(home)
                return { request in
                    await inspected.add(request.paths)
                    return try await inner(request)
                }
            }
            defer { MainWindowController.batchRenameInspector = native }
            let timers = try search(["source.txt", "Alpha/deep.txt"], in: tab)
            #expect(
                await waitUntil {
                    timers.advance(0.2)
                    return tab.content.entries.count == 2
                })
            let source = try #require(tab.content.entries.first { $0.name == "source.txt" }?.path)
            let deep = try #require(tab.content.entries.first { $0.name == "deep.txt" }?.path)
            tab.content.applySelection(ContentSelection.of([source, deep]))
            tab.renameSelected()
            let sheet = try await sheet(tab)
            #expect(sheet.titleLabel.stringValue == "Rename 2 Items")
            #expect(noChanges(sheet) == 2)
            addOld(sheet)
            #expect(await waitUntil { opened.requests.all.count == 1 })
            // In the order the results are listed (by name), whatever order they were clicked in.
            #expect(inspected.all.first == [deep, source])
            #expect(
                opened.requests.all.first
                    == BatchRenameRequest(
                        items: [
                            .init(
                                sourcePath: deep, destinationName: "deep-old.txt",
                                isFolder: false
                            ),
                            .init(
                                sourcePath: source, destinationName: "source-old.txt",
                                isFolder: false),
                        ], onConflict: .number, numberSeparator: " "))
            await close(opened)
        }

        // The settings and presets are kept after the app quits: the state file read again has them.
        // B-DLG-089 B-DLG-121
        // T-4184b912
        @Test func keepsTheSettingsAndPresetsAfterTheAppQuits() async throws {
            let opened = try await open()
            let tab = opened.tab
            select(opened, ["a.txt", "b.txt"])
            tab.renameSelected()
            let sheet = try await sheet(tab)
            sheet.modeControl.choose(.add)
            batchRenameType(sheet.addTextField, "-old")
            batchRenamePick(sheet.presetsPopUp, "Save as Preset\u{2026}")
            batchRenameType(sheet.presetNameField, "Old")
            sheet.presetSaveButton.perform()
            sheet.cancelButton.perform()
            #expect(tab.batchRenameSheet == nil)
            opened.harness.store.flush()
            let reread = AppStateStore(
                filePath: opened.harness.folder.appending("app-state.json").path, defaultTheme: .light,
                timer: HeldStateTimer())
            let preferences = reread.preferences()
            #expect(BatchRename.sanitizeSettings(preferences.batchRenameSettings).addText == "-old")
            #expect(BatchRename.sanitizeSettings(preferences.batchRenameSettings).mode == .add)
            #expect(BatchRename.sanitizePresets(preferences.batchRenamePresets).map(\.name) == ["Old"])
            await close(opened)
        }
    }
}
