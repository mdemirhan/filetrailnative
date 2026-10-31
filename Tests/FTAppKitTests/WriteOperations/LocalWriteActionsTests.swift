// Port by feature of the rename, New Folder, Trash, Delete Immediately and Empty Trash cases of
// apps/desktop/src/renderer/App.fileOperations.test.tsx, App.menusAndTree.test.tsx and App.writeRefusals.test.tsx: what
// one window asks of the coordinator, and what it asks the person first, driven on a real folder
import Darwin
import FTFileSystem
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTAppKit
@testable import FTOperations

/// A write service that never pastes: these tests only run the local operations.
private final class IdleWriteService: CoordinatorWriteService, @unchecked Sendable {
    private var subscribers: [@Sendable (CopyPasteProgressEvent) -> Void] = []

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

/// An explorer window as the session sees it, on the test's folder.
@MainActor
private final class Host: WriteSessionHost {
    var isClosed = false
    var activeTabID: Int? = 1
    var currentPath: String
    var selectedPaths: [String] = []
    var isSearching = false
    var selectedTreePath: String?
    private(set) var refreshes: [WriteEndRefresh] = []

    init(currentPath: String) {
        self.currentPath = currentPath
    }

    func applyWriteEnd(_ refresh: WriteEndRefresh) { refreshes.append(refresh) }
    func followMovesOnScreen(_ moves: [PathMove]) {}
    func writeLockChanged() {}
}

/// A window's file operations on a temporary home folder: the disk itself, with a Trash that moves items into the
/// home folder's `.Trash`, and a "Share" folder whose disk has none. What the window shows and asks is recorded; the
/// questions are answered with `answers`.
@MainActor
private final class Fixture {
    let root: TemporaryDirectory
    let coordinator: WriteCoordinator
    let host: Host
    let session: ExplorerWriteSession
    let clipboard = SharedClipboard()
    var shown: [(title: String, message: String)] = []
    var asked: [WriteQuestion] = []
    var answers: [Bool] = []
    /// The names submitted in a name prompt, in order, until it closes; nil, or none left, is Cancel.
    var namesTyped: [String?] = []
    var prompts: [NamePrompt] = []
    /// The reasons a name prompt showed under what was typed.
    var promptRefusals: [String] = []
    var events: [WindowWriteEvent] = []
    private var observation: ExplorerWindowObservation?

    init() throws {
        root = try TemporaryDirectory(prefix: "filetrail-local-actions")
        let home = root.path
        try FileManager.default.createDirectory(atPath: home + "/.Trash", withIntermediateDirectories: false)
        try FileManager.default.createDirectory(atPath: home + "/Share", withIntermediateDirectories: false)
        let fileSystem = NativeWriteFileSystem(trash: { path in
            if path.hasPrefix(home + "/Share/") {
                throw OperationError(
                    "“\(NodePath.basename(path))” couldn’t be moved to the Trash. This disk may not have a Trash.",
                    code: CopyPasteErrors.noTrashErrorCode)
            }
            let destination = home + "/.Trash/" + NodePath.basename(path)
            try NativeFS.renameExclusive(path, destination)
            return destination
        })
        coordinator = WriteCoordinator(
            writeService: IdleWriteService(), fileSystem: fileSystem, options: WriteCoordinatorOptions(homePath: home))
        host = Host(currentPath: home)
        session = ExplorerWriteSession(coordinator: coordinator, host: host, clipboard: clipboard)
        observation = session.observe { [weak self] in self?.events.append($0) }
    }

    var actions: WindowWriteActions {
        var dialogs = WriteDialogs()
        dialogs.show = { [weak self] title, message, _ in self?.shown.append((title, message)) }
        dialogs.confirm = { [weak self] question, _ in
            self?.asked.append(question)
            return self?.answers.isEmpty == false ? self?.answers.removeFirst() ?? false : false
        }
        dialogs.askName = { [weak self] prompt, _, submit in
            guard let self else { return }
            self.prompts.append(prompt)
            while !self.namesTyped.isEmpty, let typed = self.namesTyped.removeFirst() {
                switch await submit(typed) {
                case .close: return
                case .refuse(let message): self.promptRefusals.append(message)
                }
            }
        }
        return WindowWriteActions(session: session, tab: nil, dialogs: dialogs)
    }

    func path(_ name: String) -> String { root.path + "/" + name }

    func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: path(name)) }

    func make(_ name: String, folder: Bool = false) throws {
        if folder {
            try FileManager.default.createDirectory(atPath: path(name), withIntermediateDirectories: true)
        } else {
            try "x".write(toFile: path(name), atomically: false, encoding: .utf8)
        }
    }

    /// The end of each of this window's operations, in order.
    var ends: [WriteOperationEvent] {
        events.compactMap { if case .ended(let event, _) = $0 { event } else { nil } }
    }

    /// Bounded by time, not by a number of turns: the other suites share the main actor.
    func waitForEnds(_ count: Int) async throws {
        let deadline = Date().addingTimeInterval(20)
        while ends.count < count {
            if Date() >= deadline { throw OperationError("Timed out waiting for the operation to end.") }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    /// Another window's operation runs in the coordinator until `release`; with `told`, this window has heard of it.
    func anotherWindowRuns(told: Bool = true) throws {
        let handle = try coordinator.queueLocalWriteOperation(action: .trash, window: other) { [held] operation in
            await held.wait()
            operation.emit(operation.progress(.cancelled))
        }
        if told {
            session.otherWindowProgress(
                WriteOperationEvent(operationId: handle.operationId, action: .trash, status: .running))
        }
    }

    func release() { held.open() }

    private let other = OtherWindow()
    private let held = Held()

    @MainActor
    final class OtherWindow: WriteOperationWindow {
        var isClosed = false
        func receive(_ message: WriteOperationMessage) throws {}
    }

    @MainActor
    final class Held {
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

    func close() async {
        release()
        await coordinator.shutDown(maxWaitMs: 0)
        root.remove()
    }
}

@MainActor
@Suite struct LocalWriteActionsTests {
    // MARK: Rename

    // F-243 F-300 F-302 T-05cea347
    @Test func renamesWhatWasTypedThroughTheCoordinatorAndClosesTheField() async throws {
        let fixture = try Fixture()
        try fixture.make("a.txt")

        let outcome = await fixture.actions.commitRename(
            path: fixture.path("a.txt"), typed: "  b.txt ", hiddenFilesShown: false)
        #expect(outcome == .started)
        try await fixture.waitForEnds(1)

        #expect(fixture.ends.first?.status == .completed)
        #expect(!fixture.exists("a.txt") && fixture.exists("b.txt"))
        // Its end selects it in the folder on screen.
        #expect(fixture.host.refreshes.last?.selecting == [fixture.path("b.txt")])
        await fixture.close()
    }

    // The refusal goes to the rename field, which stays open; nothing else is shown.
    // F-302 T-91956dcd
    // B-CLIP-197
    @Test func givesTheRenameFieldTheRefusal() async throws {
        let fixture = try Fixture()
        try fixture.make("a.txt")
        try fixture.make("b.txt")

        let actions = fixture.actions
        #expect(
            await actions.commitRename(path: fixture.path("a.txt"), typed: "b.txt", hiddenFilesShown: false)
                == .refused("An item named “b.txt” already exists."))
        #expect(
            await actions.commitRename(path: fixture.path("a.txt"), typed: "a/b", hiddenFilesShown: false)
                == .refused(ItemNames.error(for: "a/b") ?? ""))
        // The name it has: nothing to do.
        #expect(
            await actions.commitRename(path: fixture.path("a.txt"), typed: "a.txt", hiddenFilesShown: false)
                == .unchanged)
        #expect(fixture.shown.isEmpty)
        #expect(!fixture.session.isWriteLocked)
        await fixture.close()
    }

    // F-243 T-8a7e5f61 T-e673aabb
    @Test func asksBeforeARenameWouldHideTheItemAndLeavesTheNameOnCancel() async throws {
        let fixture = try Fixture()
        try fixture.make("a.txt")

        #expect(
            await fixture.actions.commitRename(path: fixture.path("a.txt"), typed: ".a", hiddenFilesShown: false)
                == .unchanged)
        _ = await waitUntil { !fixture.asked.isEmpty }
        #expect(fixture.asked == [LocalWriteRules.dotNameQuestion])
        #expect(fixture.asked.first?.cancelIsDefault == true)
        #expect(fixture.exists("a.txt"))

        // While hidden files are shown, nothing is asked.
        #expect(
            await fixture.actions.commitRename(path: fixture.path("a.txt"), typed: ".a", hiddenFilesShown: true)
                == .started)
        try await fixture.waitForEnds(1)
        #expect(fixture.asked.count == 1)
        #expect(fixture.exists(".a"))
        await fixture.close()
    }

    // A folder of the tree is renamed in a prompt: a refusal stays in it with the reason, until a name is used.
    // F-243 F-302
    @Test func keepsTheRenamePromptOpenWithTheReasonANameWasRefused() async throws {
        let fixture = try Fixture()
        try fixture.make("Folder", folder: true)
        try fixture.make("Taken", folder: true)

        fixture.namesTyped = ["Taken", "Renamed"]
        await fixture.actions.renameInDialog(fixture.path("Folder"), hiddenFilesShown: false)
        #expect(
            fixture.prompts == [
                NamePrompt(
                    title: "Rename “Folder”", message: nil, label: "New name", submitLabel: "Rename",
                    initialName: "Folder")
            ])
        #expect(fixture.promptRefusals == ["An item named “Taken” already exists."])
        #expect(fixture.shown.isEmpty)
        try await fixture.waitForEnds(1)
        #expect(fixture.exists("Renamed") && !fixture.exists("Folder"))
        await fixture.close()
    }

    // F-247 T-a40a49e4 T-eccf7009
    @Test func saysAtOnceThatARenameWaitsForARunningOperation() async throws {
        let fixture = try Fixture()
        try fixture.make("a.txt")
        try fixture.anotherWindowRuns()

        #expect(
            await fixture.actions.commitRename(path: fixture.path("a.txt"), typed: "b.txt", hiddenFilesShown: false)
                == .unchanged)
        #expect(fixture.shown.map(\.title) == ["Couldn’t Rename"])
        #expect(fixture.shown.map(\.message) == [WriteDialogs.busyMessage])
        #expect(fixture.exists("a.txt"))
        await fixture.close()
    }

    // MARK: New Folder

    // In the folder on screen it is made at once with a free name, then named in its row: the one actually made,
    // which got the next free name when the listing didn't know of one made meanwhile.
    // F-243 F-297 F-299 T-35a7e9cf
    // B-CLIP-199 B-SEL-144 T-574fdd65 T-9f23bfcd
    @Test func makesTheFolderOnScreenAtOnceAndNamesTheOneActuallyMadeInItsRow() async throws {
        let fixture = try Fixture()
        // Made elsewhere meanwhile: the window hasn't listed it.
        try fixture.make("untitled folder", folder: true)

        let outcome = try await fixture.actions.newFolder(in: fixture.root.path)
        guard case .queued = outcome else {
            Issue.record("not started: \(outcome)")
            return
        }
        try await fixture.waitForEnds(1)

        #expect(fixture.exists("untitled folder 2"))
        #expect(fixture.session.pendingInlineRenamePath == fixture.path("untitled folder 2"))
        #expect(fixture.namesTyped.isEmpty)
        await fixture.close()
    }

    // F-247 T-f8ae027e T-d9459142
    @Test func doesntWaitToRenameALaterFolderAfterOneWasRefusedWhileBusy() async throws {
        let fixture = try Fixture()
        try fixture.anotherWindowRuns()
        #expect(try await fixture.actions.newFolder(in: fixture.root.path) == .cancelled)

        #expect(fixture.shown.map(\.title) == ["Couldn’t Make a New Folder"])
        #expect(fixture.session.pendingInlineRenamePath == nil)
        #expect(!fixture.exists("untitled folder"))
        await fixture.close()
    }

    // Elsewhere the name is asked for first, suggested free in the folder it goes into.
    // F-297 T-8cf4f276 T-71b8e8a7 T-3ae883e9
    // B-CLIP-199 B-SEL-144 T-56b88ca6
    @Test func asksTheNameOfAFolderMadeElsewhereAndBeforeItWouldBeHidden() async throws {
        let fixture = try Fixture()
        try fixture.make("Inner", folder: true)

        fixture.namesTyped = [".hidden"]
        fixture.answers = [false]
        #expect(try await fixture.actions.newFolder(in: fixture.path("Inner"), selectInTree: true) == .cancelled)
        #expect(fixture.asked == [LocalWriteRules.dotNameQuestion])
        #expect(!fixture.exists("Inner/.hidden"))

        fixture.namesTyped = ["Made"]
        let outcome = try await fixture.actions.newFolder(in: fixture.path("Inner"), selectInTree: true)
        guard case .queued = outcome else {
            Issue.record("not started: \(outcome)")
            return
        }
        #expect(fixture.session.pendingTreeSelectionPath == fixture.path("Inner/Made"))
        try await fixture.waitForEnds(1)
        #expect(fixture.exists("Inner/Made"))

        // A name taken once it was asked about is refused in a dialog.
        fixture.namesTyped = [".Made"]
        fixture.answers = [true]
        try FileManager.default.createDirectory(atPath: fixture.path("Inner/.Made"), withIntermediateDirectories: false)
        #expect(
            try await fixture.actions.newFolder(in: fixture.path("Inner"))
                == .error(message: "An item named “.Made” already exists."))
        #expect(fixture.shown.last?.title == "Couldn’t Make a New Folder")
        #expect(fixture.promptRefusals.isEmpty)
        await fixture.close()
    }

    // The prompt says where the folder goes; a bad name, or one taken, stays in it with the reason, what was typed
    // kept, until a name is made or the prompt is cancelled.
    // F-297
    // T-56b88ca6
    @Test func keepsTheNewFolderPromptOpenWithTheReasonANameWasRefused() async throws {
        let fixture = try Fixture()
        try fixture.make("Inner/Made", folder: true)

        fixture.namesTyped = ["Made", "a/b", "Other"]
        let outcome = try await fixture.actions.newFolder(in: fixture.path("Inner"), selectInTree: true)
        guard case .queued = outcome else {
            Issue.record("not started: \(outcome)")
            return
        }
        #expect(
            fixture.prompts == [
                NamePrompt(
                    title: "New Folder", message: "In “Inner”", label: "Folder name", submitLabel: "Create Folder",
                    initialName: "untitled folder")
            ])
        #expect(fixture.promptRefusals == ["An item named “Made” already exists.", ItemNames.error(for: "a/b") ?? ""])
        #expect(fixture.shown.isEmpty)
        try await fixture.waitForEnds(1)
        #expect(fixture.exists("Inner/Other"))

        // Cancelled after a refusal: nothing is made, and nothing else is said.
        fixture.namesTyped = ["Made", nil]
        #expect(try await fixture.actions.newFolder(in: fixture.path("Inner"), selectInTree: true) == .cancelled)
        #expect(fixture.promptRefusals.count == 3)
        #expect(fixture.shown.isEmpty)
        #expect(!fixture.session.isWriteLocked)
        await fixture.close()
    }

    // F-297 T-04593422
    @Test func saysWhyTheFolderCouldntBeMadeInTheFolderOnScreen() async throws {
        let fixture = try Fixture()
        fixture.host.currentPath = fixture.path("Gone")

        #expect(
            try await fixture.actions.newFolder(in: fixture.path("Gone"))
                == .error(message: "“Gone” no longer exists."))
        #expect(fixture.shown.map(\.title) == ["The folder couldn’t be made"])
        #expect(fixture.session.pendingInlineRenamePath == nil)
        #expect(!fixture.session.isWriteLocked)
        await fixture.close()
    }

    // MARK: Trash and Delete Immediately

    // F-290 F-291 T-bb64604a
    @Test func movesTheItemsToTheTrash() async throws {
        let fixture = try Fixture()
        try fixture.make("a.txt")
        try fixture.make("b.txt")

        _ = try await fixture.actions.trash([fixture.path("a.txt"), fixture.path("b.txt")])
        try await fixture.waitForEnds(1)

        #expect(fixture.ends.first?.status == .completed)
        #expect(fixture.exists(".Trash/a.txt") && fixture.exists(".Trash/b.txt"))
        #expect(fixture.asked.isEmpty)
        await fixture.close()
    }

    // A quick double ⌘⌫: the lock is taken before the request is sent, so the second press finds it taken.
    // F-247 T-b45fe448 T-aca62778
    // B-CLIP-109
    @Test func sendsOneTrashRequestForAQuickDoubleCommandDelete() async throws {
        let fixture = try Fixture()
        try fixture.make("a.txt")
        let actions = fixture.actions

        async let first = actions.trash([fixture.path("a.txt")])
        async let second = actions.trash([fixture.path("a.txt")])
        let outcomes = try await [first, second]
        try await fixture.waitForEnds(1)

        #expect(outcomes.filter { if case .queued = $0 { true } else { false } }.count == 1)
        #expect(fixture.shown.map(\.title) == ["Couldn’t Move to Trash"])
        #expect(fixture.shown.map(\.message) == [WriteDialogs.busyMessage])
        await fixture.close()
    }

    // What is in the Trash is never moved there again, from the keyboard or a menu.
    // F-290 T-daa5fb71
    @Test func trashesNothingThatIsInTheTrash() async throws {
        let fixture = try Fixture()
        try fixture.make(".Trash/old.txt")

        #expect(try await fixture.actions.trash([fixture.path(".Trash/old.txt")]) == .cancelled)
        #expect(fixture.shown.isEmpty)
        #expect(fixture.exists(".Trash/old.txt"))
        await fixture.close()
    }

    // F-290 T-7b041681
    // B-CLIP-196
    @Test func saysWhyTheTrashCouldntStartAndLeavesNoProgressBehind() async throws {
        let fixture = try Fixture()

        #expect(
            try await fixture.actions.trash([fixture.path("Documents")])
                == .error(message: "“Documents” can't be moved to the Trash."))
        #expect(fixture.shown.map(\.title) == ["Couldn’t Move to Trash"])
        #expect(fixture.session.card == nil)
        await fixture.close()
    }

    // F-247 T-90958c14
    @Test func saysAnotherOperationIsRunningWhenTheCoordinatorFindsOne() async throws {
        let fixture = try Fixture()
        try fixture.make("a.txt")
        // The slot is taken without this window knowing of it.
        try fixture.anotherWindowRuns(told: false)
        let outcome = try await fixture.actions.trash([fixture.path("a.txt")])

        #expect(outcome == .blocked(message: WriteDialogs.busyMessage))
        #expect(fixture.shown.map(\.message) == [WriteDialogs.busyMessage])
        #expect(fixture.session.card == nil)
        await fixture.close()
    }

    // Their disk has no Trash: as Finder does, the person is asked, Cancel the default, and they are deleted
    // immediately on Delete, nothing on Cancel.
    // F-294 F-295 T-e4a54dd7 T-bedd9795
    // B-CLIP-133
    @Test func asksAndDeletesImmediatelyWhatItsDiskCouldntTakeToTheTrash() async throws {
        let fixture = try Fixture()
        try fixture.make("Share/a.txt")
        try fixture.make("Share/b.txt")

        fixture.answers = [false]
        _ = try await fixture.actions.trash([fixture.path("Share/a.txt")])
        try await fixture.waitForEnds(1)
        _ = await waitUntil { !fixture.asked.isEmpty }
        #expect(fixture.asked == [LocalWriteRules.deleteWithoutTrashQuestion([fixture.path("Share/a.txt")])])
        #expect(fixture.asked.first?.cancelIsDefault == true)
        #expect(fixture.exists("Share/a.txt"))

        fixture.answers = [true]
        _ = try await fixture.actions.trash([fixture.path("Share/b.txt")])
        try await fixture.waitForEnds(2)
        try await fixture.waitForEnds(3)
        #expect(fixture.ends.last?.action == .deleteImmediately)
        #expect(!fixture.exists("Share/b.txt"))
        #expect(fixture.exists("Share/a.txt"))
        await fixture.close()
    }

    // F-294 T-6f4bb610
    // B-CLIP-133
    @Test func reportsOtherTrashFailuresAsFailuresWithoutAsking() async throws {
        let fixture = try Fixture()
        try fixture.make("Share/a.txt")

        _ = try await fixture.actions.trash([fixture.path("Share/a.txt"), fixture.path("gone.txt")])
        try await fixture.waitForEnds(1)
        // The gone item counts as done; only the no-Trash one failed.
        _ = await waitUntil { !fixture.asked.isEmpty }
        #expect(fixture.asked.count == 1)

        let failing = try Fixture()
        try failing.make("Share/a.txt")
        try failing.make("locked.txt")
        #expect(lchflags(failing.path("locked.txt"), UInt32(UF_IMMUTABLE)) == 0)
        _ = try await failing.actions.trash([failing.path("Share/a.txt"), failing.path("locked.txt")])
        try await failing.waitForEnds(1)
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(failing.asked.isEmpty)
        #expect(failing.ends.first?.status == .failed)
        await fixture.close()
        await failing.close()
    }

    // Asked about first, Cancel the default; only what is in a Trash.
    // F-295 F-296 T-54e37a9c
    // B-CLIP-196
    @Test func deletesImmediatelyAfterAskingAndSaysWhyItCouldntStart() async throws {
        let fixture = try Fixture()
        try fixture.make(".Trash/old.txt")
        try fixture.make("kept.txt")

        fixture.answers = [false]
        #expect(try await fixture.actions.deleteImmediately([fixture.path(".Trash/old.txt")]) == .cancelled)
        #expect(fixture.asked == [LocalWriteRules.deleteImmediatelyQuestion([fixture.path(".Trash/old.txt")])])
        #expect(fixture.exists(".Trash/old.txt"))

        fixture.answers = [true]
        _ = try await fixture.actions.deleteImmediately([fixture.path(".Trash/old.txt")])
        try await fixture.waitForEnds(1)
        #expect(!fixture.exists(".Trash/old.txt"))

        fixture.answers = [true]
        #expect(
            try await fixture.actions.deleteImmediately([fixture.path("kept.txt")])
                == .error(message: "“kept.txt” isn't in the Trash, so it can't be deleted immediately."))
        #expect(fixture.shown.map(\.title) == ["Couldn’t Delete"])
        #expect(fixture.exists("kept.txt"))
        await fixture.close()
    }

    // A folder of the tree is moved to the Trash after asking.
    // F-290 T-9bd51531
    // B-CLIP-132 B-TREE-146
    @Test func asksBeforeTrashingATreeFolder() async throws {
        let fixture = try Fixture()
        try fixture.make("Folder", folder: true)

        fixture.answers = [false]
        #expect(try await fixture.actions.trash([fixture.path("Folder")], askFirst: true) == .cancelled)
        #expect(fixture.asked.map(\.title) == ["Move “Folder” to the Trash?"])
        #expect(fixture.exists("Folder"))

        fixture.answers = [true]
        _ = try await fixture.actions.trash([fixture.path("Folder")], askFirst: true)
        try await fixture.waitForEnds(1)
        #expect(fixture.exists(".Trash/Folder"))
        await fixture.close()
    }

    // MARK: Empty Trash

    // F-304 F-305 T-dc52b88b T-a73c478d
    // B-CLIP-049 T-33ba7245
    @Test func emptiesTheTrashAfterAskingAndLetsGoOfClipboardItemsThatWereInIt() async throws {
        let fixture = try Fixture()
        var emptied = 0
        let trashed = fixture.path(".Trash/old.txt")
        fixture.clipboard.set(
            .ready(
                mode: .copy, sourcePaths: [trashed, fixture.path("kept.txt")], sourceEntries: [:], capturedAt: "t1"),
            from: nil)

        fixture.answers = [false]
        let actions = fixture.actions
        actions.emptyTrashRunner = {
            emptied += 1
            return (true, nil)
        }
        #expect(try await actions.emptyTrash() == .cancelled)
        #expect(fixture.asked == [LocalWriteRules.emptyTrashQuestion])
        #expect(emptied == 0)

        fixture.answers = [true]
        _ = try await actions.emptyTrash()
        #expect(emptied == 1)
        guard case .ready(_, let kept, _, _) = fixture.clipboard.contents else {
            Issue.record("the clipboard was emptied")
            return
        }
        #expect(kept == [fixture.path("kept.txt")])
        await fixture.close()
    }

    // F-304 T-6200e703
    @Test func refusesEmptyTrashWithoutAskingWhileAnotherOperationRuns() async throws {
        let fixture = try Fixture()
        try fixture.anotherWindowRuns()
        let outcome = try await fixture.actions.emptyTrash()

        #expect(outcome == .cancelled)
        #expect(fixture.asked.isEmpty)
        #expect(fixture.shown.map(\.title) == ["Couldn’t Empty the Trash"])
        await fixture.close()
    }

    // F-305 T-9407a866
    // T-3a244590
    @Test func saysWhyTheTrashWasntEmptied() async throws {
        let fixture = try Fixture()
        fixture.answers = [true]
        let actions = fixture.actions
        actions.emptyTrashRunner = {
            (false, "execution error: Not authorized to send Apple events to Finder. (-1743)")
        }

        _ = try await actions.emptyTrash()
        #expect(fixture.shown.map(\.title) == ["Couldn’t Empty the Trash"])
        #expect(fixture.shown.first?.message.hasPrefix("File Trail needs permission to control Finder.") == true)
        await fixture.close()
    }

    // MARK: Batch rename (`startBatchRename`; the sheet that settles the names is P6-03's)

    // F-570
    @Test func renamesWhatTheSheetSettledThroughTheCoordinator() async throws {
        let fixture = try Fixture()
        try fixture.make("a.txt")
        try fixture.make("b.txt")
        try fixture.make("sub", folder: true)
        let actions = fixture.actions

        let outcome = await actions.batchRename(
            BatchRenameRequest(items: [
                .init(sourcePath: fixture.path("a.txt"), destinationName: "b.txt", isFolder: false),
                .init(sourcePath: fixture.path("b.txt"), destinationName: "a.txt", isFolder: false),
                .init(sourcePath: fixture.path("sub"), destinationName: "Day 1", isFolder: true),
            ]))
        guard case .queued = outcome else {
            Issue.record("not started: \(outcome)")
            return
        }
        try await fixture.waitForEnds(1)

        #expect(fixture.ends.first?.action == .batchRename)
        #expect(fixture.ends.first?.status == .completed)
        #expect(fixture.exists("a.txt") && fixture.exists("b.txt") && fixture.exists("Day 1"))
        // Which items were folders, for the sheet to open again on those that weren't renamed.
        #expect(actions.batchRenameFolders[fixture.path("sub")] == true)
        #expect(actions.batchRenameFolders[fixture.path("a.txt")] == false)
        await fixture.close()
    }

    // F-396
    @Test func saysWhyABatchRenameWasRefusedBeforeItStarted() async throws {
        let fixture = try Fixture()
        try fixture.make("a.txt")

        let outcome = await fixture.actions.batchRename(
            BatchRenameRequest(items: [
                .init(sourcePath: fixture.path("a.txt"), destinationName: "a.txt", isFolder: false)
            ]))

        #expect(outcome == .error(message: "Nothing would be renamed."))
        #expect(fixture.shown.map(\.title) == ["Couldn’t Rename"])
        #expect(fixture.shown.map(\.message) == ["Nothing would be renamed."])
        #expect(fixture.session.card == nil)
        await fixture.close()
    }

    @Test func saysAtOnceThatABatchRenameWaitsForARunningOperation() async throws {
        let fixture = try Fixture()
        try fixture.make("a.txt")
        try fixture.anotherWindowRuns()

        let outcome = await fixture.actions.batchRename(
            BatchRenameRequest(items: [
                .init(sourcePath: fixture.path("a.txt"), destinationName: "b.txt", isFolder: false)
            ]))

        #expect(outcome == .cancelled)
        #expect(fixture.shown.map(\.title) == ["Couldn’t Rename"])
        #expect(fixture.shown.map(\.message) == [WriteDialogs.busyMessage])
        #expect(fixture.exists("a.txt"))
        await fixture.close()
    }
}
