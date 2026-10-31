// Port of what apps/desktop/src/renderer/hooks/useExplorerActions.ts does for the Info panel: copyGetInfoPath/Name, the
// open, terminal, Finder and editor actions, runContextSubmenuAction, changeDefaultApp and Always Open With
import AppKit
import FTFileSystem
import FTFoundation

/// The system actions behind the Info panel's buttons, with the notices the original shows when one fails.
@MainActor
final class InfoActions {
    unowned let host: MainWindowController
    /// Always Open With changed what a kind opens in: the Open With answers are asked again.
    var onLookupsForgotten: () -> Void = {}
    /// Shows a notice; a window in a test replaces it.
    var notice: (_ title: String, _ message: String) -> Void
    /// Asks the Always Open With question; true to go on.
    var confirmAlways: @MainActor (_ appName: String, _ kindName: String?) async -> Bool
    /// What opens files and apps; tests give their own, so nothing opens on this Mac.
    var opener: SystemOpener = .workspace
    /// Makes an app what a kind of file opens in; tests give their own, so they leave this Mac's defaults alone.
    var setDefaultApplication: @MainActor (_ appPath: String, _ contentType: String) async -> OperationResult = {
        await SystemActions.setDefaultApplication(applicationPath: $0, contentType: $1)
    }
    /// The Other… picker, nil when nothing was chosen; tests give their own, so no panel opens.
    var pickApplication: @MainActor (NSWindow?) async -> (path: String, name: String)? = { window in
        let choice = await SystemPickers.pickApplication(window: window)
        guard !choice.canceled, let path = choice.appPath, let name = choice.appName else { return nil }
        return (path, name)
    }
    /// Where Copy Path and Copy Name put the text; tests give it a private pasteboard.
    var pasteboard: NSPasteboard = .general

    init(host: MainWindowController) {
        self.host = host
        // The window's alerts (`showModalNotice`, `confirmAlwaysOpenWith`).
        notice = { [weak host] title, message in
            host?.showNotice(title: title, message: message)
        }
        confirmAlways = { [weak host] appName, kindName in
            await InWindowNoticePresenter().confirmAlwaysOpenWith(
                appName: appName, kindName: kindName, in: host?.window)
        }
    }

    // MARK: Copy

    func copy(_ text: String, what: String) -> Bool {
        let board = pasteboard
        board.clearContents()
        guard board.setString(text, forType: .string) else {
            notice("Couldn’t Copy the \(what)", "File Trail couldn’t put it on the clipboard.")
            return false
        }
        return true
    }

    // MARK: Open

    /// `openPathExternally`: a failure is only logged.
    func openExternally(_ path: String) {
        if host.noteUseAndOpenDiskImage(path) { return }
        let opener = opener
        Task { @MainActor in
            ActionNoticeText.logOpenFailure(await SystemActions.openPath(path, opener: opener))
        }
    }

    func openInTerminal(_ path: String) {
        host.onFolderUsed?()
        let terminal = host.preferences.terminalApp
        let opener = opener
        Task { @MainActor [weak self] in
            let result = await SystemActions.openInTerminal(path: path, terminalApp: terminal, opener: opener)
            if !result.ok {
                self?.notice(ActionNoticeText.terminalFailureTitle, ActionNoticeText.terminalFailureMessage)
            }
        }
    }

    func showInFinder(_ path: String) {
        let opener = opener
        Task { @MainActor [weak self] in
            let result = await SystemActions.openPaths(
                [path], withApplication: ApplicationPaths.finderAppPath, opener: opener)
            if !result.ok {
                self?.notice(
                    ActionNoticeText.finderFailureTitle,
                    ActionNoticeText.finderFailureMessage(count: 1, detail: result.error))
            }
        }
    }

    /// `editPathInTextEditor`: the panel can show an item that is not in the file list, so nothing is looked up.
    func edit(_ path: String) {
        let editor = host.preferences.defaultTextEditor
        Task { @MainActor [weak self] in
            await self?.openPaths([path], app: (editor.appPath, editor.appName))
        }
    }

    // MARK: Open With

    /// `openPathsWithApplication`.
    private func openPaths(_ paths: [String], app: (path: String, name: String)) async {
        host.onFolderUsed?()
        let result = await SystemActions.openPaths(paths, withApplication: app.path, opener: opener)
        if !result.ok {
            notice(
                ActionNoticeText.openFailureTitle(app.name),
                ActionNoticeText.openFailureMessage(
                    count: paths.count, appName: app.name, detail: result.error ?? "\(app.name) didn’t answer."))
        }
    }

    private func chosenApp(_ action: OpenWithAction) async -> (path: String, name: String)? {
        switch action {
        case .application(_, _, let appPath, let appName, _): return (appPath, appName)
        case .other: return await pickApplication(host.window)
        }
    }

    private func isAlways(_ action: OpenWithAction) -> Bool {
        switch action {
        case .application(_, _, _, _, let always), .other(_, _, _, let always): always
        }
    }

    /// `runContextSubmenuAction`: opens the items in the app chosen; Always Open With asks first.
    func runOpenWith(_ action: OpenWithAction, paths: [String], kind: OpenWithKind?) {
        Task { @MainActor [weak self] in
            guard let self, !paths.isEmpty, let app = await self.chosenApp(action) else { return }
            if self.isAlways(action), let kind, !kind.isFolder {
                await self.alwaysOpenWith(app, kind: kind, paths: paths)
            } else {
                await self.openPaths(paths, app: app)
            }
        }
    }

    /// `changeDefaultApp`: the app chosen becomes the kind's app, once asked; nothing is opened.
    func changeDefaultApp(_ action: OpenWithAction, kind: OpenWithKind?) {
        guard let kind, !kind.isFolder else { return }
        Task { @MainActor [weak self] in
            guard let self, let app = await self.chosenApp(action) else { return }
            await self.alwaysOpenWith(app, kind: kind, paths: [])
        }
    }

    private func alwaysOpenWith(_ app: (path: String, name: String), kind: OpenWithKind, paths: [String]) async {
        guard await confirmAlways(app.name, kind.name) else { return }
        let result = await setDefaultApplication(app.path, kind.contentType)
        guard result.ok else {
            notice(
                "Couldn’t Change the App",
                "\(kind.name.map { "\($0) files" } ?? "These files") still open in the app they opened in before. \(result.error ?? "macOS refused the change.")"
            )
            return
        }
        onLookupsForgotten()
        if !paths.isEmpty { await openPaths(paths, app: app) }
    }
}
