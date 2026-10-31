// Review round 1 of P3-05: a cut pasted is a Move To (useExplorerActions.ts startPasteFromClipboard), the startup and
// recovery notices' words (main.ts), the write commands' pane rules (useExplorerShortcuts.ts, shortcutPolicy.ts), the
// tree branches a write reads again (useExplorerNavigationController.ts refreshDirectory), and the folder watch held
// while a write is locked (App.tsx useFolderWatch `held`)
import AppKit
import FTFileSystem
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit
@testable import FTOperations

/// A write service whose analyses finish at once with nothing to report.
private final class StubWriteService: CoordinatorWriteService, @unchecked Sendable {
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
private final class FakeHost: WriteSessionHost {
    var isClosed = false
    var activeTabID: Int? = 1
    var currentPath = "/Users/demo/Folder"
    var selectedPaths: [String] = []
    var isSearching = false
    var selectedTreePath: String?

    func applyWriteEnd(_ refresh: WriteEndRefresh) {}
    func followMovesOnScreen(_ moves: [PathMove]) {}
    func writeLockChanged() {}
}

@MainActor
private final class Shown {
    var titles: [String] = []
    var messages: [String] = []
    var infos: [String] = []

    var dialogs: WriteDialogs {
        var dialogs = WriteDialogs()
        dialogs.show = { [unowned self] title, message, _ in
            titles.append(title)
            messages.append(message)
        }
        dialogs.showInfo = { [unowned self] title, message, _ in
            infos.append(title)
            messages.append(message)
        }
        return dialogs
    }
}

@MainActor
@Suite struct ParityProbeTests {
    private let service = StubWriteService()
    private let host = FakeHost()
    private let clipboard = SharedClipboard()
    private let coordinator: WriteCoordinator
    private let session: ExplorerWriteSession

    init() {
        coordinator = WriteCoordinator(writeService: service, options: WriteCoordinatorOptions())
        session = ExplorerWriteSession(coordinator: coordinator, host: host, clipboard: clipboard)
    }

    private func cut() {
        clipboard.set(
            .ready(
                mode: .cut, sourcePaths: ["/Users/demo/a.txt"], sourceEntries: [:],
                capturedAt: "2026-10-08T10:00:00.000Z"), from: nil)
    }

    // B-CLIP-107: a cut pasted while a write runs is refused as a move ("Couldn't Move"), as
    // startPasteFromClipboard's `request.mode === "cut" ? "move_to" : "paste"` asks.
    @Test func aCutPastedWhileBusyIsRefusedAsAMove() async {
        cut()
        session.applyCard(WriteOperationCardState(action: .copyTo, stage: .running, targetPath: "/x"))
        let shown = Shown()
        _ = await WindowWriteActions(session: session, tab: nil, dialogs: shown.dialogs).paste(
            into: "/Users/demo/Folder")
        #expect(shown.titles == ["Couldn\u{2019}t Move"])
    }

    // B-CLIP-110: its card is a move's, and what couldn't be checked is said of moving.
    @Test func aCutPastedIsAMoveOnItsCard() async {
        cut()
        var actions: [WriteOperationAction] = []
        let observation = session.observe { event in
            if case .card(let card?) = event { actions.append(card.action) }
        }
        let shown = Shown()
        _ = await WindowWriteActions(session: session, tab: nil, dialogs: shown.dialogs).paste(
            into: "/Users/demo/Folder")
        withExtendedLifetime(observation) {}
        #expect(actions == [.moveTo])
        #expect(shown.titles == ["Couldn\u{2019}t Move"])
        #expect(shown.messages == ["File Trail couldn\u{2019}t check the items to move. Nothing was changed."])
    }

    // A copy pasted stays a paste.
    @Test func aCopyPastedWhileBusyIsRefusedAsAPaste() async {
        clipboard.set(
            .ready(mode: .copy, sourcePaths: ["/Users/demo/a.txt"], sourceEntries: [:], capturedAt: "t"), from: nil)
        session.applyCard(WriteOperationCardState(action: .copyTo, stage: .running, targetPath: "/x"))
        let shown = Shown()
        _ = await WindowWriteActions(session: session, tab: nil, dialogs: shown.dialogs).paste(
            into: "/Users/demo/Folder")
        #expect(shown.titles == ["Couldn\u{2019}t Paste"])
    }

    // Work a crash cut short is told once the window is up, as a warning with main.ts's words.
    @Test func startupNoticesSayWorkWasCutShort() {
        let shown = Shown()
        AppWriteOperations.showStartupNotices(["One.", "Two."], dialogs: shown.dialogs, window: nil)
        AppWriteOperations.showStartupNotices([], dialogs: shown.dialogs, window: nil)
        #expect(shown.titles == ["Work was cut short when File Trail last stopped"])
        #expect(shown.messages == ["One.\n\nTwo."])
        #expect(shown.infos.isEmpty)
    }

    // Items that waited for their disk are told as an information, one or several.
    @Test func recoveryNoticesNameOneOrSeveral() {
        let shown = Shown()
        AppWriteOperations.showRecoveryNotices(["One."], dialogs: shown.dialogs, window: nil)
        AppWriteOperations.showRecoveryNotices(["One.", "Two."], dialogs: shown.dialogs, window: nil)
        AppWriteOperations.showRecoveryNotices([], dialogs: shown.dialogs, window: nil)
        #expect(
            shown.infos == [
                "An item waiting for its disk is in place now", "Items waiting for their disk are in place now",
            ])
        #expect(shown.messages == ["One.", "One.\n\nTwo."])
        #expect(shown.titles.isEmpty)
    }

    // Cut and Copy from the tree take one of its folders, never a favorite, which only points to one
    // (TREE_FOLDER_ONLY_COMMANDS, getFileSystemItemPath).
    // B-TREE-150 B-TREE-151 T-68c0297a T-c1650cf7 T-de1cd805 T-f50b4602
    @Test func cutAndCopyOfAFavoriteDoNothing() {
        let favorite = ShortcutContext(focusedPane: .tree, selectedTreeTargetKind: .favorite)
        let folder = ShortcutContext(focusedPane: .tree, selectedTreeTargetKind: .filesystemFolder)
        for command in [RendererCommand.editCut, .editCopy, .cutSelection, .copySelection] {
            #expect(!MainWindowController.canRunWriteCommand(command, favorite))
            #expect(MainWindowController.canRunWriteCommand(command, folder))
        }
        #expect(
            MainWindowController.clipboardSource(
                focusedPane: .tree, treeTargetKind: .favorite, treeTargetPath: "/Users/demo/Projects",
                selectedPaths: ["/Users/demo/a.txt"]) == [])
        #expect(
            MainWindowController.clipboardSource(
                focusedPane: .tree, treeTargetKind: .filesystemFolder, treeTargetPath: "/Users/demo/Projects",
                selectedPaths: ["/Users/demo/a.txt"]) == ["/Users/demo/Projects"])
        #expect(
            MainWindowController.clipboardSource(
                focusedPane: .content, treeTargetKind: .filesystemFolder, treeTargetPath: "/Users/demo/Projects",
                selectedPaths: ["/Users/demo/a.txt"]) == ["/Users/demo/a.txt"])
    }

    // The list's commands (Move To, Duplicate, Rename, Trash, New Folder) act only with the list focused: never on a
    // selection left in the list while the tree has the keyboard, or with no pane focused. Paste goes into the folder
    // on screen even with no pane focused; Undo, Redo and Empty Trash act from anywhere.
    // B-SEL-173 B-TREE-152 B-TREE-154 T-11201414 T-3f697d1f T-7778e453 T-81bf2f83 T-ef3db613 T-ffb0bc5e
    @Test func listCommandsNeedTheListFocused() {
        let tree = ShortcutContext(focusedPane: .tree, selectedTreeTargetKind: .filesystemFolder)
        let none = ShortcutContext(focusedPane: nil)
        let list = ShortcutContext(focusedPane: .content)
        for command in [
            RendererCommand.moveSelection, .duplicateSelection, .renameSelection, .trashSelection, .newFolder,
        ] {
            #expect(!MainWindowController.canRunWriteCommand(command, tree))
            #expect(!MainWindowController.canRunWriteCommand(command, none))
            #expect(MainWindowController.canRunWriteCommand(command, list))
        }
        for command in [RendererCommand.editPaste, .pasteSelection] {
            #expect(MainWindowController.canRunWriteCommand(command, none))
            #expect(MainWindowController.canRunWriteCommand(command, tree))
        }
        for command in [RendererCommand.undo, .redo, .emptyTrash] {
            #expect(MainWindowController.canRunWriteCommand(command, none))
            #expect(MainWindowController.canRunWriteCommand(command, tree))
        }
    }

    // After a write, only the branches it touched are read again (extraTreeReloadPaths), each folder once, not every
    // open branch of the tree.
    // B-TREE-093 T-0c451ae2
    @Test func aWriteReadsOnlyTheBranchesItTouched() async {
        let model = SidebarModel()
        var children: [String: [TreePaths.Child]] = [:]
        func folder(_ path: String, _ names: [String]) {
            children[path] = names.map {
                TreePaths.Child(path: "\(path)/\($0)", name: $0, isHidden: false, isSymlink: false)
            }
        }
        let folders = (0..<20).map { "f\($0)" }
        folder("/Users/demo", ["Documents"] + folders)
        folder("/Users/demo/Documents", ["a"])
        for name in folders { folder("/Users/demo/\(name)", ["inner"]) }
        var reads: [String] = []
        model.readChildren = { path, _ in
            reads.append(path)
            return children[path] ?? []
        }
        model.restore(
            rootPath: "/Users/demo", selected: nil, subview: .tree, favoritesExpanded: true, locationsExpanded: true)
        model.currentPath = "/Users/demo/Documents"
        await model.loadChildren("/Users/demo", expandOnSuccess: true)
        for name in ["Documents"] + folders { await model.loadChildren("/Users/demo/\(name)", expandOnSuccess: true) }
        reads = []
        // A paste of /Users/demo/f0/a into Documents.
        await model.refreshWriteBranches([
            "/Users/demo/Documents", "/Users/demo/f0", "/Users/demo/Documents/a", "/Users/demo/Documents",
        ])
        #expect(reads == ["/Users/demo/Documents", "/Users/demo/f0", "/Users/demo/Documents/a"])
    }

    // T-b39e8166: a move remaps the folder on screen: its old branch is read again all the way down its open folders.
    @Test func aWriteReadsTheOpenFoldersBelowABranchItTouched() async {
        let model = SidebarModel()
        func child(_ path: String) -> TreePaths.Child {
            TreePaths.Child(path: path, name: NodePath.basename(path), isHidden: false, isSymlink: false)
        }
        let children: [String: [TreePaths.Child]] = [
            "/tmp": [child("/tmp/test1"), child("/tmp/closed")],
            "/tmp/test1": [child("/tmp/test1/kotlin")],
            "/tmp/test1/kotlin": [child("/tmp/test1/kotlin/src")],
            "/tmp/closed": [child("/tmp/closed/inner")],
        ]
        var reads: [String] = []
        model.readChildren = { path, _ in
            reads.append(path)
            return children[path] ?? []
        }
        model.restore(rootPath: "/tmp", selected: nil, subview: .tree, favoritesExpanded: true, locationsExpanded: true)
        model.currentPath = "/tmp/test1/kotlin"
        for path in ["/tmp", "/tmp/test1", "/tmp/test1/kotlin"] {
            await model.loadChildren(path, expandOnSuccess: true)
        }
        reads = []
        await model.refreshWriteBranches(["/tmp"])
        #expect(reads == ["/tmp", "/tmp/test1", "/tmp/test1/kotlin"])
    }
}

extension ExplorerWindowlessTests {
    /// B-CLIP-147, B-VIEW-187: changes to the folder on screen wait while a write runs in this window or another,
    /// and are read once it is over.
    @MainActor @Suite(.windowlessAlone) struct WriteHoldsFolderChangesTests {
        // B-CLIP-147
        @Test func changesWaitWhileAWriteIsLocked() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let operations = AppWriteOperations(
                userData: harness.folder.url, directoryService: DirectoryService(), windows: harness.windows,
                trash: .standIn,
                log: { _ in })
            let group = try #require(tab.group)
            let session = operations.session(for: group)
            session.applyCard(WriteOperationCardState(action: .copyTo, stage: .running, targetPath: "/x"))
            #expect(tab.isWriteLocked)
            harness.windows.folderChanged(
                windowID: tab.windowID, FolderChange(path: tab.folder.path, changedPaths: ["/x/a"]))
            #expect(tab.pendingChange?.changedPaths == ["/x/a"])
            session.applyCard(nil)
            #expect(tab.pendingChange == nil)
            withExtendedLifetime(operations) {}
            await harness.close()
        }
    }
}
