// Port by feature of the rest of App.pasteFlow.test.tsx, App.fileOperations.test.tsx, App.menusAndTree.test.tsx,
// App.openItems.test.tsx and ContentPane.reveal.test.tsx on how a paste can fail and what a write's end leaves
// (useExplorerActions.ts:1056-1137, 2172-2264, 2584-2628, 3099-3106): first one window's side over a write service the test
// answers for, then real tabs of a window that is never shown, with the app's real file operations on a temporary folder
import AppKit
import FTFileSystem
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit
@testable import FTOperations

private struct Refused: LocalizedError {
    var errorDescription: String?
}

/// A write service that answers the analysis as the test says, and whose progress the test sends.
private final class ScriptedPasteService: CoordinatorWriteService, @unchecked Sendable {
    enum Analysis {
        case refused(String)
        case finishedWith(status: CopyPasteAnalysisJobStatus, error: String?)
        case report(CopyPasteAnalysisReport)
    }

    var analysis: Analysis
    var analyses = 0
    /// Why the start is refused, if it is.
    var startRefusal: String?
    private var subscribers: [@Sendable (CopyPasteProgressEvent) -> Void] = []

    init(_ analysis: Analysis) {
        self.analysis = analysis
    }

    func emit(_ event: CopyPasteProgressEvent) {
        for subscriber in subscribers { subscriber(event) }
    }

    func subscribe(_ listener: @escaping @Sendable (CopyPasteProgressEvent) -> Void) -> @Sendable () -> Void {
        subscribers.append(listener)
        return {}
    }

    func startCopyPasteAnalysis(_ request: CopyPasteAnalysisRequest, keep: Set<String>) throws
        -> CopyPasteAnalysisStartHandle
    {
        analyses += 1
        if case .refused(let message) = analysis {
            throw Refused(errorDescription: message)
        }
        return CopyPasteAnalysisStartHandle(analysisId: "analysis-\(analyses)", status: .queued)
    }

    func getCopyPasteAnalysisUpdate(_ analysisId: String) throws -> CopyPasteAnalysisUpdate {
        switch analysis {
        case .refused(let message):
            throw Refused(errorDescription: message)
        case .finishedWith(let status, let error):
            return CopyPasteAnalysisUpdate(
                analysisId: analysisId, status: status, done: true, report: nil, error: error)
        case .report(var report):
            report.analysisId = analysisId
            return CopyPasteAnalysisUpdate(
                analysisId: analysisId, status: .complete, done: true, report: report, error: nil)
        }
    }

    func cancelCopyPasteAnalysis(_ analysisId: String) -> Bool { true }

    func startCopyPaste(_ start: CopyPasteExecutionRequest, keep: Set<String>) throws -> CopyPasteOperationHandle {
        if let startRefusal { throw Refused(errorDescription: startRefusal) }
        return CopyPasteOperationHandle(operationId: "copy-op-\(analyses)", status: .queued)
    }

    func resolveRuntimeConflict(
        _ operationId: String, conflictId: String, action: CopyPasteChoice, applyToRemaining: Bool
    ) -> Bool { true }

    func cancelOperation(_ operationId: String) -> Bool { true }
}

@MainActor
private final class PasteHost: WriteSessionHost {
    var isClosed = false
    var activeTabID: Int? = 1
    var currentPath = "/Users/demo/Folder"
    var selectedPaths: [String] = []
    var isSearching = false
    var selectedTreePath: String?
    private(set) var refreshes: [WriteEndRefresh] = []

    func applyWriteEnd(_ refresh: WriteEndRefresh) { refreshes.append(refresh) }
    func followMovesOnScreen(_ moves: [PathMove]) {}
    func writeLockChanged() {}
}

/// One window's side of a paste, with nothing on screen.
@MainActor
private final class PasteFixture {
    nonisolated static let source = "/Users/demo/source.txt"
    nonisolated static let destination = "/Users/demo/Folder"

    let service: ScriptedPasteService
    let host = PasteHost()
    let clipboard = SharedClipboard()
    let session: ExplorerWriteSession
    let actions: WindowWriteActions
    private let coordinator: WriteCoordinator
    private let shownBox = Shown()

    private final class Shown {
        var shown: [(title: String, message: String)] = []
    }

    var shown: [(title: String, message: String)] { shownBox.shown }

    init(_ analysis: ScriptedPasteService.Analysis, mode: ClipboardMode = .copy) {
        service = ScriptedPasteService(analysis)
        coordinator = WriteCoordinator(writeService: service, options: WriteCoordinatorOptions())
        session = ExplorerWriteSession(coordinator: coordinator, host: host, clipboard: clipboard)
        var dialogs = WriteDialogs()
        let box = shownBox
        dialogs.show = { title, message, _ in box.shown.append((title, message)) }
        actions = WindowWriteActions(session: session, tab: nil, dialogs: dialogs)
        actions.presentPreparing = { _, _, _ in nil }
        clipboard.set(ClipboardRules.set(mode, [Self.source], capturedAt: "t"), from: nil)
    }

    /// The paste under way ends so.
    func end(
        _ operationId: String, _ status: CopyPasteOperationStatus, mode: FTOperations.CopyPasteMode, completed: Int,
        failed: Int = 0,
        cancelled: Int = 0, error: String? = nil
    ) {
        let items = (0..<completed).map { _ in
            CopyPasteItemResult(
                sourcePath: Self.source, destinationPath: Self.destination + "/source.txt", sourceKind: .file,
                status: .completed, error: nil)
        }
        service.emit(
            CopyPasteProgressEvent(
                operationId: operationId, analysisId: "analysis-1", mode: mode, status: status,
                completedItemCount: completed, totalItemCount: 1, completedByteCount: 0, totalBytes: nil,
                currentSourcePath: nil, currentDestinationPath: nil, runtimeConflict: nil,
                result: CopyPasteOperationResult(
                    operationId: operationId, mode: mode, status: status, destinationDirectoryPath: Self.destination,
                    startedAt: Date(), finishedAt: Date(),
                    summary: CopyPasteOperationSummary(
                        topLevelItemCount: 1, totalItemCount: 1, completedItemCount: completed,
                        failedItemCount: failed, skippedItemCount: 0, cancelledItemCount: cancelled,
                        completedByteCount: 0, totalBytes: nil),
                    items: items, error: error)))
    }
}

/// What the analysis of the one item says: nothing in the way, or `issues`.
private func report(
    mode: FTOperations.CopyPasteMode = .copy, issues: [CopyPasteAnalysisIssue] = []
) -> CopyPasteAnalysisReport {
    let absent = NodeFingerprint(exists: false, kind: .missing)
    let node = CopyPasteAnalysisNode(
        id: "item-1", sourcePath: PasteFixture.source, destinationPath: PasteFixture.destination + "/source.txt",
        sourceKind: .file, destinationKind: .missing, disposition: .new, conflictClass: nil,
        sourceFingerprint: NodeFingerprint(exists: true, kind: .file, size: 1), destinationFingerprint: absent,
        children: [], totalNodeCount: 1, conflictNodeCount: 0)
    return CopyPasteAnalysisReport(
        analysisId: "analysis-1", mode: mode, sourcePaths: [PasteFixture.source],
        destinationDirectoryPath: PasteFixture.destination, nodes: [node], issues: issues, warnings: [],
        summary: CopyPasteAnalysisSummary(
            topLevelItemCount: 1, totalNodeCount: 1, totalBytes: 1, fileConflictCount: 0, directoryConflictCount: 0,
            mismatchConflictCount: 0, blockedCount: 0))
}

@MainActor
@Suite struct PasteEndsMatrixTests {
    private static let couldntPaste = "Couldn\u{2019}t Paste"
    private static let couldntCheck = "File Trail couldn\u{2019}t check the items to paste. Nothing was changed."

    // T-0a889e91 T-53a1f491 T-0ed7aa96 T-85792b9b B-CLIP-069: the analysis refused, failed with its message or without one
    // or found what can't be pasted: "Couldn't Paste", nothing started, the clipboard kept, and the next paste analyzes
    // again.
    // B-CLIP-072 T-65506a7d: a paste refused as it starts says so once, in the words every busy notice has.
    @Test func aPasteRefusedAsItStartsSaysSoOnce() async throws {
        let busy = WriteServiceMessages.writeOperationBusy
        let refused = "The disk went away."
        for (message, shown) in [(busy, WriteDialogs.busyMessage), (refused, refused)] {
            let fixture = PasteFixture(.report(report()))
            fixture.service.startRefusal = message
            let outcome = await fixture.actions.pasteFromClipboard(into: PasteFixture.destination)
            #expect(outcome == .error(message: shown) || outcome == .blocked(message: shown))
            #expect(fixture.shown.map(\.message) == [shown])
            #expect(!fixture.session.isWriteLocked)
        }
        // And one the analysis refuses because a write without a card has the slot.
        let fixture = PasteFixture(.refused(busy))
        _ = await fixture.actions.pasteFromClipboard(into: PasteFixture.destination)
        #expect(fixture.shown.map(\.message) == [WriteDialogs.busyMessage])
    }

    // B-NAV-140 B-SEL-026: a write's end says what it took out of its folder.
    @Test func aMovesEndSaysWhatLeft() async throws {
        let fixture = PasteFixture(.report(report(mode: .cut)), mode: .cut)
        let outcome = await fixture.actions.pasteFromClipboard(into: PasteFixture.destination)
        guard case .queued(let operationId) = outcome else {
            Issue.record("not started: \(outcome)")
            return
        }
        fixture.end(operationId, .completed, mode: .cut, completed: 1)
        #expect(await waitUntil { fixture.host.refreshes.last?.leftPaths == [PasteFixture.source] })
    }

    // T-e0ffebfc: a drop from another app that went through the review is still one when it starts.
    @Test func aReviewedDropFromAnotherAppIsOneWhenItStarts() async throws {
        let fixture = PasteFixture(.report(report()))
        let analysisId = "analysis-1"
        TabDragDrop.externalDropAnalyses.insert(analysisId)
        let outcome = await fixture.actions.pasteFromClipboard(into: PasteFixture.destination)
        guard case .queued(let operationId) = outcome else {
            Issue.record("not started: \(outcome)")
            return
        }
        #expect(!TabDragDrop.externalDropAnalyses.contains(analysisId))
        #expect(TabDragDrop.externalDropOperations.remove(operationId) != nil)
    }

    @Test func aPasteTheAnalysisCantClearSaysWhyAndCanBeTriedAgain() async throws {
        let refused = "The disk went away."
        let blocked = CopyPasteAnalysisIssue(
            code: .destinationNotDirectory, message: "Destination must be an existing folder.", sourcePath: nil,
            destinationPath: PasteFixture.destination)
        let cases: [(ScriptedPasteService.Analysis, String)] = [
            (.refused(refused), refused),
            (.finishedWith(status: .error, error: "  It broke.  "), "It broke."),
            (.finishedWith(status: .error, error: nil), Self.couldntCheck),
            (.finishedWith(status: .error, error: "   "), Self.couldntCheck),
            (.report(report(issues: [blocked])), "\u{201C}Folder\u{201D} isn't a folder."),
        ]
        for (analysis, message) in cases {
            let fixture = PasteFixture(analysis)
            let before = fixture.clipboard.contents
            for attempt in 1...2 {
                let outcome = await fixture.actions.pasteFromClipboard(into: PasteFixture.destination)
                #expect(outcome == .error(message: message) || outcome == .blocked(message: message))
                #expect(fixture.service.analyses == attempt)
                #expect(fixture.shown.count == attempt)
                #expect(fixture.shown.last?.title == Self.couldntPaste)
                #expect(fixture.shown.last?.message == message)
                #expect(fixture.clipboard.contents == before)
                #expect(fixture.session.card == nil)
            }
        }
    }

    // T-1d4fe1c3 T-0af25258 B-CLIP-052: a cut that failed or was stopped with nothing moved stays on the clipboard, and
    // can be pasted again; one that moved something is let go of.
    @Test func aCutThatMovedNothingStaysOnTheClipboard() async throws {
        let ends: [(CopyPasteOperationStatus, failed: Int, cancelled: Int)] = [
            (.failed, failed: 1, cancelled: 0), (.cancelled, failed: 0, cancelled: 1),
        ]
        for (status, failed, cancelled) in ends {
            let fixture = PasteFixture(.report(report(mode: .cut)), mode: .cut)
            let before = fixture.clipboard.contents
            let outcome = await fixture.actions.pasteFromClipboard(into: PasteFixture.destination)
            guard case .queued(let operationId) = outcome else {
                Issue.record("the paste didn't start: \(outcome)")
                continue
            }
            fixture.end(operationId, status, mode: .cut, completed: 0, failed: failed, cancelled: cancelled)
            #expect(await waitUntil { fixture.session.card == nil })
            #expect(fixture.clipboard.contents == before)

            let again = await fixture.actions.pasteFromClipboard(into: PasteFixture.destination)
            guard case .queued(let second) = again else {
                Issue.record("the second paste didn't start: \(again)")
                continue
            }
            #expect(fixture.service.analyses == 2)
            fixture.end(second, .completed, mode: .cut, completed: 1)
            #expect(await waitUntil { fixture.clipboard.contents == .empty })
        }
    }

    // T-6df1af15 B-CLIP-141: something else picked while the paste ran stays, and isn't replaced by what it made; the
    // selection left as it was gets what was made.
    @Test(arguments: [
        (["/Users/demo/Folder/other.txt"], true), (["/Users/demo/Folder/a.txt", "/Users/demo/Folder/b.txt"], true),
        ([], true), (["/Users/demo/Folder/a.txt"], false),
    ])
    func whatWasPickedWhileAPasteRanStays(_ pickedMeanwhile: [String], _ picked: Bool) async throws {
        let fixture = PasteFixture(.report(report()))
        fixture.host.selectedPaths = ["/Users/demo/Folder/a.txt"]
        let outcome = await fixture.actions.pasteFromClipboard(into: PasteFixture.destination)
        guard case .queued(let operationId) = outcome else {
            Issue.record("the paste didn't start: \(outcome)")
            return
        }
        fixture.host.selectedPaths = pickedMeanwhile
        fixture.end(operationId, .completed, mode: .copy, completed: 1)
        #expect(await waitUntil { !fixture.host.refreshes.isEmpty })
        #expect(fixture.host.refreshes.last?.selecting == (picked ? nil : [PasteFixture.destination + "/source.txt"]))
    }

    // T-f0c2b565 B-CLIP-193: what an Undo brought back into the folder on screen is selected; what it put elsewhere isn't.
    @Test func anUndoSelectsWhatCameBackIntoTheFolderOnScreen() {
        func undo(to destination: String) -> WriteOperationResult {
            LocalWriteResults.result(
                operationId: "undo-1", action: .undo, targetPath: nil, startedAt: Date(timeIntervalSince1970: 0),
                finishedAt: Date(timeIntervalSince1970: 1), totalItemCount: 1, completedItemCount: 1,
                items: [
                    WriteOperationItem(
                        sourcePath: "/Users/demo/.Trash/a.txt", destinationPath: destination, status: .completed)
                ], status: .completed, error: nil)
        }
        let here = "/Users/demo/Folder"
        #expect(
            AfterWrite.selection(
                undo(to: here + "/a.txt"), currentPath: here, isSearching: false, selectionChanged: false)
                == [here + "/a.txt"])
        #expect(
            AfterWrite.selection(
                undo(to: "/elsewhere/a.txt"), currentPath: here, isSearching: false, selectionChanged: false)
                == nil)
        #expect(
            AfterWrite.selection(
                undo(to: here + "/a.txt"), currentPath: here, isSearching: true, selectionChanged: false)
                == nil)
    }
}

extension ExplorerWindowlessTests {
    @MainActor
    @Suite(.windowlessAlone) struct WriteEndsInWindowMatrixTests {
        private func path(_ window: WritingWindow, _ name: String) -> String {
            window.folder.appendingPathComponent(name).path
        }

        /// Search results on screen, of a stand-in engine that finds `names` in the folder.
        private func searching(_ window: WritingWindow, finding names: [String]) async throws -> FakeSearchEngine {
            let tab = window.tab
            let engine = FakeSearchEngine()
            let timers = ManualTimers()
            tab.search.session.engine = engine
            tab.search.session.timers = timers
            engine.finds = { _ in (names, false, false) }
            let field = try #require(tab.searchField)
            field.stringValue = "note"
            tab.search.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
            timers.advance(0.4)
            #expect(await waitUntil { names.allSatisfy { name in tab.content.entries.contains { $0.name == name } } })
            return engine
        }

        // B-CLIP-047: a copied item renamed is followed by the clipboard, which it still is; a cut of one
        // renamed is cancelled.
        @Test func theClipboardFollowsARenameThroughTheRealOperation() async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            let actions = try #require(tab.writeActions)
            window.select(["note.txt"])
            tab.perform(.copySelection)
            let capturedAt = tab.services.clipboard.contents.capturedAt
            _ = try await actions.rename(path(window, "note.txt"), to: "renamed.txt")
            #expect(
                await waitUntil { tab.services.clipboard.contents.sourcePaths == [path(window, "renamed.txt")] })
            #expect(tab.services.clipboard.contents.mode == .copy)
            #expect(tab.services.clipboard.contents.capturedAt == capturedAt)
            #expect(await waitUntil { !tab.isWriteLocked })

            tab.services.clipboard.set(
                ClipboardRules.set(.cut, [path(window, "renamed.txt")], capturedAt: "t"), from: nil)
            _ = try await actions.rename(path(window, "renamed.txt"), to: "again.txt")
            #expect(await waitUntil { !tab.services.clipboard.contents.hasItems })
            await window.close()
        }

        // T-f3d3ef14 B-CLIP-074: a paste whose only item is gone: "Couldn't Paste" naming it, nothing written, and the
        // clipboard empty.
        @Test func aPasteOfOnlyAGoneItemPastesNothingAndSaysSo() async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            let note = path(window, "note.txt")
            tab.services.clipboard.set(ClipboardRules.set(.copy, [note], capturedAt: "t"), from: nil)
            tab.clipboardChanged()
            try FileManager.default.removeItem(atPath: note)
            tab.go(to: window.folder.appendingPathComponent("Gamma"))
            #expect(await waitUntil { tab.folder.lastPathComponent == "Gamma" })
            tab.perform(.pasteSelection)
            #expect(await waitUntil { !window.recorder.shown.isEmpty })
            #expect(window.recorder.shown.first?.title == "Couldn\u{2019}t Paste")
            #expect(
                window.recorder.shown.first?.message
                    == "\u{201C}note.txt\u{201D} couldn\u{2019}t be pasted because it was moved or deleted since it was copied."
            )
            #expect(!window.exists("Gamma/note.txt"))
            #expect(!tab.services.clipboard.contents.hasItems)
            await window.close()
        }

        // T-43a6da52 B-CLIP-143: results on screen stay through a write, and are found again when it
        // changed something; a write that changed nothing, or one from another tab in front, leaves them.
        @Test func resultsOnScreenAreFoundAgainAfterAWriteThatChangedSomething() async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            let actions = try #require(tab.writeActions)
            let engine = try await searching(window, finding: ["note.txt", "Alpha"])
            var searches = engine.starts.count

            _ = try await actions.trash([path(window, "note.txt")])
            #expect(await waitUntil { engine.starts.count == searches + 1 })
            #expect(await waitUntil { !tab.isWriteLocked })
            #expect(tab.searchRootPath != nil)
            searches = engine.starts.count

            // A copy of what can't be read changes nothing.
            let locked = path(window, "locked.txt")
            try "x".write(toFile: locked, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked) }
            var endedWithNothing = false
            let observation = actions.session.observe { event in
                if case .ended(let ended, _) = event, ended.result?.summary.completedItemCount == 0 {
                    endedWithNothing = true
                }
            }
            _ = await actions.copyTo([locked], destination: path(window, "Gamma"))
            #expect(await waitUntil { endedWithNothing && !tab.isWriteLocked })
            withExtendedLifetime(observation) {}
            try await Task.sleep(for: .milliseconds(100))
            #expect(engine.starts.count == searches)
            #expect(tab.searchRootPath != nil)
            CopyPasteResultPresenter.shared.sheet?.buttons.last?.perform()

            let group = try #require(tab.group)
            group.openTab(path: path(window, "Gamma"), from: tab)
            #expect(await waitUntil { group.tabs.count == 2 })
            let other = try #require(group.tabs.first { $0 !== tab })
            other.servicesOverride = window.harness.services
            other.ensureLoaded()
            #expect(await waitUntil { other.folder.lastPathComponent == "Gamma" })
            #expect(group.selected === other)
            let otherActions = try #require(other.writeActions)
            _ = try await otherActions.trash([path(window, "Beta")])
            #expect(await waitUntil { !window.exists("Beta") && !other.isWriteLocked })
            try await Task.sleep(for: .milliseconds(100))
            #expect(engine.starts.count == searches)
            tab.search.session.hideResults()
            await window.close()
        }

        // T-7f1c1f2a B-CLIP-144: a filter doesn't stop a renamed item being selected: it is shown and selected though the
        // filter would hide its new name.
        @Test func aRenamedItemTheFilterWouldHideIsStillSelected() async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            let actions = try #require(tab.writeActions)
            tab.content.setFilter("note")
            #expect(await waitUntil { tab.content.entries.map(\.name) == ["note.txt"] })
            _ = try await actions.rename(path(window, "note.txt"), to: "zzz.txt")
            let made = path(window, "zzz.txt")
            #expect(await waitUntil { tab.content.selection.leadPath == made })
            #expect(tab.content.listed.contains { $0.name == "zzz.txt" })
            await window.close()
        }

        // T-643b6df1: a file pasted far below the rows in sight is selected and brought into view once it is listed.
        @Test func aFilePastedBelowTheRowsInSightIsBroughtIntoView() async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            for index in 0..<300 {
                try "y".write(
                    to: window.folder.appendingPathComponent("a-\(index).txt"), atomically: false, encoding: .utf8)
            }
            tab.refresh()
            #expect(await waitUntil { tab.content.entries.count > 300 })
            window.harness.layout(tab)
            let far = path(window, "Alpha/zz-far.txt")
            try "y".write(toFile: far, atomically: true, encoding: .utf8)
            tab.services.clipboard.set(ClipboardRules.set(.copy, [far], capturedAt: "t"), from: nil)
            let scroller = try #require(tab.content.pane as? any RevealScroller)
            let before = scroller.scrollOrigin
            tab.perform(.pasteSelection)
            let made = path(window, "zz-far.txt")
            #expect(await waitUntil { tab.content.selection.leadPath == made })
            let position = try #require(tab.content.entries.firstIndex { $0.path == made })
            #expect(await waitUntil { scroller.isInView(index: position) })
            #expect(scroller.scrollOrigin != before)
            await window.close()
        }

        // T-1993a471: the Trash on screen is read again once it is emptied, its items gone.
        @Test func anEmptiedTrashOnScreenIsReadAgain() async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            let group = try #require(tab.group)
            // The Trash of a home folder the test owns.
            let trash = window.folder.appendingPathComponent(".Trash")
            try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: false)
            let old = trash.appendingPathComponent("old.txt")
            try "o".write(to: old, atomically: true, encoding: .utf8)
            tab.go(to: trash)
            #expect(await waitUntil { tab.content.entries.map(\.name) == ["old.txt"] })
            let coordinator = WriteCoordinator(
                writeService: ScriptedPasteService(.finishedWith(status: .error, error: nil)),
                options: WriteCoordinatorOptions(homePath: window.folder.path))
            let session = ExplorerWriteSession(coordinator: coordinator, host: group, clipboard: nil)
            var dialogs = window.recorder.dialogs
            dialogs.confirm = { _, _ in true }
            let actions = WindowWriteActions(session: session, tab: tab, dialogs: dialogs)
            let cache = tab.services.directoryService.cache
            actions.emptyTrashRunner = {
                try? FileManager.default.removeItem(at: old)
                cache.clear()
                return (ok: true, error: nil)
            }
            _ = try await actions.emptyTrash()
            #expect(await waitUntil { tab.content.entries.isEmpty })
            await window.close()
        }
    }
}
