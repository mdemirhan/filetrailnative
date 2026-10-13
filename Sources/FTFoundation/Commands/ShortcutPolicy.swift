// Port of apps/desktop/src/renderer/lib/shortcutPolicy.ts
import Foundation

/// Which view fills the window.
public enum MainView: String, Sendable, Hashable, Codable {
    case explorer, help, settings
}

public enum FocusedPane: String, Sendable, Hashable, Codable {
    case tree, content
}

public enum SelectedTreeTargetKind: String, Sendable, Hashable, Codable {
    case filesystemFolder, favorite, favoritesRoot
}

/// What decides whether a command or a key can act now.
public struct ShortcutContext: Equatable, Sendable {
    public var actionNoticeOpen: Bool
    public var copyPasteModalOpen: Bool
    public var focusedPane: FocusedPane?
    public var locationSheetOpen: Bool
    public var mainView: MainView
    public var selectedTreeTargetKind: SelectedTreeTargetKind?

    public init(
        actionNoticeOpen: Bool = false, copyPasteModalOpen: Bool = false, focusedPane: FocusedPane? = nil,
        locationSheetOpen: Bool = false, mainView: MainView = .explorer,
        selectedTreeTargetKind: SelectedTreeTargetKind? = nil
    ) {
        self.actionNoticeOpen = actionNoticeOpen
        self.copyPasteModalOpen = copyPasteModalOpen
        self.focusedPane = focusedPane
        self.locationSheetOpen = locationSheetOpen
        self.mainView = mainView
        self.selectedTreeTargetKind = selectedTreeTargetKind
    }
}

/// Which commands and keys act where. App-level view toggles such as `?` and `Cmd+,` are handled outside the explorer
/// registry. This only classifies renderer commands and raw explorer shortcuts that dispatch through the central key
/// binding table. The tree-focus bucket tables are in TreeFocusBuckets.swift.
public enum ShortcutPolicy {
    private static let editCommands: Set<RendererCommand> = [.editCut, .editCopy, .editPaste, .editSelectAll]

    /// Content commands that also work from the tree, on its selected folder and never on a selection left behind in
    /// the file list. Paste goes into that folder; copy and cut take the folder itself.
    private static let treeSafeRendererCommands: Set<RendererCommand> = [
        .openSelection, .openSelectionInNewTab, .openSelectionInNewWindow, .openInTerminal, .copyPath, .copySelection,
        .cutSelection, .pasteSelection,
    ]

    /// A favorite is a pointer to a folder, not something to copy or move: these act on folders of the tree only, as
    /// the favorite's right-click menu does.
    private static let treeFolderOnlyCommands: Set<String> = ["copySelection", "cutSelection"]

    /// Help opens from anywhere a menu can be used, including the Help page itself.
    private static let helpCommands: Set<RendererCommand> = [.openHelp, .openKeyboardShortcuts]

    private static let treeSafeRawShortcuts: Set<RawExplorerShortcutID> = [
        .copyPath, .openInTerminal, .copySelection, .cutSelection, .pasteSelection,
    ]

    /// `canHandleRendererCommand`.
    public static func canHandle(_ command: RendererCommand, _ context: ShortcutContext) -> Bool {
        if editCommands.contains(command) {
            return true
        }
        if command == .openSettings {
            return !context.locationSheetOpen && !context.actionNoticeOpen
        }
        if context.actionNoticeOpen || context.locationSheetOpen || context.copyPasteModalOpen {
            return false
        }
        // ⌘W closes the tab, or the window, from the Help page as well.
        if command == .closeTab || helpCommands.contains(command) {
            return true
        }
        // Like Finder, Paste goes into the folder on screen even when no pane has focus (for example right after
        // opening an empty folder).
        if command == .pasteSelection, context.focusedPane == nil {
            return context.mainView == .explorer
        }
        if treeFocusBucket(of: command) == .contentOnly {
            switch context.focusedPane {
            case .content:
                return context.mainView == .explorer
            case .tree:
                if treeSafeRendererCommands.contains(command) {
                    return isSafeTreeTarget(command.rawValue, context.selectedTreeTargetKind)
                        && context.mainView == .explorer
                }
                return false
            case nil:
                return false
            }
        }
        return context.mainView == .explorer
    }

    /// `canHandleExplorerKeyboardShortcuts`.
    public static func canHandleExplorerKeyboardShortcuts(_ context: ShortcutContext) -> Bool {
        context.mainView == .explorer && !context.actionNoticeOpen && !context.copyPasteModalOpen
            && !context.locationSheetOpen
    }

    /// `canHandleRawExplorerShortcut`.
    public static func canHandleRaw(_ shortcut: RawExplorerShortcutID, _ context: ShortcutContext) -> Bool {
        if !canHandleExplorerKeyboardShortcuts(context) {
            return false
        }
        if context.focusedPane != .tree {
            return true
        }
        if treeFocusBucket(of: shortcut) != .contentOnly {
            return true
        }
        return treeSafeRawShortcuts.contains(shortcut)
            && isSafeTreeTarget(shortcut.rawValue, context.selectedTreeTargetKind)
    }

    private static func isSafeTreeTarget(_ name: String, _ kind: SelectedTreeTargetKind?) -> Bool {
        if treeFolderOnlyCommands.contains(name) {
            return kind == .filesystemFolder
        }
        return kind == .filesystemFolder || kind == .favorite
    }

    // MARK: Context menus

    /// The command whose shortcut a context-menu item shows (`CONTEXT_MENU_SHORTCUT_COMMANDS`), by the item's id.
    public static let contextMenuShortcutCommands: [String: ShortcutCommandID] = [
        "open": .openSelection, "openInNewTab": .openSelectionInNewTab, "openInNewWindow": .openSelectionInNewWindow,
        "quickLook": .quickLookSelection, "showInfo": .toggleInfoPanel, "calculateSize": .calculateSize,
        "revealInFolder": .revealInFolder, "edit": .editSelection, "cut": .cut, "copy": .copy, "paste": .paste,
        "move": .moveSelection, "rename": .renameSelection, "duplicate": .duplicateSelection, "newFolder": .newFolder,
        "terminal": .openInTerminal, "copyPath": .copyPath, "rootTreeHere": .rootTreeAtSelection,
        "trash": .trashSelection,
    ]

    /// `getContextMenuShortcutLabel`: the shortcut shown beside a context-menu item, only where pressing it now would
    /// do what the item does.
    public static func contextMenuShortcutLabel(
        actionID: String, context: ShortcutContext, shortcuts: ShortcutDisplay = .defaults
    ) -> String? {
        guard let command = contextMenuShortcutCommands[actionID] else { return nil }
        return isContextMenuShortcutLive(actionID, context) ? shortcuts.label(command) : nil
    }

    private static func isContextMenuShortcutLive(_ action: String, _ context: ShortcutContext) -> Bool {
        switch action {
        case "open":
            return canHandle(.openSelection, context)
        case "openInNewTab":
            // As with Paste: a tree or favorite menu opens the right-clicked folder, the key the selected one.
            return context.focusedPane != .tree && canHandle(.openSelectionInNewTab, context)
        case "openInNewWindow":
            return context.focusedPane != .tree && canHandle(.openSelectionInNewWindow, context)
        case "quickLook":
            return canHandle(.quickLookSelection, context)
        case "showInfo":
            return canHandle(.toggleInfoPanel, context)
        case "calculateSize":
            // As with Paste: a tree or favorite menu sizes the right-clicked folder, the key the selected one.
            return context.focusedPane != .tree && canHandle(.calculateSize, context)
        case "revealInFolder":
            return canHandle(.revealInFolder, context)
        case "edit":
            return canHandle(.editSelection, context)
        case "cut":
            return canHandleRaw(.cutSelection, context)
        case "copy":
            return canHandleRaw(.copySelection, context)
        case "paste":
            // A tree or favorite menu pastes into the right-clicked folder, while Cmd+V from the tree pastes into
            // the selected one, so the badge would promise the wrong target.
            return context.focusedPane != .tree && canHandleRaw(.pasteSelection, context)
        case "move":
            return canHandleRaw(.moveSelection, context)
        case "rename":
            return canHandleRaw(.renameSelection, context)
        case "duplicate":
            return canHandleRaw(.duplicateSelection, context)
        case "newFolder":
            return canHandleRaw(.newFolder, context)
        case "terminal":
            return canHandle(.openInTerminal, context)
        case "copyPath":
            return canHandleRaw(.copyPath, context) || canHandle(.copyPath, context)
        case "rootTreeHere":
            return canHandle(.rootTreeAtSelection, context)
        case "trash":
            return canHandleRaw(.trashSelection, context)
        default:
            return false
        }
    }
}
