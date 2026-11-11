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
}
