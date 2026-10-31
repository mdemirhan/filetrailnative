// Port of apps/desktop/src/renderer/lib/shortcutTargets.ts
import Foundation

/// Which paths a command acts on, from which pane has the keyboard.
public enum ShortcutTargets {
    public struct Selection: Equatable, Sendable {
        public var focusedPane: FocusedPane?
        public var lastFocusedPane: FocusedPane?
        public var contextMenuPaths: [String]
        public var selectedContentPaths: [String]
        public var selectedTreePath: String?
        public var currentPath: String

        public init(
            focusedPane: FocusedPane? = nil, lastFocusedPane: FocusedPane? = nil, contextMenuPaths: [String] = [],
            selectedContentPaths: [String] = [], selectedTreePath: String? = nil, currentPath: String = ""
        ) {
            self.focusedPane = focusedPane
            self.lastFocusedPane = lastFocusedPane
            self.contextMenuPaths = contextMenuPaths
            self.selectedContentPaths = selectedContentPaths
            self.selectedTreePath = selectedTreePath
            self.currentPath = currentPath
        }
    }

    /// `resolveOpenInTerminalPaths`.
    public static func openInTerminalPaths(_ input: Selection) -> [String] {
        if !input.contextMenuPaths.isEmpty {
            return input.contextMenuPaths
        }
        let activePane = input.focusedPane ?? input.lastFocusedPane
        if activePane == .tree {
            if let tree = input.selectedTreePath, !tree.isEmpty {
                return [tree]
            }
            return input.currentPath.isEmpty ? [] : [input.currentPath]
        }
        if !input.selectedContentPaths.isEmpty {
            return input.selectedContentPaths
        }
        return input.currentPath.isEmpty ? [] : [input.currentPath]
    }

    private static func selectionPaths(_ input: Selection) -> [String] {
        if !input.contextMenuPaths.isEmpty {
            return input.contextMenuPaths
        }
        let activePane = input.focusedPane ?? input.lastFocusedPane
        if activePane == .tree {
            if let tree = input.selectedTreePath, !tree.isEmpty {
                return [tree]
            }
            return []
        }
        return input.selectedContentPaths
    }

    /// `resolveOpenSelectionPaths`.
    public static func openSelectionPaths(_ input: Selection) -> [String] {
        selectionPaths(input)
    }

    /// `resolveEditSelectionPaths`.
    public static func editSelectionPaths(_ input: Selection) -> [String] {
        selectionPaths(input)
    }

    public struct RootTreeInput: Equatable, Sendable {
        public var focusedPane: FocusedPane?
        public var lastFocusedPane: FocusedPane?
        public var contextMenuFolderPath: String?
        public var selectedContentFolderPath: String?
        public var selectedTreePath: String?
        public var currentPath: String

        public init(
            focusedPane: FocusedPane? = nil, lastFocusedPane: FocusedPane? = nil, contextMenuFolderPath: String? = nil,
            selectedContentFolderPath: String? = nil, selectedTreePath: String? = nil, currentPath: String = ""
        ) {
            self.focusedPane = focusedPane
            self.lastFocusedPane = lastFocusedPane
            self.contextMenuFolderPath = contextMenuFolderPath
            self.selectedContentFolderPath = selectedContentFolderPath
            self.selectedTreePath = selectedTreePath
            self.currentPath = currentPath
        }
    }

    /// `resolveRootTreeTargetPath`: the folder "Root Tree at Selected Folder" acts on: the folder selected in the
    /// focused pane, or the folder on screen when the selection is not a single folder.
    public static func rootTreeTargetPath(_ input: RootTreeInput) -> String? {
        if let menu = input.contextMenuFolderPath, !menu.isEmpty {
            return menu
        }
        let activePane = input.focusedPane ?? input.lastFocusedPane
        let selected = activePane == .tree ? input.selectedTreePath : input.selectedContentFolderPath
        if let selected, !selected.isEmpty {
            return selected
        }
        return input.currentPath.isEmpty ? nil : input.currentPath
    }
}
