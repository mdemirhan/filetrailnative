import AppKit
import FTFoundation
@preconcurrency import Quartz

extension MainWindowController {
    /// The notifications of the tab's window.
    var notifications: NotificationOverlay? { NotificationOverlay.overlay(for: window) }

    /// Puts the right-click menus, the notifications and the progress card, and Space for Quick Look on the tab.
    func installMenusAndNotifications() {
        contextMenus.install()
        contextMenus.clipboardSourcePaths = { [weak self] in
            self?.services.clipboard.contents.sourcePaths ?? []
        }
        _ = NotificationOverlay.install(
            in: workspace,
            bars: { [weak self] in
                guard let shell = self?.content.contentShell else { return [] }
                return [shell.pathBarRow] + (shell.infoRow.isOpen ? [shell.infoRow] : [])
            },
            isEnabled: { [weak self] in self?.preferences.notificationsEnabled ?? true })
        notifications?.progress.currentPath = { [weak self] in self?.folderPath ?? "" }
        guard let window else { return }
        WindowEventRouting.add(window) { [weak self] event in self?.handleQuickLookKey(event) ?? false }
    }

    /// "Show notifications" changed: those showing go when it is off.
    func notificationsSettingChanged() {
        notifications?.notificationsSettingChanged()
    }

    // MARK: Quick Look

    /// Space, while it is Quick Look's key, previews the selected item while the file list has the keyboard (`quickLook`
    /// in the key table), unless a filter is being typed: then Space is part of its text ("my doc") until Esc ends it,
    /// and the list takes it. A pinned filter leaves Space to Quick Look. Any other key chosen for it goes through the
    /// list's keys.
    private func handleQuickLookKey(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.keyCode == 49,
            event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
            ShortcutCommands.resolve(preferences.shortcutOverrides).commandByShortcut["Space"] == .quickLookSelection,
            window?.attachedSheet == nil, DialogScrim.front(in: window) == nil, !(window?.firstResponder is NSText),
            focusedPane == .content,
            !content.selection.isEmpty,
            !content.listFilter.isActive || content.pinnedFilter != nil
        else { return false }
        quickLookSelection()
        return true
    }

    /// `quickLookSelection`: the lead item of the selection, or the selected item.
    func quickLookSelection() {
        let selection = content.selection
        guard let path = selection.leadPath ?? selection.paths.first else { return }
        quickLook(path: path)
    }

    func quickLook(path: String) {
        if let showQuickLook {
            showQuickLook(path)
            return
        }
        let content = content
        QuickLookController.shared.toggle(path, from: window) { path in
            QuickLookItemFrame.picture(of: path, entries: content.entries, in: content.view)
        }
    }

    override nonisolated func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override nonisolated func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = QuickLookController.shared
            panel.delegate = QuickLookController.shared
        }
    }

    override nonisolated func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { QuickLookController.shared.ended() }
    }
}
