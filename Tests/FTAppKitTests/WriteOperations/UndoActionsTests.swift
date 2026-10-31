// Port by feature of the Undo cases of apps/desktop/src/renderer/App.undo.test.tsx (startUndo, askUndoQuestion of
// apps/desktop/src/renderer/hooks/useExplorerActions.ts): what one window asks of the coordinator for ⌘Z and ⇧⌘Z, and
// what it asks the person first, driven on a real folder. The text field's own Undo (T-af1c755a, T-7b2fe094) is the
// menu router's (P4-01); what happens after an Undo (T-f0c2b565, T-8339f67a, T-ec337946) is P5-08's result flow, and
// its toast is in Clipboard/WriteEndInWindowTests.swift.
import AppKit
import Darwin
import FTFileSystem
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTAppKit
@testable import FTOperations

/// A write service that never pastes: these tests only run the local operations and their Undo.
private final class NoPasteService: CoordinatorWriteService, @unchecked Sendable {
    func subscribe(_ listener: @escaping @Sendable (CopyPasteProgressEvent) -> Void) -> @Sendable () -> Void { {} }
    func startCopyPasteAnalysis(_ request: CopyPasteAnalysisRequest, keep: Set<String>) throws
        -> CopyPasteAnalysisStartHandle
    {
        CopyPasteAnalysisStartHandle(analysisId: "analysis-1", status: .queued)
    }
    func getCopyPasteAnalysisUpdate(_ analysisId: String) throws -> CopyPasteAnalysisUpdate {
        CopyPasteAnalysisUpdate(analysisId: analysisId, status: .complete, done: true, report: nil, error: nil)
    }
    func cancelCopyPasteAnalysis(_ analysisId: String) -> Bool { true }
    func startCopyPaste(_ start: CopyPasteExecutionRequest, keep: Set<String>) throws -> CopyPasteOperationHandle {
        CopyPasteOperationHandle(operationId: "copy-op-1", status: .queued)
    }
    func resolveRuntimeConflict(
        _ operationId: String, conflictId: String, action: CopyPasteChoice, applyToRemaining: Bool
    ) -> Bool { true }
    func cancelOperation(_ operationId: String) -> Bool { true }
}

@MainActor
private final class UndoHost: WriteSessionHost {
    var isClosed = false
    var activeTabID: Int? = 1
    var currentPath: String
    var selectedPaths: [String] = []
    var isSearching = false
    var selectedTreePath: String?

    init(currentPath: String) {
        self.currentPath = currentPath
    }

    func applyWriteEnd(_ refresh: WriteEndRefresh) {}
    func followMovesOnScreen(_ moves: [PathMove]) {}
    func writeLockChanged() {}
}

/// A window's file operations on a temporary home folder with a Trash folder, and a history to undo from.
@MainActor
private final class UndoFixture {
    let root: TemporaryDirectory
    let history = UndoHistory()
    let coordinator: WriteCoordinator
    let session: ExplorerWriteSession
    private let host: UndoHost
    var shown: [(title: String, message: String)] = []
    var asked: [WriteQuestion] = []
    var answers: [Bool] = []
    /// What happens while a question is up.
    var whileAsked: () throws -> Void = {}
    var events: [WindowWriteEvent] = []
    private var observation: ExplorerWindowObservation?

    init() throws {
        root = try TemporaryDirectory(prefix: "filetrail-undo-actions")
        let home = root.path
        try FileManager.default.createDirectory(atPath: home + "/.Trash", withIntermediateDirectories: false)
        let count = Counted()
        let fileSystem = NativeWriteFileSystem(trash: { path in
            let destination = home + "/.Trash/\(count.next())-" + NodePath.basename(path)
            try NativeFS.renameExclusive(path, destination)
            return destination
        })
        let history = history
        coordinator = WriteCoordinator(
            writeService: NoPasteService(), fileSystem: fileSystem,
            options: WriteCoordinatorOptions(
                homePath: home, recordUndo: { history.record($0) }, undoHistory: history))
        let host = UndoHost(currentPath: home)
        self.host = host
        session = ExplorerWriteSession(coordinator: coordinator, host: host, clipboard: nil)
        observation = session.observe { [weak self] in self?.events.append($0) }
    }

    var actions: WindowWriteActions {
        var dialogs = WriteDialogs()
        dialogs.show = { [weak self] title, message, _ in self?.shown.append((title, message)) }
        dialogs.confirm = { [weak self] question, _ in
            self?.asked.append(question)
            try? self?.whileAsked()
            return self?.answers.isEmpty == false ? self?.answers.removeFirst() ?? false : false
        }
        return WindowWriteActions(session: session, tab: nil, dialogs: dialogs)
    }

    func path(_ name: String) -> String { root.path + "/" + name }
    func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: path(name)) }
    func write(_ name: String, _ text: String = "x") throws {
        try text.write(toFile: path(name), atomically: false, encoding: .utf8)
    }

    var ends: [WriteOperationEvent] {
        events.compactMap { if case .ended(let event, _) = $0 { event } else { nil } }
    }

    func waitForEnds(_ count: Int) async throws {
        let deadline = Date().addingTimeInterval(20)
        while ends.count < count {
            if Date() >= deadline { throw OperationError("Timed out waiting for the operation to end.") }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    /// A rename through the window, to its end.
    func rename(_ name: String, to newName: String) async throws {
        let before = ends.count
        _ = try await actions.rename(path(name), to: newName)
        try await waitForEnds(before + 1)
    }

    func close() async {
        await coordinator.shutDown(maxWaitMs: 0)
        root.remove()
    }

    final class Counted: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func next() -> Int {
            lock.withLock {
                value += 1
                return value
            }
        }
    }
}

@MainActor
@Suite(.serialized) struct UndoActionsTests {
    // F-246 F-377 T-74e34ae7 T-1f83c7c1
    @Test func undoesTheLastFileOperation() async throws {
        let fixture = try UndoFixture()
        try fixture.write("a.txt")
        try await fixture.rename("a.txt", to: "b.txt")
        #expect(fixture.history.menu().undo == "Rename")

        let outcome = await fixture.actions.undo()
        guard case .queued = outcome else {
            Issue.record("expected the Undo to start, got \(outcome)")
            return
        }
        try await fixture.waitForEnds(2)
        #expect(fixture.ends.last?.action == .undo)
        #expect(fixture.ends.last?.status == .completed)
        #expect(fixture.exists("a.txt") && !fixture.exists("b.txt"))
        #expect(fixture.history.menu() == UndoMenuLabels(undo: nil, redo: "Rename", cantUndo: false))
        #expect(fixture.asked.isEmpty)
        await fixture.close()
    }

    // F-246 T-ea9c0a16 T-1f83c7c1
    @Test func redoesWhatWasUndone() async throws {
        let fixture = try UndoFixture()
        try fixture.write("a.txt")
        try await fixture.rename("a.txt", to: "b.txt")
        _ = await fixture.actions.undo()
        try await fixture.waitForEnds(2)

        _ = await fixture.actions.redo()
        try await fixture.waitForEnds(3)
        #expect(fixture.ends.last?.action == .redo)
        #expect(fixture.exists("b.txt") && !fixture.exists("a.txt"))
        #expect(fixture.history.menu() == UndoMenuLabels(undo: "Rename", redo: nil, cantUndo: false))
        await fixture.close()
    }

    // F-386 T-8c7fea26
    @Test func doesNothingMoreForAKeyHeldDown() async throws {
        let fixture = try UndoFixture()
        try fixture.write("a.txt")
        try await fixture.rename("a.txt", to: "b.txt")
        let actions = fixture.actions
        async let first = actions.undo()
        async let second = actions.undo()
        let outcomes = await [first, second]
        #expect(outcomes.filter { if case .queued = $0 { true } else { false } }.count == 1)
        try await fixture.waitForEnds(2)
        #expect(fixture.exists("a.txt"))
        #expect(fixture.shown.isEmpty)
        await fixture.close()
    }

    // F-386 T-8c7fea26 B-CLIP-185 B-SEL-114
    @Test func aHeldCommandZRunsOneUndoAPress() throws {
        func key(_ characters: String, _ flags: NSEvent.ModifierFlags, repeat isARepeat: Bool) throws -> NSEvent {
            try #require(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                    context: nil, characters: characters, charactersIgnoringModifiers: characters,
                    isARepeat: isARepeat, keyCode: 6))
        }
        // The press runs Undo (and Redo); the repeats of the key held down don't.
        #expect(MainWindowController.undoRuns(for: try key("z", .command, repeat: false)))
        #expect(!MainWindowController.undoRuns(for: try key("z", .command, repeat: true)))
        #expect(!MainWindowController.undoRuns(for: try key("Z", [.command, .shift], repeat: true)))
        // A click on the menu item, or no event at all, always does.
        let click = try #require(
            NSEvent.mouseEvent(
                with: .leftMouseUp, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 0))
        #expect(MainWindowController.undoRuns(for: click))
        #expect(MainWindowController.undoRuns(for: nil))
    }

    // F-551 T-1d67a013 B-CLIP-191
    @Test func givesTheQuestionTheNamesItLists() {
        let names = ["a.txt", "b.txt", "c.txt", "d.txt", "e.txt", "f.txt"]
        let question = WindowWriteActions.undoQuestion(.nameTaken(names: names), .undo, .trash)
        #expect(question.title == "6 items have names that other items have taken where they would go back.")
        #expect(question.list == ["a.txt", "b.txt", "c.txt", "d.txt", "e.txt", "and 1 more"])
        let one = UndoQuestion.ChangedItem(name: "x", putBack: false, replaced: false)
        #expect(WindowWriteActions.undoQuestion(.changed(items: [one]), .undo, .duplicate).list.isEmpty)
    }

    // F-386 F-552 T-ba10f104
    // B-CLIP-186 T-c2f18eb0
    @Test func startsNothingWhileAnotherOperationRunsAndSaysSo() async throws {
        let fixture = try UndoFixture()
        try fixture.write("a.txt")
        try await fixture.rename("a.txt", to: "b.txt")
        let gate = AsyncGate()
        let handle = try fixture.coordinator.queueLocalWriteOperation(action: .rename, window: fixture.session) {
            operation in
            await gate.wait()
            operation.emit(operation.progress(.cancelled))
        }
        fixture.session.adoptWriteOperation(handle.operationId)

        let outcome = await fixture.actions.undo()
        #expect(outcome == .cancelled || outcome == .blocked(message: WriteDialogs.busyMessage))
        #expect(fixture.shown.map(\.message) == [WriteDialogs.busyMessage])
        #expect(fixture.shown.first?.title == "Couldn’t Undo")
        #expect(fixture.exists("b.txt"))
        gate.open()
        await fixture.close()
    }

    // T-7a4e47ef B-CLIP-192: another operation starts while the question is up: answering it says so, and nothing is undone.
    @Test func saysAnotherOperationStartedWhileTheQuestionWasUp() async throws {
        let fixture = try UndoFixture()
        try fixture.write("a.txt", "a")
        try await fixture.rename("a.txt", to: "b.txt")
        try fixture.write("a.txt", "someone else's")
        fixture.answers = [true]
        let gate = AsyncGate()
        fixture.whileAsked = { [unowned fixture] in
            let handle = try fixture.coordinator.queueLocalWriteOperation(action: .rename, window: fixture.session) {
                operation in
                await gate.wait()
                operation.emit(operation.progress(.cancelled))
            }
            fixture.session.adoptWriteOperation(handle.operationId)
        }

        let outcome = await fixture.actions.undo()
        if case .queued = outcome { Issue.record("it started") }
        #expect(fixture.asked.count == 1)
        #expect(fixture.shown.map(\.message) == [WriteDialogs.busyMessage])
        #expect(fixture.shown.first?.title == "Couldn\u{2019}t Undo")
        #expect(fixture.exists("b.txt"))
        #expect(!fixture.exists("a 2.txt"))
        gate.open()
        await fixture.close()
    }

    // F-551 T-07c23f02
    @Test func asksAboutANameTakenAndGoesAheadWithKeepBoth() async throws {
        let fixture = try UndoFixture()
        try fixture.write("a.txt", "a")
        try await fixture.rename("a.txt", to: "b.txt")
        try fixture.write("a.txt", "someone else's")
        fixture.answers = [true]

        _ = await fixture.actions.undo()
        try await fixture.waitForEnds(2)
        #expect(
            fixture.asked == [
                WriteQuestion(
                    title: "An item named “a.txt” is already where it would go back.",
                    message: "Undo puts it back with a number added to its name.", confirmLabel: "Keep Both",
                    destructive: false, cancelIsDefault: false)
            ])
        #expect(try String(contentsOfFile: fixture.path("a 2.txt"), encoding: .utf8) == "a")
        #expect(try String(contentsOfFile: fixture.path("a.txt"), encoding: .utf8) == "someone else's")
        await fixture.close()
    }

    // F-551 T-94e67861
    @Test func saysWhyACopyThatChangedWouldGoToTheTrashAfterAskingAboutNames() async throws {
        let fixture = try UndoFixture()
        try fixture.write("a.txt", "a")
        try fixture.write("b.txt", "b")
        // Trashed, then one name taken; and a new folder that has something in it since.
        try await fixture.coordinator.createFolder(
            parentDirectoryPath: fixture.root.path, folderName: "F", window: fixture.session)
        _ = try await UndoWaits.until { fixture.history.menu().undo == "New Folder" ? true : nil }
        try fixture.write("F/inside.txt")
        let undo = fixture.history.top(.undo)?.units ?? []
        let ended = fixture.ends.count
        _ = try await fixture.actions.trash([fixture.path("a.txt")])
        try await fixture.waitForEnds(ended + 1)
        let trashed = fixture.history.top(.undo)?.units ?? []
        fixture.history.record(
            FinishedWrite(action: .write(.paste), log: .undoable(units: undo + trashed), items: []))
        try fixture.write("a.txt", "someone else's")
        fixture.answers = [true, true]

        _ = await fixture.actions.undo()
        try await fixture.waitForEnds(ended + 2)
        #expect(fixture.asked.map(\.confirmLabel) == ["Keep Both", "Move to Trash"])
        #expect(fixture.asked.last?.title == "“F” was changed after it was copied.")
        #expect(fixture.asked.last?.cancelIsDefault == true)
        #expect(!fixture.exists("F"))
        #expect(fixture.exists("a 2.txt"))
        await fixture.close()
    }

    // F-551 T-af05c51d
    @Test func startsNothingWhenAQuestionIsCancelled() async throws {
        let fixture = try UndoFixture()
        try fixture.write("a.txt", "a")
        try await fixture.rename("a.txt", to: "b.txt")
        try fixture.write("a.txt", "someone else's")
        fixture.answers = [false]

        #expect(await fixture.actions.undo() == .cancelled)
        #expect(fixture.asked.count == 1)
        #expect(fixture.exists("b.txt"))
        #expect(fixture.history.menu().undo == "Rename")
        #expect(!fixture.session.isWriteLocked)
        await fixture.close()
    }

    // F-386 F-395 T-92802a36
    // B-CLIP-187
    @Test func startsNothingWhenThereIsNothingToUndo() async throws {
        let fixture = try UndoFixture()
        #expect(await fixture.actions.undo() == .cancelled)
        #expect(await fixture.actions.redo() == .cancelled)
        #expect(fixture.shown.isEmpty)
        #expect(fixture.asked.isEmpty)
        // After an operation that can't be undone: Can't Undo, and nothing either.
        fixture.history.record(
            FinishedWrite(action: .emptyTrash, log: .notUndoable(reason: .deletedForGood), items: []))
        #expect(fixture.history.menu().cantUndo)
        #expect(await fixture.actions.undo() == .cancelled)
        #expect(fixture.shown.isEmpty)
        await fixture.close()
    }

    // F-388 T-f676628a
    // B-CLIP-187 B-CLIP-196 T-babf6471
    @Test func saysWhyAnUndoCouldntStart() async throws {
        let fixture = try UndoFixture()
        try fixture.write("a.txt", "a")
        try await fixture.coordinator.createFolder(
            parentDirectoryPath: fixture.root.path, folderName: "F", window: fixture.session)
        _ = try await UndoWaits.until { fixture.history.menu().undo == "New Folder" ? true : nil }
        let made = fixture.history.top(.undo)?.units ?? []
        try await fixture.rename("a.txt", to: "b.txt")
        let renamed = fixture.history.top(.undo)?.units ?? []
        fixture.history.record(FinishedWrite(action: .write(.paste), log: .undoable(units: made + renamed), items: []))
        try fixture.write("a.txt", "someone else's")
        // While the question about the name is open, something is put in the new folder.
        var dialogs = WriteDialogs()
        dialogs.show = { title, message, _ in fixture.shown.append((title, message)) }
        dialogs.confirm = { question, _ in
            fixture.asked.append(question)
            try? fixture.write("F/more.txt")
            return true
        }
        let actions = WindowWriteActions(session: fixture.session, tab: nil, dialogs: dialogs)

        let outcome = await actions.undo()
        #expect(outcome == .error(message: "“F” was changed after Undo was chosen. Choose Undo again."))
        #expect(fixture.shown.first?.title == "Couldn’t Undo")
        #expect(fixture.shown.first?.message == "“F” was changed after Undo was chosen. Choose Undo again.")
        #expect(fixture.exists("F"))
        await fixture.close()
    }
}

/// Opens once; everything waiting goes on.
@MainActor
private final class AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }
}

enum UndoWaits {
    /// Waits, bounded by time, for `read` to give something.
    @MainActor
    static func until<T>(_ read: () -> T?) async throws -> T {
        let deadline = Date().addingTimeInterval(10)
        while true {
            if let value = read() { return value }
            if Date() >= deadline { throw OperationError("Timed out waiting for condition.") }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }
}
