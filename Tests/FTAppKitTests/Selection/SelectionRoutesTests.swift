import AppKit
import FTFileSystem
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit
@testable import FTOperations

/// Counts reads.
private final class ReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func add() { lock.withLock { count += 1 } }
    var reads: Int { lock.withLock { count } }
}

/// Counts the reads of one folder: the tree reads its way down from the disk's root at the same time.
private struct CountingFolders: ExplorerFileSystem {
    let folder: String
    let counter: ReadCounter
    private let real = NativeFileSystem()

    func readDirectory(_ path: String) throws -> [DirectoryRecord] {
        if path == folder { counter.add() }
        return try real.readDirectory(path)
    }

    func stat(_ path: String) throws -> FileStats { try real.stat(path) }
    func lstat(_ path: String) throws -> FileStats { try real.lstat(path) }
    func realpath(_ path: String) throws -> String { try real.realpath(path) }
}

private final class AnotherWindow: WriteOperationWindow {
    var isClosed = false
    func receive(_ message: WriteOperationMessage) {}
}

extension ExplorerWindowlessTests {
    @MainActor
    @Suite struct SelectionRoutesTests {
        // F2 with another window's write running opens no field and says why at once.
        @Test func f2WhileAnotherWindowWritesOpensNoFieldAndSaysWhy() async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            window.select(["note.txt"])
            let held = LocalWritesInWindowTests.Held()
            let handle = try window.operations.coordinator.queueLocalWriteOperation(
                action: .trash, window: AnotherWindow()
            ) { operation in
                await held.wait()
                operation.emit(operation.progress(.cancelled))
            }
            let group = try #require(tab.group)
            window.operations.session(for: group).otherWindowProgress(
                WriteOperationEvent(operationId: handle.operationId, action: .trash, status: .running))

            let responder = try #require(tab.window?.firstResponder)
            responder.keyDown(with: try systemKeyEvent(120))
            #expect(tab.content.inlineRename == nil)
            #expect(window.recorder.shown.map(\.title) == ["Couldn\u{2019}t Rename"])
            held.open()
            await window.close()
        }

        // Another view keeps the selection, folder and history; no folder is read; the new view starts at the
        // top and brings the lead into view.
        @Test func aViewSwitchKeepsTheSelectionAndReadsNothing() async throws {
            let harness = try ExplorerHarness.windowless()
            let many = try harness.makeFolder(named: "Many", files: 300)
            let tab = try await harness.open(many.path)
            tab.perform(.viewAsDetails)
            #expect(await waitUntil { tab.content.entries.count == 300 && tab.content.pane != nil })
            harness.layout(tab)
            let counter = ReadCounter()
            let service = DirectoryService(fileSystem: CountingFolders(folder: tab.shownFolderPath, counter: counter))
            tab.servicesOverride = ExplorerServices(
                directoryService: service, iconStore: TestServices.icons, clipboard: harness.windows.clipboard,
                preferences: harness.channel)
            let lead = tab.content.entries[250].path
            tab.content.select(paths: [lead])
            let (history, shown) = (tab.navigationHistory.paths, tab.shownFolderPath)

            tab.perform(.viewAsIcons)
            #expect(await waitUntil { tab.content.pane is ItemGridPane })
            harness.layout(tab)
            await settle()
            #expect(tab.viewMode == .icons)
            #expect(tab.selectedPaths == [lead])
            #expect(tab.content.selection.leadPath == lead)
            #expect(tab.navigationHistory.paths == history)
            #expect(tab.shownFolderPath == shown)
            #expect(counter.reads == 0)
            let scroller = try #require(tab.content.pane as? any RevealScroller)
            #expect(scroller.isInView(index: 250))

            // A lead at the start of the list: the new view is at its top, not where the last one was.
            tab.content.select(paths: [tab.content.entries[0].path])
            tab.content.pane?.scrollPosition = (top: 2_000, left: 0)
            tab.perform(.viewAsDetails)
            #expect(await waitUntil { !(tab.content.pane is ItemGridPane) })
            harness.layout(tab)
            await settle()
            #expect(tab.content.pane?.scrollPosition.top == 0)
            #expect(counter.reads == 0)

            // The same reader counts a read when there is one, so nothing above went past it.
            tab.perform(.refreshOrApplySearchSort)
            #expect(await waitUntil { counter.reads > 0 })

            // The switch waits for a dialog, not for search results.
            let engine = FakeSearchEngine()
            let timers = ManualTimers()
            tab.search.session.engine = engine
            tab.search.session.timers = timers
            engine.finds = { _ in (["item-000.txt"], false, false) }
            let field = try #require(tab.searchField)
            field.stringValue = "item"
            tab.search.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
            timers.advance(0.4)
            #expect(await waitUntil { tab.search.session.resultsVisible })
            #expect(tab.canPerform(.viewAsIcons))
            tab.search.session.hideResults()
            tab.perform(.openLocationSheet)
            #expect(tab.goToBox != nil)
            #expect(!tab.canPerform(.viewAsIcons))
            await harness.close()
        }
    }
}
