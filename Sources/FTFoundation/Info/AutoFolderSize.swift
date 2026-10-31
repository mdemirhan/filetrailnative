// Port of getAutoFolderSizePath of apps/desktop/src/renderer/hooks/useAutoFolderSize.ts
import Foundation

public enum AutoFolderSize {
    /// How long a folder stays selected, or in the Info panel, before it is measured (`AUTO_FOLDER_SIZE_DELAY_MS`). The
    /// Info panel and the Info Row both wait it out: they share one measurement.
    public static let delayMilliseconds = 500.0

    /// The folder the Info panel or the Info Row measures by itself: the item Show Info put in the panel (`showInfoPath`,
    /// once the panel shows it as `infoItem`), or else the one item selected, when it is a folder in the home folder or a
    /// bundle anywhere. The row shows the selection, never Show Info's item; with both open, the panel's item is measured.
    public static func path(
        infoPanelOpen: Bool, infoRowOpen: Bool = false, selectedPaths: [String],
        selected: (path: String, kind: EntryKind)?, showInfoPath: String? = nil,
        infoItem: (path: String, kind: EntryKind)? = nil, homePath: String
    ) -> String? {
        guard infoPanelOpen || infoRowOpen else { return nil }
        let item: (path: String, kind: EntryKind)?
        if infoPanelOpen, let showInfoPath {
            item = infoItem?.path == showInfoPath ? infoItem : nil
        } else {
            item = selectedPaths.count == 1 && selected?.path == selectedPaths[0] ? selected : nil
        }
        guard let item, item.kind.isFolderSizeEligible else { return nil }
        if item.kind == .bundle { return item.path }
        var home = homePath
        while home.hasSuffix("/") { home.removeLast() }
        return !home.isEmpty && item.path.hasPrefix(home + "/") ? item.path : nil
    }
}
