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
    var confirmAlways: (_ appName: String, _ kindName: String?) -> Bool

    init(host: MainWindowController) {
        self.host = host
        notice = { [weak host] title, message in
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            alert.addButton(withTitle: "OK")
            if let window = host?.window {
                alert.beginSheetModal(for: window, completionHandler: nil)
            } else {
                alert.runModal()
            }
        }
        confirmAlways = { appName, kindName in
            let alert = NSAlert()
            alert.messageText =
                "Are you sure you want to change all similar documents to open with the application “\(appName)”?"
            alert.informativeText =
                kindName.map {
                    "This change will apply to every “\($0)” file, opened from File Trail, Finder or any other app."
                }
                ?? "This change will apply to every file of this kind, opened from File Trail, Finder or any other app."
            alert.addButton(withTitle: "Change All")
            alert.addButton(withTitle: "Cancel")
            return alert.runModal() == .alertFirstButtonReturn
        }
    }

    // MARK: Copy

    func copy(_ text: String, what: String) -> Bool {
        let board = NSPasteboard.general
        board.clearContents()
        guard board.setString(text, forType: .string) else {
            notice("Couldn’t Copy the \(what)", "File Trail couldn’t put it on the clipboard.")
            return false
        }
        return true
    }

    // MARK: Open

    func openExternally(_ path: String) {
        Task { @MainActor [weak self] in
            let result = await SystemActions.openPath(path)
            if !result.ok {
                self?.notice("Couldn’t Open It", result.error ?? "macOS didn’t open it.")
            }
        }
    }

    func openInTerminal(_ path: String) {
        let terminal = host.preferences.terminalApp
        Task { @MainActor [weak self] in
            let result = await SystemActions.openInTerminal(path: path, terminalApp: terminal)
            if !result.ok {
                self?.notice(
                    "Couldn’t Open in \(result.terminalName)",
                    "File Trail couldn’t open \(result.terminalName). \(result.error ?? "")")
            }
        }
    }

    func showInFinder(_ path: String) {
        Task { @MainActor [weak self] in
            let result = await SystemActions.openPaths([path], withApplication: ApplicationPaths.finderAppPath)
            if !result.ok { self?.notice("Couldn’t Show It in Finder", result.error ?? "") }
        }
    }

    func edit(_ path: String) {
        let editor = host.preferences.defaultTextEditor
        Task { @MainActor [weak self] in
            let result = await SystemActions.editInTextEditor(path: path, editor: editor)
            if !result.ok {
                self?.notice(
                    "Couldn’t Open in \(editor.appName)",
                    "File Trail couldn’t open it in \(editor.appName). \(result.error ?? "")")
            }
        }
    }

    // MARK: Open With

    private func openPaths(_ paths: [String], app: (path: String, name: String)) async {
        let result = await SystemActions.openPaths(paths, withApplication: app.path)
        if !result.ok {
            notice(
                "Couldn’t Open in \(app.name)",
                "File Trail couldn’t open \(paths.count == 1 ? "it" : "them") in \(app.name). \(result.error ?? "\(app.name) didn’t answer.")"
            )
        }
    }

    private func chosenApp(_ action: OpenWithAction) async -> (path: String, name: String)? {
        switch action {
        case .application(_, _, let appPath, let appName, _): return (appPath, appName)
        case .other:
            let choice = await SystemPickers.pickApplication(window: host.window)
            guard !choice.canceled, let path = choice.appPath, let name = choice.appName else { return nil }
            return (path, name)
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
        guard confirmAlways(app.name, kind.name) else { return }
        let result = await SystemActions.setDefaultApplication(applicationPath: app.path, contentType: kind.contentType)
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
