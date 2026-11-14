// Window ▸ Workspaces: a window saved by name, and opened again
import AppKit
import FTFileSystem
import FTFoundation

extension ExplorerWindows {
    /// The workspaces kept, in the menu's order.
    var workspaces: [Workspace] { store.preferences().workspaces }

    /// Opens the workspace `id` as it was saved, in a new window, or in place of `tab`'s window (the menu's item with
    /// ⌥). A window whose tabs a sheet or a dialog holds isn't replaced.
    func openWorkspace(id: String, inPlaceOf tab: MainWindowController? = nil) {
        let kept = workspaces
        guard let index = Workspaces.index(id: id, in: kept) else { return }
        if let tab, tab.group?.isBlocked ?? true {
            NSSound.beep()
            return
        }
        var workspace = kept[index]
        let replaced = withGoneFoldersReplaced(workspace.session)
        workspace.session = replaced.session
        var opened: ExplorerTabGroup?
        opened = controller.openWorkspace(workspace, replacing: tab?.group?.windowID) { [weak self] in
            guard let self, replaced.tabs > 0, store.preferences().notificationsEnabled else { return }
            showNotice(.workspaceFoldersGone(tabs: replaced.tabs), opened?.selected?.window)
        }
    }

    /// Workspace 1 to 5: the workspace at `slot` in the list, in a window of its own or in place of `tab`'s. Nothing
    /// for a slot with none.
    func openWorkspace(slot: Int, inPlaceOf tab: MainWindowController? = nil) {
        let kept = workspaces
        guard kept.indices.contains(slot) else { return }
        openWorkspace(id: kept[slot].id, inPlaceOf: tab)
    }

    /// The session with each folder that is gone shown as the nearest folder above it that is there (Home when none
    /// is), and how many tabs had one. A folder whose disk doesn't answer in time is kept: its tab finds its way when
    /// it is shown.
    private func withGoneFoldersReplaced(_ session: WindowSession) -> (session: WindowSession, tabs: Int) {
        let folders = Workspaces.folders(of: session)
        let kept = ScreenGeometry.keepsWaitingTabs(folders)
        let gone = Set(zip(folders, kept).filter { !$0.1 }.map(\.0))
        let home = home
        return Workspaces.replacingGoneFolders(session, gone: gone) { path in
            ExplorerTabs.pathAndAncestors(path).dropFirst().first { ScreenGeometry.isFolder($0) } ?? home
        }
    }

    // MARK: Saving

    /// Save Window as Workspace…: a name is asked (the workspace the window came from, or its front tab's folder, to
    /// begin with), and the window's tabs, panels and size are kept under it. A name another workspace has asks
    /// before replacing it. The window is known by the workspace from then on.
    func saveWorkspace(from tab: MainWindowController) {
        guard let group = tab.group, let window = tab.window, !group.isBlocked else { return }
        group.saveSession()
        guard let snapshot = controller.workspaceSnapshot(of: group.windowID) else { return }
        let linked = group.workspace
        let kept = workspaces
        let slot = linked.flatMap { Workspaces.index(id: $0.id, in: kept) } ?? kept.count
        let prompt = NamePrompt(
            title: "Save Window as Workspace",
            message: WorkspaceText.saveMessage(snapshot.session, key: workspaceKey(slot: slot)),
            label: "Workspace name", submitLabel: "Save", initialName: linked?.name ?? tab.tabDescription.label)
        Task { @MainActor [weak self, weak tab] in
            var chosen: String?
            await InWindowAlerts.askName(prompt, in: window) { typed in
                chosen = Workspaces.cleanName(typed)
                return .close
            }
            guard let self, let tab, let name = chosen, !name.isEmpty else { return }
            let current = workspaces
            let existing = Workspaces.index(named: name, in: current)
            if let existing, current[existing].id != linked?.id {
                let question = WriteQuestion(
                    title: "Replace \u{201C}\(current[existing].name)\u{201D}?",
                    message:
                        "A workspace with this name is kept already. Its tabs are replaced by this window\u{2019}s.",
                    confirmLabel: "Replace", destructive: false, cancelIsDefault: false)
                guard await InWindowAlerts.confirm(question, in: window) else { return }
            } else if existing == nil, current.count >= Workspaces.limit {
                tab.showNotice(title: WorkspaceText.limitTitle, message: WorkspaceText.limitMessage)
                return
            }
            // Under a new name it is a new workspace, and the one the window came from stays as it was.
            let id = existing.map { current[$0].id } ?? Workspaces.newID()
            let saved = Workspace(id: id, name: name, bounds: snapshot.bounds, session: snapshot.session)
            tab.updatePreferences { $0.workspaces = Workspaces.saving(saved, in: $0.workspaces) }
            controller.setWorkspace(id, of: group.windowID)
            group.reportMenuStates()
        }
    }

    /// Update "Name": the window's tabs, panels and size saved over the workspace it came from.
    func updateWorkspace(from tab: MainWindowController) {
        guard let group = tab.group, !group.isBlocked, let linked = group.workspace else { return }
        group.saveSession()
        guard let snapshot = controller.workspaceSnapshot(of: group.windowID) else { return }
        tab.updatePreferences { preferences in
            guard let at = Workspaces.index(id: linked.id, in: preferences.workspaces) else { return }
            let kept = preferences.workspaces[at]
            preferences.workspaces[at] = Workspace(
                id: kept.id, name: kept.name, bounds: snapshot.bounds, session: snapshot.session)
        }
    }

    /// The key that opens the workspace at `slot`, as the menu shows it; nil past the keyed ones, or with no key.
    private func workspaceKey(slot: Int) -> String? {
        guard Workspaces.slotCommands.indices.contains(slot) else { return nil }
        let bindings = ShortcutCommands.resolve(store.preferences().shortcutOverrides).bindings
        return Shortcuts.menuShortcut(bindings[Workspaces.slotCommands[slot]] ?? []).map(ShortcutLabels.format)
    }
}

/// What the workspaces say.
enum WorkspaceText {
    /// Under Save Window as Workspace's title: what is kept, and the key that opens it.
    static func saveMessage(_ session: WindowSession, key: String?) -> String {
        let summary = Workspaces.summary(session) + "."
        guard let key else { return summary }
        return summary + " \(key) opens it."
    }

    static let limitTitle = "No more workspaces can be saved"
    static let limitMessage =
        "Up to \(Workspaces.limit) are kept. Remove one in Settings \u{203A} Browsing to save this window."
}
