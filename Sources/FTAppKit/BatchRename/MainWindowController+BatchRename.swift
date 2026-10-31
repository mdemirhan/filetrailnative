// Port of openRenameDialog's branch for several items, openBatchRenameFor, openBatchRenameSheet, startBatchRename and
// the batch_rename branch of retryFailedCopyPasteItems (apps/desktop/src/renderer/hooks/useExplorerActions.ts
// 2425-2443, 3649-3760), and of the sheet's part of apps/desktop/src/renderer/App.tsx (its mounting, Escape from
// anywhere, explorerFocusSuppressed and copyPasteModalOpen)
import AppKit
import FTFileSystem
import FTFoundation
import FTOperations

extension MainWindowController {
    /// How the items' checks are made for a home folder: on the disk, off the main thread. A test gives its own.
    static var batchRenameInspector: @MainActor (_ homePath: String) -> BatchRenameSheetModel.Inspector = { home in
        let deps = BatchRenameInspectDeps.native(homePath: home)
        return { request in await BatchRenameInspect.inspect(request, deps) }
    }

    /// Starts a rename the sheet settled through the file operations; a test records the request instead.
    static var runBatchRename: @MainActor (WindowWriteActions, BatchRenameRequest) async -> Void = { actions, request in
        _ = await actions.batchRename(request)
    }

    /// Which items of the last rename of several were folders, by explorer window and by the path asked for: the sheet
    /// opens again on the items that weren't renamed, each numbered as it was (`batchRenameFoldersRef`).
    private static var batchRenameFolders: [Int: [String: Bool]] = [:]

    /// The Rename sheet for several items, while it is up.
    var batchRenameSheet: BatchRenameSheetView? {
        dialogs.lazy.compactMap { $0.panel as? BatchRenameSheetView }.first
    }

    /// Whether the Rename sheet is up: the panes take no keyboard and the list's shortcuts wait (B-DLG-091).
    var isBatchRenameOpen: Bool { batchRenameSheet != nil }

    /// Rename, F2 and Return on several items open the sheet (`openRenameDialog`).
    func installBatchRename() {
        openBatchRename = { [weak self] entries in self?.openBatchRename(for: entries) }
    }

    private var batchRenameWindowKey: Int { group?.windowID ?? windowID }

    /// `openBatchRenameFor`: the items in the order the list (or the search results) shows them, which numbers them. A
    /// folder, or a link to one, is renamed whole; a package keeps its extension.
    func openBatchRename(for entries: [DirectoryEntry]) {
        let wanted = Set(entries.map(\.path))
        let targets = content.entries.filter { wanted.contains($0.path) }.map {
            BatchRenameTarget(path: $0.path, name: $0.name, isFolder: $0.isDirectoryLike)
        }
        openBatchRenameSheet(targets)
    }

    /// `openBatchRenameSheet`, every way in: the menus close; a write running here or in another window is said
    /// instead; no items, no sheet. The keyboard leaves where it was and the tree's type-ahead is cleared. The last
    /// settings and the presets are read as it opens, and the items are checked.
    func openBatchRenameSheet(_ targets: [BatchRenameTarget]) {
        AppMenuPresenter.shared.close()
        let actions = writeActions
        if let actions, actions.refuseWhileBusy(.operation(.batchRename)) { return }
        guard !targets.isEmpty, let window, batchRenameSheet == nil else { return }
        sidebarController.model.clearTypeahead()
        let home = actions?.session.coordinator.homePath ?? FileManager.default.homeDirectoryForCurrentUser.path
        let model = BatchRenameSheetModel(
            inspector: Self.batchRenameInspector(home),
            readSaved: { [weak self] in
                let preferences = self?.preferences ?? AppPreferences.defaults()
                return .init(settings: preferences.batchRenameSettings, presets: preferences.batchRenamePresets)
            },
            save: { [weak self] patch in self?.updatePreferences(patch) },
            log: { NSLog("filetrail.batchRename: %@", $0) })
        model.open(targets)
        let sheet = BatchRenameSheetView(model: model)
        let scrim = DialogScrim(panel: sheet, placement: .sheet)
        scrim.setAccessibilityIdentifier("batchRename.scrim")
        sheet.onCancel = { [weak model, weak scrim] in
            model?.close()
            scrim?.dismiss()
        }
        sheet.onRename = { [weak self, weak model, weak scrim] request in
            // The sheet closes (its settings kept), then the rename starts.
            model?.close()
            scrim?.dismiss()
            self?.startBatchRename(request)
        }
        scrim.present(in: window)
        sheet.takeKeyboard()
    }

    /// `startBatchRename`: renames the items the sheet settled. A write started meanwhile is said, and the sheet stays
    /// closed; a start that fails says why under "Couldn’t Rename". Which items were folders is kept for Try Again.
    func startBatchRename(_ request: BatchRenameRequest) {
        guard let actions = writeActions else { return }
        if actions.refuseWhileBusy(.operation(.batchRename)) { return }
        Self.batchRenameFolders[batchRenameWindowKey] = Dictionary(
            request.items.map { ($0.sourcePath, $0.isFolder) }, uniquingKeysWith: { _, last in last })
        let run = Self.runBatchRename
        Task { await run(actions, request) }
    }

    /// Try Again after a rename of several left items not renamed (the result sheet calls it once it is dismissed): the
    /// sheet opens again on those items, where each is now (`destinationPath ?? sourcePath`), taken from the result and
    /// not from the list, as one may be hidden or not listed. Each is a folder as it was when it was asked for.
    func reopenBatchRename(after event: WriteOperationEvent) {
        guard event.action == .batchRename, let result = event.result else { return }
        openBatchRenameSheet(Self.retryTargets(result, folders: Self.batchRenameFolders[batchRenameWindowKey] ?? [:]))
    }

    /// The targets of a Try Again: the items not completed, under their names now.
    static func retryTargets(_ result: WriteOperationResult, folders: [String: Bool]) -> [BatchRenameTarget] {
        result.items.compactMap { item in
            guard item.status != .completed, let path = item.destinationPath ?? item.sourcePath, !path.isEmpty else {
                return nil
            }
            let isFolder = folders[item.sourcePath ?? path] ?? false
            return BatchRenameTarget(path: path, name: NodePath.basename(path), isFolder: isFolder)
        }
    }
}
