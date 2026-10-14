// Port of sendCommand and the host callbacks of createApplicationMenuTemplate (apps/desktop/src/main/appMenu.ts)
import AppKit
import FTFoundation

/// Where an explorer command goes: the explorer window that has the keyboard, or the one in front while another
/// window (Settings) has it. `focused` says which of the two it is.
struct ExplorerCommandTarget {
    var handle: any ExplorerWindowHandle
    var focused: Bool
}

/// The target of every menu item of the application menu. A chosen item is sent to the explorer window it acts on, or
/// handled natively by the window that has the keyboard.
@MainActor
final class MenuCommandRouter: NSObject, NSMenuItemValidation {
    /// The explorer window a menu command goes to; see `ApplicationMenuSync.explorerFor`.
    var explorerFor: (NSWindow?) -> ExplorerCommandTarget? = { _ in nil }
    /// The window that has the keyboard.
    var focusedWindow: () -> NSWindow? = { NSApp.keyWindow }
    /// Whether a text field of the explorer window has the keyboard: the edit commands are then its own.
    var isTextEditing: (ExplorerCommandTarget) -> Bool = { _ in false }
    /// Asks the window that has the keyboard to do an edit command itself, through the responder chain.
    var performNativeEdit: (Selector, NSWindow) -> Void = { selector, _ in
        NSApp.sendAction(selector, to: nil, from: nil)
    }

    /// About and Settings are windows of their own; the host opens them when it provides these.
    var onOpenAbout: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    /// Help is a window too, opened from whichever window has the focus.
    var onOpenHelp: ((HelpTopicID?) -> Void)?
    /// Called after an item has sent its command. macOS flips a checkmark on its own when the item is chosen; the host
    /// puts back what the window last reported, so the marks only ever show what is really on.
    var onCommandSent: (() -> Void)?
    /// A command chosen with no explorer window open (`ApplicationMenu.commandsWithoutExplorerWindow`).
    var onCommandWithoutExplorerWindow: ((RendererCommand) -> Void)?
    /// New Window chosen while another window (Settings) has the keyboard: the host opens it beside the explorer window
    /// in front, which may not be able to take the command.
    var onNewWindowFromOtherWindow: (() -> Void)?

    /// The ids of the items the explorer window's state dims. AppKit asks `validateMenuItem` for each as it opens.
    private(set) var disabledItemIDs: Set<String> = []

    func setItem(_ id: String, enabled: Bool) {
        if enabled { disabledItemIDs.remove(id) } else { disabledItemIDs.insert(id) }
    }

    /// A new menu starts with every item on.
    func resetEnabled() { disabledItemIDs = [] }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let id = menuItem.identifier?.rawValue else { return true }
        return !disabledItemIDs.contains(id)
    }

    // MARK: Choosing

    /// The action of every item of the application menu.
    @objc func chooseMenuItem(_ sender: NSMenuItem) {
        choose(itemID: sender.identifier?.rawValue ?? "")
    }

    /// Carries out the item with this id, as a click on it does.
    func choose(itemID: String) {
        switch itemID {
        case ApplicationMenuBuilder.aboutItemID:
            if let onOpenAbout { onOpenAbout() } else { NSApp.orderFrontStandardAboutPanel(nil) }
        case ApplicationMenuBuilder.settingsItemID:
            if let onOpenSettings { onOpenSettings() } else { send(.openSettings, focusedWindow: focusedWindow()) }
        default:
            // Two items share a command: "toggleFavorite:add" and "undo:text" send the command before the colon.
            let name = itemID.split(separator: ":", maxSplits: 1).first.map(String.init) ?? itemID
            guard let command = RendererCommand(rawValue: name) else { return }
            send(command, focusedWindow: focusedWindow())
            onCommandSent?()
        }
    }

    /// `NATIVE_EDIT_COMMANDS`.
    static func nativeEditSelector(_ command: RendererCommand) -> Selector? {
        switch command {
        case .undo: Selector(("undo:"))
        case .redo: Selector(("redo:"))
        case .editCut: #selector(NSText.cut(_:))
        case .editCopy: #selector(NSText.copy(_:))
        case .editPaste: #selector(NSText.paste(_:))
        case .editSelectAll: #selector(NSResponder.selectAll(_:))
        default: nil
        }
    }

    /// `sendCommand`.
    func send(_ command: RendererCommand, focusedWindow focused: NSWindow?) {
        if command == .openHelp || command == .openKeyboardShortcuts, let onOpenHelp {
            onOpenHelp(command == .openKeyboardShortcuts ? .shortcuts : nil)
            return
        }
        // The menu is shared by every window. When another window (Settings) is focused, edit commands act on its
        // focused text field natively and explorer commands do not apply.
        let target = explorerFor(focused)
        if target == nil, ApplicationMenu.commandsWithoutExplorerWindow.contains(command) {
            onCommandWithoutExplorerWindow?(command)
            return
        }
        if let focused, !(target?.focused ?? false) {
            if let selector = Self.nativeEditSelector(command) {
                performNativeEdit(selector, focused)
            }
            // Only the explorer has tabs; ⌘W in any other window closes that window.
            if command == .closeTab {
                focused.performClose(nil)
            }
            if command == .newWindow {
                onNewWindowFromOtherWindow?()
            }
            return
        }
        guard let target else { return }
        // A text field of the explorer window has the keyboard: Cut, Copy, Paste, Undo and the like are its own.
        if isTextEditing(target), let selector = Self.nativeEditSelector(command),
            let window = target.handle.window ?? focused
        {
            performNativeEdit(selector, window)
            return
        }
        target.handle.perform(command)
    }
}
