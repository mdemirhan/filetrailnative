// Port of apps/desktop/src/renderer/lib/explorerPaneFocus.ts
import Foundation

public enum ExplorerPaneFocus {
    /// `resolveExplorerPaneRestoreTarget`: where the keyboard goes back to when no pane has it: the explicit target, else
    /// the pane that had it last, else the file list, else the tree.
    public static func restoreTarget(
        preferred: FocusedPane?, lastFocused: FocusedPane?, hasTreePane: Bool, hasContentPane: Bool
    ) -> FocusedPane? {
        let candidates: [FocusedPane?] = [
            preferred, lastFocused, hasContentPane ? .content : nil, hasTreePane ? .tree : nil,
        ]
        for candidate in candidates {
            if candidate == .tree, hasTreePane { return .tree }
            if candidate == .content, hasContentPane { return .content }
        }
        return nil
    }
}
