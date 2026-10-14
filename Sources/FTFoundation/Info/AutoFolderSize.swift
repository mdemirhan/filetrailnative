// Port of getAutoFolderSizePath of apps/desktop/src/renderer/hooks/useAutoFolderSize.ts
import Foundation

public enum AutoFolderSize {
    /// How long a folder stays selected before it is measured (`AUTO_FOLDER_SIZE_DELAY_MS`).
    public static let delayMilliseconds = 500.0

    /// The folder the Info panel measures by itself: the one folder selected, when it is in the home folder.
    public static func path(
        infoPanelOpen: Bool, selectedPaths: [String], selected: (path: String, kind: EntryKind)?, homePath: String
    ) -> String? {
        guard infoPanelOpen, selectedPaths.count == 1, let selected else { return nil }
        guard selected.path == selectedPaths[0], selected.kind.isFolderSizeEligible else { return nil }
        var home = homePath
        while home.hasSuffix("/") { home.removeLast() }
        return !home.isEmpty && selected.path.hasPrefix(home + "/") ? selected.path : nil
    }
}
